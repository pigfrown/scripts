set -euo pipefail

# --- Settings ---
GPG_RECIP="2D5B59DD15F376AD4EC6D6F41286EF9CAC1CF0EA"
CIPHER_DIR="$HOME/wb"
MOUNT_DIR="$HOME/wb.mount"
PASS_GPG="$HOME/.config/wb.pass.gpg"
IDLE="30m"   # change to e.g. 10m, 1h, or comment out the -idle flag later

# --- Create dirs ---
mkdir -p "$CIPHER_DIR" "$MOUNT_DIR" "$(dirname "$PASS_GPG")"
chmod 700 "$CIPHER_DIR" "$MOUNT_DIR" "$(dirname "$PASS_GPG")"

# --- Create a random passphrase, encrypt it to your GPG key, and delete plaintext copy ---
umask 077
tmp_pass="$(mktemp)"
openssl rand -base64 48 > "$tmp_pass"
gpg --batch --yes --encrypt --recipient "$GPG_RECIP" -o "$PASS_GPG" "$tmp_pass"
shred -u "$tmp_pass"
chmod 600 "$PASS_GPG"

# --- Initialise gocryptfs vault (one-time) ---
tmp_dec="$(mktemp)"
gpg --quiet --decrypt "$PASS_GPG" > "$tmp_dec"
gocryptfs -init -passfile "$tmp_dec" "$CIPHER_DIR"
shred -u "$tmp_dec"

echo
echo "✅ Vault initialised."
echo "Cipher dir: $CIPHER_DIR"
echo "Mount dir : $MOUNT_DIR"
echo "Passphrase: $PASS_GPG (GPG-encrypted)"
echo
echo "Next: mount with the command printed below."
echo

# --- Print mount/unmount commands ---
cat <<EOF
Mount:
  gocryptfs -extpass "gpg --quiet --decrypt $PASS_GPG" -idle $IDLE "$CIPHER_DIR" "$MOUNT_DIR"

Unmount:
  fusermount3 -u "$MOUNT_DIR"
EOF
