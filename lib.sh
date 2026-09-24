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

# Recent kernel log lines matching the known instant-resume signature.
journal_evidence() {
    command -v journalctl >/dev/null 2>&1 || return 0
    journalctl -k --since "-7 days" -g "xHC error in resume|USBSTS 0x401" --no-pager -q 2>/dev/null | tail -n 5
}

# PCI addresses of xHCI controllers actually named in a resume-error log
# line -- this is hardware evidence, not a name-pattern guess. ACPI wakeup
# source naming for the xHCI controller varies by vendor (XHC0, XHCI, PTXH,
# ...), so matching the address seen failing is far more reliable than
# matching a name prefix.
xhci_journal_culprits() {
    journal_evidence | grep -oE '[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]' | sort -u
}

sanitize_name() {
    echo "$1" | tr ':.' '--' | tr '[:upper:]' '[:lower:]'
}
