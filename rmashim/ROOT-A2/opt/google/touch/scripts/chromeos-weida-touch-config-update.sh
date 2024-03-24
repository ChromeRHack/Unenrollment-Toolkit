#!/bin/sh

# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Chrome OS Wedia Touch Config Update Script
# This script checks whether a payload config in rootfs should be applied
# to the touch device. If so, this will trigger the update_config mechanism in
# the kernel driver. The config update mechanism is a unique feature of
# weida touchscreen devices.
#

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh


WEIDA_CONFIG_LINK_PATH="/lib/firmware/wdt87xx_cfg.bin"

DEFINE_string "device" "WDHT0001:00" "device name" "d"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

get_device_config_csum() {
  # Extract the checksum of the config currently on the device and normalize
  # the hex digits to lowercase.
  echo "$(cat "$1/config_csum")" | tr [:upper:] [:lower:]
}

get_file_config_csum() {
  # Config checksum is at the end of the config binary's filename.
  # They should be named in the format:  hardwareID_configcsum.bin
  # eg: 22b90051_5dbda749.bin
  local filepath="$1"
  local filename=${filepath%.*}
  local file_csum=${filename#*_}

  echo $file_csum
}

update_config() {
  local touch_device_path="$1"
  local config_file_path="$2"
  local device_config_csum="$(get_device_config_csum "${touch_device_path}")"
  local file_config_csum="$(get_file_config_csum "${config_file_path}")"

  log_msg "Device config checksum : ${device_config_csum}"
  log_msg "New config checksum : ${file_config_csum}"

  if [ "${device_config_csum}" != "${file_config_csum}" ]; then
    printf 1 > "${touch_device_path}/update_config"

    local ret=$?
    if [ ${ret} -ne 0 ]; then
      die "Config update failed. ret=${ret}"
    else
      local new_config_csum="$(get_device_config_csum "${touch_device_path}")"
      log_msg "Updated config checksum : ${new_config_csum}"
    fi
  else
    log_msg "Config is up-to-date, no need to update"
  fi
}

main() {
  local touch_device_name="${FLAGS_device}"
  local touch_device_path=""
  local config_link_name="$(basename "${WEIDA_CONFIG_FILE_PATH}")"
  local config_file_path="$(readlink "${WEIDA_CONFIG_LINK_PATH}")"

  touch_device_path="$(find_i2c_device_by_name "${touch_device_name}" \
                       "update_config config_csum")"
  if [ -z "${touch_device_path}" ]; then
    die "${touch_device_name} not found on system."
  fi

  if [ ! -e "${WEIDA_CONFIG_LINK_PATH}" ] ||
     [ ! -e "${config_file_path}" ]; then
    die "No valid config file with name ${config_link_name} found."
  fi

  update_config "${touch_device_path}" "${config_file_path}"
  exit 0
}

main "$@"
