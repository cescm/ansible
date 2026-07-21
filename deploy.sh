#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VAULT_PASS_FILE="${VAULT_PASS_FILE:-$SCRIPT_DIR/.vault_pass}"

if [ ! -f "$VAULT_PASS_FILE" ]; then
  echo "ERROR: Vault password file not found at $VAULT_PASS_FILE"
  echo "Create it with:"
  echo "  echo 'your-vault-password' > $VAULT_PASS_FILE && chmod 600 $VAULT_PASS_FILE"
  exit 1
fi

TAGS="${TAGS:-common,ssh,docker,rclone,samba,scripts,nvidia,mergerfs,opencode}"
LIMIT="${LIMIT:-all}"

echo "============================================"
echo " Homelab Ansible Provisioner"
echo " Target: $LIMIT"
echo " Tags: $TAGS"
echo "============================================"

exec ansible-playbook playbook.yml \
  --limit "$LIMIT" \
  --tags "$TAGS" \
  --vault-password-file "$VAULT_PASS_FILE" \
  "$@"
