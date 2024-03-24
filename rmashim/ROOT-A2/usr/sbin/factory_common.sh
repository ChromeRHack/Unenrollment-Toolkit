#!/bin/sh
# Copyright 2017 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# A common library for factory shim.

LSB_RELEASE_FILE=/etc/lsb-release
LSB_FACTORY_FILE=/mnt/stateful_partition/dev_image/etc/lsb-factory

# Returns the key for "key=value" format string.
getLSBKey() {
  local key=""
  if [[ "$1" == ?*'='* ]]; then
    key="$(echo "$1" | cut -d = -f 1)"
  fi
  echo "${key}"
}

# Returns the value for "key=value" format string.
getLSBValue() {
  local value=""
  if [[ "$1" == ?*'='* ]]; then
    value="$(echo "$1" | cut -d = -f 2-)"
  fi
  echo "${value}"
}

# Return the value for a given key in the override lsb-release file.
# If no value is found, checks in the standard lsb-release file.
findLSBValue()
{
  # Check factory LSB file.
  local key="$1"
  local value="$(getLSBValue "$(grep "^${key}" "${LSB_FACTORY_FILE}")")"

  # TODO(hungte) Support dev_image/etc/lsb-release if needed.

  if [ -z "$value" ]; then
    value="$(getLSBValue "$(grep "^${key}" "${LSB_RELEASE_FILE}")")"
  fi

  echo "${value}"
}

# Bring up network
bringup_network() {
  # Probe USB Ethernet devices.
  local module
  local module_name
  local result=1
  for module in /lib/modules/*/kernel/drivers/net/usb/*; do
    module_name="$(basename "${module%.ko}")"
    modprobe ${module_name}
  done

  # Try to bring up network and get an IP address on each Ethernet device.
  for iface in $(ifconfig -a | grep -Eo 'eth[0-9]+'); do
    ifconfig ${iface} up || true
    udhcpc -t 3 -f -q -n -i ${iface} -s /etc/udhcpc.script && result=0
  done
  return ${result}
}

# Try to register into Overlord server if available.
register_to_overlord() {
  local omaha_url="$1"
  local tty_file="$2"
  local log_file="$3"
  local machine_id=""

  local server="${omaha_url#*://}"
  server="${server%%:*}"
  server="${server%% }"
  server="${server## }"
  [ -n "${server}" ] || return 1

  # Build machine ID by MAC addresses.
  local eth="$(netstat -r | grep '^default ')"
  machine_id="$(ip link show ${eth##* } | grep 'link/ether' |
                sed 's/.*ether //;s/ brd .*//' | tr '\n' ',' | sed 's/,$//')"
  [ -n "${machine_id}" ] || machine_id="UnknownMachineId.$(uuidgen 2>/dev/null)"

  local header_tty="$(mktemp)" header_log="$(mktemp)"
  local header='{"name":"register",
                 "params":{"sid":"%s","mid":"%s","format":%s,"mode":4}}\r\n'
  printf "${header}" "Console" "${machine_id}" "1" >"${header_tty}"
  printf "${header}" "DebugLog" "${machine_id}" "0" >"${header_log}"

  # nc@busybox may have problem in receiving data from pipe (due to buffer size
  # and timeout), so we should write the command into a scripting file and let
  # busybox create the pipe internally.
  local tty_piper="$(mktemp)" log_piper="$(mktemp)"
  echo "tail -n +0 -qF ${header_tty} ${tty_file}" >"${tty_piper}"
  echo "tail -n +0 -qF ${header_log} ${log_file}" >"${log_piper}"
  chmod a+rx "${tty_piper}" "${log_piper}"
  local connect_cmd="while true; do busybox nc ${server} 4455 -e %s;
                     sleep 10; done"

  if [ -n "${tty_file}" ]; then
    setsid sh -c "$(printf "${connect_cmd}" ${tty_piper})" &
  fi
  setsid sh -c "$(printf "${connect_cmd}" ${log_piper})" &
}
