#!/usr/bin/env bash
#
# Functions to manage the "Docker host" LXC containers on Proxmox.
#
# The pattern these containers follow:
#   - docker installed and running
#   - a docker-compose file; the "one true location" is namespaced per project:
#         /opt/<project>/docker-compose.yml
#   - project-local bind mounts live under the same dir (e.g. /opt/<project>/config)
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
#                                   been moved to the standard /opt/<app> layout;
#                                   redeploy_lxc requires it before it will run.
# Tag a CT with e.g.:  pct set <id> --tags docker
# (note: --tags REPLACES the whole list, so include all: --tags docker;noauto)
DOCKER_TAG="${DOCKER_TAG:-docker}"
DOCKER_PROTECT_TAG="${DOCKER_PROTECT_TAG:-noauto}"
DOCKER_STANDARD_TAG="${DOCKER_STANDARD_TAG:-docker-standardised}"

# Throwaway image used by migrate_volumes_to_binds to read a docker volume and
# copy/tar its contents (mounted read-only). Any tiny image with cp+tar works.
DOCKER_MIGRATE_IMAGE="${DOCKER_MIGRATE_IMAGE:-alpine}"

# True if the container's config carries the given tag.
# Usage: _ct_has_tag <CTID> <tag>
_ct_has_tag() {
  local tags
  tags=$(pct config "$1" 2>/dev/null | awk -F': ' '/^tags:/{print $2}')
  [[ ";${tags};" == *";${2};"* ]]
}

# True if the container carries the protect (denylist) tag.
# Usage: _ct_is_protected <CTID>
_ct_is_protected() { _ct_has_tag "$1" "$DOCKER_PROTECT_TAG"; }

# Add a tag to a container, preserving its existing tags. No-op if already set.
# (pct set --tags REPLACES the whole list, so we read, append, and write back.)
# Usage: _ct_add_tag <CTID> <tag>
_ct_add_tag() {
  local ctid="$1" tag="$2" tags
  _ct_has_tag "$ctid" "$tag" && return 0
  tags=$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^tags:/{print $2}')
  [[ -n "$tags" ]] && tags="${tags};${tag}" || tags="$tag"
  pct set "$ctid" --tags "$tags"
}

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
  nonconf=$(printf '%s\n' "$files" | grep -vE '^/opt/[^/]+/docker-compose\.yml$' || true)

  if [[ -z "$nonconf" ]]; then
    echo "CT ${ctid}: ✔ conformant (${count} project(s) under /opt/<app>/)."
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

# Bring up every compose stack found under /opt/<app>/docker-compose.yml.
# Usage: compose_up_all <CTID-or-name>
compose_up_all() {
  local ctid
  ctid=$(_resolve_ctid "${1:-}") || return 2
  ct_has_docker "$ctid" || { echo "CT ${ctid}: no docker."; return 2; }
  pct exec "$ctid" -- bash -c '
    find /opt -maxdepth 2 -type f -name docker-compose.yml 2>/dev/null | while read -r f; do
      d=$(dirname "$f")
      echo "compose up: $d"
      ( cd "$d" && docker-compose up -d )
    done
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

# Convert a container to the standard layout:
#   /opt/<project>/docker-compose.yml  with project-local bind mounts moved
#   alongside it. External (shared) bind mounts are reported and left in place.
#
# For each running compose project it: backs up the compose file + working dir,
# `compose down`, moves project-local dirs and the compose file under /opt/<app>,
# then `compose up -d` from the new location.
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
# Usage: convert_to_standard <CTID-or-name> [--name <app>] [--apply] [--force]
convert_to_standard() {
  local apply=0 a name_override="" force=0
  local args=()
  while [[ $# -gt 0 ]]; do
    a=$1
    case "$a" in
      --apply) apply=1 ;;
      --force) force=1 ;;
      --name) name_override=$2; shift ;;
      --name=*) name_override=${a#--name=} ;;
      *) args+=("$a") ;;
    esac
    shift
  done

  local ctid
  ctid=$(_resolve_ctid "${args[0]:-}") || return 2

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
  local proj wd cf name target target_compose binds b rel m src dst
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

    name=${name_override:-$proj}
    target="/opt/${name}"
    target_compose="${target}/docker-compose.yml"

    echo
    echo "Project '${proj}':"
    echo "  compose : ${cf}"
    echo "  workdir : ${wd}"
    echo "  target  : ${target_compose}"

    if [[ "$cf" == "$target_compose" ]]; then
      echo "  -> already conformant."
      continue
    fi

    # project-local bind mounts move with the project; external ones don't
    binds=$(pct exec "$ctid" -- bash -c "
      for id in \$(docker ps -q --filter label=com.docker.compose.project=${proj}); do
        docker inspect \$id --format '{{range .Mounts}}{{if eq .Type \"bind\"}}{{.Source}}{{\"\n\"}}{{end}}{{end}}'
      done | sort -u
    " </dev/null)

    local moves=()
    while read -r b; do
      [[ -z "$b" || "$b" == "$cf" ]] && continue
      if [[ "$b" == "${wd%/}/"* ]]; then
        rel=${b#${wd%/}/}
        moves+=("$b|${target}/${rel}")
        echo "  local bind  : ${b}  ->  ${target}/${rel}"
      else
        echo "  EXTERNAL    : ${b}  (left in place)"
      fi
    done <<< "$binds"

    _ct_step "$ctid" "$apply" "backup compose+workdir to ${backup_dir}/${proj}" \
      "mkdir -p '${backup_dir}/${proj}' && cp '${cf}' '${backup_dir}/${proj}/' && tar czf '${backup_dir}/${proj}/workdir.tgz' -C '$(dirname "$wd")' '$(basename "$wd")'" || return 1

    _ct_step "$ctid" "$apply" "compose down" \
      "cd '${wd}' && docker-compose -f '${cf}' -p '${proj}' down" || return 1

    _ct_step "$ctid" "$apply" "create ${target}" "mkdir -p '${target}'" || return 1

    for m in "${moves[@]}"; do
      src=${m%%|*}
      dst=${m##*|}
      _ct_step "$ctid" "$apply" "move ${src} -> ${dst}" \
        "mkdir -p '$(dirname "$dst")' && mv '${src}' '${dst}'" || return 1
    done

    _ct_step "$ctid" "$apply" "move compose -> ${target_compose}" \
      "mv '${cf}' '${target_compose}'" || return 1

    # Bring up under the (possibly renamed) project so the running stack matches
    # its new /opt/<name> home. Safe to rename here: check_volumes already
    # guaranteed no named volumes exist that a new prefix would orphan.
    _ct_step "$ctid" "$apply" "compose up -d from ${target} (project '${name}')" \
      "cd '${target}' && docker-compose -f '${target_compose}' -p '${name}' up -d" || return 1

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
          "docker run --rm -v '${vname}:/v:ro' -v '${backup_dir}/${proj}:/b' '${DOCKER_MIGRATE_IMAGE}' tar czf '/b/vol-${vname}.tgz' -C /v ." \
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
