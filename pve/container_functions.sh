#!/usr/bin/env bash
#
# Functions to manage Debian LXC containers on Proxmox (pct).
#
# Source this file to get the functions in your shell:
#   source /path/to/pve/container_functions.sh
#
# Conventions (match the other scripts in ./pve):
#   - Template container lives at CTID 999.
#   - Functions accept a CTID or a container name.

DEFAULT_TEMPLATE_CTID=999

# vzdump backup defaults (used by backup_lxc; redeploy_lxc passes its own
# overrides). Override in your shell/env.
BACKUP_STORAGE="${BACKUP_STORAGE:-local}"    # vzdump target (needs "backup" content)
BACKUP_KEEP="${BACKUP_KEEP:-3}"              # backups kept per CT (auto-pruned)
BACKUP_MODE="${BACKUP_MODE:-snapshot}"       # snapshot | suspend | stop
BACKUP_COMPRESS="${BACKUP_COMPRESS:-zstd}"   # none | lzo | gzip | zstd

# Resolve a CTID or container name to a CTID.
# Usage: _resolve_ctid <CTID-or-name>
_resolve_ctid() {
  local target="$1"

  if [[ -z "$target" ]]; then
    echo "Must pass a container ID or name" >&2
    return 1
  fi

  if [[ "$target" =~ ^[0-9]+$ ]]; then
    echo "$target"
    return 0
  fi

  local ctid
  ctid=$(pct list | awk -v name="$target" '$3 == name {print $1}')
  if [[ -z "${ctid:-}" ]]; then
    echo "Could not find container with name: $target" >&2
    return 1
  fi
  echo "$ctid"
}

# Update a Debian container: apt update / upgrade / autoremove.
# Usage: update_debian <CTID-or-name>
update_debian() {
  local ctid
  ctid=$(_resolve_ctid "${1:-}") || return 1

  echo "Updating CT ${ctid}..."
  pct exec "$ctid" -- bash -c "apt update && apt upgrade -y && apt autoremove -y"
  echo "✔ CT ${ctid} updated."
}

# Load a template (convert back to a normal container), update it, then
# re-create the template.
#
# In Proxmox a template is really two things: the `template: 1` flag in the
# config AND a disk stored as a base volume (basevol-<id>-disk-N). A template
# can't be started, so to update it we just toggle the flag:
#   1. Clear the template flag        ("load")
#   2. Start it, run update_debian, stop it
#   3. Set the template flag again    ("recreate")
#
# Note: we do NOT use `pct template` to re-create. That command only converts a
# normal disk into a base volume (the first-time conversion); on an already-
# templated container the disk is already a basevol, so it fails with
# "Template feature is not available for '<storage>:basevol-...'". Re-adding the
# config flag is all that's needed.
#
# Usage: update_template [CTID-or-name]   (defaults to CTID 999)
update_template() {
  local ctid
  ctid=$(_resolve_ctid "${1:-$DEFAULT_TEMPLATE_CTID}") || return 1

  if [[ $EUID -ne 0 ]]; then
    echo "This function must be run as root on the Proxmox host" >&2
    return 1
  fi

  local conf="/etc/pve/lxc/${ctid}.conf"
  if [[ ! -f "$conf" ]]; then
    echo "Config not found: ${conf}" >&2
    return 1
  fi

  local was_template=0
  if grep -q '^template: 1$' "$conf"; then
    was_template=1
  fi

  # 1. Load: clear the template flag so the container can start.
  if [[ $was_template -eq 1 ]]; then
    echo "Loading template CT ${ctid} (clearing template flag)..."
    sed -i '/^template: 1$/d' "$conf"
  else
    echo "CT ${ctid} is not a template; updating it in place."
  fi

  # 2. Update: start, update, stop.
  echo "Starting CT ${ctid}..."
  pct start "$ctid"

  # Give the container a moment to bring up networking before apt runs.
  sleep 5

  if ! update_debian "$ctid"; then
    echo "Update failed; stopping CT ${ctid} and restoring template flag." >&2
    pct stop "$ctid" || true
    [[ $was_template -eq 1 ]] && _set_template_flag "$conf"
    return 1
  fi

  echo
  echo "  CT ${ctid} is running. Exec in to make additional changes:"
  echo "    pct exec ${ctid} -- bash"
  echo
  local reply
  read -r -p "  Finalise? [Y/n] " reply
  case "${reply,,}" in
    n|no)
      echo "Aborted — stopping CT ${ctid} and restoring template flag (version not bumped)." >&2
      pct stop "$ctid" || true
      [[ $was_template -eq 1 ]] && _set_template_flag "$conf"
      return 1
      ;;
  esac

  echo "Stopping CT ${ctid}..."
  pct stop "$ctid"

  # 3. Recreate: set the template flag again (the disk is already a basevol).
  if [[ $was_template -eq 1 ]]; then
    echo "Recreating template from CT ${ctid}..."
    _set_template_flag "$conf"
    _tmpl_bump_ver "$ctid"
    echo "✔ Template CT ${ctid} updated and re-created."
  else
    echo "✔ CT ${ctid} updated (left as a normal container)."
  fi
}

# Add `template: 1` to the main section of a container config, unless already set.
_set_template_flag() {
  local conf="$1"
  grep -q '^template: 1$' "$conf" || sed -i '1i template: 1' "$conf"
}

# ── Container tag helpers ──────────────────────────────────────────────────────

# True if the container's config carries the given tag.
_ct_has_tag() {
  local tags
  tags=$(pct config "$1" 2>/dev/null | awk -F': ' '/^tags:/{print $2}')
  [[ ";${tags};" == *";${2};"* ]]
}

