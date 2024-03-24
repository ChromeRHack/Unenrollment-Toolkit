#!/bin/sh

# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'

GOODIX_FW_UPDATE_USER="goodixfwupdate"
GOODIX_FW_UPDATE_GROUP="goodixfwupdate"
GOODIX_TOUCHSCREEN_HIDRAW="/dev/goodix_touchscreen_hidraw"
FW_LINK_NAME="goodix_firmware.bin"
FW_LINK_PATH="/lib/firmware/goodix-ts.bin"
GDIXUPDATE="/usr/sbin/gdixupdate"
GOODIX_VENDOR_ID="27C6"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  local i
  local ret

  for i in $(seq 3); do
    minijail0 -u "${GOODIX_FW_UPDATE_USER}" -g "${GOODIX_FW_UPDATE_GROUP}" \
        -n -S /opt/google/touch/policies/gdixupdate.update.policy \
        "${GDIXUPDATE}" -f -d "$1" "$2"

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
  minijail0 -u "${GOODIX_FW_UPDATE_USER}" -g "${GOODIX_FW_UPDATE_GROUP}" \
      -n -S /opt/google/touch/policies/gdixupdate.query.policy \
      "${GDIXUPDATE}" -p -d "${touch_device_path}"
}

compare_fw_versions() {
  local active_fw_version="$1"
  local fw_version="$2"

  local fw_version_major=""
  local fw_version_minor=""

  local active_fw_version_major=""
  local active_fw_version_minor=""

  active_fw_version_major=${active_fw_version%%.*}
  active_fw_version_minor=${active_fw_version##*.}

  fw_version_major=${fw_version%%.*}
  fw_version_minor=${fw_version##*.}

  compare_multipart_version "${active_fw_version_major}" "${fw_version_major}" \
                            "${active_fw_version_minor}" "${fw_version_minor}"
}

create_goodix_hidraw() {
  local touch_device="$1"
  local dev_t_major=""
  local dev_t_minor=""

  if [ -e "${GOODIX_TOUCHSCREEN_HIDRAW}" ]; then
    log_msg "Touchscreen hidraw device already exists."
    return 0
  fi

  if [ -c "${touch_device}" ]; then
    # create a device node for touchscreen firmware update
    dev_t_major="$(ls -l "${touch_device}" | awk '{print $5}')"
    dev_t_major=${dev_t_major%%,}
    dev_t_minor="$(ls -l "${touch_device}" | awk '{print $6}')"
    mknod "${GOODIX_TOUCHSCREEN_HIDRAW}" c "${dev_t_major}" "${dev_t_minor}"
    if [ $? -ne 0 ]; then
      die "Failed create node: '${GOODIX_TOUCHSCREEN_HIDRAW}'."
    fi

    # Change ownership and access mode for goodix touchscreen device
    chown "${GOODIX_FW_UPDATE_USER}":"${GOODIX_FW_UPDATE_GROUP}" \
          "${GOODIX_TOUCHSCREEN_HIDRAW}"
    if [ $? -ne 0 ]; then
      die "Failed change owner of node: '${GOODIX_TOUCHSCREEN_HIDRAW}'."
    fi

    chmod 0660 ${GOODIX_TOUCHSCREEN_HIDRAW}
    if [ $? -ne 0 ]; then
      die "Failed change mode of node: '${GOODIX_TOUCHSCREEN_HIDRAW}'."
    fi
  else
    die "Not a legal node: '${touch_device}'."
  fi
  return 0
}

main() {
  local touch_device_name="${FLAGS_device}"
  local touch_device_path=""
  local active_product_id=""
  local active_fw_version=""
  local update_type=""
  local update_needed="${FLAGS_FALSE}"
  local product_id=""
  local fw_link_path=""
  local fw_path=""
  local fw_name=""

  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi

  # Find the device path if it exists "/dev/hidrawX".
  touch_device_path="$(find_i2c_hid_device "${touch_device_name##*-}")"
  if [ -z "${touch_device_path}" ]; then
    die "${touch_device_name} not found on system. Aborting update."
  fi

  create_goodix_hidraw "${touch_device_path}"
  touch_device_path="${GOODIX_TOUCHSCREEN_HIDRAW}"
  log_msg "Touch device path: '${touch_device_path}'"

  # Find the active fw version and the product ID currently in use.
  active_product_id="${touch_device_name##*_}"
  active_fw_version="$(get_active_firmware_version "${touch_device_path}")"

  # Find the fw version and product ID on disk.
  fw_link_path="$(find_fw_link_path "${FW_LINK_NAME}" "${active_product_id}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"

  fw_path="$(readlink -f "${fw_link_path}")"
  if [ -z "${fw_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${FLAGS_device} found."
  fi

  fw_name="$(basename "${fw_path}" ".bin")"

  product_id=${fw_name%_*}
  fw_version=${fw_name#"${product_id}_"}
  # Check to make sure we found the device we're expecting. If the product
  # IDs don't match, abort immediately to avoid flashing the wrong device.
  if [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "Current product id: ${active_product_id}"
    log_msg "Updater product id: ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Compare the two versions, and see if an update is needed.
  log_msg "Product ID: ${active_product_id}"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"

  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${fw_name}"
    update_firmware "${touch_device_path}" "${fw_path}"

    # Confirm that the FW was updated by checking the current FW version again.
    active_fw_version="$(get_active_firmware_version "${touch_device_path}")"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"

    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"
  fi
  exit 0
}

main "$@"
