#!/usr/bin/env bash
set -euo pipefail
PREFIX="suspend-wake-fix"

if [ "$(id -u)" != "0" ]; then
    echo "This needs root. Re-run with sudo." >&2
    exit 1
fi

echo "Removing linux-suspend-instant-wake-fix units and rules..."

for svc in /etc/systemd/system/${PREFIX}-*.service; do
    [ -e "$svc" ] || continue
    echo "  disabling $(basename "$svc")"
    systemctl disable --now "$(basename "$svc")" 2>/dev/null || true
    rm -f "$svc"
done

for rule in /etc/udev/rules.d/99-${PREFIX}-*.rules; do
    [ -e "$rule" ] || continue
    echo "  removing $(basename "$rule")"
    rm -f "$rule"
done

systemctl daemon-reload
udevadm control --reload-rules 2>/dev/null || true

echo "Done. Wakeup flags return to their default (driver/firmware-decided) state the"
echo "next time the affected device is reinitialized -- typically the next reboot."
