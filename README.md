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

## Reporting issues

If for some reason it doesn't work for you, please open an issue and post the results of this script (mandatory):

```
sudo -v
read -r -p "Enter your name (for log identification): " REPORTER </dev/tty

if [ -z "$REPORTER" ]; then
  echo "Name is required."
  exit 1
fi

echo "User: $REPORTER"
echo ""
echo "Model: $(cat /sys/class/dmi/id/product_name)"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "Distro: $PRETTY_NAME"
else
    echo "Distro: unknown"
fi
echo ""
echo "- tiny-dfr -"
if systemctl cat tiny-dfr.service >/dev/null 2>&1; then
        echo "tiny-dfr service is installed"
    else
        echo "no tiny-dfr is installed"
    fi
if systemctl is-active --quiet tiny-dfr.service 2>/dev/null; then
        echo "tiny-dfr is active"
    else
        echo "tiny-dfr is inactive"
    fi
echo ""
echo "- desktop environment - "
ps -e | grep -E -i "xfce|kde|gnome"
echo ""
echo "Kernel: $(uname -r)"
echo ""
echo "- generated t2-suspend.service contents -"
echo ""
cat /etc/systemd/system/t2-suspend.service
echo ""

T2=$(lspci | grep "T2 Bridge Controller" | awk '{print $1}')

if [ -z "$T2" ]; then
    echo "T2 device not found!"
    exit 1
fi

echo "T2 device: $T2"

RP=$(basename "$(readlink -f /sys/bus/pci/devices/0000:${T2}/..)")
echo "Root Port: $RP"

echo ""
echo "- Network Controller(s) -"
lspci | grep -Ei "Network controller|Wireless|Wi-Fi" | while read line; do
    bdf=$(echo "$line" | awk '{print $1}')
    name=$(echo "$line" | cut -d' ' -f2-)
    echo "  $bdf  $name"
done

echo ""
echo "- Kernel Command Line -"
cat /proc/cmdline

echo ""
echo "- ASPM Policy -"
cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null

echo ""
echo "- dmesg ASPM Messages -"
sudo dmesg | grep -i aspm

echo ""
echo "- Root Port PCIe Info -"
sudo lspci -vvv -s "$RP" | grep -E "LnkCap|LnkCtl|LnkSta|L1Sub|PM"

echo ""
echo "- T2 Endpoint PCIe Info -"
sudo lspci -vvv -s "$T2" | grep -E "LnkCap|LnkCtl|LnkSta|PM"
```

If it hangs on resume and you need to hard reboot please post the output of prior boot:
```
journalctl -b -1 -k
```

Otherwise current boot:
```
journalctl -b -0 -k
```


## Notes

- The audio workaround is optional because it can help on some systems and regress audio/session reconnects on others.
- iMac systems are allowed to proceed without a keyboard backlight path.
- MacBook systems require a working keyboard backlight to be detected for installation.
- Slow resume times (up to 30 seconds) is normal. It's caused by ibridge/slow smpboot times
