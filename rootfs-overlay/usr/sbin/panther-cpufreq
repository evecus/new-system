#!/bin/sh
# CPU 调频设置 — 移植自 ophub /etc/default/cpufrequtils 机制(免 cpufrequtils 包)
# 配置: /etc/default/panther-cpufreq (GOVERNOR / MIN_SPEED / MAX_SPEED)
[ -r /etc/default/panther-cpufreq ] && . /etc/default/panther-cpufreq
GOVERNOR="${GOVERNOR:-schedutil}"

for policy in /sys/devices/system/cpu/cpufreq/policy*; do
    [ -d "$policy" ] || continue
    if [ -n "${MIN_SPEED}" ] && [ -f "$policy/scaling_min_freq" ]; then
        echo "$MIN_SPEED" > "$policy/scaling_min_freq" 2>/dev/null
    fi
    if [ -n "${MAX_SPEED}" ] && [ -f "$policy/scaling_max_freq" ]; then
        echo "$MAX_SPEED" > "$policy/scaling_max_freq" 2>/dev/null
    fi
    if [ -f "$policy/scaling_governor" ]; then
        echo "$GOVERNOR" > "$policy/scaling_governor" 2>/dev/null
    fi
done
exit 0
