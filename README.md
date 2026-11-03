# Linux Suspend Instant-Wake Fix

Fixes the common Linux suspend bug where the machine resumes within a second
or two of going to sleep, every time. Diagnoses the cause instead of guessing,
then disables the specific wake source responsible.

## The bug

Suspend to RAM (S3) doesn't fail quietly — it wakes because some piece of
hardware sent a wake signal and the kernel obeyed it, exactly as designed.
Two components cause this far more often than anything else:

- **A PCIe device sending a stale PME** (Power Management Event). The usual
  source is the PCIe root port your NVMe SSD is plugged into: the port has
  wake-up enabled by default, the NVMe fires a PME during an earlier
  suspend/resume, and the signal gets left "stuck" asserted instead of
  clearing. The next suspend, the kernel sees the stuck signal and pulls the
  system straight back out of sleep.
- **A USB (xHCI) controller failing to suspend cleanly.** Look for this in
  your logs:
  ```
  xhci_hcd 0000:02:00.0: xHC error in resume, USBSTS 0x401, Reinit
  ```
  That's the USB controller failing its resume handshake and reinitializing.
  Confirmed as a real, actively-discussed kernel regression:
  [bugzilla.kernel.org #216470](https://bugzilla.kernel.org/show_bug.cgi?id=216470).
  The error alone doesn't prove an instant wake, because some controllers log
  it on every resume, even after hours of normal sleep. This tool only treats
  it as evidence when it was logged during a sleep that lasted under 10 seconds.

Both produce the same symptom: suspend, then near-instant resume, every time.
It shows up across laptops with NVMe SSDs, AMD Ryzen desktops (B550/X670E
boards come up constantly in bug reports, often right after a BIOS update),
and all-in-ones where a USB touchscreen shares power with the display. It's
not distro-specific — the same root cause is reported under Arch, Ubuntu,
Fedora, and Mint, because it lives in the kernel's USB/PCI power management
code. See [Related reading](#related-reading) below for the specific reports.

## What this tool does differently from a copy-pasted forum fix

This bug is hardware-specific — the exact PCI address or ACPI wakeup name
varies per machine, so there's no one command to paste. This tool:

1. **Diagnoses first.** `diagnose.sh` finds your NVMe's parent PCI root port,
   lists every PCI device with wakeup enabled, parses `/proc/acpi/wakeup`,
   and checks the last 7 days of the journal, across reboots, for xHC resume
   errors during instant wakes — read-only, no root.
2. **Only touches devices matching the known pattern** (the NVMe's own root
   port, or an ACPI source named `XHC*`/`GPP*`) unless you explicitly pass
   `--pci`/`--xhc` for something else. It won't blindly disable every
   "enabled" wake source it finds — some of those may be intentional (e.g.
   Wake-on-LAN, Bluetooth wake for a keyboard).
3. **Fixes a real correctness bug in the naive version of this fix.**
   Writing to `/proc/acpi/wakeup` *toggles* the device's state rather than
   setting it — so a systemd service that unconditionally writes `XHC0` to
   it before every suspend will re-enable the wake source the next time it
   runs, undoing the fix. When the ACPI entry exposes a sysfs node (most
   xHCI controllers do — visible as `pci:0000:XX:XX.X` in
   `/proc/acpi/wakeup`), this tool uses the PCI `power/wakeup` file instead,
   which is a direct set, not a toggle, and reaches the same underlying
   wakeup flag. It only falls back to the ACPI toggle file for the rare
   device with no sysfs node, and guards that write so it only fires when
   the source is currently enabled.
4. **Backs the udev rule with a systemd service**, since a udev rule only
   runs at boot — if a driver's resume routine, a power tool, or a kernel
   update re-arms the wake flag afterward, the udev rule alone won't catch
   it again until next boot. The systemd service (`Before=suspend.target`)
   re-applies the fix immediately before every suspend.
5. **Supports `--dry-run`** so you can see exactly what would be written
   before anything touches `/etc`.

## Step 1: diagnose

```bash
git clone https://github.com/IamAndelib/linux-suspend-instant-wake-fix.git
cd linux-suspend-instant-wake-fix
./diagnose.sh
```

No root needed. It prints a verdict telling you which device is likely
responsible and the exact `install.sh` command to fix it.

## Step 2: fix it

```bash
sudo ./install.sh
```

With no arguments it re-runs the same detection as `diagnose.sh`, shows you
exactly what it found, and asks for confirmation before writing anything.
To target a specific device instead:

```bash
sudo ./install.sh --pci 0000:00:01.1     # a PCIe root port / bridge
sudo ./install.sh --xhc XHC0             # an ACPI wakeup source
```

Preview without changing anything (no root required):

```bash
./install.sh --dry-run
```

## Testing it properly

This bug is order-dependent — one successful suspend doesn't prove anything:

1. Reboot, then confirm the flag is already disabled with no manual steps.
2. Suspend once, confirm it stays asleep for a couple of minutes.
3. Wake it, then suspend again immediately without touching anything else.
   This second suspend is the real test — it's what tells you whether
   something re-armed the wake flag after the first resume, which is
   exactly what the systemd service exists to prevent.
4. If both rounds stay asleep, you're done.

## Other angles worth knowing about

- **BIOS/UEFI**, if your board offers it: look for "Wake on PCI-E", "PCIe
  device wake", or "Wake on PME" (sometimes bundled under "Wake on LAN").
  This silences the problem before the OS is even involved and survives
  reinstalls. Be cautious with "ErP Ready" — it can also affect suspend
  behavior, not always helpfully.
- **Keep the NVMe out of its deepest power state**, as an alternative if
  disabling wake-up isn't practical: `echo on | sudo tee
  /sys/bus/pci/devices/<addr>/power/control`, or the kernel parameter
  `nvme_core.default_ps_max_latency_us=0`. Trades a little idle power for
  sidestepping the power-state transition that triggers the PME.
- In a minority of reports, some ACPI wake sources were disabled in both
  software and BIOS and the problem still didn't fully clear — a reminder
  that this occasionally sits below what the OS can control, and firmware
  or hardware may share the blame.

## Uninstall

```bash
sudo ./uninstall.sh
```

Removes every udev rule and systemd service this tool created and reloads
udev/systemd. Wakeup flags return to their default, driver/firmware-decided
state the next time the device is reinitialized (typically next boot).

## Related reading

- [Arch Linux forums: xhci_hcd xHC error in resume, USBSTS 0x401, Reinit](https://bbs.archlinux.org/viewtopic.php?id=300818)
- [Ubuntu bug #2020176: system fails to suspend as it resumes immediately](https://bugs.launchpad.net/bugs/2020176)
- [kernel.org Bugzilla #216470: xHC error in resume, USBSTS 0x401, Reinit](https://bugzilla.kernel.org/show_bug.cgi?id=216470)
- [Ubuntu bug #2002237: ASUS ROG STRIX X670E / Ryzen 9 7900X](https://bugs.launchpad.net/bugs/2002237)
- [Linux Mint forums: Gigabyte B550 Aorus, fixed with a systemd service after a BIOS update](https://forums.linuxmint.com/viewtopic.php?t=429873)
- [Unraid forums: USB xHC error in resume](https://forums.unraid.net/topic/143540-usb-xhc-error-in-resume/)

## License

MIT — see [LICENSE](LICENSE).
