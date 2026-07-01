#!/usr/bin/env bash
#
# Functions to manage the "Docker host" LXC containers on Proxmox.
#
# The pattern these containers follow:
#   - docker installed and running
#   - a single docker-compose file at /opt/docker-compose.yml covering all apps
#   - each app's files live under /opt/<app>/ (e.g. /opt/radarr/config)
#
# Not every container uses docker; those are reported as "not applicable" and
# skipped, never modified.
#
# Source this file to get the functions in your shell:
#   source /path/to/pve/docker_functions.sh
#
# Depends on _resolve_ctid from container_functions.sh (auto-sourced below).

_DOCKER_FUNCS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=container_functions.sh
[[ $(type -t _resolve_ctid) == function ]] \
  || source "${_DOCKER_FUNCS_DIR}/container_functions.sh"

# PVE tags that drive eligibility for the bulk helpers:
#   DOCKER_TAG          allowlist — only CTs carrying it are considered
#   DOCKER_PROTECT_TAG  denylist  — CTs carrying it are NEVER acted on
#   DOCKER_STANDARD_TAG marker    — set by convert_to_standard once a CT has
#                                   been moved to the standard layout
#                                   (/opt/docker-compose.yml + /opt/<app>/);
#                                   redeploy_lxc requires it before it will run.
# Tag a CT with e.g.:  pct set <id> --tags docker
# (note: --tags REPLACES the whole list, so include all: --tags docker;noauto)
DOCKER_TAG="${DOCKER_TAG:-docker}"
DOCKER_PROTECT_TAG="${DOCKER_PROTECT_TAG:-noauto}"
DOCKER_STANDARD_TAG="${DOCKER_STANDARD_TAG:-docker-standardised}"

# Throwaway image used by migrate_volumes_to_binds to read a docker volume and
# copy/tar its contents (mounted read-only). Any tiny image with cp+tar works.
DOCKER_MIGRATE_IMAGE="${DOCKER_MIGRATE_IMAGE:-alpine}"

# True if the container carries the protect (denylist) tag.
# Usage: _ct_is_protected <CTID>
_ct_is_protected() { _ct_has_tag "$1" "$DOCKER_PROTECT_TAG"; }

# True if the container has docker installed and the daemon is running.
# Usage: ct_has_docker <CTID-or-name>
ct_has_docker() {
  local ctid
  ctid=$(_resolve_ctid "${1:-}") || return 2
  pct exec "$ctid" -- bash -c 'command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1'
}

