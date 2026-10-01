# Shared by post-fs-data.sh and service.sh. Needs MODDIR.

# The file thermal-engine reads its rules from on this device; the daemon
# names it in the output of "thermal-engine -o".
THERMAL_CONF=/vendor/etc/thermal-engine-8150.conf
THERMAL_OURS=$MODDIR/thermal-engine.conf
RUN_DIR=/dev/.alphaplus_server

# in_init_ns <command>: run in init's mount namespace, the one thermal-engine
# is started in.
in_init_ns() {
    if [ "$(readlink /proc/1/ns/mnt)" = "$(readlink /proc/self/ns/mnt)" ]; then
        "$@"
    else
        /data/adb/ksu/bin/busybox nsenter -t 1 -m -- "$@"
    fi
}

thermal_is_mounted() {
    grep -q " $THERMAL_CONF " /proc/1/mountinfo
}

# Bind a copy of the stock configuration without its skin-temperature rules
# over the stock file. The copy is regenerated from the stock file on every
# boot, so a ROM update that changes the other rules is picked up; the vendor
# partition itself is not modified.
thermal_mount() {
    local context

    thermal_is_mounted && return 0
    [ -r "$THERMAL_CONF" ] || { echo "missing: $THERMAL_CONF"; return 1; }
    awk '/^\[/ { drop = /^\[(SKIN-|GPU_MONITOR)/ } !drop' "$THERMAL_CONF" > "$THERMAL_OURS" ||
        return 1
    if ! grep -q '^\[' "$THERMAL_OURS" || cmp -s "$THERMAL_CONF" "$THERMAL_OURS"; then
        echo "no skin rules found in $THERMAL_CONF, leaving it alone"
        return 1
    fi
    context=$(ls -Z "$THERMAL_CONF")
    chmod 644 "$THERMAL_OURS" && chcon "${context%% *}" "$THERMAL_OURS" ||
        { echo "cannot label $THERMAL_OURS"; return 1; }
    in_init_ns mount -o bind "$THERMAL_OURS" "$THERMAL_CONF" ||
        { echo "bind mount failed"; return 1; }
    echo "skin rules removed: $(grep -c '^\[SKIN-' "$THERMAL_CONF") left," \
         "$(grep -c '^\[' "$THERMAL_CONF") other rules kept"
}
