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
# Tag a CT with e.g.:  pct set <id> --tags docker
# (note: --tags REPLACES the whole list, so include all: --tags docker;noauto)
DOCKER_TAG="${DOCKER_TAG:-docker}"
DOCKER_PROTECT_TAG="${DOCKER_PROTECT_TAG:-noauto}"

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
      echo "CT ${ctid}: volumes present but --force given — proceeding anyway."
    else
      echo "CT ${ctid}: docker volumes in use (above) — refusing to convert. Pass --force to override."
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
  else
    echo "Dry-run only. Re-run with --apply to perform the changes above."
  fi
}
