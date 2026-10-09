#!/bin/sh

for c in /sys/devices/system/cpu/cpu[0-9]*; do
    for s in 1 3 4 5; do
        disable="$c/cpuidle/state$s/disable"
        [ "$(cat "$disable")" = "1" ] && continue
        echo 1 > "$disable" && echo "disabled $disable"
    done
done
