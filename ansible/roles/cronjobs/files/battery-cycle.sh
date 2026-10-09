#!/bin/sh
# Keep battery cycling between LOW and HIGH percent instead of sitting at 100%.

LOW=40
HIGH=60

CAPACITY_FILE="/sys/class/power_supply/qcom-battery/capacity"

CHARGE_CURRENT=800000   # 0.8A

CHARGER_LIMIT="$(find -L /sys/class/power_supply -maxdepth 2 \( -name current_max -o -name input_current_limit \) 2>/dev/null | head -n1)"

if [ ! -f "$CAPACITY_FILE" ] || [ ! -f "$CHARGER_LIMIT" ]; then
    logger -t battery_cycle "sysfs paths not found, aborting"
    exit 1
fi

CAPACITY="$(cat "$CAPACITY_FILE")"

if [ "$CAPACITY" -le "$LOW" ]; then
    logger -t battery_cycle "Capacity ${CAPACITY}% <= ${LOW}%, charging"
    echo "$CHARGE_CURRENT" | tee "$CHARGER_LIMIT" > /dev/null
elif [ "$CAPACITY" -ge "$HIGH" ]; then
    logger -t battery_cycle "Capacity ${CAPACITY}% >= ${HIGH}%, discharging"
    echo "0" | tee "$CHARGER_LIMIT" > /dev/null
fi
