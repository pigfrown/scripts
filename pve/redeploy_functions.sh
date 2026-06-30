#!/usr/bin/env bash
#
# Cattle-style redeploy of a Debian docker LXC: destroy the container and
# recreate a fresh one from a template, keeping its identity and data:
#   - same CTID
#   - same MAC / VLAN / bridge / IP (net lines copied verbatim)
#   - same bind-mount points (host paths survive destroy, re-attached)
#   - same idmap / raw lxc.* lines
#   - same /opt payload (tar'd off the old rootfs, restored into the new one)
#
# Result: a drop-in replacement on a fresh OS/template, then `compose up`.
#
# A vzdump backup is taken BEFORE anything is destroyed; roll back with
# rollback_lxc if a redeploy goes wrong.
#
# Source this file:  source /path/to/pve/redeploy_functions.sh
# Run on the Proxmox host, as root.

_REDEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=container_functions.sh
[[ $(type -t _resolve_ctid) == function ]] \
  || source "${_REDEPLOY_DIR}/container_functions.sh"
# shellcheck source=docker_functions.sh
[[ $(type -t _ct_is_protected) == function ]] \
  || source "${_REDEPLOY_DIR}/docker_functions.sh"

# Defaults — override in your shell/env.
REDEPLOY_TEMPLATE="${REDEPLOY_TEMPLATE:-999}"               # template CTID to clone
REDEPLOY_BACKUP_STORAGE="${REDEPLOY_BACKUP_STORAGE:-local}" # vzdump target (needs "backup" content)
REDEPLOY_CLONE_STORAGE="${REDEPLOY_CLONE_STORAGE:-}"        # storage for new rootfs (blank = template's)

# Per-CT preserve manifests: extra base-system paths to carry across a redeploy.
# One absolute path per line (files or dirs); # comments and blank lines ignored.
# On /etc/pve so it is cluster-synced and survives the container's destroy.
REDEPLOY_PRESERVE_DIR="${REDEPLOY_PRESERVE_DIR:-/etc/pve/redeploy}"

# Print the main section (everything before the first [snapshot]) of a CT config.
_conf_main() {
  awk '/^\[/{exit} {print}' "/etc/pve/lxc/$1.conf" 2>/dev/null
}

