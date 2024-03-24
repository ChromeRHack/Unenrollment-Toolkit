#!/bin/sh

# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_string 'device_path' '' "device path" 'p'
DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

SIS_FW_UPDATE_USER="sisfwupdate"
SIS_FW_UPDATE_GROUP="sisfwupdate"
SIS_TOUCH_I2C_HIDRAW="/dev/sis_touch_i2c_hidraw"
SIS_TOUCH_USB_HIDRAW="/dev/sis_touch_usb_hidraw"
SIS_FIRMWARE_NAME='sis.bin'
SIS_VENDOR_ID="0457"

# Consoletool path
CONSOLETOOL_DIR="/usr/sbin"
GET_FIRMWARE_ID="${CONSOLETOOL_DIR}/SiSGetFirmwareId"
UPDATE_FW="${CONSOLETOOL_DIR}/SiSUpdateFW"

# Consoletool settings
WAIT_RESET_TIME="4"

get_active_product_id() {
  local hidpath="$(echo "${FLAGS_device_path}"/*:${SIS_VENDOR_ID}:*.*)"
  local hidname="hid-$(echo "${hidpath##*/}" | \
                       awk -F'[:.]' '{ print $2 "_" $3 }')"
  local product_id="${hidname#*_}"
  echo "${product_id}"
}

get_active_firmware_version() {
  local sis_touch_hidraw="$1"
  local sis_log=""
  sis_log="$(minijail0 -u "${SIS_FW_UPDATE_USER}" -g "${SIS_FW_UPDATE_GROUP}" \
                 -n -S /opt/google/touch/policies/sisupdate.query.policy \
                 ${GET_FIRMWARE_ID} "-n=${sis_touch_hidraw}" "-dis-crto")"
  local ret="$?"

  if [ "${ret}" -eq "0" ]; then
    # Parse active firmware version
    local version_text="$(echo "${sis_log}" \
      | grep "Active Firmware Version : " | head -1)"

    echo "${version_text##*"Active Firmware Version : "}"
    exit 0
  else
    # Some error occurred when executing "getFirmwareId"
    die "'getFirmwareId' failed, code=${ret}"
  fi
}

compare_fw_versions() {
  local active_fw_version="$1"
  local fw_version="$2"
  local active_fw_version_major=${active_fw_version%%.*}
  local active_fw_version_minor=${active_fw_version##*.}
  local fw_version_major=${fw_version%%.*}
  local fw_version_minor=${fw_version##*.}
  compare_multipart_version "${active_fw_version_major}" "${fw_version_major}" \
                            "${active_fw_version_minor}" "${fw_version_minor}"
}

update_firmware() {
  local sis_touch_hidraw="$1"
  local fw_path="$2"

  minijail0 -u "${SIS_FW_UPDATE_USER}" -g "${SIS_FW_UPDATE_GROUP}" \
      -n -S /opt/google/touch/policies/sisupdate.update.policy \
      ${UPDATE_FW} "-n=${sis_touch_hidraw}" "-ba" \
      "${fw_path}" "-wrs=${WAIT_RESET_TIME}"
  local ret="$?"

  # Show info for the exit-value of ececuting "updateFW"
  if [ "${ret}" -eq "0" ]; then
    log_msg "'updateFW' succeded"
  else
    # Some error occurred when executing "updateFW"
    log_msg "error: 'updateFW' failed, code=${ret}"
  fi
}

create_sis_hidraw() {
  local sis_touch_hidraw=""
  local touch_device=""
  local dev_t_major=""
  local dev_t_minor=""

  # Check touch interface if i2c or usb
  case "${FLAGS_device_path}" in
    */i2c*)
      sis_touch_hidraw=${SIS_TOUCH_I2C_HIDRAW}
      ;;
    */usb*)
      sis_touch_hidraw=${SIS_TOUCH_USB_HIDRAW}
      ;;
    *)
      sis_touch_hidraw=${SIS_TOUCH_I2C_HIDRAW}
  esac

  # Remove sis_touch_hidraw if it exists. The det_t_major/minor may be changed.
  if [ -e "${sis_touch_hidraw}" ]; then
    rm -rf ${sis_touch_hidraw}
  fi

  # Find the device path if it exists "/dev/hidrawX".
  hidraw_sysfs_path="$(echo "${FLAGS_device_path}"/*:${SIS_VENDOR_ID}:*.*/hidraw/hidraw*)"
  touch_device="/dev/${hidraw_sysfs_path##*/}"

  if [ -c "${touch_device}" ]; then
    # create a device node for touch firmware update
    dev_t_major="$(ls -l "${touch_device}" | awk '{print $5}')"
    dev_t_major=${dev_t_major%%,}
    dev_t_minor="$(ls -l "${touch_device}" | awk '{print $6}')"
    mknod "${sis_touch_hidraw}" c "${dev_t_major}" "${dev_t_minor}"
    if [ $? -ne 0 ]; then
      die "Failed create node: '${sis_touch_hidraw}'."
    fi

    # Change ownership for sis touch device
    chown "${SIS_FW_UPDATE_USER}":"${SIS_FW_UPDATE_GROUP}" \
          "${sis_touch_hidraw}"
    if [ $? -ne 0 ]; then
      die "Failed change owner of node: '${sis_touch_hidraw}'."
    fi

    # Change access mode for sis touch device
    chmod 0660 ${sis_touch_hidraw}
    if [ $? -ne 0 ]; then
      die "Failed change mode of node: '${sis_touch_hidraw}'."
    fi

  else
    die "Not a legal node: '${touch_device}'."
  fi
  echo "${sis_touch_hidraw}"
}

