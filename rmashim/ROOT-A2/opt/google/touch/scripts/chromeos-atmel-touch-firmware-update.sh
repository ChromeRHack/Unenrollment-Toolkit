#!/bin/sh

# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
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
DEFINE_string 'firmware_name' '' "firmware name (in /lib/firmware)" 'n'

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

CORRUPTED_HW_VERSION="0.0"
ATMEL_FW_VERSION_SYSFS="fw_version"
ATMEL_FW_UPDATE_SYSFS="update_fw"
ATMEL_FW_FILENAME_SYSFS="fw_file"
ATMEL_HW_VERSION_SYSFS="hw_version"
ATMEL_REQUIRED_SYSFS="${ATMEL_FW_FILENAME_SYSFS} ${ATMEL_FW_VERSION_SYSFS} \
                      ${ATMEL_FW_UPDATE_SYSFS} ${ATMEL_HW_VERSION_SYSFS}"


get_active_firmware_version() {
  local touch_device_path="$1"
  cat "${touch_device_path}/${ATMEL_FW_VERSION_SYSFS}"
}


get_major_version_number() {
  # Extract the major version number for an Atmel FW version string of the
  # form major.minor.build
  local fw_version="$1"
  echo "${fw_version%%.*}"
}

get_minor_version_number() {
  # Extract the minor version number for an Atmel FW version string of the
  # form major.minor.build
  local fw_version="$1"
  local major="$(get_major_version_number "${fw_version}")"
  local fw_version_without_major=${fw_version#${major}.}
  echo "${fw_version_without_major%.*}"
}

get_build_number() {
  # Extract the build number for an Atmel FW version string of the
  # form major.minor.build
  # This function also takes a second parameter the others do not, which
  # indicates if the number should be converted from hex to decimal
  local fw_version="$1"
  local needs_hex_to_decimal_conversion="$2"
  local build_number="${fw_version##*.}"

  if [ ${needs_hex_to_decimal_conversion} -eq ${FLAGS_TRUE} ]; then
    hex_to_decimal "${build_number}"
  else
    echo "${build_number}"
  fi
}

set_fw_file() {
  # Atmel touch devices have a fw_file sysfs entry that allows you to
  # specify a filename for the fw updater.  This function takes in
  # the location of the fw binary and configures the new fw update to
  # read from that file.
  local touch_device_path="$1"
  local fw_link_name="$2"
  local sysfs_entry="${touch_device_path}/${ATMEL_FW_FILENAME_SYSFS}"

  printf "${fw_link_name}" > "${sysfs_entry}"

  if [ "$(cat "${sysfs_entry}")" != "${fw_link_name}" ]
  then
    die "Unable set firmware file name to '${fw_link_name}'."
  fi
}

compare_fw_versions() {
  local active_fw_version="$1"
  local fw_version="$2"

  # Parse the FW versions into their separate components. Atmel FW version
  # strings are made up of three numbers separated by dots. They follow
  # the form: major.minor.build_number
  # Note: Due to a mixup early on, the build number is in hex when reading from
  #       the sysfs entries, but is stored in decimal in the filename of the
  #       updater's FW binary.
  local fw_version_major="$(get_major_version_number "${fw_version}")"
  local fw_version_minor="$(get_minor_version_number "${fw_version}")"
  local fw_version_build="$(get_build_number "${fw_version}" ${FLAGS_FALSE})"
  local active_fw_version_major="$(get_major_version_number "${active_fw_version}")"
  local active_fw_version_minor="$(get_minor_version_number "${active_fw_version}")"
  local active_fw_version_build="$(get_build_number "${active_fw_version}" ${FLAGS_TRUE})"

  compare_multipart_version "${active_fw_version_major}" "${fw_version_major}" \
                            "${active_fw_version_minor}" "${fw_version_minor}" \
                            "${active_fw_version_build}" "${fw_version_build}"
}

main() {
  local touch_device_name="${FLAGS_device}"
  local touch_device_path=""
  local update_needed=""
  local update_type=""
  local fw_link_name=""
  local active_hw_version=""
  local active_fw_version=""
  local fw_path=""
  local fw_link_path=""
  local fw_filename=""
  local fw_name=""
  local hw_version=""
  local fw_version=""

  # First, confirm that the specified device exists
  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi
  touch_device_path="$(find_i2c_device_by_name "${touch_device_name}" \
                       "${ATMEL_REQUIRED_SYSFS}")"
  if [ -z "${touch_device_path}" ]; then
    die "${touch_device_name} not found on system. Aborting update."
  fi

  # Find the device's HW version
  active_hw_version="$(cat ${touch_device_path}/${ATMEL_HW_VERSION_SYSFS})"
  if [ -z "${active_hw_version}" ]; then
    die "No hw version found in ${touch_device_path}."
  fi

  # Find the location of the correct FW to load in /lib/firmware
  fw_link_path="$(find_fw_link_path "${FLAGS_firmware_name}" \
                                    "${active_hw_version}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  fw_path="$(readlink "${fw_link_path}")"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${touch_device_name} found."
  fi

  # Parse out the HW & FW versions that the updater has (from its filename)
  fw_filename="$(basename "${fw_path}")"
  fw_name=${fw_filename%.*}
  hw_version=${fw_name%_*}
  fw_version=${fw_name##*_}
  if [ -z "${hw_version}" ] || [ -z "${fw_version}" ]; then
    die "Unable to determine hw/fw versions on disk from ${fw_path}."
  fi

  # If the updater expected a different HW version, stop now.
  if [ "${active_hw_version}" = "${CORRUPTED_HW_VERSION}" ]; then
    log_msg "Forcing FW update, the device appears to have corrupted FW"
  elif [ "${hw_version}" != "${active_hw_version}" ]; then
    log_msg "Hardware HW version : ${active_hw_version}"
    log_msg "Updater HW version  : ${hw_version}"
    die "HW Version mismatch, unable to continue!"
  fi

  # Query the device and then do the same, parsing it into its components
  active_fw_version="$(get_active_firmware_version "${touch_device_path}")"
  if [ -z "${active_fw_version}" ]; then
    echo "Unable to determine active FW version."
  fi

  # Compare the two versions, and see if an update is needed
  log_msg "Product ID : ${hw_version}"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"
  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # If we do indeed need to perform an update, do it now
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${fw_name}"

    # Configure the touch driver to know which fw file to load, then update
    fw_link_name="$(basename "${fw_link_path}")"
    set_fw_file "${touch_device_path}" "${fw_link_name}"
    standard_update_firmware "${touch_device_path}" "${touch_device_name}" \
                             "${fw_path}"

    # Confirm that the update succeded, by re-reading the fw version
    active_fw_version="$(get_active_firmware_version "${touch_device_path}")"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"

    rebind_driver "${touch_device_path}"
  fi

  exit 0
}

main "$@"
