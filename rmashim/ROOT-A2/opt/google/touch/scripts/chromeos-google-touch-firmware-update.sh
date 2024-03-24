#!/bin/sh

# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device_path' '' "device path" 'p'

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

FW_LINK="/lib/firmware/google_touchpad.bin"

# Sysfs entry created by cros_ec driver.
CROS_TP_SYSFS="/sys/class/chromeos/cros_tp"

# Flashrom programmer argument, we are type "tp"
PROGRAMMER="ec:type=tp"

extract_numerical_fw_version() {
  # FW version string has the following format:
  # rose_v1.1.6371-3fc259f2c
  # This function extract the "numerical" part, which is "1.1.6371"
  echo $1 | sed -n "s/^.*_v\(.*\)-.*$/\1/p"
}

get_minor_version() {
  local major_minor=${1%.*}
  echo ${major_minor#*.}
}

compare_fw_versions() {
  # FW version string has the following format:
  # rose_v1.1.6371-3fc259f2c
  # We only need to compare the numeric part of the version string.
  local active_fw_ver_raw="$1"
  local updater_fw_ver_raw="$2"
  local active_fw_ver="$(extract_numerical_fw_version "${active_fw_ver_raw}")"
  local updater_fw_ver="$(extract_numerical_fw_version "${updater_fw_ver_raw}")"

  local active_fw_ver_major="${active_fw_ver%%.*}"
  local active_fw_ver_minor="$(get_minor_version "${active_fw_ver}")"
  local active_fw_ver_revision="${active_fw_ver##*.}"

  local updater_fw_ver_major="${updater_fw_ver%%.*}"
  local updater_fw_ver_minor="$(get_minor_version "${updater_fw_ver}")"
  local updater_fw_ver_revision="${updater_fw_ver##*.}"

  compare_multipart_version "${active_fw_ver_major}" "${updater_fw_ver_major}" \
                            "${active_fw_ver_minor}" "${updater_fw_ver_minor}" \
                            "${active_fw_ver_revision}" "${updater_fw_ver_revision}"
}

get_fw_version_from_disk() {
  # The on-disk FW version is determined by reading the filename which
  # is in the format "FWVERSION.hex" where the fw version is a hex
  # number preceeded by 0x and using lower case letters. We follow the fw's
  # link to the actual file then strip away everything in the FW's filename
  # but the FW version.
  local fw_link="$1"
  local fw_filepath=""
  local fw_filename=""
  local fw_ver=""

  if [ ! -L "${fw_link}" ]; then
    return
  fi
  fw_filepath="$(readlink -f "${fw_link}")"
  if [ ! -e "${fw_filepath}" ]; then
    return
  fi

  fw_filename="$(basename "${fw_filepath}")"
  fw_ver="${fw_filename%.*}"
  echo "${fw_ver}"
}

real_get_active_fw_version() {
  local fw_copy=$(cat "${CROS_TP_SYSFS}"/version | awk 'NR==3 { print $3 }')

  # If TP firmware is still in RO, wait 1 second for it to jump to RW.
  if [ "${fw_copy}" = "RO" ]; then
    sleep 1
    fw_copy=$(cat "${CROS_TP_SYSFS}"/version | awk 'NR==3 { print $3 }')
  fi

  cat "${CROS_TP_SYSFS}"/version | grep ${fw_copy} | awk 'NR==1 { print $3 }'
}

get_active_fw_version() {
  local active_fw_ver
  # If we check the touchpad during RWSIG jump, we may get an empty version
  # number. In this case, retry after 1 seconds and we should get the correct
  # version number.
  for i in $(seq 0 10); do
    active_fw_ver="$(real_get_active_fw_version)"
    if [ -n "${active_fw_ver}" ]; then
      echo ${active_fw_ver}
      return
    fi
    sleep 1
  done
}

display_splash() {
  chromeos-boot-alert update_touchpad_firmware
}

# TODO(wnhuang): remove these once we have RO-WP enabled.
force_flash() {
  display_splash

  st_flash --board=eve "${FW_LINK}"

  if [ "$?" -ne "0" ]; then
    die "Unable to flash new touchpad firmware, abort."
  fi

  # We need a reboot so the cros_ec kernel driver get reloaded. This should
  # only happen once when device is transiting from old firmware to EC
  # firmware.
  log_msg "========================== WARNING =========================="
  log_msg "Reboot to reload touchpad driver, this will only happen once."
  log_msg "============================================================="
  reboot
  exit 0  # Reboot is not a blocking call, so we need to explicity exit.
}

# Eve TP firmware version before 6627 has issue which may cause flashrom to
# fail (see b/38018926). If detct firmware version < 6627, force an update with
# st_flash.
check_for_force_update() {
  local active_fw_ver_raw="$(cat "${CROS_TP_SYSFS}"/version | \
                             awk 'NR==1 { print $3 }')"
  local active_fw_ver="$(extract_numerical_fw_version "${active_fw_ver_raw}")"
  local active_fw_ver_revision="${active_fw_ver##*.}"

  if [ "${active_fw_ver_revision}" -lt "6627" ]; then
    log_msg "Detected firmware with issue, force reflashing touchpad firmware."
    force_flash
  fi
}

main() {
  local ret

  # Active firmware version (RW version)
  local active_fw_ver="$(get_active_fw_version)"
  local updater_fw_ver="$(get_fw_version_from_disk "${FW_LINK}")"
  log_msg "Current active fw version is: '${active_fw_ver}'"
  log_msg "Current updater fw version is: '${updater_fw_ver}'"
  if [ -z "${active_fw_ver}" ]; then
    die "Unable to detect the active FW version."
  fi
  if [ -z "${updater_fw_ver}" ]; then
    die "Unable to detect the updater's FW version on disk."
  fi

  check_for_force_update

  update_type="$(compare_fw_versions "${active_fw_ver}" "${updater_fw_ver}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${updater_fw_ver}"

    display_splash

    # Determine if WP is enabled
    local extra_flashrom_arg=""
    local wp_status="$(flashrom -p "${PROGRAMMER}" --wp-status | \
                       sed -n 's/WP: status: \(.*\)/\1/p' 2>/dev/null)"

    # Only update RW section if WP is enabled
    if [ "${wp_status}" != "0x00" ]; then
      extra_flashrom_arg="-i EC_RW"
    fi

    # Run the actual firmware update
    flashrom -p "${PROGRAMMER}" ${extra_flashrom_arg} -w "${FW_LINK}"

    # Check if update was successful
    active_fw_ver="$(get_active_fw_version)"
    update_type="$(compare_fw_versions "${active_fw_ver}" "${updater_fw_ver}")"
    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_ver}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_ver}"

    rebind_driver "${FLAGS_device_path}"
    if [ "$?" -ne "0" ]; then
      log_msg "Driver rebind failed, doing a reboot to reload driver."
      reboot
      exit 0
    fi
  else
    # Force rebind driver to reload RW HID descriptor
    rebind_driver "${FLAGS_device_path}"
  fi
}

main "$@"
