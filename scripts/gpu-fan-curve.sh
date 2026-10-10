#!/usr/bin/env bash
# Aggressive fan curve for the three RX 6700 (Navi 22) cards.
#
# Navi 22 is SMU11: there is no gpu_od/fan_ctrl/fan_curve sysfs node, so the
# only way to override the stock curve is manual PWM from userspace. This takes
# every amdgpu hwmon out of zero-RPM auto mode (pwm1_enable=2 -> 1) and drives
# pwm1 itself.
#
# Background: 2026-08-03 the box was force-powered-off by an amdgpu SW CTF on
# c3:00.0 under ROCm load. The stock curve lets the cards soak at 74-82 C edge
# while drawing 5 W, which leaves no headroom when a job starts. This curve
# trades noise for headroom.
#
# Runs as root (needs write access to /sys/class/drm/card*/device/hwmon/*/pwm1).

set -uo pipefail

# --- curve -----------------------------------------------------------------
# "tempC:duty%" breakpoints, ascending. Linear interpolation between points,
# clamped at both ends. Tune these; everything else is mechanism.
#
# Sized to hit 100% at 80 C — well below the 110 C junction SW CTF kill — so the
# fans are already maxed on the way up rather than catching up after the spike.
# Junction crit is 110 C, mem crit 105 C; 80 C leaves ~30 C of margin to work in.
CURVE=(30:35 45:50 55:65 65:80 72:92 80:100)

POLL=2          # seconds between samples
HYSTERESIS=4    # only ramp *down* after temp falls this far below the held value
PANIC_TEMP=85   # at or above this, 100% ignoring curve *and* hysteresis (safety
                # net if CURVE is edited to something less aggressive)
MIN_DUTY=35     # never below this, even cold. This is what kills zero-RPM mode:
                # 35% measured ~1289 RPM on these cards, so the fans always spin.

# --- curve evaluation ------------------------------------------------------
# duty% for a given temp, linear between breakpoints.
duty_for() {
    local t=$1 i prev_t prev_d cur_t cur_d
    prev_t=${CURVE[0]%%:*}; prev_d=${CURVE[0]##*:}

    (( t <= prev_t )) && { echo "$prev_d"; return; }

    for (( i = 1; i < ${#CURVE[@]}; i++ )); do
        cur_t=${CURVE[i]%%:*}; cur_d=${CURVE[i]##*:}
        if (( t <= cur_t )); then
            echo $(( prev_d + (t - prev_t) * (cur_d - prev_d) / (cur_t - prev_t) ))
            return
        fi
        prev_t=$cur_t; prev_d=$cur_d
    done
    echo "$prev_d"
}

# --dump-curve: print the resolved table and exit. Needs no root, no hardware.
if [[ "${1:-}" == "--dump-curve" ]]; then
    printf 'temp  duty  pwm   approx RPM (fan1_max=3300)\n'
    for t in $(seq 30 5 95); do
        d=$(duty_for "$t"); (( d < MIN_DUTY )) && d=$MIN_DUTY
        (( t >= PANIC_TEMP )) && d=100
        printf '%3d C %3d%%  %3d   ~%d\n' "$t" "$d" $(( d * 255 / 100 )) $(( d * 3300 / 100 ))
    done
    exit 0
fi

# --- discovery -------------------------------------------------------------
HWMONS=()
for h in /sys/class/drm/card*/device/hwmon/hwmon*; do
    [[ -r "$h/name" && "$(<"$h/name")" == "amdgpu" ]] || continue
    [[ -w "$h/pwm1" && -w "$h/pwm1_enable" ]] || continue
    HWMONS+=("$h")
done

if [[ ${#HWMONS[@]} -eq 0 ]]; then
    echo "gpu-fan-curve: no writable amdgpu hwmon found (need root)" >&2
    exit 1
fi

card_id() { basename "$(readlink -f "$1/../..")"; }

# --- restore stock behaviour on the way out --------------------------------
restore() {
    local h
    trap - TERM INT EXIT
    for h in "${HWMONS[@]}"; do
        echo 2 > "$h/pwm1_enable" 2>/dev/null
    done
    echo "gpu-fan-curve: restored automatic fan control"
    exit 0
}
trap restore TERM INT EXIT

if [[ "${1:-}" == "--restore" ]]; then
    restore
fi

# hottest of edge/junction/mem, in whole degrees C
hottest() {
    local h=$1 f v max=0
    for f in temp1_input temp2_input temp3_input; do
        [[ -r "$h/$f" ]] || continue
        v=$(<"$h/$f")
        (( v > max )) && max=$v
    done
    echo $(( max / 1000 ))
}

# --- main loop -------------------------------------------------------------
declare -A HELD   # per-card temp the current duty is based on (hysteresis anchor)

for h in "${HWMONS[@]}"; do
    echo 1 > "$h/pwm1_enable" || echo "gpu-fan-curve: cannot set manual mode on $h" >&2
    HELD["$h"]=0
done
echo "gpu-fan-curve: managing ${#HWMONS[@]} card(s): $(for h in "${HWMONS[@]}"; do printf '%s ' "$(card_id "$h")"; done)"

while :; do
    for h in "${HWMONS[@]}"; do
        # amdgpu can drop back to auto across driver events; re-assert.
        [[ "$(<"$h/pwm1_enable")" == "1" ]] || echo 1 > "$h/pwm1_enable" 2>/dev/null

        temp=$(hottest "$h")
        held=${HELD["$h"]}

        # Ramp up instantly; ramp down only past the hysteresis band.
        if (( temp > held )); then
            held=$temp
        elif (( temp <= held - HYSTERESIS )); then
            held=$temp
        fi
        HELD["$h"]=$held

        if (( temp >= PANIC_TEMP )); then
            duty=100
        else
            duty=$(duty_for "$held")
        fi
        (( duty < MIN_DUTY )) && duty=$MIN_DUTY
        (( duty > 100 )) && duty=100

        pwm=$(( duty * 255 / 100 ))
        [[ "$(<"$h/pwm1")" == "$pwm" ]] || echo "$pwm" > "$h/pwm1" 2>/dev/null
    done
    sleep "$POLL"
done
