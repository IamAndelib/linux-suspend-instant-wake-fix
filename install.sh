#!/usr/bin/env bash
# Fix Linux suspend-wakes-immediately caused by a stale PCIe PME or an
# enabled ACPI wakeup source (commonly the NVMe root port or the xHCI/USB
# controller). See README.md for background; diagnose.sh for read-only
# detection only.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

PREFIX="suspend-wake-fix"
PCI_TARGETS=()
ACPI_TARGETS=()
YES=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: sudo $0 [options]

  --pci ADDRESS   Disable wakeup on this PCI device (e.g. 0000:00:01.1). Repeatable.
  --xhc NAME      Disable this ACPI wakeup source (e.g. XHC0). Repeatable.
  --yes, -y       Don't prompt for confirmation.
  --dry-run       Show what would be done; make no changes. No root required.
  -h, --help      Show this help.

With no --pci/--xhc given, auto-selects only journal-confirmed xHCI
controllers and NVMe root ports currently showing wakeup=enabled, and asks
before touching them. Run ./diagnose.sh first for the full picture, including
weaker name-pattern matches (XHC*/GPP*) that need --pci/--xhc explicitly.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pci) PCI_TARGETS+=("$2"); shift 2 ;;
        --xhc) ACPI_TARGETS+=("$2"); shift 2 ;;
        --yes|-y) YES=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
done

if [ "$DRY_RUN" = 0 ] && [ "$(id -u)" != "0" ]; then
    echo "This needs root (writes /etc/udev and /etc/systemd files). Re-run with sudo." >&2
    exit 1
fi

command -v lspci >/dev/null 2>&1 || { echo "ERROR: lspci not found (install pciutils)." >&2; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "ERROR: systemd not found; this fix relies on systemd." >&2; exit 1; }

explicit=0
[ "${#PCI_TARGETS[@]}" -gt 0 ] && explicit=1
[ "${#ACPI_TARGETS[@]}" -gt 0 ] && explicit=1

# --- Auto-detect candidates when no explicit target was given --------------
if [ "$explicit" = 0 ]; then
    echo "No targets given; detecting currently-enabled wake sources matching the known pattern..."
    echo

    while read -r b; do
        [ -n "$b" ] || continue
        st=$(cat "/sys/bus/pci/devices/$b/power/wakeup" 2>/dev/null || echo "")
        [ "$st" = "enabled" ] && PCI_TARGETS+=("$b")
    done < <(nvme_parent_bridges)

    while read -r addr; do
        [ -n "$addr" ] || continue
        st=$(cat "/sys/bus/pci/devices/$addr/power/wakeup" 2>/dev/null || echo "")
        if [ "$st" = "enabled" ]; then
            already=0
            for existing in "${PCI_TARGETS[@]}"; do [ "$existing" = "$addr" ] && already=1; done
            [ "$already" = 0 ] && PCI_TARGETS+=("$addr")
        fi
    done < <(xhci_journal_culprits)

    if [ "${#PCI_TARGETS[@]}" -eq 0 ] && [ "${#ACPI_TARGETS[@]}" -eq 0 ]; then
        echo "Nothing journal-confirmed or matching the NVMe-root-port pattern is currently"
        echo "enabled. Run ./diagnose.sh for the full report, including weaker name-pattern"
        echo "matches (XHC*/GPP*) that this auto-mode intentionally skips -- target those"
        echo "explicitly with --pci/--xhc if diagnose.sh points you at one."
        exit 0
    fi
fi

echo "Targets:"
for addr in "${PCI_TARGETS[@]}"; do echo "  PCI  $addr  ($(pci_class_desc "$addr"))"; done
for name in "${ACPI_TARGETS[@]}"; do echo "  ACPI $name"; done
echo

if [ "$DRY_RUN" = 0 ] && [ "$YES" = 0 ]; then
    read -r -p "Disable wakeup on the above? A udev rule + systemd service will be installed for each. [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted, nothing changed."; exit 0; }
fi

apply_pci() {
    local addr="$1" tag rule svc cur
    tag=$(sanitize_name "$addr")
    rule="/etc/udev/rules.d/99-${PREFIX}-${tag}.rules"
    svc="/etc/systemd/system/${PREFIX}-${tag}.service"

    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] would write $rule"
        echo "[dry-run] would write $svc (enable + start)"
        return
    fi

    if [ ! -e "/sys/bus/pci/devices/$addr" ]; then
        echo "WARNING: $addr not found under /sys/bus/pci/devices, skipping." >&2
        return
    fi

    echo "ACTION==\"add\", SUBSYSTEM==\"pci\", KERNEL==\"$addr\", ATTR{power/wakeup}=\"disabled\"" > "$rule"

    cat > "$svc" <<EOF
[Unit]
Description=Disable PCIe wakeup on $addr before suspend (linux-suspend-instant-wake-fix)
Before=suspend.target systemd-suspend.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo disabled > /sys/bus/pci/devices/$addr/power/wakeup'

[Install]
WantedBy=suspend.target
EOF

    udevadm control --reload-rules
    udevadm trigger --action=add --sysname-match="$addr"
    udevadm settle
    systemctl daemon-reload
    systemctl enable --now "${PREFIX}-${tag}.service"

    cur=$(cat "/sys/bus/pci/devices/$addr/power/wakeup")
    echo "PCI $addr: wakeup=$cur  (rule: $rule, service: $svc)"
}

apply_acpi() {
    local name="$1" tag svc node pci_addr state
    node=$(acpi_wakeup_devices | awk -v n="$name" '$1==n{print $3; exit}')

    if [ -n "${node:-}" ] && [ "$node" != "-" ] && [[ "$node" == pci:* ]]; then
        # Has a real sysfs node -- use the PCI power/wakeup file instead of
        # /proc/acpi/wakeup, which toggles on every write and is unsafe to
        # re-run unconditionally before every suspend.
        pci_addr="${node#pci:}"
        if [ -e "/sys/bus/pci/devices/$pci_addr" ]; then
            echo "ACPI $name has sysfs node $node -- using the PCI sysfs interface for it (not a toggle)."
            apply_pci "$pci_addr"
            return
        fi
    fi

    tag=$(sanitize_name "$name")
    svc="/etc/systemd/system/${PREFIX}-${tag}.service"

    if [ "$DRY_RUN" = 1 ]; then
        echo "[dry-run] would write $svc (state-guarded ACPI toggle for $name), enable + start it"
        return
    fi

    # No sysfs node available: fall back to /proc/acpi/wakeup, guarding the
    # write so it only fires when the source is currently *enabled* --
    # writing unconditionally would re-enable it on the next run.
    cat > "$svc" <<EOF
[Unit]
Description=Disable ACPI wakeup source $name before suspend (linux-suspend-instant-wake-fix)
Before=suspend.target systemd-suspend.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'grep -q "^$name\\b.*\\*enabled" /proc/acpi/wakeup && echo $name > /proc/acpi/wakeup || true'

[Install]
WantedBy=suspend.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${PREFIX}-${tag}.service"

    state=$(acpi_wakeup_devices | awk -v n="$name" '$1==n{print $2; exit}')
    echo "ACPI $name: state=$state  (service: $svc)"
}

for addr in "${PCI_TARGETS[@]}"; do apply_pci "$addr"; done
for name in "${ACPI_TARGETS[@]}"; do apply_acpi "$name"; done

echo
if [ "$DRY_RUN" = 1 ]; then
    echo "Dry run only -- nothing was changed."
else
    echo "Done. Test it properly: suspend, wake, then suspend again immediately."
    echo "The second suspend is what actually proves the fix -- see README.md."
fi
