#!/usr/bin/env bash
# Wake the Windows gaming PC (Game_On) via Wake-on-LAN magic packet.
#
# Usage:
#   wake-pc.sh            # send packet, wait up to 120s for the PC to answer ping
#   wake-pc.sh --no-wait  # send packet and exit
#
# Needs WoL enabled in BIOS + on the Intel I211 adapter, and Fast Startup off.
# PC_MAC, PC_IP, PC_BCAST come from the environment or the repo's .env (gitignored).
set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env"
if [[ -f "$ENV_FILE" ]]; then
  # only the PC_* lines, never the rest of .env
  while IFS='=' read -r k v; do
    [[ -z "${!k:-}" ]] && export "$k=$v"
  done < <(grep -E '^PC_(MAC|IP|BCAST)=' "$ENV_FILE")
fi
MAC="${PC_MAC:?set PC_MAC in .env}"
IP="${PC_IP:?set PC_IP in .env}"
BCAST="${PC_BCAST:?set PC_BCAST in .env}"

if ping -c1 -W1 "$IP" >/dev/null 2>&1; then
  echo "PC ($IP) is already up."
  exit 0
fi

python3 - "$MAC" "$BCAST" <<'PY'
import socket, sys
mac = bytes.fromhex(sys.argv[1].replace(":", "").replace("-", ""))
pkt = b"\xff" * 6 + mac * 16
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    for port in (9, 7):
        s.sendto(pkt, (sys.argv[2], port))
PY
echo "Magic packet sent to $MAC via $BCAST."

[[ "${1:-}" == "--no-wait" ]] && exit 0

for _ in $(seq 1 60); do
  if ping -c1 -W1 "$IP" >/dev/null 2>&1; then
    echo "PC ($IP) is up."
    exit 0
  fi
  sleep 1
done
echo "PC did not answer ping within ~120s (still booting, or WoL not enabled)." >&2
exit 1
