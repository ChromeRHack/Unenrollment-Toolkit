#!/bin/sh

# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'

RMI4UPDATE="/usr/sbin/rmi4update"
SYNAPTICS_VENDOR_ID="06CB"


# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  local i
  local ret

  for i in $(seq 5); do
    minijail0 -S /opt/google/touch/policies/rmi4update.update.policy \
        ${RMI4UPDATE} -f -d "$1" "$2"

    ret=$?
    if [ ${ret} -eq 0 ]; then
      return 0
    fi
    log_msg "FW update attempt #${i} failed... retrying."
  done
  die "Error updating touch firmware. ${ret}"
}

get_active_firmware_version() {
  local touch_device_path="$1"
  minijail0 -S /opt/google/touch/policies/rmi4update.query.policy \
      ${RMI4UPDATE} -p -d "${touch_device_path}"
}

find_fw_path() {
  local hw_version="$1"
  local fw_link_name="$2"
  local fw_link_path="$(find_fw_link_path "${fw_link_name}" "${hw_version}")"
  local fw_path="$(readlink "${fw_link_path}")"

  echo "${fw_path}"
}


compare_fw_versions() {
  local active_fw_version="$1"
  local fw_version="$2"

  local fw_version_major=""
  local fw_version_minor=""
  local fw_version_build_hex=""
  local fw_version_build=""

  local active_fw_version_major=""
  local active_fw_version_minor=""
  local active_fw_version_build=""

  local minor_build_tmp=""

  # Synaptics FWs are in the format major.minor.build (eg: 1.7.1e4aa0) so
  # the next step is to parse those values out.
  # Note: that due to an unfortunate quirk, the "active" build number is in hex
  #       but the other is not, so we must covert it here to compare them
  active_fw_version_major=${active_fw_version%%.*}
  minor_build_tmp=${active_fw_version#$active_fw_version_major.}
  active_fw_version_minor=${minor_build_tmp%.*}
  active_fw_version_build_hex=${minor_build_tmp#*.}
  active_fw_version_build=$(hex_to_decimal "${active_fw_version_build_hex}")

  fw_version_major=${fw_version%%.*}
  minor_build_tmp=${fw_version#$fw_version_major.}
  fw_version_minor=${minor_build_tmp%.*}
  fw_version_build=${minor_build_tmp#*.}

  compare_multipart_version "${active_fw_version_major}" "${fw_version_major}" \
                            "${active_fw_version_minor}" "${fw_version_minor}" \
                            "${active_fw_version_build}" "${fw_version_build}"
}

main() {
  local trackpad_device_name="${FLAGS_device}"
  local touch_device_path=""
  local active_product_id=""
  local active_fw_version=""
  local update_type=""
  local update_needed="${FLAGS_FALSE}"
  local product_id=""
  local fw_link_path=""
  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi

  modprobe -q hid-rmi || die "Not able to load hid-rmi kernel module"
  # Find the device path if it exists "/dev/hidrawX"
  touch_device_path="$(find_i2c_hid_device ${trackpad_device_name##*-})"
  log_msg "touch_device_path: '${touch_device_path}'"
  if [ -z "${touch_device_path}" ]; then
    die "${trackpad_device_name} not found on system. Aborting update."
  fi

  # Find the active fw version and the product ID currently in use
  active_product_id="${trackpad_device_name##*_}"
  active_fw_version="$(get_active_firmware_version "${touch_device_path}")"

  # Find the fw version and product ID on disk
  fw_path="$(find_fw_path ${active_product_id} ${FLAGS_device})"
  if [ -z "${fw_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${FLAGS_device} found."
  fi
  fw_name="$(basename "${fw_path}" | sed "s/.bin$//")"

  product_id=${fw_name%_*}
  fw_version=${fw_name#"${product_id}_"}

  # Check to make sure we found the device we're expecting.  If the product
  # IDs don't match, abort immediately to avoid flashing the wrong device.
  if [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "Current product id : ${active_product_id}"
    log_msg "Updater product id  : ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Compare the two versions, and see if an update is needed
  log_msg "Product ID : ${active_product_id}"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"
  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # If an update is needed, start it now and confirm it worked.
  if [ "${update_needed}" -eq ${FLAGS_TRUE} ]; then
    log_msg "Update FW to ${fw_name}"
    update_firmware "${touch_device_path}" "${fw_path}"

    # Confirm that the FW was updated by checking the current FW version again
    active_fw_version="$(get_active_firmware_version "${touch_device_path}")"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"
  fi

  exit 0
}

main "$@"
