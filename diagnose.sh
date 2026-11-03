#!/usr/bin/env bash
# Read-only diagnostic for "suspend wakes up immediately" (stale PCIe PME /
# xHCI resume failure). Makes no changes -- safe to run any time, no root
# required (journal evidence may be limited without journalctl access).
set -uo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

echo "=== Linux suspend instant-wake diagnostic ==="
echo

echo "-- NVMe parent root port(s) --"
bridges=$(nvme_parent_bridges)
if [ -z "$bridges" ]; then
    echo "  No NVMe device found behind a discrete PCI bridge."
else
    while read -r b; do
        [ -n "$b" ] || continue
        st=$(cat "/sys/bus/pci/devices/$b/power/wakeup" 2>/dev/null || echo "unknown")
        cnt=$(pci_wakeup_count "$b")
        desc=$(pci_class_desc "$b")
        echo "  $b  wakeup=$st  wakeup_count=$cnt  ($desc)"
    done <<< "$bridges"
fi
echo

echo "-- All PCI devices with wakeup enabled --"
found_pci=0
while read -r addr status; do
    [ "$status" = "enabled" ] || continue
    found_pci=1
    cnt=$(pci_wakeup_count "$addr")
    desc=$(pci_class_desc "$addr")
    echo "  $addr  wakeup_count=$cnt  ($desc)"
done < <(pci_wakeup_devices)
[ "$found_pci" = 1 ] || echo "  (none)"
echo

echo "-- ACPI wakeup sources (/proc/acpi/wakeup) --"
found_acpi=0
while read -r name state node; do
    found_acpi=1
    marker=""
    [[ "$name" == XHC* || "$name" == GPP* || "$name" == GPRW* ]] && marker="   <-- common culprit pattern"
    echo "  $name  $state  sysfs=$node$marker"
done < <(acpi_wakeup_devices)
[ "$found_acpi" = 1 ] || echo "  (unreadable or empty)"
echo

echo "-- Journal evidence: xHC resume errors, last 7 days --"
ev=$(journal_evidence)
if [ -n "$ev" ]; then
    echo "$ev" | sed 's/^/  /'
else
    echo "  none found (or journalctl unavailable without elevated permissions)"
fi
echo

echo "-- Sleep cycles, last 7 days --"
read -r cycles_total cycles_instant <<< "$(sleep_cycle_counts)"
echo "  $cycles_total completed, $cycles_instant lasted under ${INSTANT_WAKE_MAX_SECS}s"
echo

echo "-- Journal-confirmed xHCI controller(s) --"
journal_culprits=$(xhci_journal_culprits)
found_jc=0
while read -r addr; do
    [ -n "$addr" ] || continue
    found_jc=1
    st=$(cat "/sys/bus/pci/devices/$addr/power/wakeup" 2>/dev/null || echo "unknown")
    desc=$(pci_class_desc "$addr")
    echo "  $addr  wakeup=$st  ($desc)  -- logged a resume error during a sleep under ${INSTANT_WAKE_MAX_SECS}s"
done <<< "$journal_culprits"
if [ "$found_jc" = 0 ]; then
    echo "  (none -- no resume error was logged during a sleep under ${INSTANT_WAKE_MAX_SECS}s)"
    [ -z "$ev" ] || echo "  Resume errors on normal-length sleeps don't indicate an instant wake."
fi
echo

echo "=== Verdict ==="
verdict_found=0
if [ -n "$journal_culprits" ]; then
    while read -r addr; do
        [ -n "$addr" ] || continue
        st=$(cat "/sys/bus/pci/devices/$addr/power/wakeup" 2>/dev/null || echo "")
        if [ "$st" = "enabled" ]; then
            echo "  Likely culprit (confirmed by journal): $addr has wakeup=enabled and logged a resume error during an instant wake."
            echo "    A sleep this short can also be you waking the machine yourself -- check that it matches what you saw."
            echo "    Fix with: sudo ./install.sh --pci $addr"
            verdict_found=1
        fi
    done <<< "$journal_culprits"
fi
if [ -n "$bridges" ]; then
    while read -r b; do
        [ -n "$b" ] || continue
        st=$(cat "/sys/bus/pci/devices/$b/power/wakeup" 2>/dev/null || echo "")
        if [ "$st" = "enabled" ]; then
            echo "  Likely culprit: PCI bridge $b (NVMe root port) has wakeup=enabled."
            echo "    Fix with: sudo ./install.sh --pci $b"
            verdict_found=1
        fi
    done <<< "$bridges"
fi
acpi_pattern_hit=0
while read -r name state node; do
    if [ "$state" = "enabled" ] && [[ "$name" == XHC* || "$name" == GPP* ]]; then
        acpi_pattern_hit=1
        echo "  Possible culprit (name pattern only, not journal-confirmed): ACPI source $name, sysfs=$node."
        echo "    Investigate, then fix with: sudo ./install.sh --xhc $name"
    fi
done < <(acpi_wakeup_devices)
[ "$acpi_pattern_hit" = 1 ] && verdict_found=1

if [ "$verdict_found" = 0 ]; then
    echo "  No enabled wake source matching a known pattern was found right now."
    echo "  wakeup_count only increments after an actual wake, so if you're still seeing"
    echo "  instant resume, re-run this right after a failed suspend/resume cycle, and"
    echo "  check the 'All PCI devices with wakeup enabled' and ACPI sections above by hand"
    echo "  -- your culprit may be a device outside the common NVMe/XHC/GPP pattern."
fi
echo
echo "Note: name-pattern matches (XHC*/GPP*) are commonly right but not vendor-universal --"
echo "the ACPI name for the same physical xHCI controller varies (XHC0, XHCI, PTXH, ...)."
echo "A journal-confirmed match above is the strongest signal; 'install.sh' with no"
echo "arguments only auto-selects journal-confirmed and NVMe-root-port matches, never"
echo "a bare name-pattern guess -- use --xhc/--pci explicitly for those."
