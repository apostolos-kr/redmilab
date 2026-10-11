#!/bin/sh
# Keep the white notification LED on while the node is up,
# so phones look alive with the screen off.
# Each phone has exactly one white:* LED (whyred: white:status,
# mido: white:indicator). The kernel's default-on trigger drives
# the LED itself once selected.
# sysfs LED state does not survive reboot (re-applied via @reboot cron).

trigger=$(find /sys/class/leds -maxdepth 1 -name 'white:*')/trigger
grep -q '\[default-on\]' "$trigger" && exit 0
echo default-on > "$trigger"
echo 'Set white LED trigger to default-on'
