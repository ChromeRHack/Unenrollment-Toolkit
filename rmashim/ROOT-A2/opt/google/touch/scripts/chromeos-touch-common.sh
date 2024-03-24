#!/bin/sh

# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

I2C_DEVICES_PATH="/sys/bus/i2c/devices"

# powerd will check this lock file and block device suspension.
POWERD_LOCK_FILE="/run/lock/power_override/touch_updater.lock"

# The function will run the cmd and block powerd from suspending the system.
# It's done by creating the lock file while the cmd is running. Remove the lock
# file once it returns.
run_cmd_and_block_powerd() {
  trap 'rm -f "${POWERD_LOCK_FILE}"' EXIT
  echo $$ > "${POWERD_LOCK_FILE}"
  "$@"
  rm -f "${POWERD_LOCK_FILE}"
  trap - EXIT
}

# Find touchscreen/pad path in i2c devices given it's device name and a list
# of the sysfs entries it is expect to have (this can help skip over some
# bogus devices that have already been disconnected)
# The required sysfs filenames could be supplied as a space-delimited string
find_i2c_device_by_name() {
  local dev=""
  local name_to_find="$1"
  local required_sysfs="$2"

  for dev in "${I2C_DEVICES_PATH}"/*/name; do
    local dev_name="$(cat "${dev}")"
    if [ "${name_to_find}" = "${dev_name}" ]; then
      local missing_sysfs_entry=0
      local path="${dev%/name}"

      for sysfs in $required_sysfs; do
        if [ ! -e "${path}/${sysfs}" ]; then
          missing_sysfs_entry=1
        fi
      done

      if [ "${missing_sysfs_entry}" -eq 0 ]; then
        echo "${path}"
        return 0
      fi
    fi
  done
  return 1
}

find_i2c_hid_device() {
  local dev=""
  local path=""
  local vid="${1%_*}"
  local pid="${1#*_}"

  for dev in "${I2C_DEVICES_PATH}"/*/; do
    local driver_name="$(readlink -f ${dev}/driver | xargs basename)"
    if [ "i2c_hid" = "${driver_name}" ]; then
      local hid_path=$(echo ${dev}/*:${vid}:${pid}.*)
      if [ -d "${hid_path}" ]; then
        local hidraw_sysfs_path=$(echo ${hid_path}/hidraw/hidraw*)
        path="/dev/${hidraw_sysfs_path##*/}"
        break
      fi
    fi
  done
  echo "${path}"
}

