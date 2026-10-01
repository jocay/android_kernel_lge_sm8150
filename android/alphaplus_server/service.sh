#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/config.sh"
. "$MODDIR/thermal.sh"

exec > "$MODDIR/boot.log" 2>&1

log() { echo "[$(date '+%F %T')] $*"; }

# put <value> <file>: write a sysfs/procfs value, logging anything that fails
put() {
    [ -e "$2" ] || { log "skip (missing): $2"; return 1; }
    echo "$1" > "$2" 2>/dev/null || { log "FAILED: $1 > $2"; return 1; }
}

# Framework commands ("cmd", "settings") hand their stdio to system_server,
# which SELinux does not let write to this script's log file, so the call
# fails unless stdio points somewhere neutral.
quiet() { "$@" < /dev/null > /dev/null 2>&1; }

thermal_setup() {
    if [ "$DISABLE_SKIN_THROTTLE" = 1 ]; then
        [ -s "$MODDIR/thermal.log" ] && log "post-fs-data: $(cat "$MODDIR/thermal.log")"
        mkdir -p "$RUN_DIR"
        if [ ! -e "$RUN_DIR/thermal_early" ]; then
            # thermal-engine is already running with the stock rules (module
            # installed without a reboot, or the early mount failed): mount
            # now and restart it once.
            if result=$(thermal_mount); then
                stop vendor.thermal-engine
                start vendor.thermal-engine
                : > "$RUN_DIR/thermal_early"
                log "$result; thermal-engine restarted to load the new rules"
            else
                log "FAILED: $result"
            fi
        fi
        if thermal_is_mounted; then
            log "thermal-engine ($(getprop init.svc.vendor.thermal-engine)):" \
                "$(grep -c '^\[SKIN-' "$THERMAL_CONF") skin rules," \
                "skin temperature $(($(skin_temp) / 1000)) C"
        else
            log "FAILED: skin rules still active"
        fi
    fi

    if [ "$DISABLE_KERNEL_PASSIVE_TRIPS" = 1 ]; then
        n=0
        for z in /sys/class/thermal/thermal_zone*; do
            case "$(cat "$z/type")" in
            *-step) put disabled "$z/mode" && n=$((n + 1)) ;;
            esac
        done
        log "kernel thermal zones disabled: $n"
    fi
}

# The sensor the skin rules are keyed on ("vts"), in millidegrees.
skin_temp() {
    for z in /sys/class/thermal/thermal_zone*; do
        if [ "$(cat "$z/type")" = vts-virt-therm ]; then
            cat "$z/temp"
            return
        fi
    done
    echo 0
}

cpu_setup() {
    if [ "$KEEP_CORES_ONLINE" = 1 ]; then
        for c in /sys/devices/system/cpu/cpu*/core_ctl; do
            [ -e "$c/max_cpus" ] && put "$(cat "$c/max_cpus")" "$c/min_cpus"
        done
    fi
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        put "$CPU_GOVERNOR" "$p/scaling_governor"
        log "${p##*/}: $(cat "$p/scaling_governor"), max $(cat "$p/scaling_max_freq") of $(cat "$p/cpuinfo_max_freq") kHz"
    done
    log "cpus online: $(cat /sys/devices/system/cpu/online)"
    if [ "$DISABLE_DEEP_IDLE" = 1 ]; then
        for s in /sys/devices/system/cpu/cpu*/cpuidle/state1/disable; do put 1 "$s"; done
    fi
}

power_setup() {
    if [ "$STAY_AWAKE" = 1 ]; then
        dumpsys deviceidle disable all > /dev/null
        put alphaplus_server /sys/power/wake_lock
        log "doze enabled: $(dumpsys deviceidle enabled all), wakelocks: $(cat /sys/power/wake_lock)"
    fi
    if [ -n "$CHARGE_LIMIT" ]; then
        for kv in charging_control_enabled:1 charging_control_mode:3 \
                  "charging_control_charging_limit:$CHARGE_LIMIT"; do
            content insert --uri content://lineagesettings/system \
                --bind "name:s:${kv%%:*}" --bind "value:s:${kv##*:}" ||
                log "FAILED: lineage setting ${kv%%:*}"
        done
        log "charge limit: $(dumpsys lineagehealth | grep -m1 'Limit:' | tr -d ' ')"
    fi
}

