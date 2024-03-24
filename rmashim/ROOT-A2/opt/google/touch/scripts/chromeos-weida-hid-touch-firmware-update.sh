#!/bin/sh
# Copyright 2017 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'
DEFINE_string 'device_path' '' "device path" 'p'

FW_LINK_NAME="wdt87xx.bin"
WDT_UTIL="/usr/sbin/wdt_util"
GET_ACTIVE_FW_VER="-v"
GET_ACTIVE_PARAM_VER="-c"
GET_ACTIVE_PROD_ID="-i"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  local fw_path="$1"
  local ret
  local cmd_log=""

  for i in $(seq 3); do
    cmd_log="$(
      minijail0 -S /opt/google/touch/policies/wdt_util.update.policy \
          "${WDT_UTIL}" -u "${fw_path}" -b -d "${FLAGS_device}"
    )"

    ret=$?
    if [ ${ret} -eq 1 ]; then
      return 0
    fi
    log_msg "FW update attempt #${i} failed: ${cmd_log}"
    sleep 1
  done
  die "Error updating touch firmware. ${ret}"
}

get_active_fw_param_ver() {
  # Get the fw & param version of this device.
  minijail0 -S /opt/google/touch/policies/wdt_util.query.policy \
    "${WDT_UTIL}" "${GET_ACTIVE_FW_VER}" "${GET_ACTIVE_PARAM_VER}" -d \
    "${FLAGS_device}"
}

get_active_product_id() {
  # Get the product id of this device.
  minijail0 -S /opt/google/touch/policies/wdt_util.query.policy \
    "${WDT_UTIL}" "${GET_ACTIVE_PROD_ID}" -d "${FLAGS_device}"
}

compare_fw_versions() {
  # Weida firmware versions are combined by two hexidecimal number. One is the
  # FW version and the other one is the date code of parameters. To compare
  # the active versions and the one we're considering, this function converts
  # them to decimal first for the comparison, but displays them in their
  # original hexidecimal form for clarity and simplicity in the logs.
  local raw_active_fw_param_ver="$1"
  local raw_active_fw_ver="${raw_active_fw_param_ver%_*}"
  local raw_active_param_ver="${raw_active_fw_param_ver#"${raw_active_fw_ver}_"}"

  local raw_fw_param_ver="$2"
  local raw_fw_ver="${raw_fw_param_ver%_*}"
  local raw_param_ver="${raw_fw_param_ver#"${raw_fw_ver}_"}"

  local decimal_active_fw_ver="$(hex_to_decimal "$raw_active_fw_ver")"
  local decimal_active_param_ver="$(hex_to_decimal "$raw_active_param_ver")"
  local decimal_fw_ver="$(hex_to_decimal "$raw_fw_ver")"
  local decimal_param_ver="$(hex_to_decimal "$raw_param_ver")"

  compare_multipart_version "${decimal_active_fw_ver}" "${decimal_fw_ver}" \
                            "${decimal_active_param_ver}" "${decimal_param_ver}"
}

main() {
  local device_name="${FLAGS_device}"
  local active_product_id=""
  local active_fw_param_ver=""
  local fw_link_path=""
  local fw_path=""
  local fw_filename=""
  local fw_name=""
  local update_type=""
  local update_needed=${FLAGS_FALSE}
  local product_id=""
  local fw_version=""
  local product_fw=""
  local fw_param_ver=""

  # This script runs early at bootup, so if the touch driver is mistakenly
  # included as a module (as opposed to being compiled directly in) the i2c
  # device may not be present yet. Pause long enough for for people to notice
  # and fix the kernel config.
  check_i2c_chardev_driver

  # Determine the product ID of the device we're considering updating
  active_product_id="$(get_active_product_id)"

  # Make sure there is a FW that looks like it's for the same product ID
  fw_link_path="$(find_fw_link_path "${FW_LINK_NAME}" "${active_product_id}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  fw_path="$(readlink "${fw_link_path}")"
  if [ ! -e "${fw_link_path}" ] ||
     [ ! -e "${fw_path}" ]; then
    die "No valid firmware for weida-${active_product_id} found."
  fi

  # Parse out the version numbers for the new FW from it's filename
  # The filename is as following format: product_fw_parameter.bin,
  # like 01017401_2082_0133c65b.bin. 01017401 is the product id,
  # 2082 is fw version and 0133c65b is the version of parameters.
  fw_filename="${fw_path##*/}"
  fw_name="${fw_filename%.bin}"
  product_fw="${fw_name%_*}"
  param_version="${fw_name#"${product_fw}_"}"
  product_id="${product_fw%_*}"
  fw_param_ver="${fw_name#"${product_id}_"}"
  if [ -n "${active_product_id}" ] &&
     [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "Current product id: ${active_product_id}"
    log_msg "Updater product id: ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Get the current FW version that's loaded on the touch IC
  active_fw_param_ver="$(get_active_fw_param_ver)"
  log_msg "Product ID: ${product_id}"
  log_msg "Current Firmware_parameters: ${active_fw_param_ver}"
  log_msg "Updater Firmware_parameters: ${fw_param_ver}"

  # Determine if an update is needed, and if we do, trigger it now
  update_type="$(compare_fw_versions "${active_fw_param_ver}" \
                                     "${fw_param_ver}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"
  if [ ${update_needed} -eq ${FLAGS_TRUE} ]; then
    log_msg "Updating FW to ${fw_filename}..."
    update_firmware "${fw_path}"

    active_fw_param_ver="$(get_active_fw_param_ver)"
    log_msg "Current Firmware (after update attempt): ${active_fw_param_ver}"

    update_type="$(compare_fw_versions "${active_fw_param_ver}" \
                                       "${fw_param_ver}")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_param_ver}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_param_ver}"

    rebind_driver "${FLAGS_device_path}"
  fi

  exit 0
}

main "$@"
