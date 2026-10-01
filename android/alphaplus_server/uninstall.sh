#!/system/bin/sh
# Most of what the module sets is runtime state that a reboot clears. The
# charging limit, connectivity check URLs and NTP server are persistent system
# settings, so put those back to the system defaults.
content insert --uri content://lineagesettings/system \
    --bind name:s:charging_control_enabled --bind value:s:0
for k in captive_portal_http_url captive_portal_https_url captive_portal_fallback_url \
         captive_portal_other_fallback_urls ntp_server; do
    settings delete global "$k"
done
