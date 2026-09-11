#!/bin/sh
# IRQ 亲和性调度 — 移植自 ophub balethirq.pl(unifreq), sh 重写(免 perl 依赖)
# 功能: 按 /etc/balance_irq 把 eth0/USB 等 IRQ 绑到指定核, 并为网卡启用 RPS
CONF=/etc/balance_irq
[ -f "$CONF" ] || exit 0
NPROC=$(nproc)
[ "$NPROC" -ge 1 ] || exit 0
FULL_MASK=$(( (1 << NPROC) - 1 ))

# 1) IRQ 绑核
awk '{print $1"\t"$2}' "$CONF" | while read -r dev cpu; do
    [ -n "$dev" ] || continue
    [ "$cpu" -ge 0 ] 2>/dev/null || continue
    [ "$cpu" -lt "$NPROC" ] || continue
    mask=$(printf '%x' $((1 << cpu)))
    # /proc/interrupts 行尾是设备名, 匹配设备名前缀
    grep -F "$dev" /proc/interrupts | cut -d: -f1 | tr -d ' ' | while read -r irq; do
        [ -n "$irq" ] && [ -f "/proc/irq/$irq/smp_affinity" ] && \
            echo "$mask" > "/proc/irq/$irq/smp_affinity" 2>/dev/null
    done
done

# 2) 网卡 RPS: 排除 eth0 绑定的核, 其余核处理软中断
ETH0_CPU=$(awk '$1=="eth0"{print $2}' "$CONF")
[ -n "$ETH0_CPU" ] || ETH0_CPU=0
[ "$ETH0_CPU" -lt "$NPROC" ] || ETH0_CPU=0
RPS_MASK=$(printf '%x' $((FULL_MASK & ~(1 << ETH0_CPU))))
for net in eth0 end0; do
    [ -d "/sys/class/net/$net/queues" ] || continue
    for q in /sys/class/net/$net/queues/rx-*; do
        [ -f "$q/rps_cpus" ] && echo "$RPS_MASK" > "$q/rps_cpus" 2>/dev/null
        [ -f "$q/rps_flow_cnt" ] && echo 4096 > "$q/rps_flow_cnt" 2>/dev/null
    done
done
[ -f /proc/sys/net/core/rps_sock_flow_entries ] && \
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
exit 0