# Add a tag to a container, preserving existing tags. No-op if already set.
# (pct set --tags REPLACES the whole list, so we read, append, and write back.)
_ct_add_tag() {
  local ctid="$1" tag="$2" tags
  _ct_has_tag "$ctid" "$tag" && return 0
  tags=$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^tags:/{print $2}')
  [[ -n "$tags" ]] && tags="${tags};${tag}" || tags="$tag"
  pct set "$ctid" --tags "$tags"
}

# Remove a specific tag from a container. No-op if not present.
_ct_remove_tag() {
  local ctid="$1" tag="$2" tags new_tags
  tags=$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^tags:/{print $2}')
  new_tags=$(printf '%s' "$tags" | tr ';' '\n' | grep -xvF "$tag" | grep -v '^$' \
               | tr '\n' ';' | sed 's/;$//')
  [[ "$tags" == "$new_tags" ]] && return 0
  pct set "$ctid" --tags "$new_tags"
}

# Remove all tags with the given prefix, then stamp new_tag in their place.
# Used to replace versioned tags like tmplver-1 → tmplver-2.
_ct_replace_tag_prefix() {
  local ctid="$1" prefix="$2" new_tag="$3" tags new_tags
  tags=$(pct config "$ctid" 2>/dev/null | awk -F': ' '/^tags:/{print $2}')
  new_tags=$(printf '%s' "$tags" | tr ';' '\n' | grep -v "^${prefix}" | grep -v '^$' \
               | tr '\n' ';' | sed 's/;$//')
  [[ -n "$new_tags" ]] && new_tags="${new_tags};${new_tag}" || new_tags="$new_tag"
  pct set "$ctid" --tags "$new_tags"
}

# ── Template version helpers ───────────────────────────────────────────────────
#
# Template version is tracked via a PVE tag on the template CT itself:
#   tmplver-N   (e.g. tmplver-1, tmplver-2)
#
# Containers deployed by redeploy_lxc get a corresponding tag:
#   from-<tmplCTID>-v<N>   (e.g. from-999-v2)
#
# Use lxc_template_status to see which containers are current or stale.

# Print the current version number of a template CT (0 if unversioned).
_tmpl_get_ver() {
  local tags ver
  tags=$(pct config "$1" 2>/dev/null | awk -F': ' '/^tags:/{print $2}')
  ver=$(printf '%s' "$tags" | tr ';' '\n' | sed -n 's/^tmplver-//p' | tail -1)
  echo "${ver:-0}"
}

# Increment the tmplver-N tag on a template CT (creates v1 if unversioned).
_tmpl_bump_ver() {
  local ctid="$1" cur next
  cur=$(_tmpl_get_ver "$ctid")
  next=$(( cur + 1 ))
  _ct_replace_tag_prefix "$ctid" "tmplver-" "tmplver-${next}"
  echo "  template version: v${cur} → v${next}"
}

# Take a full vzdump backup of a container — its config + every PVE-managed
# volume (rootfs and storage-backed mountpoints). Host bind mounts are NOT
# included (that's external data living outside the CT). This is the same
# archive redeploy_lxc takes as its rollback point, so any backup in these
# scripts goes through here.
#
# The archive lands on $BACKUP_STORAGE and old ones are auto-pruned to the last
# $BACKUP_KEEP per CT. Defaults come from the BACKUP_* vars above; flags
# override per-call. vzdump's own output streams to stderr; the resulting
# archive path is printed to stdout (and nothing else), so callers can capture
# it:  file=$(backup_lxc 118)
#
# Must run as root on the Proxmox host.
# Usage: backup_lxc <CTID-or-name> [--storage S] [--keep N] [--mode M] [--compress C]
backup_lxc() {
  if [[ $EUID -ne 0 ]]; then
    echo "Run as root on the Proxmox host" >&2
    return 1
  fi

  local storage="$BACKUP_STORAGE" keep="$BACKUP_KEEP" mode="$BACKUP_MODE" compress="$BACKUP_COMPRESS"
  local a pos=()
  while [[ $# -gt 0 ]]; do
    a=$1
    case "$a" in
      --storage)    storage=$2; shift ;;
      --storage=*)  storage=${a#--storage=} ;;
      --keep)       keep=$2; shift ;;
      --keep=*)     keep=${a#--keep=} ;;
      --mode)       mode=$2; shift ;;
      --mode=*)     mode=${a#--mode=} ;;
      --compress)   compress=$2; shift ;;
      --compress=*) compress=${a#--compress=} ;;
      *)            pos+=("$a") ;;
    esac
    shift
  done

  local ctid
  ctid=$(_resolve_ctid "${pos[0]:-}") || return 1
  [[ -f "/etc/pve/lxc/${ctid}.conf" ]] || { echo "No such CT: ${ctid}" >&2; return 1; }

  echo "vzdump CT ${ctid} (mode ${mode}, ${compress}) -> ${storage}, keep-last=${keep}..." >&2
  # Capture vzdump's output (to parse the archive path) but replay it to stderr,
  # so the caller's stdout stays clean — just the archive path. Direct
  # assignment keeps $? as vzdump's own exit status (no masking pipe).
  local out rc
  out=$(vzdump "$ctid" --mode "$mode" --compress "$compress" --storage "$storage" \
          --prune-backups "keep-last=${keep}" 2>&1); rc=$?
  printf '%s\n' "$out" >&2
  if [[ $rc -ne 0 ]]; then
    echo "vzdump failed for CT ${ctid}." >&2
    return 1
  fi

  local file
  file=$(sed -n "s/.*creating vzdump archive '\([^']*\)'.*/\1/p" <<<"$out" | tail -1)
  if [[ -z "$file" ]]; then
    echo "backup_lxc: could not parse archive path from vzdump output (see above)." >&2
    return 1
  fi
  echo "✔ CT ${ctid} backed up: ${file}" >&2
  printf '%s\n' "$file"
}
