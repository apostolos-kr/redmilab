# Battery charge voltage limited to 3.9 V (whyred + mido)

(AI generated after manual troubleshooting)

Both phones are always on a charger as k3s nodes. Instead of sitting at ~4.4 V,
the cell voltage is capped at 3.9 V by lowering `voltage-max-design-microvolt`
in the battery node of the device tree.

Based on: <https://github.com/bryansplace/PostmarketOS-limit-battery-voltage>

## xiaomi-whyred (Redmi Note 5)

whyred boots a `boot.img` from the `boot` partition (Android bootloader), so
the loose `/boot/*.dtb` files are ignored: the device tree is appended to the
kernel inside `boot.img`, built by `boot-deploy` from
`/boot/dtbs/qcom/sdm636-xiaomi-whyred.dtb`. The guide's
`qcom-smbchg-usb/online` toggle does not apply either; whyred uses
`pm660-charger`, where `online` is read-only.

What was done:

1. `voltage-max-design-microvolt` was changed from `0x4342c0` (4.408 V) to
   `0x3b8260` (3.9 V) in the battery node.
2. `boot.img` was rebuilt with `boot-deploy` in scratch dirs using the
   modified dtb (a baseline rebuild with the stock dtb was byte-identical to
   the flashed image; the modified one differs in 23 bytes: 20 header hash
   + 3 voltage).
3. The image was test-booted with `fastboot boot` (RAM only), then flashed
   with `fastboot flash boot`.

Reproduce:

```sh
dtc -I dtb -O dts /boot/dtbs/qcom/sdm636-xiaomi-whyred.dtb -o ~/whyred.dts 2>/dev/null
sed 's/0x4342c0/0x3b8260/' ~/whyred.dts > ~/whyred-mod.dts   # one changed line
dtc -I dts -O dtb ~/whyred-mod.dts -o ~/whyred-mod.dtb 2>/dev/null
# rebuild boot.img via boot-deploy in scratch dirs (stock dtb restored after),
# then from fastboot mode: fastboot boot <img> to test, fastboot flash boot <img>
# rollback: fastboot flash boot <original.img>
```

Verify:

```sh
od -An -tx1 /sys/firmware/devicetree/base/battery/voltage-max-design-microvolt   # 00 3b 82 60
cat /sys/class/power_supply/qcom-battery/voltage_max_design                      # 3900000
```

Observed behavior: the limit is enforced by the charger — voltage floats at
~3.911 V while charge current tapers from ~420 mA to ~30 mA (constant-voltage
taper). The phone runs from USB input (~1.1–1.5 W); unplug/replug resumes
charging immediately with no stuck state. Brief `Full` samples with zeroed
 readings occur while charging continues and are normal. Gauge percentage is
unreliable after a reboot; go by voltage (3.9 V reads about 53–59 %).

Caveats: lower limits leave little runtime during
a power cut; never go below the 3.4 V design minimum. Flashing is the risky
step — keep the original image and test with `fastboot boot` first.

## xiaomi-mido (Redmi Note 4X)

mido boots via lk2nd straight from `/boot` (`fdtdir /` in extlinux.conf; the
`boot` partition holds only the bootloader), so the loose
`/boot/msm8953-xiaomi-mido.dtb` is the device tree in use and no image rebuild
or flash is needed. The charger node is `qcom-smbchg-usb` and the stock limit
is `0x42d560` (4.38 V).

What was done:

1. `voltage-max-design-microvolt` was changed from `0x42d560` to `0x3b8260`
   (3.9 V) in the battery node.
2. The recompiled dtb was verified to differ from the original in only the
   voltage bytes, installed to `/boot`, and the phone was rebooted.

Reproduce:

```sh
dtc -I dtb -O dts /boot/msm8953-xiaomi-mido.dtb -o ~/mido.dts 2>/dev/null
sed 's/0x42d560/0x3b8260/' ~/mido.dts > ~/mido-mod.dts        # one changed line
dtc -I dts -O dtb ~/mido-mod.dts -o ~/mido-mod.dtb 2>/dev/null
cp ~/mido-mod.dtb /boot/msm8953-xiaomi-mido.dtb && sync && sudo reboot
# rollback: restore the backed-up original dtb to /boot
```

Verify:

```sh
od -An -tx1 /sys/firmware/devicetree/base/battery/voltage-max-design-microvolt   # 00 3b 82 60
cat /sys/class/power_supply/qcom-battery/voltage_max_design                      # 3900000
```

Observed behavior: after reboot the limit is live and charging proceeds
(3.898 V at about +320 mA). Gauge percentage is unreliable right after a boot;
go by voltage.

Caveats: lower limits leave little runtime during a power cut; never go below
the 3.4 V design minimum.
