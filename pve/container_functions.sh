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

  echo "Stopping CT ${ctid}..."
  pct stop "$ctid"

  # 3. Recreate: set the template flag again (the disk is already a basevol).
  if [[ $was_template -eq 1 ]]; then
    echo "Recreating template from CT ${ctid}..."
    _set_template_flag "$conf"
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
