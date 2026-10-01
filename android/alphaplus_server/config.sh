# Tunables for the G8 Server Tuning module. Edit, then reboot.
# On the device: /data/adb/modules/alphaplus_server/config.sh

# --- Thermal -----------------------------------------------------------------
# 1: drop the skin-temperature rules from thermal-engine's configuration.
#    LG tuned them for a phone held in the hand: they take the prime core's
#    top frequency away at 36 C skin temperature and step the four big cores
#    down to 0.83 GHz by 44 C. The charging-current rules and the junction
#    temperature rules of the same daemon stay in force.
DISABLE_SKIN_THROTTLE=1

# 1: also disable the kernel's own thermal zones (the "*-step" ones). They
#    only act at 85 C board / 110 C junction and above, so they cost nothing in
#    normal operation and are the last protection if the cooler fails.
#    Leave at 0 unless you accept losing that.
DISABLE_KERNEL_PASSIVE_TRIPS=0

# --- CPU ---------------------------------------------------------------------
# cpufreq governor for all clusters: performance | schedutil
CPU_GOVERNOR=performance
# 1: keep every big and prime core online (core_ctl otherwise parks them
#    when the load is low).
KEEP_CORES_ONLINE=1
# 1: disable the deep idle state (C1, ~0.9 ms wake-up) so cores answer
#    interrupts faster. Raises idle power draw.
DISABLE_DEEP_IDLE=1

# --- Power management --------------------------------------------------------
# 1: disable doze / app standby idle modes and hold a wakelock so the system
#    never suspends with the screen off.
STAY_AWAKE=1
# Stop charging at this percentage (70-100, LineageOS charging control).
# Empty: leave the system setting alone.
CHARGE_LIMIT=80

# --- Network -----------------------------------------------------------------
# 1: keep Wi-Fi out of power save and in low-latency mode.
WIFI_LOW_LATENCY=1
# 1: apply TCP settings (BBR and fq_codel when the kernel has them, larger
#    buffers, no slow start after idle, TCP Fast Open).
NET_TUNING=1
# 1: act as a router: IPv4/IPv6 forwarding on, reverse-path filtering off, and
#    forwarded packets accepted (Android drops them unless tethering is on).
#    Needed for a side router / transparent proxy; set 0 if the phone only
#    serves its own traffic.
ROUTER_FORWARDING=1

# --- Connectivity check and time ---------------------------------------------
# Android decides whether a network "has internet" by fetching these URLs, and
# its defaults (Google) are not fully reachable from mainland China, so the
# network shows as having no internet. Empty CONNECTIVITY_CHECK_HOST: leave
# the system settings alone.
CONNECTIVITY_CHECK_HOST=connectivitycheck.platform.hicloud.com
CONNECTIVITY_CHECK_FALLBACKS="http://connect.rom.miui.com/generate_204,http://wifi.vivo.com.cn/generate_204,http://www.google.cn/generate_204"
# NTP server (the default time.android.com is unreachable there too).
# Empty: leave the system setting alone.
NTP_SERVER=ntp.aliyun.com

# --- adb ---------------------------------------------------------------------
# TCP port adbd listens on at every boot. Empty: USB only.
ADB_TCP_PORT=5555
# 1: accept any adb client without authorization (USB and TCP).
#    Anyone who can reach the port gets a shell, and root if Shell is granted
#    root in KernelSU. Only for a trusted network.
ADB_NO_AUTH=1
