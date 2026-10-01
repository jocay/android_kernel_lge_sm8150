#!/system/bin/sh
# Runs before init starts adbd and thermal-engine, so both pick up what is set
# here on their first start.
MODDIR=${0%/*}
. "$MODDIR/config.sh"
. "$MODDIR/thermal.sh"

# adbd only honours ro.adb.secure=0 on debuggable builds or with an unlocked
# bootloader (ro.boot.verifiedbootstate=orange); this device is unlocked.
[ "$ADB_NO_AUTH" = 1 ] && resetprop -n ro.adb.secure 0

# Not a persist.* property on purpose: removing the module restores USB-only.
[ -n "$ADB_TCP_PORT" ] && resetprop -n service.adb.tcp.port "$ADB_TCP_PORT"

if [ "$DISABLE_SKIN_THROTTLE" = 1 ]; then
    mkdir -p "$RUN_DIR"
    # The marker tells service.sh that thermal-engine started with our file.
    thermal_mount > "$MODDIR/thermal.log" 2>&1 && : > "$RUN_DIR/thermal_early"
fi

exit 0
