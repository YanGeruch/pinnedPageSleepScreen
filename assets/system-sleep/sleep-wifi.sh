#!/bin/sh
# Stock reMarkable hook (see sleep-wifi.sh.orig) + pinnedPageSleepScreen gate:
# skip the WiFi/BT driver reload when the wake is the RTC sleep-clock timer
# (wakeup_reason 0x00) — the device is awake for seconds and needs no radio.
# /run/pinsleep-wifi-off marks "modules were left unloaded" so the next
# "before" phase doesn't tear down what isn't there (and doesn't burn 1s
# waiting for a wlan0 that will never appear). A user wake (button 0x04,
# pen 0x10, charger 0x20) restores normally; waking mid-window is covered
# by the mod's Navigator wake handler. OTA updates overwrite this file with
# stock — a re-deploy reinstalls the gate.
WAKEUP_REASON=/sys/devices/platform/soc@0/44000000.bus/44340000.i2c/i2c-0/0-0008/slg46824-wakeup.1.auto/wakeup_reason

if [ "${1}" == "before" ]; then
	if [ -e /run/pinsleep-wifi-off ]; then
		echo "$(basename ${0}): Wifi/BT already down (RTC wake), nothing to stop" > /dev/kmsg
		exit 0
	fi
	echo "$(basename ${0}): Shutting down Wifi/BT" > /dev/kmsg

	# In the context of suspend-then-hibernate, wifi module gets reinstalled
	# and then removed right away, when device is woken up from suspend
	# state and starts hiberating. This causes an issue that wifi stops
	# working after wake-up from hibernate.  Fix the issue by waiting 1s
	# before shutting wlan0 down.
	if [ ! -e /sys/class/net/wlan0 ]; then
		echo "$(basename ${0}): Waiting for wlan0" > /dev/kmsg
		sleep 1
	fi

	if lsmod | grep -q btnxpuart; then
		rmmod btnxpuart
		touch /run/reload-bt
	fi

	ifconfig wlan0 down
	rmmod iw61x_sdw61x
elif [ "${1}" == "after" ]; then
	systemd-run ${0} "async-after"
elif [ "${1}" == "async-after" ]; then
	if [ "$(cat ${WAKEUP_REASON} 2>/dev/null)" == "0x00" ]; then
		echo "$(basename ${0}): RTC wake, skipping Wifi/BT restore" > /dev/kmsg
		touch /run/pinsleep-wifi-off
		exit 0
	fi
	rm -f /run/pinsleep-wifi-off
	echo "$(basename ${0}): Restoring Wifi/BT" > /dev/kmsg
	modprobe iw61x_sdw61x
	if [ -e /run/reload-bt ]; then
		modprobe btnxpuart
		rm /run/reload-bt
	fi
fi
