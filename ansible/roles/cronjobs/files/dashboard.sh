#!/bin/sh
# Prints a status dashboard to the phone screen (tty1) only.
# Never writes to stdout/SSH - every write is redirected to /dev/tty1 and discarded elsewhere.

TTY=/dev/tty1

# Screen asleep -> do nothing at all
BLANK="$(cat /sys/class/graphics/fb0/blank 2>/dev/null)"
if [ "$BLANK" != 0 ] && [ "$BLANK" != 4 ]; then exit 0; fi

setfont /usr/share/consolefonts/ter-v32n.psf.gz -C "$TTY" 2>/dev/null

YELLOW='\033[1;33m'
GREEN='\033[1;32m'
CYAN='\033[1;36m'
PINK='\033[1;35m'
RESET='\033[0m'

# ---- Gather network info ----
WLAN_IP="$(nmcli -t -f IP4.ADDRESS device show wlan0 2>/dev/null | cut -d: -f2)"
TS_IP="$(nmcli -t -f IP4.ADDRESS device show tailscale0 2>/dev/null | cut -d: -f2)"

# ---- Gather battery info from sysfs ----
BATT="/sys/class/power_supply/qcom-battery"
CAPACITY="$(cat "$BATT/capacity" 2>/dev/null)"
TEMP_RAW="$(cat "$BATT/temp" 2>/dev/null)"
TEMP_C="$((TEMP_RAW / 10))"

BATT_VOLTAGE="$(cat "$BATT/voltage_now" 2>/dev/null)"
BATT_CURRENT="$(cat "$BATT/current_now" 2>/dev/null)"
POWER_MW="$(( (BATT_VOLTAGE * BATT_CURRENT) / 1000000000 ))"
VOLT_MV="$((BATT_VOLTAGE / 1000))"

if [ "$TEMP_C" -gt 40 ] 2>/dev/null; then TEMP_COLOR="$YELLOW"; else TEMP_COLOR="$RESET"; fi

# ---- Gather CPU from busybox top ----
TOP_OUT="$(top -bn1)"

# ---- Pods hosted on this node ----
PODS="$(/usr/local/bin/k3s kubectl get pods --request-timeout=5s -A --field-selector "spec.nodeName=$(uname -n)" \
    -o custom-columns=':metadata.namespace,:metadata.name,:status.phase' --no-headers 2>/dev/null)"

# ---- Gather memory from /proc/meminfo ----
MEM_TOTAL="$(grep '^MemTotal:' /proc/meminfo | cut -d: -f2 | tr -d ' kB')"
MEM_AVAIL="$(grep '^MemAvailable:' /proc/meminfo | cut -d: -f2 | tr -d ' kB')"
MEM_PCT="$(( (100 * (MEM_TOTAL - MEM_AVAIL)) / MEM_TOTAL ))"

CPU_LINE="$(echo "$TOP_OUT" | grep "^CPU:")"
CPU_IDLE="$(echo "$CPU_LINE" | grep -o '[0-9]*% idle' | grep -o '[0-9]*')"
CPU_PCT=$((100 - CPU_IDLE))

# ---- Render to screen only ----
{
    printf '\033c'
    printf "\n\n\n\n\n\n\n"

    printf "${YELLOW}%-11s${RESET} %s\n" "WiFi:" "$WLAN_IP"
    printf "${YELLOW}%-11s${RESET} %s\n\n" "Tailscale:" "$TS_IP"

    printf "${GREEN}%-11s${RESET} %s mV (%s%%)\n" "Battery:" "$VOLT_MV" "$CAPACITY"
    printf "${GREEN}%-11s${RESET} %d mW\n" "Power:" "$POWER_MW"
    printf "${GREEN}%-11s${TEMP_COLOR} %s C\n\n" "Temp:" "$TEMP_C"

    printf "${PINK}%-11s${RESET} %s%%\n" "CPU:" "$CPU_PCT"
    printf "${PINK}%-11s${RESET} %s%%\n\n" "RAM:" "$MEM_PCT"

    printf "${CYAN}%-11s${RESET}\n%s\n" "K3s pods:" "$PODS"

    printf "${RESET}%-11s${RESET} %s\n" "Updated:" "$(date '+%Y-%m-%d %H:%M:%S')"
} | tee "$TTY" > /dev/null