net_setup() {
    [ "$NET_TUNING" = 1 ] || return
    s=/proc/sys/net
    grep -qw bbr $s/ipv4/tcp_available_congestion_control &&
        put bbr $s/ipv4/tcp_congestion_control
    # Fails harmlessly on a kernel without fq_codel built in.
    echo fq_codel > $s/core/default_qdisc 2>/dev/null
    put 0 $s/ipv4/tcp_slow_start_after_idle
    put 3 $s/ipv4/tcp_fastopen
    put 16777216 $s/core/rmem_max
    put 16777216 $s/core/wmem_max
    put "4096 131072 16777216" $s/ipv4/tcp_rmem
    put "4096 65536 16777216" $s/ipv4/tcp_wmem
    log "tcp: $(cat $s/ipv4/tcp_congestion_control), qdisc: $(cat $s/core/default_qdisc)"
}

router_setup() {
    [ "$ROUTER_FORWARDING" = 1 ] || return
    s=/proc/sys/net
    put 1 $s/ipv4/ip_forward
    put 1 $s/ipv6/conf/all/forwarding
    # Covers "all", "default" (interfaces that appear later, such as a USB
    # Ethernet adapter) and every interface that exists now.
    for f in $s/ipv4/conf/*/rp_filter; do put 0 "$f"; done
    # netd ends the FORWARD chain with a DROP for everything that is not
    # tethering. oem_fwd is the chain it calls first and leaves to the device.
    for ipt in iptables ip6tables; do
        $ipt -w -C oem_fwd -j ACCEPT 2>/dev/null || $ipt -w -A oem_fwd -j ACCEPT ||
            log "FAILED: $ipt oem_fwd"
    done
    log "forwarding: ipv4 $(cat $s/ipv4/ip_forward), ipv6 $(cat $s/ipv6/conf/all/forwarding)"
}

# These are persistent system settings; they are re-applied on every boot so a
# reinstalled system ends up configured the same way.
connectivity_setup() {
    if [ -n "$CONNECTIVITY_CHECK_HOST" ]; then
        quiet settings put global captive_portal_http_url "http://$CONNECTIVITY_CHECK_HOST/generate_204" &&
        quiet settings put global captive_portal_https_url "https://$CONNECTIVITY_CHECK_HOST/generate_204" ||
            log "FAILED: connectivity check URLs"
        if [ -n "$CONNECTIVITY_CHECK_FALLBACKS" ]; then
            quiet settings put global captive_portal_fallback_url "${CONNECTIVITY_CHECK_FALLBACKS%%,*}"
            quiet settings put global captive_portal_other_fallback_urls "$CONNECTIVITY_CHECK_FALLBACKS"
        fi
        log "connectivity check: $(settings get global captive_portal_https_url 2>/dev/null)"
    fi
    if [ -n "$NTP_SERVER" ]; then
        quiet settings put global ntp_server "$NTP_SERVER" || log "FAILED: ntp_server"
        log "ntp server: $(settings get global ntp_server 2>/dev/null)"
    fi
}

adb_setup() {
    [ -n "$ADB_TCP_PORT" ] || [ "$ADB_NO_AUTH" = 1 ] || return
    # The settings provider can still be busy right after boot.
    i=0
    until quiet settings put global adb_enabled 1 || [ $i -ge 5 ]; do
        sleep 5; i=$((i + 1))
    done
    [ "$(settings get global adb_enabled 2>/dev/null)" = 1 ] || log "FAILED: adb_enabled"
    log "adb: tcp port '$(getprop service.adb.tcp.port)', ro.adb.secure=$(getprop ro.adb.secure)"
}

# The framework's forced modes only register while Wi-Fi is connected, and
# power save comes back after a reconnect, so re-assert both whenever the
# driver reports power save on.
wifi_watch() {
    [ "$WIFI_LOW_LATENCY" = 1 ] || return
    while :; do
        if iw dev wlan0 get power_save 2>/dev/null | grep -q ': on'; then
            quiet cmd wifi force-hi-perf-mode enabled || log "FAILED: wifi hi-perf mode"
            quiet cmd wifi force-low-latency-mode enabled || log "FAILED: wifi low-latency mode"
            iw dev wlan0 set power_save off && log "wlan0: power save turned off"
        fi
        sleep 30
    done
}

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
# Let the power HAL finish its own boot-time setup first.
sleep 10

log "applying server tuning"
thermal_setup
cpu_setup
power_setup
net_setup
router_setup
connectivity_setup
adb_setup
log "done"
wifi_watch
