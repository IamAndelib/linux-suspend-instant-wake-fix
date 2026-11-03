#!/usr/bin/env bash
# Shared detection helpers for linux-suspend-instant-wake-fix.
# Sourced by diagnose.sh and install.sh -- not meant to be run directly.

# Prints the PCI address of the parent bridge/root port of each NVMe
# controller found on the system, one per line.
nvme_parent_bridges() {
    local nvme_path parent
    for nvme_path in /sys/class/nvme/nvme*; do
        [ -e "$nvme_path/device" ] || continue
        parent=$(basename "$(readlink -f "$nvme_path/device/..")")
        if [[ "$parent" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]$ ]]; then
            echo "$parent"
        fi
    done | sort -u
}

# Prints "ADDRESS STATUS" for every PCI device exposing power/wakeup.
pci_wakeup_devices() {
    local f addr status
    for f in /sys/bus/pci/devices/*/power/wakeup; do
        [ -e "$f" ] || continue
        status=$(cat "$f" 2>/dev/null) || continue
        [ -n "$status" ] || continue
        addr=$(basename "$(dirname "$(dirname "$f")")")
        echo "$addr $status"
    done
}

pci_wakeup_count() {
    cat "/sys/bus/pci/devices/$1/power/wakeup_count" 2>/dev/null || echo 0
}

pci_class_desc() {
    lspci -s "$1" 2>/dev/null | cut -d' ' -f2-
}

# Prints "NAME STATE SYSFS_NODE_OR_DASH" for every /proc/acpi/wakeup entry.
acpi_wakeup_devices() {
    [ -r /proc/acpi/wakeup ] || return 0
    tail -n +2 /proc/acpi/wakeup | while read -r name _sstate status node; do
        [ -n "$name" ] || continue
        st="disabled"
        [[ "$status" == *enabled* ]] && st="enabled"
        echo "$name $st ${node:--}"
    done
}

# A sleep shorter than this counts as an instant wake. Normal resume work
# stretches a true instant wake to several seconds, so this can't be 1-2s.
INSTANT_WAKE_MAX_SECS="${INSTANT_WAKE_MAX_SECS:-10}"

# Kernel log lines from the last 7 days, across boots. Don't use `journalctl
# -k` here: it implies --boot=0, so --since would silently stop at the last
# reboot. Extra arguments are passed through to journalctl.
kernel_journal() {
    command -v journalctl >/dev/null 2>&1 || return 0
    journalctl _TRANSPORT=kernel --since "-7 days" --no-pager -q "$@" 2>/dev/null
}

# Recent kernel log lines matching the xHCI resume-error signature.
journal_evidence() {
    kernel_journal -g "xHC error in resume|USBSTS 0x401" | tail -n 5
}

# Prints "TOTAL INSTANT": completed sleep cycles in the journal, and how many
# of them lasted under INSTANT_WAKE_MAX_SECS.
sleep_cycle_counts() {
    kernel_journal -o short-unix -g "PM: suspend (entry|exit)" |
        awk -v max="$INSTANT_WAKE_MAX_SECS" '
            /PM: suspend entry/ { start = $1; next }
            /PM: suspend exit/  {
                if (start) { total++; if ($1 - start < max) instant++ }
                start = 0
            }
            END { print total + 0, instant + 0 }'
}

# PCI addresses of xHCI controllers that logged a resume error during an
# instant wake -- hardware evidence, not a name-pattern guess. ACPI wakeup
# source naming for the xHCI controller varies by vendor (XHC0, XHCI, PTXH,
# ...), so matching the address seen failing is far more reliable than
# matching a name prefix.
#
# The error alone proves nothing: some controllers log it on every resume,
# including after hours of normal sleep. So only errors logged during a cycle
# that lasted under INSTANT_WAKE_MAX_SECS count.
xhci_journal_culprits() {
    kernel_journal -o short-unix -g "PM: suspend (entry|exit)|xHC error in resume|USBSTS 0x401" |
        awk -v max="$INSTANT_WAKE_MAX_SECS" '
            BEGIN {
                h = "[0-9a-fA-F]"
                addr = h h h h ":" h h ":" h h "\\." h
            }
            /PM: suspend entry/ { start = $1; errors = ""; next }
            /PM: suspend exit/  {
                if (start && $1 - start < max) printf "%s", errors
                start = 0; errors = ""; next
            }
            match($0, addr) { errors = errors substr($0, RSTART, RLENGTH) "\n" }' |
        sort -u
}

sanitize_name() {
    echo "$1" | tr ':.' '--' | tr '[:upper:]' '[:lower:]'
}