main() {
  local sis_touch_hidraw=""
  local active_product_id=""
  local fw_link_path=""
  local fw_filename=""
  local fw_name=""
  local product_id=""
  local fw_version=""
  local active_fw_version=""
  local update_type=""
  local update_needed="${FLAGS_FALSE}"
  local ret=""
  local product_id_matches="${FLAGS_FALSE}"

  # Check if specify the hidraw_name.
  if [ -z "${FLAGS_device_path}" ]; then
    die "Please specify a hidraw_name using -d"
  fi

  # Get the active product-id.
  active_product_id="$(get_active_product_id)"

  if [ -z "${active_product_id}" ]; then
    log_msg "Unable to determine active product id"
    die "Aborting.  Can not continue safely without knowing active product id"
  fi

  # Find the FW that the updater is considering flashing on the touch device.
  fw_link_path="$(find_fw_link_path ${SIS_FIRMWARE_NAME} ${active_product_id})"
  fw_path="$(readlink -f "${fw_link_path}")"

  log_msg "Attempting to load FW: '${fw_link_path}'"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${FLAGS_device_path} found."
  fi

  fw_filename=${fw_path##*/}
  fw_name=${fw_filename%.bin}
  product_id=${fw_name%_*}
  fw_version=${fw_name#"${product_id}_"}

  # Make sure the product ID is what the updater expects.
  log_msg "Hardware product id : ${active_product_id}"
  log_msg "Updater product id  : ${product_id}"
  if [ "${product_id}" = "${active_product_id}" ]; then
    product_id_matches=${FLAGS_TRUE}
  fi

  if [ "${product_id_matches}" -ne ${FLAGS_TRUE} ]; then
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Create sis hidraw
  sis_touch_hidraw="$(create_sis_hidraw)"
  log_msg "Create node succeded: '${sis_touch_hidraw}'."

  # Get device's fw version.
  active_fw_version="$(get_active_firmware_version ${sis_touch_hidraw})"
  ret="$?"

  if [ ${ret} -ne "0" ]; then
    log_msg "Unable to determine active firmware version"
    die "Aborting. Can not continue safely without knowing active FW version"
  elif [ -z "${active_fw_version}" ]; then
    log_msg "Get empty active firmware version"
    die "Aborting. Can not continue safely without knowing active FW version"
  fi

  # Compare the two versions, and see if an update is needed
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"
  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # If an update is needed, start it now and confirm it worked.
  if [ "${update_needed}" -eq ${FLAGS_TRUE} ]; then
    log_msg "Update FW to ${fw_name}"
    update_firmware ${sis_touch_hidraw} ${fw_path}

    # Recreate sis hidraw. The /dev/hidrawX may be changed after device reset.
    sis_touch_hidraw="$(create_sis_hidraw)"
    log_msg "Recreate node succeded: '${sis_touch_hidraw}'."

    # Confirm that the FW was updated by checking the current FW version again
    active_fw_version="$(get_active_firmware_version ${sis_touch_hidraw})"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"

    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi

    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"
  fi
}

main
