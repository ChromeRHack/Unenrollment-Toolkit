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

CYAPA_FIRMWARE_NAME='cyapa.bin'
CYAPA_FW_VERSION_SYSFS="firmware_version"
CYAPA_PRODUCT_ID_SYSFS="product_id"
CYAPA_REQUIRED_SYSFS="${CYAPA_FW_VERSION_SYSFS} ${CYAPA_PRODUCT_ID_SYSFS} \
                      update_fw"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

compare_fw_versions() {
  local active_fw_version="$1"
  local fw_version="$2"

  local active_fw_version_major=""
  local active_fw_version_minor=""
  local fw_version_major=""
  local fw_version_minor=""

  active_fw_version_major=${active_fw_version%%.*}
  active_fw_version_minor=${active_fw_version##*.}
  fw_version_major=${fw_version%%.*}
  fw_version_minor=${fw_version##*.}

  compare_multipart_version "${active_fw_version_major}" "${fw_version_major}" \
                            "${active_fw_version_minor}" "${fw_version_minor}"
}

main() {
  local device_name="${FLAGS_device}"
  local device_path=""
  local update_needed=""
  local active_product_id=""
  local active_fw_version=""
  local fw_path=""
  local fw_link_path=""
  local fw_filename=""
  local fw_name=""
  local product_id=""
  local fw_version=""
  local update_type=""

  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi

  # Find the device in the filesystem.
  device_path="$(find_i2c_device_by_name "${device_name}" \
                          "${CYAPA_REQUIRED_SYSFS}")"
  if [ -z "${device_path}" ]; then
    die "${device_name} not found on system. Aborting update."
  fi

  # Find the product ID that the touch device is reporting itself as.
  active_product_id="$(cat ${device_path}/${CYAPA_PRODUCT_ID_SYSFS})"
  if [ -z "${active_product_id}" ]; then
    log_msg "Unable to determine active product id"
    die "Aborting.  Can not continue safely without knowing active product ID"
  fi

  # Find the FW that the updater is considering flashing on the touch device.
  fw_link_path="$(find_fw_link_path "${CYAPA_FIRMWARE_NAME}" \
                                    "${active_product_id}")"
  fw_path="$(readlink "${fw_link_path}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${touch_device_name} found."
  fi
  fw_filename=${fw_path##*/}
  fw_name=${fw_filename%.bin}
  product_id=${fw_name%_*}
  fw_version=${fw_name#"${product_id}_"}

  # Make sure the product ID is what the updater expects.
  local product_id_matches=${FLAGS_FALSE}
  log_msg "Hardware product id : ${active_product_id}"
  log_msg "Updater product id  : ${product_id}"
  if [ "${product_id}" = "${active_product_id}" ]; then
    product_id_matches=${FLAGS_TRUE}
  elif [ "${active_product_id}" = "CYTRA-119001-TD" ]; then
    product_id_matches=${FLAGS_TRUE}
  elif [ "${active_product_id}" = "CYTRA-103001-00" -a
         "${product_id}" = "CYTRA-101003-00" ]; then
    product_id_matches=${FLAGS_TRUE}
  fi
  if [ "${product_id_matches}" -ne ${FLAGS_TRUE} ]; then
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Check the touch device's FW version and compare to the updater's.
  active_fw_version="$(get_active_firmware_version_from_sysfs \
                         "${CYAPA_FW_VERSION_SYSFS}" "${device_path}")"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"

  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # If an update is needed, start it now and confirm it worked.
  if [ "${update_needed}" -eq ${FLAGS_TRUE} ]; then
    log_msg "Update FW to ${fw_name}"
    standard_update_firmware "${device_path}" "${fw_path}"

    # Confirm that the FW was updated by checking the current FW version again
    active_fw_version="$(get_active_firmware_version_from_sysfs \
                           "${CYAPA_FW_VERSION_SYSFS}" "${device_path}")"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"

    rebind_driver "${device_path}"
  fi

  exit 0
}

main "$@"
