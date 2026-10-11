#!/usr/bin/env bash
#
# Installs S59mjpg_streamer on a Creality K1C and starts it.
#
# Usage: ./install.sh <printer-ip>
#
# Root access must be enabled on the printer first:
#   gear icon -> Root account information -> scroll to the bottom -> tick -> Next Step
# Default credentials: root / creality_2023

set -euo pipefail

PRINTER="${1:-}"
if [ -z "$PRINTER" ]; then
    echo "Usage: $0 <printer-ip>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/S59mjpg_streamer"

if [ ! -f "$SRC" ]; then
    echo "S59mjpg_streamer not found next to this script" >&2
    exit 1
fi

# The printer runs dropbear without an sftp server, so scp needs the legacy protocol (-O).
# Its host key algorithms predate current OpenSSH defaults, hence the explicit -o options.
SSH_OPTS=(
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o ConnectTimeout=10
)

echo "Copying S59mjpg_streamer to $PRINTER"
scp -O "${SSH_OPTS[@]}" "$SRC" "root@$PRINTER:/etc/init.d/S59mjpg_streamer"

# /etc is wiped by firmware updates, keep a copy on the data partition
scp -O "${SSH_OPTS[@]}" "$SRC" "root@$PRINTER:/usr/data/S59mjpg_streamer"

echo "Enabling and starting"
ssh "${SSH_OPTS[@]}" "root@$PRINTER" \
    'chmod +x /etc/init.d/S59mjpg_streamer /usr/data/S59mjpg_streamer; /etc/init.d/S59mjpg_streamer restart'

echo "Checking the stream"
sleep 2
code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://$PRINTER:8080/?action=snapshot" || true)

if [ "$code" = "200" ]; then
    echo "OK: http://$PRINTER:8080/?action=stream"
else
    echo "Snapshot returned HTTP $code. Check that cam_app is running:" >&2
    echo "  ssh root@$PRINTER 'ps w | grep cam_app'" >&2
    exit 1
fi
