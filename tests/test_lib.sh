#!/usr/bin/env bash
# Tests the journal parsing in lib.sh against a stubbed journalctl.
# Run: ./tests/test_lib.sh
set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fails=0

# Fails like the real journal would hide data: -k means current boot only.
# Otherwise prints the fixture lines matching the -g pattern.
cat > "$WORK/journalctl" <<'EOF'
#!/usr/bin/env bash
pattern=""
while [ $# -gt 0 ]; do
    case "$1" in
        -k|--dmesg) exit 0 ;;
        -g|--grep) pattern="$2"; shift ;;
    esac
    shift
done
grep -E "$pattern" "$FIXTURE"
EOF
chmod +x "$WORK/journalctl"
export PATH="$WORK:$PATH"

# shellcheck source=../lib.sh
source "$ROOT/lib.sh"

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok   - $name"
    else
        echo "FAIL - $name: expected [$expected], got [$actual]"
        fails=$((fails + 1))
    fi
}

export FIXTURE="$WORK/journal"
ERR="xhci_hcd 0000:02:00.0: xHC error in resume, USBSTS 0x401, Reinit"
ERR2="xhci_hcd 0000:09:00.3: xHC error in resume, USBSTS 0x401, Reinit"

# Normal sleep with the error: not evidence of anything.
cat > "$FIXTURE" <<EOF
1000.000000 host kernel: PM: suspend entry (deep)
4600.000000 host kernel: $ERR
4600.100000 host kernel: PM: suspend exit
EOF
check "error during a long sleep is not a culprit" "" "$(xhci_journal_culprits)"
check "long sleep counts as a cycle, not instant" "1 0" "$(sleep_cycle_counts)"
check "error is still shown as raw evidence (needs no -k)" \
    "1" "$(journal_evidence | grep -c 'xHC error')"

# Instant wake with the error.
cat > "$FIXTURE" <<EOF
1000.000000 host kernel: PM: suspend entry (deep)
1004.000000 host kernel: $ERR
1004.500000 host kernel: PM: suspend exit
EOF
check "error during an instant wake is a culprit" "0000:02:00.0" "$(xhci_journal_culprits)"
check "instant wake is counted" "1 1" "$(sleep_cycle_counts)"

# A long cycle's error must not leak into the next, instant cycle.
cat > "$FIXTURE" <<EOF
1000.000000 host kernel: PM: suspend entry (deep)
4600.000000 host kernel: $ERR2
4600.100000 host kernel: PM: suspend exit
5000.000000 host kernel: PM: suspend entry (deep)
5004.000000 host kernel: $ERR
5004.500000 host kernel: PM: suspend exit
EOF
check "only the instant cycle's controller is named" "0000:02:00.0" "$(xhci_journal_culprits)"
check "mixed cycles are counted" "2 1" "$(sleep_cycle_counts)"

# Interrupted cycle (crash or power loss during sleep), then a new boot.
cat > "$FIXTURE" <<EOF
1000.000000 host kernel: PM: suspend entry (deep)
1001.000000 host kernel: $ERR2
9000.000000 host kernel: PM: suspend entry (deep)
9900.000000 host kernel: PM: suspend exit
EOF
check "interrupted cycle's error is dropped" "" "$(xhci_journal_culprits)"
check "interrupted cycle isn't counted" "1 0" "$(sleep_cycle_counts)"

: > "$FIXTURE"
check "empty journal has no culprits" "" "$(xhci_journal_culprits)"
check "empty journal counts zero" "0 0" "$(sleep_cycle_counts)"

[ "$fails" = 0 ] && echo "All passed." || { echo "$fails failed."; exit 1; }