# Print the preserve-manifest paths for a CT (comments/blank stripped).
_redeploy_preserve_paths() {
  local mf="${REDEPLOY_PRESERVE_DIR}/${1}.preserve" line
  [[ -f "$mf" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    read -r line <<<"$line"   # trim surrounding whitespace
    [[ -z "$line" ]] && continue
    printf '%s\n' "$line"
  done < "$mf"
}

# Wait until a container responds to exec (after start/reboot).
_ct_wait_ready() {
  local ctid="$1" tries="${2:-30}" n=0
  while (( n < tries )); do
    pct exec "$ctid" -- true </dev/null 2>/dev/null && return 0
    sleep 2; ((n++))
  done
  return 1
}

# Show base-system drift vs a stock Debian + template, to help build a preserve
# manifest: modified package files (incl. conffiles like Caddyfile, /etc/crontab)
# and unpackaged files in config dirs (custom systemd units, cron.d, scripts).
# Usage: ct_changed_files <CTID-or-name>
ct_changed_files() {
  local ctid
  ctid=$(_resolve_ctid "${1:-}") || return 2

  echo "=== CT ${ctid}: modified package files (dpkg -V) ==="
  echo "    cols: '5'=checksum differs, 'c'=conffile"
  pct exec "$ctid" -- dpkg -V </dev/null 2>/dev/null || true
  echo
  echo "=== CT ${ctid}: unpackaged files in config dirs ==="
  pct exec "$ctid" -- bash -c '
    comm -23 \
      <(find /etc /usr/local /root /var/spool/cron -type f 2>/dev/null | sort -u) \
      <(sort -u /var/lib/dpkg/info/*.list 2>/dev/null)
  ' </dev/null
  echo
  echo "Add the paths you want kept to: ${REDEPLOY_PRESERVE_DIR}/${ctid}.preserve"
}

# Redeploy a container from a template.
# DRY-RUN by default; pass --apply to actually do it.
# Usage: redeploy_lxc <CTID-or-name> [template-CTID-or-name] [--apply]
redeploy_lxc() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root on the Proxmox host" >&2
    return 1
  fi

  local apply=0 a pos=()
  for a in "$@"; do
    case "$a" in
      --apply) apply=1 ;;
      *) pos+=("$a") ;;
    esac
  done

  local ctid template
  ctid=$(_resolve_ctid "${pos[0]:-}") || return 2
  template=$(_resolve_ctid "${pos[1]:-$REDEPLOY_TEMPLATE}") || return 2

  if _ct_is_protected "$ctid"; then
    echo "CT ${ctid}: protected (tag '${DOCKER_PROTECT_TAG}') — refusing to redeploy."
    return 2
  fi

  [[ -f "/etc/pve/lxc/${ctid}.conf" ]]     || { echo "No such CT: ${ctid}" >&2; return 1; }
  [[ -f "/etc/pve/lxc/${template}.conf" ]] || { echo "No such template: ${template}" >&2; return 1; }

  local old tmpl
  old=$(_conf_main "$ctid")
  tmpl=$(_conf_main "$template")
  grep -q '^template: 1$' <<<"$tmpl" || { echo "CT ${template} is not a template." >&2; return 1; }

  # unprivileged must match or idmap/permissions break
  local old_unpriv tmpl_unpriv
  old_unpriv=$(sed -n 's/^unprivileged: //p' <<<"$old"); old_unpriv=${old_unpriv:-0}
  tmpl_unpriv=$(sed -n 's/^unprivileged: //p' <<<"$tmpl"); tmpl_unpriv=${tmpl_unpriv:-0}
  if [[ "$old_unpriv" != "$tmpl_unpriv" ]]; then
    echo "ERROR: unprivileged mismatch (CT=${old_unpriv}, template=${tmpl_unpriv}) — idmap would break." >&2
    return 1
  fi

  # classify mount points: bind (host path) vs storage volume
  local l key val src bind_mps=() storage_mps=()
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    key=${l%%:*}; val=${l#*: }; src=${val%%,*}
    if [[ "$src" == /* ]]; then bind_mps+=("$key|$val"); else storage_mps+=("$l"); fi
  done < <(grep -E '^mp[0-9]+:' <<<"$old")

  if (( ${#storage_mps[@]} )); then
    echo "ERROR: CT ${ctid} has storage-backed mount(s) that 'pct destroy' would delete:" >&2
    printf '  %s\n' "${storage_mps[@]}" >&2
    echo "Reassigning CT-owned volumes isn't automated yet — aborting." >&2
    return 1
  fi

  # values carried from the old config
  local hostname features cores memory swap onboot arch tags startup
  hostname=$(sed -n 's/^hostname: //p' <<<"$old")
  features=$(sed -n 's/^features: //p' <<<"$old")
  cores=$(sed -n 's/^cores: //p' <<<"$old")
  memory=$(sed -n 's/^memory: //p' <<<"$old")
  swap=$(sed -n 's/^swap: //p' <<<"$old")
  onboot=$(sed -n 's/^onboot: //p' <<<"$old")
  arch=$(sed -n 's/^arch: //p' <<<"$old")
  tags=$(sed -n 's/^tags: //p' <<<"$old")
  startup=$(sed -n 's/^startup: //p' <<<"$old")
  local net_lines idmap_lines lxc_lines
  mapfile -t net_lines   < <(grep -E '^net[0-9]+:' <<<"$old")
  mapfile -t idmap_lines < <(grep -E '^lxc\.idmap:' <<<"$old")
  mapfile -t lxc_lines   < <(grep -E '^lxc\.' <<<"$old")
  local preserve_paths
  mapfile -t preserve_paths < <(_redeploy_preserve_paths "$ctid")

  local mode="DRY-RUN"; (( apply )) && mode="APPLY"
  cat <<EOF

=== redeploy_lxc CT ${ctid} from template ${template} [${mode}] ===
  hostname : ${hostname}
  arch     : ${arch:-(template)}    unpriv: ${old_unpriv}
  cores    : ${cores:-(template)}   memory: ${memory:-(template)}   swap: ${swap:-(template)}
  onboot   : ${onboot:-(template)}  startup: ${startup:-(none)}
  features : ${features:-(template)}
  tags     : ${tags:-(none)}
EOF
  printf '  net      : %s\n' "${net_lines[@]:-(template)}"
  if (( ${#bind_mps[@]} )); then printf '  bind mp  : %s\n' "${bind_mps[@]//|/ }"; else echo "  bind mp  : (none)"; fi
  if (( ${#idmap_lines[@]} )); then printf '  idmap    : %s\n' "${idmap_lines[@]}"; else echo "  idmap    : (none)"; fi
  if (( ${#preserve_paths[@]} )); then
    echo "  preserve : ${REDEPLOY_PRESERVE_DIR}/${ctid}.preserve"
    printf '             %s\n' "${preserve_paths[@]}"
  else
    echo "  preserve : (none — no ${REDEPLOY_PRESERVE_DIR}/${ctid}.preserve)"
  fi
  echo "  /opt     : tar from old rootfs -> restore into new clone"
  echo "  backup   : vzdump -> ${REDEPLOY_BACKUP_STORAGE} (rollback point)"
  echo

  if ! (( apply )); then
    echo "Dry-run only. Re-run with --apply to perform the redeploy."
    return 0
  fi

  local ts work optfile preservefile backup_file
  ts=$(date +%Y%m%d-%H%M%S)
  work="/root/redeploy-${ctid}-${ts}"
  optfile="${work}/opt.tgz"
  preservefile="${work}/preserve.tgz"
  mkdir -p "$work"

  echo "[1] Stopping docker in CT ${ctid}..."
  pct exec "$ctid" -- bash -c 'systemctl stop docker docker.socket 2>/dev/null || true' </dev/null

  echo "[2] Archiving /opt -> ${optfile}..."
  pct exec "$ctid" -- tar czf - -C / opt </dev/null > "$optfile" \
    || { echo "tar /opt failed" >&2; return 1; }

  if (( ${#preserve_paths[@]} )); then
    echo "[2b] Archiving preserved base-system paths..."
    local p keep=()
    for p in "${preserve_paths[@]}"; do
      if pct exec "$ctid" -- test -e "$p" </dev/null 2>/dev/null; then
        keep+=("${p#/}")
      else
        echo "      skip (missing): $p"
      fi
    done
    if (( ${#keep[@]} )); then
      pct exec "$ctid" -- tar czf - -C / "${keep[@]}" </dev/null > "$preservefile" \
        || { echo "preserve tar failed" >&2; return 1; }
    fi
  fi

  echo "[3] vzdump backup (rollback point)..."
  local bkout
  bkout=$(vzdump "$ctid" --mode stop --compress zstd --storage "$REDEPLOY_BACKUP_STORAGE" 2>&1) \
    || { echo "$bkout" >&2; echo "vzdump failed — nothing destroyed." >&2; return 1; }
  backup_file=$(sed -n "s/.*creating vzdump archive '\([^']*\)'.*/\1/p" <<<"$bkout" | tail -1)
  echo "      backup: ${backup_file:-<see vzdump output above>}"
  pct status "$ctid" | grep -q stopped || pct stop "$ctid" || true

  echo "[4] Destroying old CT ${ctid}..."
  pct destroy "$ctid" || { echo "destroy failed" >&2; return 1; }

  echo "[5] Cloning template ${template} -> CT ${ctid}..."
  local clone_args=(clone "$template" "$ctid" --full)
  [[ -n "$hostname" ]]                 && clone_args+=(--hostname "$hostname")
  [[ -n "$REDEPLOY_CLONE_STORAGE" ]]   && clone_args+=(--storage "$REDEPLOY_CLONE_STORAGE")
  pct "${clone_args[@]}" \
    || { echo "clone failed — roll back: rollback_lxc ${ctid} ${backup_file}" >&2; return 1; }

  echo "[6] Applying saved configuration..."
  local set_args=(set "$ctid") i=0
  [[ -n "$hostname" ]] && set_args+=(--hostname "$hostname")
  [[ -n "$cores" ]]    && set_args+=(--cores "$cores")
  [[ -n "$memory" ]]   && set_args+=(--memory "$memory")
  [[ -n "$swap" ]]     && set_args+=(--swap "$swap")
  [[ -n "$onboot" ]]   && set_args+=(--onboot "$onboot")
  [[ -n "$arch" ]]     && set_args+=(--arch "$arch")
  [[ -n "$startup" ]]  && set_args+=(--startup "$startup")
  [[ -n "$features" ]] && set_args+=(--features "$features")
  [[ -n "$tags" ]]     && set_args+=(--tags "$tags")
  for l in "${net_lines[@]}"; do set_args+=("--net${i}" "${l#*: }"); ((i++)); done
  for l in "${bind_mps[@]}"; do set_args+=("--${l%%|*}" "${l#*|}"); done
  pct "${set_args[@]}" \
    || { echo "pct set failed — roll back: rollback_lxc ${ctid} ${backup_file}" >&2; return 1; }

  # idmap / raw lxc lines: strip the clone's idmap, carry the old ones over
  local newconf="/etc/pve/lxc/${ctid}.conf"
  sed -i '/^lxc\.idmap:/d' "$newconf"
  for l in "${lxc_lines[@]}"; do
    grep -qxF "$l" "$newconf" || printf '%s\n' "$l" >> "$newconf"
  done

  echo "[7] Starting CT ${ctid}..."
  pct start "$ctid" \
    || { echo "start failed — roll back: rollback_lxc ${ctid} ${backup_file}" >&2; return 1; }
  _ct_wait_ready "$ctid" || { echo "CT ${ctid} did not come up — roll back: rollback_lxc ${ctid} ${backup_file}" >&2; return 1; }

  echo "[8] Restoring /opt..."
  pct exec "$ctid" -- tar xzf - -C / < "$optfile" \
    || { echo "restore /opt failed — roll back: rollback_lxc ${ctid} ${backup_file}" >&2; return 1; }

  if [[ -s "$preservefile" ]]; then
    echo "[8b] Restoring preserved base-system paths..."
    pct exec "$ctid" -- tar xzf - -C / < "$preservefile" \
      || { echo "restore preserve failed — roll back: rollback_lxc ${ctid} ${backup_file}" >&2; return 1; }
    echo "[8c] Reloading systemd + rebooting to activate restored services..."
    pct exec "$ctid" -- systemctl daemon-reload </dev/null 2>/dev/null || true
    pct reboot "$ctid" 2>/dev/null || { pct stop "$ctid"; pct start "$ctid"; }
    _ct_wait_ready "$ctid" || echo "  (warning: CT slow to return after reboot)"
  fi

  echo "[9] Bringing docker stacks up..."
  pct exec "$ctid" -- bash -c 'systemctl start docker 2>/dev/null || true' </dev/null
  type -t compose_up_all >/dev/null && compose_up_all "$ctid" || true

  echo
  echo "✔ CT ${ctid} redeployed from template ${template}."
  echo "  Rollback:     rollback_lxc ${ctid} ${backup_file}"
  echo "  /opt archive: ${optfile}"
  [[ -s "$preservefile" ]] && echo "  preserve archive: ${preservefile}"
}

# Restore a CT from a vzdump backup (the redeploy rollback point).
# With no file, uses the most recent vzdump for that CTID on the backup storage.
# Leaves the CT stopped. Usage: rollback_lxc <CTID-or-name> [backup-file-or-volid]
rollback_lxc() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root on the Proxmox host" >&2
    return 1
  fi
  local ctid; ctid=$(_resolve_ctid "${1:-}") || return 2
  local file="${2:-}"

  if [[ -z "$file" ]]; then
    file=$(pvesm list "$REDEPLOY_BACKUP_STORAGE" --content backup --vmid "$ctid" 2>/dev/null \
      | awk 'NR>1 {print $1}' | tail -1)
    [[ -n "$file" ]] || { echo "No backup found for CT ${ctid} on ${REDEPLOY_BACKUP_STORAGE}." >&2; return 1; }
    echo "Using latest backup: ${file}"
  fi

  pct stop "$ctid" 2>/dev/null || true
  echo "Restoring CT ${ctid} from ${file}..."
  pct restore "$ctid" "$file" --force \
    || { echo "restore failed" >&2; return 1; }
  echo "✔ CT ${ctid} restored (stopped). Start with: pct start ${ctid}"
}
