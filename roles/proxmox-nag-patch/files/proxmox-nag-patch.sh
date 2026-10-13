#!/usr/bin/env bash
# proxmox-nag-patch.sh - re-aplica de forma idempotente el parche del aviso
# "No valid subscription" de la UI web de Proxmox.
#
# Sustituye la condicion `status.toLowerCase() !== 'active'` por `false` en
# proxmoxlib.js, de modo que el dialogo del aviso nunca se muestra pero la
# cadena original de commands sigue ejecutandose (orig_cmd()).
#
# Los upgrades de Proxmox sobrescriben proxmoxlib.js al actualizar el paquete
# proxmox-widget-toolkit. Este debil se lanza via DPkg::Post-Invoke tras cada
# operacion apt/dpkg y re-aplica el parche si ha desaparecido.
set -euo pipefail

FILE=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js

[ -f "$FILE" ] || exit 0

# Ya parcheado (o sin el patron original): salir sin tocar nada.
if ! grep -q "status.toLowerCase() !== 'active'" "$FILE"; then
  exit 0
fi

cp -a "$FILE" "${FILE}.bak.$(date +%s)" 2>/dev/null || true

sed -i "s/status.toLowerCase() !== 'active'/false/" "$FILE"

if command -v logger >/dev/null 2>&1; then
  logger -t proxmox-nag-patch "Proxmox subscription nag bypass re-applied to ${FILE}"
fi

echo "proxmox-nag-patch: applied"