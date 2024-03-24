#!/bin/sh

# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Chrome OS Touch Firmware Update Script
# This script checks whether a payload firmware in rootfs should be applied
# to the touch device. If so, this will trigger the update_fw mechanism in
# the kernel driver.
#

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'

RAYDIUM_NUM_RETRIES=3
RAYDIUM_FW_BOOT_MODE="Recovery"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

RAYDIUM_FW_VERSION_SYSFS="fw_version"
RAYDIUM_HW_VERSION_SYSFS="hw_version"
RAYDIUM_FW_UPDATE_SYSFS="update_fw"
RAYDIUM_FW_BOOTMODE_SYSFS="boot_mode"
RAYDIUM_REQUIRED_SYSFS="${RAYDIUM_FW_BOOTMODE_SYSFS} ${RAYDIUM_FW_VERSION_SYSFS} \
                      ${RAYDIUM_FW_UPDATE_SYSFS} ${RAYDIUM_HW_VERSION_SYSFS}"

get_active_firmware_version() {
  local touch_device_path="$1"
  cat "${touch_device_path}/${RAYDIUM_FW_VERSION_SYSFS}"
}

get_major_version_number() {
  # Parse the major version number for an Raydium FW version string
  local fw_version="$1"
  echo "${fw_version%%.*}"
}

get_minor_version_number() {
  # Parse the minor version number for an Raydium FW version string
  local fw_version="$1"
  local major="$(get_major_version_number "${fw_version}")"
  local fw_version_without_major=${fw_version#${major}.}
  echo "${fw_version_without_major%.*}"
}

compare_fw_versions() {
  local active_fw_version="$1"
  local fw_version="$2"

  # Parse the FW versions into their separate components. Raydium FW version
  # strings are made up of two numbers separated by dots. They follow
  # the form: major.minor
  local fw_version_major="$(get_major_version_number "${fw_version}")"
  local fw_version_minor="$(get_minor_version_number "${fw_version}")"
  local active_fw_version_major="$(get_major_version_number "${active_fw_version}")"
  local active_fw_version_minor="$(get_minor_version_number "${active_fw_version}")"
  compare_multipart_version "${active_fw_version_major}" "${fw_version_major}" \
                            "${active_fw_version_minor}" "${fw_version_minor}"
}

main() {
  local touch_device_name="${FLAGS_device}"
  local touch_device_path=""
  local update_needed=""
  local update_type=""
  local fw_link_name=""
  local active_hw_version=""
  local active_fw_version=""
  local active_boot_mode=""
  local fw_path=""
  local fw_tmp_link_path=""
  local fw_link_path=""
  local fw_filename=""
  local fw_name=""
  local hw_fw_version=""
  local fw_version=""
  local hw_version=""
  local firmware_name=""

  # Make sure the specified device exists
  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi
  touch_device_path="$(find_i2c_device_by_name "${touch_device_name}" \
                       "${RAYDIUM_REQUIRED_SYSFS}")"
  if [ -z "${touch_device_path}" ]; then
    die "${touch_device_name} not found on system. Aborting update."
  fi

  # Read the device's HW version
  active_hw_version="$(cat ${touch_device_path}/${RAYDIUM_HW_VERSION_SYSFS})"
  active_boot_mode="$(cat ${touch_device_path}/${RAYDIUM_FW_BOOTMODE_SYSFS})"
  if [ -z "${active_hw_version}" ]; then
    die "No hw version found in ${touch_device_path}."
  fi

  # Find the location of the correct FW to load in /lib/firmware
  firmware_name="raydium_${active_hw_version}.fw"
  fw_link_path="$(find_fw_link_path "${firmware_name}" "${active_hw_version}")"
  fw_folder="$(dirname "$(readlink -f "${fw_link_path}")")"
  fw_file_cnt=$(find "${fw_folder}" -type f -name "*${active_hw_version}*" | wc -l)

  if [ "${fw_file_cnt}" != "1" ]; then
    die "Multiple fw with same hw version found in ${fw_folder}."
  fi

  log_msg "Attempting to load FW: '${fw_link_path}'"
  fw_path="$(readlink -f "${fw_link_path}")"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${touch_device_name} found."
  fi

  # Parse out firmware versions from the firmware filename
  fw_filename="$(basename "${fw_path}")"
  fw_name=${fw_filename%.*}
  hw_fw_version=${fw_name#*_}
  fw_version=${fw_name##*_}
  hw_version=${hw_fw_version%_*}
  if [ -z "${hw_version}" ] || [ -z "${fw_version}" ]; then
    die "Unable to determine hw/fw versions on disk from ${fw_path}."
  fi

  # If the updater expected a different HW version in normal mode, stop now.
  if [ "${active_boot_mode}" = "${RAYDIUM_FW_BOOT_MODE}" ]; then
    log_msg "Device in boot mode, skipping HW version check to recover"
  elif [ "${hw_version}" != "${active_hw_version}" ]; then
    log_msg "Hardware HW version : ${active_hw_version}"
    log_msg "Updater HW version  : ${hw_version}"
    die "HW Version mismatch, unable to continue!"
  fi

  active_fw_version="$(get_active_firmware_version "${touch_device_path}")"
  if [ -z "${active_fw_version}" ]; then
    echo "Unable to determine active FW version."
  fi

  # Parse the firmware versions to see if the firmware should be updated
  log_msg "Device boot mode : ${active_boot_mode}"
  log_msg "HW version : ${active_hw_version}"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"
  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # If the updater firmware versions is newer than current firmware versions,
  # do the update flow.
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${fw_name}"

    for i in $(seq "${RAYDIUM_NUM_RETRIES}"); do
      standard_update_firmware "${touch_device_path}" "${touch_device_name}" \
                             "${fw_path}"
      # Confirm that the update succeded, by re-reading the fw version
      active_fw_version="$(get_active_firmware_version "${touch_device_path}")"
      update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
      if  [ "${update_type}" -eq "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
        break
      else
        log_msg "Firmware update failed, try # ${i}, wait to retry..."
        sleep 6
        if [ "${i}" -ge $((${RAYDIUM_NUM_RETRIES} - 1))  ]; then
          die "Firmware update failed. Current Firmware: ${active_fw_version}"
        fi
      fi
    done

    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"
    rebind_driver "${touch_device_path}"
  fi

  exit 0
}

main "$@"
