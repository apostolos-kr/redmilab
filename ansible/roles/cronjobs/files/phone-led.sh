#!/bin/sh
trigger=$(find /sys/class/leds -maxdepth 1 -name 'white:*')/trigger
grep -q '\[default-on\]' "$trigger" && exit 0
echo default-on > "$trigger"
echo 'Set white LED trigger to default-on'
