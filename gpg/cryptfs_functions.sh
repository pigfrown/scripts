mount-crypt() {
  if [ $# -lt 1 ]; then
    echo "Usage: mount-crypt <cipher_dir> [timeout]"
    echo "  timeout examples: 10m, 2h, 1h30m (default: 2h)"
    return 2
  fi

  local cipher_dir="$1"
  local timeout="${2:-2h}"

  # Expand ~ manually (works in bash/zsh)
  cipher_dir="${cipher_dir/#\~/$HOME}"

  local base
  base="$(basename "$cipher_dir")"

  local mount_dir="${cipher_dir}.mount"
  local pass_gpg="$HOME/.config/${base}.pass.gpg"

  if [ ! -d "$cipher_dir" ]; then
    echo "Error: cipher dir does not exist: $cipher_dir"
    return 1
  fi

  if [ ! -f "$pass_gpg" ]; then
    echo "Error: missing passphrase file: $pass_gpg"
    echo "Expected GPG-encrypted passphrase at that path."
    return 1
  fi

  mkdir -p "$mount_dir"
  chmod 700 "$mount_dir" 2>/dev/null || true

  # If already mounted, exit cleanly
  if mountpoint -q "$mount_dir" 2>/dev/null; then
    echo "Already mounted: $mount_dir"
    return 0
  fi

  echo "Mounting:"
  echo "  cipher: $cipher_dir"
  echo "  mount : $mount_dir"
  echo "  idle  : $timeout"
  echo

  gocryptfs \
    -extpass "gpg --quiet --decrypt $pass_gpg" \
    -idle "$timeout" \
    "$cipher_dir" "$mount_dir"

  echo "Mounted at: $mount_dir"
}

umount-crypt() {
  if [ $# -lt 1 ]; then
    echo "Usage: umount-crypt <cipher_dir>"
    return 2
  fi

  local cipher_dir="$1"
  cipher_dir="${cipher_dir/#\~/$HOME}"
  local mount_dir="${cipher_dir}.mount"

  if [ ! -d "$mount_dir" ]; then
    echo "Error: mount dir does not exist: $mount_dir"
    return 1
  fi

  if ! mountpoint -q "$mount_dir" 2>/dev/null; then
    echo "Not mounted: $mount_dir"
    return 0
  fi

  echo "Unmounting: $mount_dir"
  if command -v fusermount3 >/dev/null 2>&1; then
    fusermount3 -u "$mount_dir"
  else
    fusermount -u "$mount_dir"
  fi

  echo "Unmounted."
}
