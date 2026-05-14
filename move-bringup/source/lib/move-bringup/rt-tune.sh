#!/bin/sh
# RT scheduling tune-up for the Move audio path. Idempotent; safe to run
# whenever MoveLauncher starts. Mirrors the kernel-thread pinning in
# /etc/init.d/move from the stock AbletonOS image:
#
#   - SCHED_FIFO 90 on the SPI controller kthread (spi0)
#   - SCHED_FIFO 91 on the ablspi kthread
#   - Non-audio IRQ threads pinned to CPU cores 0-2
#   - Audio-critical IRQ threads pinned to CPU core 3
#   - Workqueues default-affined to cores 0-2 so they cannot disturb 3

set -u

# Skip silently if the device tree doesn't expose an ablspi node — we may
# be running on a generic Pi with the package installed for other reasons.
[ -c /dev/ablspi0.0 ] || exit 0

ALL_CORES_BUT_AUDIO=7	# binary 0111 = cores 0,1,2
AUDIO_CORE_ONLY=8	# binary 1000 = core 3

retry_chrt() {
    prio=$1
    pattern=$2
    pids=$(pgrep "$pattern" || true)
    [ -n "$pids" ] || return 0
    for pid in $pids; do
        chrt -f -p "$prio" "$pid" 2>/dev/null || true
    done
}

retry_taskset() {
    mask=$1
    pattern=$2
    pids=$(pgrep "$pattern" || true)
    [ -n "$pids" ] || return 0
    for pid in $pids; do
        taskset -p "$mask" "$pid" >/dev/null 2>&1 || true
    done
}

retry_chrt 90 '^spi0$'
retry_chrt 91 '^ablspi'

# Push all IRQ threads off the audio core...
retry_taskset $ALL_CORES_BUT_AUDIO '^irq/'

# ...except the SPI / ablspi / DMA ones, which we want pinned to core 3.
retry_taskset $AUDIO_CORE_ONLY 'DMA IRQ|ablspi|^spi0$'

# Default workqueue affinity to the non-audio cores.
for cpumask in /sys/devices/virtual/workqueue/*/cpumask; do
    [ -w "$cpumask" ] || continue
    printf '%x\n' $ALL_CORES_BUT_AUDIO > "$cpumask" 2>/dev/null || true
done

exit 0