# Print the absolute path(s) of every compose file backing a RUNNING compose
# project in the container, discovered from container labels. One path per line.
# Falls back to a filesystem search if nothing is running.
# Usage: find_compose <CTID-or-name>
find_compose() {
  local ctid
  ctid=$(_resolve_ctid "${1:-}") || return 2

  local found
  found=$(pct exec "$ctid" -- bash -c '
    docker ps --format "{{.ID}}" 2>/dev/null | while read -r id; do
      wd=$(docker inspect "$id" \
        --format "{{ index .Config.Labels \"com.docker.compose.project.working_dir\" }}" 2>/dev/null)
      cf=$(docker inspect "$id" \
        --format "{{ index .Config.Labels \"com.docker.compose.project.config_files\" }}" 2>/dev/null)
      [ -z "$cf" ] && continue
      IFS=","
      for f in $cf; do
        case "$f" in
          /*) echo "$f" ;;
          *)  echo "${wd%/}/$f" ;;
        esac
      done
    done | sort -u
  ')

  # Fallback: nothing running with compose labels, so search common locations.
  if [[ -z "$found" ]]; then
    found=$(pct exec "$ctid" -- bash -c '
      find /opt /root /home -maxdepth 3 -type f \
        \( -name "docker-compose.y*ml" -o -name "compose.y*ml" \) \
        2>/dev/null | sort -u
    ')
  fi

  [[ -n "$found" ]] || return 1
  printf '%s\n' "$found"
}

# Validate whether a container follows the pattern.
# Conformant = every compose file lives at /opt/<project>/docker-compose.yml.
# Prints a verdict and returns:
#   0  conformant   (docker running, all compose files namespaced under /opt)
#   1  needs work   (docker running, but compose missing/elsewhere)
#   2  n/a          (no docker — skip this container)
# Usage: validate_docker_pattern <CTID-or-name>
validate_docker_pattern() {
  local ctid
  ctid=$(_resolve_ctid "${1:-}") || return 2

  if ! ct_has_docker "$ctid"; then
    echo "CT ${ctid}: no docker — not applicable, skipping."
    return 2
  fi

  local files count nonconf
  if ! files=$(find_compose "$ctid"); then
    echo "CT ${ctid}: docker running but NO compose file found — needs work."
    return 1
  fi
  count=$(printf '%s\n' "$files" | grep -c .)
  nonconf=$(printf '%s\n' "$files" | grep -vE '^/opt/docker-compose\.yml$' || true)

  if [[ -z "$nonconf" ]]; then
    echo "CT ${ctid}: ✔ conformant (compose at /opt/docker-compose.yml)."
    return 0
  fi

  echo "CT ${ctid}: needs work — ${count} compose file(s), non-conformant:"
  printf '  %s\n' $nonconf
  return 1
}

# Run validate_docker_pattern across every CT tagged '${DOCKER_TAG}',
# skipping those also tagged with the protect tag.
# Usage: validate_all_docker
validate_all_docker() {
  local ctid
  for ctid in $(pct list | awk 'NR>1 {print $1}'); do
    _ct_has_tag "$ctid" "$DOCKER_TAG" || continue
    if _ct_is_protected "$ctid"; then
      echo "CT ${ctid}: protected (tag '${DOCKER_PROTECT_TAG}') — skipping."
      continue
    fi
    validate_docker_pattern "$ctid"
  done
}

# Run convert_to_standard across every eligible CT
# (tagged '${DOCKER_TAG}', not protected). DRY-RUN by default; --apply to commit.
# Usage: convert_all_docker [--apply]
convert_all_docker() {
  local ctid
  for ctid in $(pct list | awk 'NR>1 {print $1}'); do
    _ct_has_tag "$ctid" "$DOCKER_TAG" || continue
    if _ct_is_protected "$ctid"; then
      echo "CT ${ctid}: protected (tag '${DOCKER_PROTECT_TAG}') — skipping."
      continue
    fi
    convert_to_standard "$ctid" "$@"
  done
}

# Bring up all apps defined in /opt/docker-compose.yml.
# Usage: compose_up_all <CTID-or-name>
compose_up_all() {
  local ctid
  ctid=$(_resolve_ctid "${1:-}") || return 2
  ct_has_docker "$ctid" || { echo "CT ${ctid}: no docker."; return 2; }
  pct exec "$ctid" -- bash -c '
    f=/opt/docker-compose.yml
    if [ ! -f "$f" ]; then
      echo "no /opt/docker-compose.yml found" >&2
      exit 1
    fi
    echo "compose up: /opt"
    cd /opt && docker-compose up -d
  ' </dev/null
}

# Report docker *volume* mounts (named or anonymous) used by running containers.
# These live in docker's storage, not on the project tree, so they are NOT
# carried across by convert_to_standard / a redeploy — data in them is lost
# unless migrated by hand. Bind mounts are excluded (they travel with the dir).
# Prints a verdict and returns:
#   0  no volumes  (safe to redeploy)
#   1  volumes in use  (review before redeploying)
#   2  n/a          (no docker — skip this container)
# Usage: check_volumes <CTID-or-name>
check_volumes() {
  local ctid
  ctid=$(_resolve_ctid "${1:-}") || return 2

  if ! ct_has_docker "$ctid"; then
    echo "CT ${ctid}: no docker — not applicable, skipping."
    return 2
  fi

  # container<TAB>project<TAB>volume<TAB>destination, one line per volume mount
  local vols
  vols=$(pct exec "$ctid" -- bash -c '
    docker ps --format "{{.ID}}" 2>/dev/null | while read -r id; do
      cname=$(docker inspect "$id" --format "{{.Name}}" 2>/dev/null | sed "s#^/##")
      proj=$(docker inspect "$id" --format "{{ index .Config.Labels \"com.docker.compose.project\" }}" 2>/dev/null)
      docker inspect "$id" --format "{{range .Mounts}}{{if eq .Type \"volume\"}}${cname}|{{if .Name}}{{.Name}}{{else}}<anon>{{end}}|{{.Destination}}|${proj}{{\"\n\"}}{{end}}{{end}}" 2>/dev/null
    done | sort -u
  ' </dev/null)

  if [[ -z "$vols" ]]; then
    echo "CT ${ctid}: ✔ no docker volumes in use — safe to redeploy."
    return 0
  fi

  local count
  count=$(printf '%s\n' "$vols" | grep -c .)
  echo "CT ${ctid}: ⚠ ${count} docker volume(s) in use — data will NOT survive a redeploy:"
  local cname vname dest proj note
  while IFS='|' read -r cname vname dest proj; do
    [[ -z "$cname" ]] && continue
    note=""
    # 64-char hex volume name == anonymous volume
    [[ "$vname" =~ ^[0-9a-f]{64}$ || "$vname" == "<anon>" ]] && note="  (anonymous)"
    printf '  %-20s %s -> %s%s\n' "${proj:-?}/${cname}" "$vname" "$dest" "$note"
  done <<< "$vols"
  return 1
}

# Run check_volumes across every CT tagged '${DOCKER_TAG}', skipping protected.
# Usage: check_all_volumes
check_all_volumes() {
  local ctid
  for ctid in $(pct list | awk 'NR>1 {print $1}'); do
    _ct_has_tag "$ctid" "$DOCKER_TAG" || continue
    if _ct_is_protected "$ctid"; then
      echo "CT ${ctid}: protected (tag '${DOCKER_PROTECT_TAG}') — skipping."
      continue
    fi
    check_volumes "$ctid"
  done
}

# Appended after a `tar` invocation inside a _ct_step command string, so a
# non-fatal tar warning (exit 1, e.g. "file changed as we read it" on a live
# file) doesn't fail the whole step. Real tar errors (exit >=2) still fail it.
_TAR_GUARD='; rc=$?; if [ "$rc" -gt 1 ]; then exit "$rc"; elif [ "$rc" -eq 1 ]; then echo "  note: tar reported changed files during archive (likely a live file) -- continuing" >&2; fi'

# Print a step, then either run it in the container (apply) or just show it.
# Returns non-zero if the executed command fails.
# Usage: _ct_step <ctid> <apply 0|1> <description> <command>
_ct_step() {
  local ctid="$1" apply="$2" desc="$3" cmd="$4"
  if [[ "$apply" -eq 1 ]]; then
    echo "  + ${desc}"
    if ! pct exec "$ctid" -- bash -c "$cmd" </dev/null; then
      echo "  ! FAILED: ${desc}" >&2
      return 1
    fi
  else
    echo "  [dry-run] ${desc}"
    echo "        \$ ${cmd}"
  fi
}

# Escape a string for safe use on the *match* side of a sed s### expression
# (delimiter '#'). Over-escapes: anything not alnum/_/- is backslash-protected.
# Usage: _sed_escape_re <string>
_sed_escape_re() { printf '%s' "$1" | sed 's/[^[:alnum:]_-]/\\&/g'; }

# Escape a string for safe use on the *replacement* side of a sed s### (delim
# '#'): backslash, ampersand and the delimiter itself. Usage: _sed_escape_repl
_sed_escape_repl() { printf '%s' "$1" | sed 's/[&\\#]/\\&/g'; }

# Scan a compose file (inside a container) for long-form YAML volume/bind blocks
# whose `source:` value matches any of the given strings.  Long-form blocks
# (type: bind/volume + source: + target:) cannot be rewritten by the short-form
# sed patterns used by convert_to_standard and migrate_volumes_to_binds.
# Prints each matching source: line from the file. Returns 1 if any match, 0 if clear.
# Usage: _compose_longform_sources <ctid> <cf_path_in_ct> <val>...
_compose_longform_sources() {
  local ctid="$1" cf="$2"; shift 2
  [[ $# -eq 0 ]] && return 0
  local found=0 val esc hits
  for val in "$@"; do
    esc=$(_sed_escape_re "$val")
    hits=$(pct exec "$ctid" -- grep -E \
      "^[[:space:]]+source:[[:space:]]+(\"${esc}\"|'${esc}'|${esc})[[:space:]]*$" \
      "$cf" </dev/null 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
      printf '%s\n' "$hits"
      found=1
    fi
  done
  return $found
}

# Convert a container to the standard layout:
#   /opt/docker-compose.yml  — single compose file covering all apps on the CT
#   /opt/<project>/          — each app's config binds live here
#   /opt/volumes/            — persistent data centralised here
#   External (shared) bind mounts are reported and left in place.
#
# For each running compose project it: backs up the compose file + working dir,
# `compose down`, moves the compose file and config binds under /opt/<app>, and
# centralises persistent-data binds under /opt/volumes — rewriting each compose
# source to match — then `compose up -d` from the new location. Data binds are:
#   - any <dir>/volumes/<name> bind (as produced by migrate_volumes_to_binds),
#     kept as /opt/volumes/<name> (the name is already project-prefixed);
#   - any other project-local bind whose top-level dir is NOT in the keep list
#     (see DOCKER_STANDARD_KEEP_BINDS / --keep), placed at
#     /opt/volumes/<name>_<rel> — prefixed with the project name to avoid
#     collisions in the shared tree.
# Config binds (top-level dir in the keep list, e.g. certs/config) stay with the
# project.
#
# Because the centralising step is independent of the project move, this is safe
# to re-run on an already-conformant project (compose already in /opt) to adopt
# the shared /opt/volumes layout — only the data binds are touched.
#
# DRY-RUN by default — prints the plan. Pass --apply to make changes.
# Aborts on the first failed step (after --apply) so you can inspect.
#
# By default the target dir is /opt/<compose-project>, where the compose
# project name defaults to the working-dir basename (e.g. a compose file in
# /root yields project 'root' -> /opt/root). Pass --name <app> to place the
# project under /opt/<app> instead; the stack is also brought back up under
# that name (-p <app>), so the running project matches its new home. The
# `down` still uses the original project name to match what's running. This
# rename is safe because the volume check below guarantees no named volumes
# exist that a new project prefix would orphan.
#
# Refuses to convert a container that has docker volumes in use (see
# check_volumes) — they wouldn't survive the move. Pass --force to override.
#
# Project-local binds whose top-level dir name is in this list are treated as
# config that lives with the compose file and are NOT centralised under
# /opt/volumes. Override per-run with --keep, or globally via this env var.
: "${DOCKER_STANDARD_KEEP_BINDS:=certs config}"

# Usage: convert_to_standard <CTID-or-name> [--name <app>] [--apply] [--force]
#                            [--keep <csv>]
convert_to_standard() {
  local apply=0 a name_override="" force=0 keep_override=""
  local args=()
  while [[ $# -gt 0 ]]; do
    a=$1
    case "$a" in
      --apply) apply=1 ;;
      --force) force=1 ;;
      --name) name_override=$2; shift ;;
      --name=*) name_override=${a#--name=} ;;
      --keep) keep_override=$2; shift ;;
      --keep=*) keep_override=${a#--keep=} ;;
      *) args+=("$a") ;;
    esac
    shift
  done

  # config dir names to keep with the project (vs centralise under /opt/volumes)
  local keep_arr
  IFS=', ' read -r -a keep_arr <<< "${keep_override:-$DOCKER_STANDARD_KEEP_BINDS}"

  local ctid ct_hostname pct_conf
  ctid=$(_resolve_ctid "${args[0]:-}") || return 2
  pct_conf=$(pct config "$ctid")
  ct_hostname=$(awk '/^hostname:/{print $2}' <<< "$pct_conf")

  # LXC-side paths of host passthrough mounts (mp0: /host/path,mp=/lxc/path,...)
  local host_mps=()
  while IFS= read -r mp_path; do
    [[ -n "$mp_path" ]] && host_mps+=("$mp_path")
  done < <(awk '/^mp[0-9]+:/{
    n=split($0,a,",")
    for(i=1;i<=n;i++) if(a[i]~/^mp=/) { sub(/^mp=/,"",a[i]); print a[i] }
  }' <<< "$pct_conf")

  if _ct_is_protected "$ctid"; then
    echo "CT ${ctid}: protected (tag '${DOCKER_PROTECT_TAG}') — refusing to convert."
    return 2
  fi

  if ! ct_has_docker "$ctid"; then
    echo "CT ${ctid}: no docker — not applicable, skipping."
    return 2
  fi

  if ! check_volumes "$ctid"; then
    if [[ $force -eq 1 ]]; then
      echo "CT ${ctid}: volumes present but --force given — proceeding anyway (volume data will be LOST)."
    else
      echo "CT ${ctid}: docker volumes in use (above) — refusing to convert."
      echo "  Migrate them to bind mounts first:  migrate_volumes_to_binds ${ctid} --apply"
      echo "  (or pass --force to convert anyway and lose the volume data)."
      return 2
    fi
  fi

  local mode="DRY-RUN"
  [[ $apply -eq 1 ]] && mode="APPLY"
  echo "=== convert_to_standard CT ${ctid} [${mode}] ==="

  # project|working_dir|config_files for each running compose project
  local meta
  meta=$(pct exec "$ctid" -- bash -c '
    docker ps --format "{{.ID}}" | while read -r id; do
      docker inspect "$id" --format "{{ index .Config.Labels \"com.docker.compose.project\" }}|{{ index .Config.Labels \"com.docker.compose.project.working_dir\" }}|{{ index .Config.Labels \"com.docker.compose.project.config_files\" }}"
    done | sort -u
  ' </dev/null)

  if [[ -z "$meta" ]]; then
    echo "CT ${ctid}: no running compose projects found — nothing to convert."
    return 1
  fi

  if [[ -n "$name_override" ]]; then
    local nproj
    nproj=$(printf '%s\n' "$meta" | grep -c .)
    if [[ "$nproj" -gt 1 ]]; then
      echo "CT ${ctid}: --name given but ${nproj} compose projects found — ambiguous, refusing."
      return 2
    fi
  fi

  local backup_dir="/root/compose-migration-$(date +%Y%m%d-%H%M%S)"
  local proj wd cf name target target_compose binds bsrc bdst rel m src dst
  local moves volmoves vol_name needs_move moves_pending cf_now wd_now esc_dest repl sed_expr
  while IFS='|' read -r proj wd cf; do
    [[ -z "$proj" ]] && continue

    # resolve first config file to an absolute path
    cf=${cf%%,*}
    case "$cf" in
      /*) : ;;
      *)  cf="${wd%/}/$cf" ;;
    esac

    if [[ -z "$wd" || "$wd" == "/" ]]; then
      echo
      echo "Project '${proj}': suspicious working_dir '${wd}' — SKIPPING."
      continue
    fi

    name=${name_override:-${ct_hostname:-$proj}}
    target="/opt/${name}"
    target_compose="/opt/docker-compose.yml"

    echo
    echo "Project '${proj}':"
    echo "  compose : ${cf}"
    echo "  workdir : ${wd}"
    echo "  target  : ${target_compose}"

    # Enumerate this project's bind mounts (with destinations) and classify:
    #   - volume bind  : source is a <dir>/volumes/<name> tree (produced by
    #                    migrate_volumes_to_binds; name already project-prefixed)
    #                    -> centralise as /opt/volumes/<name>, rewrite compose;
    #   - host-mount   : source is at or under a PVE host passthrough mount point
    #                    (mp0/mp1/... in the LXC config) -> left in place;
    #   - data bind    : other project-local source whose dir is NOT in the keep
    #                    list -> centralise as /opt/volumes/<name>_<rel> (prefixed
    #                    to avoid collisions), rewrite compose;
    #   - config bind  : project-local source whose dir IS in the keep list ->
    #                    stays with the project (moves into /opt/<name> if the
    #                    project itself is relocating; relative refs follow it);
    #   - external     : anything else -> left in place.
    binds=$(pct exec "$ctid" -- bash -c "
      for id in \$(docker ps -q --filter label=com.docker.compose.project=${proj}); do
        docker inspect \$id --format '{{range .Mounts}}{{if eq .Type \"bind\"}}{{.Source}}|{{.Destination}}{{\"\n\"}}{{end}}{{end}}'
      done | sort -u
    " </dev/null)

    local moves=() volmoves=() top k kept is_host_mp mp
    while IFS='|' read -r bsrc bdst; do
      [[ -z "$bsrc" || "$bsrc" == "$cf" ]] && continue
      if [[ "$bsrc" =~ /volumes/([^/]+)/?$ ]]; then
        vol_name=${BASH_REMATCH[1]}
        if [[ "$bsrc" == "/opt/volumes/${vol_name}" ]]; then
          echo "  volume bind : ${bsrc}  (already centralised)"
        else
          volmoves+=("${bsrc}|/opt/volumes/${vol_name}|${bdst}")
          echo "  volume bind : ${bsrc}  ->  /opt/volumes/${vol_name}   (at ${bdst})"
        fi
      else
        # Check whether bsrc is (or is under) a host passthrough mount point
        is_host_mp=0
        for mp in "${host_mps[@]}"; do
          if [[ "$bsrc" == "$mp" || "$bsrc" == "${mp%/}/"* ]]; then
            is_host_mp=1; break
          fi
        done
        if [[ $is_host_mp -eq 1 ]]; then
          echo "  host-mount  : ${bsrc}  (LXC passthrough — left in place)"
        elif [[ "$bsrc" == "${wd%/}/"* ]]; then
          rel=${bsrc#${wd%/}/}
          top=${rel%%/*}
          kept=0
          for k in "${keep_arr[@]}"; do [[ -n "$k" && "$top" == "$k" ]] && { kept=1; break; }; done
          if [[ $kept -eq 1 ]]; then
            moves+=("$bsrc|${target}/${rel}|${bdst}")
            echo "  config bind : ${bsrc}  (kept with project)"
          else
            volmoves+=("${bsrc}|/opt/volumes/${name}_${rel}|${bdst}")
            echo "  data bind   : ${bsrc}  ->  /opt/volumes/${name}_${rel}   (at ${bdst})"
          fi
        else
          echo "  EXTERNAL    : ${bsrc}  (left in place)"
        fi
      fi
    done <<< "$binds"

    # A config bind still needs to move if its source isn't already at the
    # per-project target (e.g. compose already lives at /opt/docker-compose.yml
    # but its config dir is still flat under /opt rather than /opt/<name>).
    moves_pending=0
    for m in "${moves[@]}"; do
      IFS='|' read -r src dst bdst <<< "$m"
      [[ "$src" != "$dst" ]] && moves_pending=1
    done

    # Work is needed if the compose file must relocate to /opt/<name>, a config
    # bind must move into the per-project target, and/or any volume bind still
    # needs centralising under /opt/volumes (the latter lets us re-run on
    # already-conformant projects to adopt the shared layout).
    needs_move=0
    [[ "$cf" != "$target_compose" ]] && needs_move=1
    if [[ $needs_move -eq 0 && ${#volmoves[@]} -eq 0 && $moves_pending -eq 0 ]]; then
      echo "  -> already conformant."
      continue
    fi

    # Pre-flight: if the compose file must move to /opt/docker-compose.yml but
    # one already exists there (from a prior app), we cannot merge automatically.
    if [[ $needs_move -eq 1 ]] && pct exec "$ctid" -- bash -c "[ -f '/opt/docker-compose.yml' ]" </dev/null; then
      echo "  ! /opt/docker-compose.yml already exists — cannot overwrite."
      echo "    Merge '${cf}' into /opt/docker-compose.yml by hand, then re-run."
      return 2
    fi

    # Pre-flight: never clobber an existing /opt/volumes/<name>; bail before we
    # touch the running stack so nothing is left half-migrated.
    for m in "${volmoves[@]}"; do
      dst=${m#*|}; dst=${dst%|*}
      if [[ $apply -eq 1 ]] && pct exec "$ctid" -- bash -c "[ -e '${dst}' ]" </dev/null; then
        if [[ $force -eq 1 ]]; then
          echo "  ! ${dst} already exists — --force given, proceeding anyway."
        else
          echo "  ! ${dst} already exists — refusing (remove it or pass --force)."
          return 2
        fi
      fi
    done

    # Pre-flight: long-form YAML volume/bind syntax cannot be rewritten by the sed
    # patterns below — catch it before touching the running stack.
    local lf_srcs=() lf_hits
    for m in "${volmoves[@]}"; do lf_srcs+=("${m%%|*}"); done
    for m in "${moves[@]}"; do lf_srcs+=("${m%%|*}"); done
    if [[ ${#lf_srcs[@]} -gt 0 ]]; then
      lf_hits=$(_compose_longform_sources "$ctid" "$cf" "${lf_srcs[@]}")
      if [[ -n "$lf_hits" ]]; then
        echo "  ! ${cf} uses long-form YAML volume syntax for source(s) that need rewriting:"
        printf '%s\n' "$lf_hits"
        echo "    The sed rewrite only handles short-form (- /src:/dst[:mode])."
        echo "    Convert these entries to short-form, then re-run convert_to_standard."
        return 2
      fi
    fi

    _ct_step "$ctid" "$apply" "backup compose+workdir to ${backup_dir}/${proj}" \
      "mkdir -p '${backup_dir}/${proj}' && cp '${cf}' '${backup_dir}/${proj}/' && tar czf '${backup_dir}/${proj}/workdir.tgz' --one-file-system -C '$(dirname "$wd")' '$(basename "$wd")'${_TAR_GUARD}" || return 1

    _ct_step "$ctid" "$apply" "compose down" \
      "cd '${wd}' && docker-compose -f '${cf}' -p '${proj}' down" || return 1

    # Relocate the project itself into /opt/<name> (skipped if already there).
    # This must run whenever a config bind needs to move, even if the compose
    # file is already sitting at ${target_compose} (e.g. it was deployed flat
    # under /opt directly, rather than relocated here from elsewhere).
    cf_now="$cf"; wd_now="$wd"
    if [[ $needs_move -eq 1 || $moves_pending -eq 1 ]]; then
      _ct_step "$ctid" "$apply" "create ${target}" "mkdir -p '${target}'" || return 1
      for m in "${moves[@]}"; do
        IFS='|' read -r src dst bdst <<< "$m"
        [[ "$src" == "$dst" ]] && continue
        _ct_step "$ctid" "$apply" "move ${src} -> ${dst}" \
          "mkdir -p '$(dirname "$dst")' && mv '${src}' '${dst}'" || return 1
      done
      if [[ $needs_move -eq 1 ]]; then
        _ct_step "$ctid" "$apply" "move compose -> ${target_compose}" \
          "mv '${cf}' '${target_compose}'" || return 1
        cf_now="$target_compose"; wd_now="/opt"
      fi
      # Rewrite config-bind sources in the compose file. Relative refs like
      # ./config would still resolve correctly after the move, but absolute
      # refs (e.g. /opt/config) point at the old location which no longer
      # exists. Anchoring on the container destination is source-format-agnostic.
      for m in "${moves[@]}"; do
        IFS='|' read -r src dst bdst <<< "$m"
        [[ "$src" == "$dst" ]] && continue
        esc_dest=$(_sed_escape_re "$bdst")
        repl=$(_sed_escape_repl "$dst")
        sed_expr='s#^([[:space:]]*-[[:space:]]*[\x22\x27]?)[^:[:space:]]+(:'"${esc_dest}"'/?(:[a-zA-Z,]+)?[\x22\x27]?[[:space:]]*)$#\1'"${repl}"'\2#'
        _ct_step "$ctid" "$apply" "rewrite compose config source -> ${dst}" \
          "sed -i -E '${sed_expr}' '${cf_now}'" || return 1
      done
    fi

    # Centralise volume binds under the shared /opt/volumes and repoint the
    # compose source at the new path.
    if [[ ${#volmoves[@]} -gt 0 ]]; then
      _ct_step "$ctid" "$apply" "create /opt/volumes" "mkdir -p '/opt/volumes'" || return 1
      for m in "${volmoves[@]}"; do
        src=${m%%|*}
        rel=${m##*|}                 # mount destination (anchors the rewrite)
        dst=${m#*|}; dst=${dst%|*}    # /opt/volumes/<name>
        _ct_step "$ctid" "$apply" "centralise ${src} -> ${dst}" \
          "mv '${src}' '${dst}'" || return 1
        # Rewrite the bind whose mount destination is ${rel} to source ${dst}.
        # Anchoring on the (unique) destination works whether the file used an
        # absolute or relative source; tolerate a trailing slash / mode / quotes.
        esc_dest=$(_sed_escape_re "$rel")
        repl=$(_sed_escape_repl "$dst")
        sed_expr='s#^([[:space:]]*-[[:space:]]*[\x22\x27]?)[^:[:space:]]+(:'"${esc_dest}"'/?(:[a-zA-Z,]+)?[\x22\x27]?[[:space:]]*)$#\1'"${repl}"'\2#'
        _ct_step "$ctid" "$apply" "rewrite compose source -> ${dst}" \
          "sed -i -E '${sed_expr}' '${cf_now}'" || return 1
      done
    fi

    # Bring the stack back up from its (possibly new) home under the (possibly
    # renamed) project name. Safe to rename here: check_volumes already
    # guaranteed no named volumes exist that a new prefix would orphan.
    _ct_step "$ctid" "$apply" "compose up -d from ${wd_now} (project '${name}')" \
      "cd '${wd_now}' && docker-compose -f '${cf_now}' -p '${name}' up -d" || return 1

    # ---------- verify (apply only) ----------
    # Confirm every centralised volume is now served from /opt/volumes on the
    # running stack. A silent compose-rewrite miss (e.g. a long-form mount the
    # short-form sed can't match) would leave the container bound to the old,
    # now-moved source — docker would recreate it empty — which this catches.
    if [[ $apply -eq 1 && ${#volmoves[@]} -gt 0 ]]; then
      local mounted leftover=""
      mounted=$(pct exec "$ctid" -- bash -c "
        for id in \$(docker ps -q --filter label=com.docker.compose.project=${name}); do
          docker inspect \$id --format '{{range .Mounts}}{{if eq .Type \"bind\"}}{{.Source}}{{\"\n\"}}{{end}}{{end}}'
        done | sort -u
      " </dev/null)
      for m in "${volmoves[@]}"; do
        dst=${m#*|}; dst=${dst%|*}
        grep -qxF "$dst" <<< "$mounted" || leftover+=" ${dst}"
      done
      if [[ -n "$leftover" ]]; then
        echo "  ! VERIFY FAILED: not mounted from /opt/volumes:${leftover}"
        echo "    The compose rewrite did not take (long-form mount / unusual syntax?)."
        echo "    Data is safely centralised in /opt/volumes and backed up in"
        echo "    ${backup_dir}/${proj}; fix the source(s) in ${cf_now} by hand, then:"
        echo "      pct exec ${ctid} -- bash -c \"cd '${wd_now}' && docker-compose -f '${cf_now}' -p '${name}' up -d\""
        return 1
      fi
      echo "  ✔ verified: volume bind(s) now served from /opt/volumes"
    fi

  done <<< "$meta"

  echo
  if [[ $apply -eq 1 ]]; then
    echo "✔ CT ${ctid}: conversion applied. Backups in ${backup_dir}."
    if _ct_add_tag "$ctid" "$DOCKER_STANDARD_TAG"; then
      echo "  tagged '${DOCKER_STANDARD_TAG}' — now eligible for redeploy_lxc."
    else
      echo "  warning: failed to set '${DOCKER_STANDARD_TAG}' tag — redeploy_lxc will refuse until it is set." >&2
    fi
  else
    echo "Dry-run only. Re-run with --apply to perform the changes above."
  fi
}

# Copy the contents of every named docker *volume* into project-local *bind
# mounts* under the compose working dir, rewrite the compose file to use those
# binds, and restart the stack — so the container ends up with no volume mounts
# and convert_to_standard will proceed (and a later redeploy carries the data
# in /opt, not in docker storage).
#
# This is the deliberate, opt-in step that convert_to_standard points you to;
# it is NOT run automatically. It only touches data safely:
#   - `compose down` is run WITHOUT -v, so the named volumes persist;
#   - data is read from the volume mounted READ-ONLY and copied with `cp -a`;
#   - every volume is tar'd to a backup first, alongside the compose file;
#   - after `up`, it VERIFIES the stack no longer mounts the migrated volumes
#     and that each bind dir matches the source (file count + total bytes);
#   - the original named volumes are LEFT IN PLACE as a rollback net — the
#     `docker volume rm` commands are printed for you to run once happy.
#
# Each named volume V (mounted at DEST) becomes the bind <workdir>/volumes/V.
# Anonymous volumes (image VOLUME / bare `- /path`) can't be rewritten safely,
# so they are backed up and reported but left in place; if any remain,
# convert_to_standard will still refuse until you handle them by hand.
#
# DRY-RUN by default — prints the plan. Pass --apply to make changes. --force
# allows writing into a target bind dir that already exists and is non-empty.
# Aborts a project on the first failed step (after --apply) so you can inspect,
# printing the exact recover-from-backup command; other projects continue.
#
# Usage: migrate_volumes_to_binds <CTID-or-name> [--apply] [--force]
migrate_volumes_to_binds() {
  local apply=0 force=0 a args=()
  while [[ $# -gt 0 ]]; do
    a=$1
    case "$a" in
      --apply) apply=1 ;;
      --force) force=1 ;;
      *) args+=("$a") ;;
    esac
    shift
  done

  local ctid
  ctid=$(_resolve_ctid "${args[0]:-}") || return 2

  if _ct_is_protected "$ctid"; then
    echo "CT ${ctid}: protected (tag '${DOCKER_PROTECT_TAG}') — refusing to migrate."
    return 2
  fi
  if ! ct_has_docker "$ctid"; then
    echo "CT ${ctid}: no docker — not applicable, skipping."
    return 2
  fi

  # proj|wd|cf|vname|dest, one line per *volume* mount on a running container
  # (same label-driven discovery as find_compose / check_volumes).
  local rows
  rows=$(pct exec "$ctid" -- bash -c '
    docker ps --format "{{.ID}}" 2>/dev/null | while read -r id; do
      proj=$(docker inspect "$id" --format "{{ index .Config.Labels \"com.docker.compose.project\" }}" 2>/dev/null)
      wd=$(docker inspect "$id" --format "{{ index .Config.Labels \"com.docker.compose.project.working_dir\" }}" 2>/dev/null)
      cf=$(docker inspect "$id" --format "{{ index .Config.Labels \"com.docker.compose.project.config_files\" }}" 2>/dev/null)
      docker inspect "$id" --format "{{range .Mounts}}{{if eq .Type \"volume\"}}${proj}|${wd}|${cf}|{{if .Name}}{{.Name}}{{else}}<anon>{{end}}|{{.Destination}}{{\"\n\"}}{{end}}{{end}}" 2>/dev/null
    done | sort -u
  ' </dev/null)

  if [[ -z "$rows" ]]; then
    echo "CT ${ctid}: ✔ no docker volumes in use — nothing to migrate."
    return 0
  fi

  local mode="DRY-RUN"; [[ $apply -eq 1 ]] && mode="APPLY"
  echo "=== migrate_volumes_to_binds CT ${ctid} [${mode}] ==="

  local backup_dir="/root/volume-migration-$(date +%Y%m%d-%H%M%S)"
  local subdir="volumes"
  local rc=0
  local orphans=() anons=()

  # Volumes on non-compose containers carry no project label; we can't place
  # them under a working dir, so report them and move on.
  local noproj
  noproj=$(printf '%s\n' "$rows" | awk -F'|' '$1==""{print $4" -> "$5}' | sort -u)

  local projects proj
  projects=$(printf '%s\n' "$rows" | awk -F'|' '$1!=""{print $1}' | sort -u)

  while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue

    local prows wd cf
    prows=$(printf '%s\n' "$rows" | awk -F'|' -v p="$proj" '$1==p')
    wd=$(printf '%s\n' "$prows" | head -1 | cut -d'|' -f2)
    cf=$(printf '%s\n' "$prows" | head -1 | cut -d'|' -f3)
    cf=${cf%%,*}
    case "$cf" in /*) : ;; *) cf="${wd%/}/$cf" ;; esac

    echo
    echo "Project '${proj}':"
    echo "  compose : ${cf}"
    echo "  workdir : ${wd}"

    if [[ -z "$wd" || "$wd" == "/" ]]; then
      echo "  -> suspicious working_dir '${wd}' — SKIPPING."
      rc=1; continue
    fi

    # named (migratable) vs anonymous (64-hex / <anon>) — same test as check_volumes
    local named_pairs named_unique anon_dests
    named_pairs=$(printf '%s\n' "$prows" | awk -F'|' '
      { v=$4; if (v=="<anon>" || v ~ /^[0-9a-f]{64}$/) next; print $4"|"$5 }' | sort -u)
    named_unique=$(printf '%s\n' "$named_pairs" | cut -d'|' -f1 | sed '/^$/d' | sort -u)
    anon_dests=$(printf '%s\n' "$prows" | awk -F'|' '
      { v=$4; if (v=="<anon>" || v ~ /^[0-9a-f]{64}$/) print $5 }' | sort -u)

    local vname dest bind
    while IFS='|' read -r vname dest; do
      [[ -z "$vname" ]] && continue
      echo "  named vol: ${vname}  ->  ${wd%/}/${subdir}/${vname}   (mounted at ${dest})"
    done <<< "$named_pairs"
    while IFS= read -r dest; do
      [[ -z "$dest" ]] && continue
      echo "  anon vol : <anonymous> at ${dest}  — NOT migrated (handle by hand)"
      anons+=("CT ${ctid} '${proj}': anonymous volume at ${dest}")
    done <<< "$anon_dests"

    if [[ -z "$named_unique" ]]; then
      echo "  -> no named volumes to migrate in this project."
      continue
    fi

    # Pre-flight: long-form YAML volume syntax cannot be rewritten by the sed
    # patterns below — catch it before touching the running stack.
    local lf_vals=() lf_hits short
    while IFS= read -r vname; do
      [[ -z "$vname" ]] && continue
      lf_vals+=("$vname")
      short="${vname#"${proj}"_}"
      [[ "$short" != "$vname" && -n "$short" ]] && lf_vals+=("$short")
    done <<< "$named_unique"
    lf_hits=$(_compose_longform_sources "$ctid" "$cf" "${lf_vals[@]}")
    if [[ -n "$lf_hits" ]]; then
      echo "  ! ${cf} uses long-form YAML volume syntax for source(s) that need rewriting:"
      printf '%s\n' "$lf_hits"
      echo "    The sed rewrite only handles short-form (- volname:/dest[:mode])."
      echo "    Convert these entries to short-form, then re-run migrate_volumes_to_binds."
      rc=1; continue
    fi

    # --- apply-only pre-flight: don't clobber existing target dirs ---
    if [[ $apply -eq 1 ]]; then
      local nonempty=0
      while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        bind="${wd%/}/${subdir}/${vname}"
        if pct exec "$ctid" -- bash -c "[ -d '${bind}' ] && [ -n \"\$(ls -A '${bind}' 2>/dev/null)\" ]" </dev/null; then
          echo "  ! target ${bind} already exists and is non-empty"
          nonempty=1
        fi
      done <<< "$named_unique"
      if [[ $nonempty -eq 1 ]]; then
        if [[ $force -eq 1 ]]; then
          echo "  (--force given — proceeding into non-empty target dir(s))"
        else
          echo "  refusing to overwrite existing data — pass --force to override. SKIPPING project."
          rc=1; continue
        fi
      fi
    fi

    local pfail=0

    # backup: compose file + a tarball per volume
    _ct_step "$ctid" "$apply" "backup compose -> ${backup_dir}/${proj}/" \
      "mkdir -p '${backup_dir}/${proj}' && cp '${cf}' '${backup_dir}/${proj}/'" || pfail=1
    if [[ $pfail -eq 0 ]]; then
      while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        _ct_step "$ctid" "$apply" "backup volume ${vname} -> ${backup_dir}/${proj}/vol-${vname}.tgz" \
          "docker run --rm -v '${vname}:/v:ro' -v '${backup_dir}/${proj}:/b' '${DOCKER_MIGRATE_IMAGE}' tar czf '/b/vol-${vname}.tgz' -C /v .${_TAR_GUARD}" \
          || { pfail=1; break; }
      done <<< "$named_unique"
    fi

    # stop the stack (volumes preserved — no -v)
    [[ $pfail -eq 0 ]] && { _ct_step "$ctid" "$apply" "compose down (volumes preserved)" \
      "cd '${wd}' && docker-compose -f '${cf}' -p '${proj}' down" || pfail=1; }

    # copy each volume's contents into its bind dir (read-only source, cp -a)
    if [[ $pfail -eq 0 ]]; then
      while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        bind="${wd%/}/${subdir}/${vname}"
        _ct_step "$ctid" "$apply" "copy volume ${vname} -> ${bind}" \
          "mkdir -p '${bind}' && docker run --rm -v '${vname}:/from:ro' -v '${bind}:/to' '${DOCKER_MIGRATE_IMAGE}' sh -c 'cp -a /from/. /to/'" \
          || { pfail=1; break; }
      done <<< "$named_unique"
    fi

    # rewrite each volume reference in the compose file to its bind path
    if [[ $pfail -eq 0 ]]; then
      while IFS='|' read -r vname dest; do
        [[ -z "$vname" ]] && continue
        bind="${wd%/}/${subdir}/${vname}"
        local esc_name esc_dest repl sed_expr name_alt short
        # docker reports the *prefixed* volume name (e.g. root_mealie-data), but
        # the compose file references the compose-local key (mealie-data). Match
        # either form so the rewrite hits short-form refs as well as explicit/
        # external names that carry the full name verbatim.
        esc_name=$(_sed_escape_re "$vname")
        name_alt="$esc_name"
        short="${vname#"${proj}"_}"
        if [[ "$short" != "$vname" && -n "$short" ]]; then
          name_alt="${esc_name}|$(_sed_escape_re "$short")"
        fi
        esc_dest=$(_sed_escape_re "$dest")
        repl=$(_sed_escape_repl "$bind")
        # match a short-form list item `- [<q>]NAME:DEST[:mode][<q>]` anchored on
        # both NAME and DEST so only the right line changes; keep any quotes/mode.
        # docker normalises DEST (strips a trailing slash) but the file may keep
        # one (`/app/data/`), so tolerate an optional trailing slash on DEST.
        # \1 = leading, \2 = the name (alternation), \3 = trailing (DEST + mode/q).
        sed_expr='s#^([[:space:]]*-[[:space:]]*[\x22\x27]?)('"${name_alt}"')(:'"${esc_dest}"'/?(:[a-zA-Z,]+)?[\x22\x27]?[[:space:]]*)$#\1'"${repl}"'\3#'
        _ct_step "$ctid" "$apply" "rewrite compose: ${vname}:${dest} -> bind" \
          "sed -i -E '${sed_expr}' '${cf}'" || { pfail=1; break; }
      done <<< "$named_pairs"
    fi

    # bring it back up from the same place / project name
    [[ $pfail -eq 0 ]] && { _ct_step "$ctid" "$apply" "compose up -d" \
      "cd '${wd}' && docker-compose -f '${cf}' -p '${proj}' up -d" || pfail=1; }

    if [[ $apply -eq 1 && $pfail -eq 1 ]]; then
      echo "  ! a step FAILED. Recover this project with:"
      echo "      pct exec ${ctid} -- bash -c \"cp '${backup_dir}/${proj}/$(basename "$cf")' '${cf}' && cd '${wd}' && docker-compose -f '${cf}' -p '${proj}' up -d\""
      echo "    (the original named volume(s) still hold the data.)"
      rc=1; continue
    fi

    # ---------- verify (apply only) ----------
    if [[ $apply -eq 1 ]]; then
      # (a) no migrated volume is still mounted on the running stack
      local still leftover=""
      still=$(pct exec "$ctid" -- bash -c '
        for id in $(docker ps -q --filter label=com.docker.compose.project='"$proj"'); do
          docker inspect "$id" --format "{{range .Mounts}}{{if eq .Type \"volume\"}}{{if .Name}}{{.Name}}{{end}}{{\"\n\"}}{{end}}{{end}}" 2>/dev/null
        done | sort -u
      ' </dev/null)
      while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        grep -qxF "$vname" <<< "$still" && leftover+=" ${vname}"
      done <<< "$named_unique"
      if [[ -n "$leftover" ]]; then
        echo "  ! VERIFY FAILED: still mounted as volume(s):${leftover}"
        echo "    The compose rewrite did not take (unusual syntax / inline comment?)."
        echo "    Data is safely copied to the bind dir(s) and backed up; the compose"
        echo "    file is at ${cf} — finish those reference(s) by hand, then re-run up."
        rc=1; continue
      fi

      # (b) each bind dir matches its source volume (file count + total bytes)
      local vfail=0 src dst
      while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        bind="${wd%/}/${subdir}/${vname}"
        src=$(pct exec "$ctid" -- bash -c "docker run --rm -v '${vname}:/v:ro' '${DOCKER_MIGRATE_IMAGE}' sh -c 'echo \$(find /v -type f | wc -l):\$(find /v -type f -exec cat {} + 2>/dev/null | wc -c)'" </dev/null)
        dst=$(pct exec "$ctid" -- bash -c "echo \$(find '${bind}' -type f | wc -l):\$(find '${bind}' -type f -exec cat {} + 2>/dev/null | wc -c)" </dev/null)
        if [[ "$src" != "$dst" ]]; then
          echo "  ! VERIFY FAILED: ${vname} source(${src}) != bind(${dst}) [files:bytes]"
          vfail=1
        else
          echo "  ✔ verified ${vname} (${dst} files:bytes)"
        fi
      done <<< "$named_unique"
      if [[ $vfail -eq 1 ]]; then
        echo "    Bind data differs from the source volume — do NOT remove the volume(s)."
        rc=1; continue
      fi

      # success for this project — queue the source volumes for manual cleanup
      while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        orphans+=("$vname")
      done <<< "$named_unique"
    fi

  done <<< "$projects"

  echo
  if [[ $apply -eq 1 ]]; then
    if [[ $rc -eq 0 ]]; then
      echo "✔ CT ${ctid}: volume migration complete. Backups in ${backup_dir}."
    else
      echo "⚠ CT ${ctid}: migration finished WITH ERRORS (see above). Backups in ${backup_dir}."
    fi
    if [[ ${#orphans[@]} -gt 0 ]]; then
      echo
      echo "The original named volumes are LEFT IN PLACE as a rollback net."
      echo "Once the apps are confirmed healthy, remove them:"
      printf '  pct exec %s -- docker volume rm' "$ctid"
      printf ' %s' "${orphans[@]}"
      echo
    fi
  else
    echo "Dry-run only. Re-run with --apply to perform the migration above."
  fi
  if [[ ${#anons[@]} -gt 0 ]]; then
    echo
    echo "Anonymous volumes were NOT migrated (ambiguous to rewrite) — handle by hand:"
    printf '  %s\n' "${anons[@]}"
  fi
  if [[ -n "$noproj" ]]; then
    echo
    echo "Volumes on non-compose containers (no project label) — not handled here:"
    printf '  %s\n' "$noproj"
  fi
  echo
  echo "Next: re-check with  check_volumes ${ctid}  then  convert_to_standard ${ctid}"
  return $rc
}

# Run migrate_volumes_to_binds across every CT tagged '${DOCKER_TAG}', skipping
# protected ones. DRY-RUN by default; pass --apply to commit.
# Usage: migrate_all_volumes [--apply] [--force]
migrate_all_volumes() {
  local ctid
  for ctid in $(pct list | awk 'NR>1 {print $1}'); do
    _ct_has_tag "$ctid" "$DOCKER_TAG" || continue
    if _ct_is_protected "$ctid"; then
      echo "CT ${ctid}: protected (tag '${DOCKER_PROTECT_TAG}') — skipping."
      continue
    fi
    migrate_volumes_to_binds "$ctid" "$@"
  done
}

# Write content to a file inside a container, with dry-run support.
# Content is base64-encoded on the host so it survives all quoting layers.
# Usage: _ct_write_file <ctid> <apply 0|1> <desc> <dest_path> <content>
_ct_write_file() {
  local ctid="$1" apply="$2" desc="$3" path="$4" content="$5"
  if [[ "$apply" -eq 1 ]]; then
    echo "  + ${desc}"
    local b64
    b64=$(printf '%s' "$content" | base64 -w0)
    if ! pct exec "$ctid" -- bash -c "printf '%s' '${b64}' | base64 -d > '${path}'" </dev/null; then
      echo "  ! FAILED: ${desc}" >&2
      return 1
    fi
  else
    echo "  [dry-run] ${desc} -> ${path}"
    printf '%s\n' "$content" | sed 's/^/        /'
  fi
}

# Add a Caddy HTTPS reverse-proxy service to a standardised Docker CT.
#
# Reads /opt/docker-compose.yml, detects the app service name and upstream port,
# creates /opt/caddy/{data,config,Caddyfile}, and appends a caddy service to the
# compose file. The Caddyfile reverse-proxies to <service>:<port> over the
# internal Docker network, using certs from /opt/certs/ (mounted at /certs).
#
# Cert files are auto-detected by name (crt/cert vs prv/key/private) and default
# to crt.pem / prv.pem if no .pem files are present yet.
#
# DRY-RUN by default — prints what would be written/run. Pass --apply to commit.
# Pass --port <N> to override the auto-detected upstream port.
#
# Usage: add_caddy <CTID-or-name> [--apply] [--port <N>]
add_caddy() {
  local apply=0 port_override="" a args=()
  while [[ $# -gt 0 ]]; do
    a=$1
    case "$a" in
      --apply)   apply=1 ;;
      --port)    port_override=$2; shift ;;
      --port=*)  port_override=${a#--port=} ;;
      *)         args+=("$a") ;;
    esac
    shift
  done

  local ctid pct_conf ct_hostname
  ctid=$(_resolve_ctid "${args[0]:-}") || return 2
  pct_conf=$(pct config "$ctid")
  ct_hostname=$(awk '/^hostname:/{print $2}' <<< "$pct_conf")

  if ! ct_has_docker "$ctid"; then
    echo "CT ${ctid}: no docker — not applicable." >&2
    return 2
  fi

  if ! pct exec "$ctid" -- bash -c '[ -f /opt/docker-compose.yml ]' </dev/null; then
    echo "CT ${ctid}: /opt/docker-compose.yml not found — run convert_to_standard first." >&2
    return 2
  fi

  if pct exec "$ctid" -- bash -c 'grep -qE "^  caddy:" /opt/docker-compose.yml' </dev/null; then
    echo "CT ${ctid}: caddy service already present in /opt/docker-compose.yml." >&2
    return 2
  fi

  local mode="DRY-RUN"
  [[ $apply -eq 1 ]] && mode="APPLY"
  echo "=== add_caddy CT ${ctid} [${mode}] ==="

  # --- Discover the first non-caddy app service name ---
  local service_name
  service_name=$(pct exec "$ctid" -- bash -c '
    awk '"'"'/^services:/{s=1;next}
         s && /^  [a-zA-Z_][a-zA-Z0-9_-]*:/{
           sub(/:$/,"",$1)
           if ($1 != "caddy") { print $1; exit }
         }'"'"' /opt/docker-compose.yml
  ' </dev/null)

  if [[ -z "$service_name" ]]; then
    echo "CT ${ctid}: could not determine app service name from /opt/docker-compose.yml." >&2
    return 2
  fi

  # --- Discover the app's upstream port ---
  local port
  if [[ -n "$port_override" ]]; then
    port="$port_override"
  else
    # Extract the rightmost port number from port-mapping lines (host:container),
    # ignoring 443 which belongs to caddy itself.
    port=$(pct exec "$ctid" -- bash -c '
      grep -E "^\s+- [\"'"'"']?[0-9.:]+:[0-9]" /opt/docker-compose.yml |
      grep -v ":443" |
      sed "s/.*:\([0-9]*\)[\"'"'"' ]*$/\1/" |
      head -1
    ' </dev/null)
    if [[ -z "$port" ]]; then
      echo "CT ${ctid}: could not detect app port — pass --port <N>." >&2
      return 2
    fi
  fi

  # --- Cert/key basenames under /opt/certs ---
  local crt_file="crt.pem" prv_file="prv.pem"

  local site="${ct_hostname}.home.arpa"

  echo "  service : ${service_name}"
  echo "  port    : ${port}"
  echo "  site    : ${site}"
  echo "  crt     : /certs/${crt_file}"
  echo "  prv     : /certs/${prv_file}"
  echo

  # --- Build Caddyfile ---
  local caddyfile
  caddyfile="$(cat <<EOF
(certs) {
	tls /certs/${crt_file} /certs/${prv_file}
}

${site} {
	import certs
	reverse_proxy ${service_name}:${port}
}
EOF
)"

  # --- Build caddy service YAML ---
  local caddy_svc
  caddy_svc="$(cat <<'EOF'
  caddy:
    image: caddy:2-alpine
    container_name: caddy
    restart: unless-stopped
    ports:
      - 443:443
    volumes:
      - /opt/caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - /opt/certs:/certs:ro
      - /opt/caddy/data:/data
      - /opt/caddy/config:/config
EOF
)"

  # --- Steps ---
  _ct_step "$ctid" "$apply" \
    "create /opt/caddy/{data,config}" \
    "mkdir -p /opt/caddy/data /opt/caddy/config" || return 1

  _ct_write_file "$ctid" "$apply" \
    "write /opt/caddy/Caddyfile" \
    "/opt/caddy/Caddyfile" \
    "$caddyfile" || return 1

  # Append caddy service — base64-encode to survive all quoting layers
  if [[ $apply -eq 1 ]]; then
    echo "  + append caddy service to /opt/docker-compose.yml"
    local b64
    b64=$(printf '%s' "$caddy_svc" | base64 -w0)
    if ! pct exec "$ctid" -- bash -c "
      printf '\n' >> /opt/docker-compose.yml
      printf '%s' '${b64}' | base64 -d >> /opt/docker-compose.yml
    " </dev/null; then
      echo "  ! FAILED: append caddy service to /opt/docker-compose.yml" >&2
      return 1
    fi
  else
    echo "  [dry-run] append caddy service to /opt/docker-compose.yml"
    printf '%s\n' "$caddy_svc" | sed 's/^/        /'
  fi

  _ct_step "$ctid" "$apply" \
    "docker-compose up -d caddy" \
    "cd /opt && docker-compose up -d caddy" || return 1

  echo
  if [[ $apply -eq 1 ]]; then
    echo "✔ CT ${ctid}: caddy added. Browse: https://${site}"
    if ! pct exec "$ctid" -- bash -c \
        "[ -f '/opt/certs/${crt_file}' ] && [ -f '/opt/certs/${prv_file}' ]" </dev/null 2>/dev/null; then
      echo
      echo "  ⚠ cert file(s) not yet in /opt/certs/ — Caddy will not start until they are."
      echo "    Expected: /opt/certs/${crt_file}  and  /opt/certs/${prv_file}"
      echo "    Then: pct exec ${ctid} -- docker restart caddy"
    fi
  else
    echo "Dry-run only. Re-run with --apply to apply."
  fi
}
