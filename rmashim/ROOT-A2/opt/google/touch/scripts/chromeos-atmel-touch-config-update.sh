#!/bin/sh

# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Chrome OS Touch Config Update Script
# This script checks whether a payload config in rootfs should be applied
# to the touch device. If so, this will trigger the update_config mechanism in
# the kernel driver. The config update mechanism is a unique feature of
# Atmel mXT touchscreen and touchpad devices.
#


. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'force' ${FLAGS_FALSE} "Force update" 'f'
DEFINE_string 'device' 'atmel_mxt_ts' "device name" 'd'

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

get_device_config_csum() {
  # Convert to lowercase.
  echo "$(cat "$1/config_csum")" | tr [:upper:] [:lower:]
}

get_file_config_csum() {
  # Config checksum is at line 4 of the raw config file.
  # Get rid of the Windows newline character and convert to lowercase.
  sed -n 4p "$1" | tr -cd "[:print:]" | tr [:upper:] [:lower:]
}

get_config_file_name() {
  local config_file_mapping="$1"
  local touch_device_path="$2"
  local board=`grep CHROMEOS_RELEASE_BOARD= /etc/lsb-release | awk -F = '{print $2}'`
  if [ ! -e "${touch_device_path}/T19_status" ]; then
    die "No T19_Status for ${touch_device_path}"
    return
  fi
  # Only support 2 different configs for now.
  read T19_status1 config1 T19_status2 config2 < "${config_file_mapping}"
  # T19 status report is async, so lets try a few times.
  printf "1" > "${touch_device_path}/T19_status"
  for i in $(seq 5); do
    local T19="$(cat "${touch_device_path}/T19_status")"
    local T19_decimal=""
    local mask="$((0xff))"
    local sensor_identifier=""
    local status1_sensor=""
    local status2_sensor=""
    case "${board}" in clapper|clapper-*)
      mask="$((0x03))"
      ;;
    esac
    T19_decimal="$((0x${T19}))"
    sensor_identifier="$(($T19_decimal & $mask))"
    status1_sensor="$(($((0x$T19_status1)) & $mask))"
    status2_sensor="$(($((0x$T19_status2)) & $mask))"
    if [ "${sensor_identifier}" = "${status1_sensor}" ]; then
      echo "${config1}"
      return
    elif [ "${sensor_identifier}" = "${status2_sensor}" ]; then
      echo "${config2}"
      return
    fi
    sleep 1
  done
  die "No matching config found"
}

update_config() {
  local touch_device_path="$1"
  local config_file_path="$2"
  local device_config_csum="$(get_device_config_csum "${touch_device_path}")"
  local file_config_csum="$(get_file_config_csum "${config_file_path}")"
  local i

  log_msg "Device config checksum : ${device_config_csum}"
  log_msg "New config checksum : ${file_config_csum}"

  if [ "${device_config_csum}" != "${file_config_csum}" ] ||
     [ ${FLAGS_force} -eq ${FLAGS_TRUE} ]; then
    printf 1 > "${touch_device_path}/update_config"
    local ret=$?
    if [ ${ret} -ne 0 ]; then
      die "Config update failed. ret=${ret}"
    fi

    # Sleep for a while to allow the device config checksum gets updated.
    # No latency concern here since config update happens rarely -- not
    # every boot but only when new set of config data is needed.
    for i in $(seq 5); do
      sleep 1
      device_config_csum="$(get_device_config_csum "${touch_device_path}")"
      log_msg "Try #${i}: Checking new device csum ${device_config_csum}"
      if [ "${device_config_csum}" = "${file_config_csum}" ]; then
        log_msg "Config update succeeded"
        exit 0
      fi
    done
    die "Config update failed. config_sum mismatched after update."
  else
    log_msg "Config is up-to-date, no need to update"
  fi
}

main() {
  local touch_device_name="${FLAGS_device}"
  local touch_device_path=""
  local config_file_name=""
  local ts_config_mapping="/opt/google/touch/config/ts_config_mapping"
  local tp_config_file_name="maxtouch-tp.cfg"
  local ts_config_file_name="maxtouch-ts.cfg"
  local config_link_path=""
  local config_file_path=""

  touch_device_path="$(find_i2c_device_by_name "${touch_device_name}" \
                       "update_config config_csum")"
  if [ -z "${touch_device_path}" ]; then
    die "${touch_device_name} not found on system."
  fi

  case "${touch_device_name}" in
  *ts*|ATML0001*)
    if [ -e "${ts_config_mapping}" ]; then
      config_file_name="$(get_config_file_name "${ts_config_mapping}" \
                                               "${touch_device_path}")"
      log_msg "Using ts_config_mapping to find config '${config_file_name}'"
    else
      config_file_name="${ts_config_file_name}"
    fi
    ;;
  *tp*|ATML0000*)
    config_file_name="${tp_config_file_name}"
    ;;
  *)
    die "No valid touch device name ${touch_device_name}."
    ;;
  esac

  config_link_path="/lib/firmware/${config_file_name}"
  config_file_path="$(readlink -f "${config_link_path}")"

  if [ ! -e "${config_link_path}" ] ||
     [ ! -e "${config_file_path}" ]; then
    die "No valid config file with name ${config_file_name} found."
  fi

  if [ ! -e "${touch_device_path}/config_file" ] ||
     [ ! -e "${touch_device_path}/update_config" ]; then
    die "Sysfs entry for config update not found."
  fi

  printf "${config_file_name}" > "${touch_device_path}/config_file"
  if [ "$(cat "${touch_device_path}/config_file")" != "${config_file_name}" ]
  then
    die "Can't set config file name to ${config_file_name}"
  fi

  update_config "${touch_device_path}" "${config_file_path}"
  exit 0
}

main "$@"
