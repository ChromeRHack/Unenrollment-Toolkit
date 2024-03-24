#!/bin/sh
# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'

FW_DIR="/lib/firmware"
FW_LINK_NAME="wdt87xx_fw.bin"
FW_LINK_PATH="${FW_DIR}/${FW_LINK_NAME}"
WEIDA_FW_VERSION_SYSFS="fw_version"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

get_active_product_id() {
  # Get the "product id" of this device.  Weida devices just use the USB ids
  # concatenated together like $USB_VENDOR_ID$USB_PRODUCT_ID
  local touch_device_path="$1"
  local input_path="${touch_device_path}/input/input*"
  local usb_vendor_id="$(cat ${input_path}/id/vendor)"
  local usb_product_id="$(cat ${input_path}/id/product)"

  if [ -z "${usb_vendor_id}" ] || [ -z "${usb_product_id}" ]; then
    die "Unable to determine a product id for ${touch_device_path}."
  fi

  echo "${usb_vendor_id}${usb_product_id}"
}

compare_fw_versions() {
  # Weida firmware versions are just a single hexidecimal number.  To compare
  # the active FW version and the one we're considering, this function converts
  # them to decimal first for the comparison, but displays them in their
  # original hexidecimal form for clarity and simplicity in the logs.
  local raw_active_fw_version="$1"
  local raw_fw_version="$2"
  local decimal_active_fw_version="$(hex_to_decimal "$raw_active_fw_version")"
  local decimal_fw_version="$(hex_to_decimal "$raw_fw_version")"

  compare_multipart_version "${decimal_active_fw_version}" "${decimal_fw_version}"
}

main() {
  local trackpad_device_name="${FLAGS_device}"
  local touch_device_path=""
  local active_product_id=""
  local active_fw_version=""
  local fw_path=""
  local fw_filename=""
  local fw_name=""
  local update_type=""
  local update_needed=${FLAGS_FALSE}
  local product_id=""
  local fw_version=""

  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi

  # Find the path to the device
  touch_device_path="$(find_i2c_device_by_name "${trackpad_device_name}" \
                       "update_fw fw_version name")"
  if [ -z "${touch_device_path}" ]; then
    die "${trackpad_device_name} not found on system. Aborting update."
  fi

  # Determine the product ID of the device we're considering updating
  active_product_id="$(get_active_product_id "${touch_device_path}")"

  # Make sure there is a FW that looks like it's for the same product ID
  log_msg "Attempting to load FW: '${FW_LINK_PATH}'"
  fw_path="$(readlink "${FW_LINK_PATH}")"
  if [ ! -e "${FW_LINK_PATH}" ] ||
     [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${trackpad_device_name} found."
  fi

  # Parse out the version numbers for the new FW from it's filename
  fw_filename=${fw_path##*/}
  fw_name=${fw_filename%.bin}
  product_id=${fw_name%_*}
  fw_version=${fw_name#"${product_id}_"}
  if [ -n "${active_product_id}" ] &&
     [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "Current product id: ${active_product_id}"
    log_msg "Updater product id: ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Get the current FW version that's loaded on the touch IC
  active_fw_version="$(get_active_firmware_version_from_sysfs \
                     "${WEIDA_FW_VERSION_SYSFS}" "${touch_device_path}")"
  log_msg "Product ID: ${product_id}"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"


  # Determine if an update is needed, and if we do, trigger it now
  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"
  if [ ${update_needed} -eq ${FLAGS_TRUE} ]; then
    log_msg "Updating FW to ${fw_filename}..."
    standard_update_firmware "${touch_device_path}"

    active_fw_version="$(get_active_firmware_version_from_sysfs \
                       "${WEIDA_FW_VERSION_SYSFS}" "${touch_device_path}")"
    log_msg "Current Firmware (after update attempt): ${active_fw_version}"

    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"

    # Rebind the driver incase there is setup that will be different with the
    # new firmware we just loaded.
    rebind_driver "${touch_device_path}"
  fi

  exit 0
}

main "$@"