find_fw_link_path() {
  # Given one or two (second is optional) hardware versions (or product ID
  # depending on the device) determine which fw symlink in /lib/firmware
  # it should try to load. This function shall try in this order:
  # <fw_link_name>_<hw_ver1>.<extension>
  # <fw_link_name>_<hw_ver2>.<extension>
  # <fw_link_name>.<extension>
  local fw_link_name="$1"
  local hw_ver1="$2"
  local hw_ver2="$3"
  local specific_fw_link_path=""
  local specific_fw_link_path2=""
  local generic_fw_link_path=""
  local fw_link_name_extension="`expr "$fw_link_name" : ".*\(\..*\)"`"
  local fw_link_name_base="${fw_link_name%$fw_link_name_extension}"

  case ${fw_link_name_base} in
  /*) fw_link_path="${fw_link_name_base}" ;;
  *)  fw_link_path="/lib/firmware/${fw_link_name_base}" ;;
  esac

  specific_fw_link_path="${fw_link_path}_${hw_ver1}${fw_link_name_extension}"
  specific_fw_link_path2="${fw_link_path}_${hw_ver2}${fw_link_name_extension}"
  generic_fw_link_path="${fw_link_path}${fw_link_name_extension}"

  if [ -e "${specific_fw_link_path}" ]; then
    echo "${specific_fw_link_path}"
  elif [ -n "${hw_ver2}" ] && [ -e "${specific_fw_link_path2}" ]; then
    echo "${specific_fw_link_path2}"
  else
    echo "${generic_fw_link_path}"
  fi
}

standard_update_firmware() {
  # Update a touch device by piping a "1" into a sysfs entry called update_fw
  # This is a common method for triggering a FW update, and it used by several
  # different touch vendors.
  local touch_device_path="$1"
  local i=""
  local ret=""

  for i in $(seq 5); do
    printf 1 > "${touch_device_path}/update_fw"
    ret=$?
    if [ ${ret} -eq 0 ]; then
      return 0
    fi
    log_msg "update_firmware try #${i} failed... retrying."
  done
  die "Error updating touch firmware. ${ret}"
}

get_active_firmware_version_from_sysfs() {
  local sysfs_name="$1"
  local touch_device_path="$2"
  local fw_version_sysfs_path="${touch_device_path}/${sysfs_name}"

  if [ -e "${fw_version_sysfs_path}" ]; then
    cat "${fw_version_sysfs_path}"
  else
    die "No firmware version sysfs at ${fw_version_sysfs_path}."
  fi
}

rebind_driver() {
  # Unbind and then bind the driver for this touchpad incase the recent FW
  # update changed the way it talks to the OS.
  local touch_device_path="$1"
  local bus_id="$(basename ${touch_device_path})"
  local driver_path="$(readlink -f ${touch_device_path}/driver)"

  log_msg "Attempting to re-bind '${bus_id}' to driver '${driver_path}'"
  echo "${bus_id}" > "${driver_path}/unbind"
  if [ "$?" -ne "0" ]; then
    log_msg "Unable to unbind."
  else
    echo "${bus_id}" > "${driver_path}/bind"
    if [ "$?" -ne "0" ]; then
      log_msg "Unable to bind the device back to the driver."
      return 1
    else
      log_msg "Success."
      return 0
    fi
  fi
}

hex_to_decimal() {
  printf "%d" "0x""$1"
}

log_msg() {
  local script_filename="$(basename $0)"
  logger -t "${script_filename%.*}[${PPID}]-${FLAGS_device}" "$@"
  echo "$@"
}

die() {
  log_msg "error: $*"
  exit 1
}


# These flags can be used as "update types" to indicate updater state
UPDATE_NEEDED_OUT_OF_DATE="1"
UPDATE_NEEDED_RECOVERY="2"
UPDATE_NOT_NEEDED_UP_TO_DATE="3"
UPDATE_NOT_NEEDED_AHEAD_OF_DATE="4"

log_update_type() {
  # Given the update type, print a corresponding message into the logs.
  local update_type="$1"
  if [ "${update_type}" -eq "${UPDATE_NEEDED_OUT_OF_DATE}" ]; then
    log_msg "Update needed, firmware out of date."
  elif [ "${update_type}" -eq "${UPDATE_NEEDED_RECOVERY}" ]; then
    log_msg "Recovery firmware update. Rolling back."
  elif [ "${update_type}" -eq "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
    log_msg "Firmware up to date."
  elif [ "${update_type}" -eq "${UPDATE_NOT_NEEDED_AHEAD_OF_DATE}" ]; then
    log_msg "Active firmware is ahead of updater, no update needed."
  else
    log_msg "Unknow update type '${update_type}'."
  fi
}

is_update_needed() {
  # Given an update type, this function returns a boolean indicating if the
  # updater should trigger an update at all.
  local update_type="$1"
  if [ "${update_type}" -eq "${UPDATE_NEEDED_OUT_OF_DATE}" ] ||
     [ "${update_type}" -eq "${UPDATE_NEEDED_RECOVERY}" ]; then
    echo ${FLAGS_TRUE}
  else
    echo ${FLAGS_FALSE}
  fi
}

compare_multipart_version() {
  # Compare firmware versions that are of the form A.B...Y.Z
  # The numbers must all be devimal integers for this to work, so
  # do your conversions before calling the function.
  # To call this function interleave the two version strings by
  # importance, starting with the active FW version.
  # eg: If your active version is A.B.C and the fw updater is X.Y.Z
  #     you should call compare_multipart_version A X B Y C Z
  local update_type=""
  local num_parts="$(($# / 2))"

  # Starting with the most significant values, compare them one
  # by one until we find a difference or run out of values.
  for i in `seq "$num_parts"`; do
    local active_component="$1"
    local updater_component="$2"
    if [ -z "${update_type}" ]; then
      if [ "${active_component}" -lt "${updater_component}" ]; then
        update_type="${UPDATE_NEEDED_OUT_OF_DATE}"
      elif [ "${active_component}" -gt "${updater_component}" ]; then
        update_type="${UPDATE_NOT_NEEDED_AHEAD_OF_DATE}"
      fi
    fi
    shift
    shift
  done

  if [ -z "${update_type}" ]; then
    update_type="${UPDATE_NOT_NEEDED_UP_TO_DATE}"
  elif [ "${FLAGS_recovery}" -eq "${FLAGS_TRUE}" ] &&
       [ "${update_type}" = "${UPDATE_NOT_NEEDED_AHEAD_OF_DATE}" ]; then
    update_type="${UPDATE_NEEDED_RECOVERY}"
  fi

  echo "${update_type}"
}

get_chassis_id() {
  # Get an identifier of chassis that may need different touchpad firmware on
  # devices sharing same image, even same main logic board.
  mosys platform chassis
}

get_platform_ver() {
  # Get platform version, since different boards (EVT, DVT etc) may need
  # different touchpad firmware on devices sharing same image.
  local version="$(mosys platform version)"
  echo "${version#rev}"
}

i2c_chardev_present() {
  # This function tests to see if there are any i2c char devices on the system.
  # It returns 0 iff /dev/i2c-* matches at least one file.
  local f=""
  for f in /dev/i2c-*; do
    if [ -e "${f}" ]; then
      return 0
    fi
  done
  return 1
}

check_i2c_chardev_driver() {
  # Check to make sure the required drivers are already availible.
  if ! i2c_chardev_present; then
    modprobe i2c-dev
    log_msg "Please compile I2C_CHARDEV into the kernel"
    log_msg "Sleeping 15s to wait for them to show up"

    # Without this the added delay is small enough that a human might not
    # notice that they had just slowed down the boot time by removing the
    # driver from the kernel.
    sleep 15
  fi
}
