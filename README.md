# t2-suspend-dispatch

Installer for a hardware-aware `systemd` suspend/resume workaround on Apple T2 Macs running Linux.

- Detects Apple T2 hardware traits needed for suspend/resume handling.
- Detects model identifier, dGPU presence, `apple_gmux force_igd`, Touch Bar, `tiny-dfr`, BCM4377, and keyboard type.
- Installs `t2-suspend.service`.
- Installs `t2-wakeup-guard.service`.
- Ensures the kernel arguments `mem_sleep_default=deep`, `pcie_ports=native`, and `pcie_aspm=off`.
- Supports GRUB, `grubby`, and `systemd-boot` based setups.
- Disables enabled `S3` wake sources from `/proc/acpi/wakeup`.
- Removes older T2 suspend fix units if present.
- Renders the suspend unit from a fixed master order and comments out unsupported blocks.
- Supports optional `PipeWire`/`PulseAudio` session handling as an install-time workaround.

## Suspend unit feature blocks

- Keyboard backlight handling for Magic Keyboard and Butterfly Keyboard layouts.
- Broadcom Wi-Fi unload/reload block.
- BCM4377 Bluetooth unload/reload block.
- Touch Bar module unload/reload block.
- `tiny-dfr` stop/restart block.
- Optional `apple_gmux` iGPU/dGPU block for `force_igd=y` setups.
- Optional audio session workaround block.

## Usage

- Run as root with `sudo ./t2-suspend-dispatch.sh`
- Review detected hardware and options.
- Choose whether to enable the optional audio workaround.
- Confirm installation.
- Re-run to enable audio-workaround if needed.

## Notes

- The audio workaround is optional because it can help on some systems and regress audio/session reconnects on others.
- iMac systems are allowed to proceed without a keyboard backlight path.
- MacBook systems require a working keyboard backlight to be detected for installation.
