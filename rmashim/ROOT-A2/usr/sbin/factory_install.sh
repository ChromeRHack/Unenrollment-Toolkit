#!/bin/bash

# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -e
umask 022

# Dump bash trace to default log file.
: "${LOG_FILE:=/var/log/factory_install.log}"
: "${LOG_TTY:=}"
if [ -n "${LOG_FILE}" ]; then
  mkdir -p "$(dirname "${LOG_FILE}")"
  # shellcheck disable=SC2093 disable=SC1083
  exec {LOG_FD}>>"${LOG_FILE}"
  export BASH_XTRACEFD="${LOG_FD}"
fi

. "/usr/share/misc/storage-info-common.sh"
# Include after other common include, side effect on GPT variable.
. "/usr/sbin/write_gpt.sh"
. "$(dirname "$0")/factory_common.sh"

normalize_server_url() {
  local removed_protocol="${1#http://}"
  local removed_path="${removed_protocol%%/*}"
  echo "http://${removed_path}"
}

# Patch dev_image/etc/lsb-factory using lsb_factory payload.
patch_lsb_factory() {
  local real_usb_dev="$(findLSBValue REAL_USB_DEV)"
  [ -n "${real_usb_dev}" ] || return
  local stateful_dev=${real_usb_dev%[0-9]*}1
  local mount_point="$(mktemp -d)"
  local board="$(findLSBValue CHROMEOS_RELEASE_BOARD)"
  local json_path="${mount_point}/cros_payloads/${board}.json"
  local temp_lsb_factory="$(mktemp)"

  echo 'Patching lsb-factory...'

  mount -o ro "${stateful_dev}" "${mount_point}"
  # If the RMA shim doesn't have lsb_factory payload, this command will fail,
  # leaving temp_lsb_factory empty.
  cros_payload install "${json_path}" "${temp_lsb_factory}" lsb_factory || true
  umount "${stateful_dev}"
  rmdir "${mount_point}"

  # Append to lsb-factory file.
  cat "${temp_lsb_factory}" >>"${LSB_FACTORY_FILE}"
  rm "${temp_lsb_factory}"
}

patch_lsb_factory

# Variables from dev_image/etc/lsb-factory that developers may want to override.
#
# - Override this if we want to install with a board different from installer
BOARD="$(findLSBValue CHROMEOS_RELEASE_BOARD)"
# - Override this if we want to install with a different factory server.
OMAHA="$(normalize_server_url "$(findLSBValue CHROMEOS_AUSERVER)")"
# - Override this for The default action if no keys were pressed before timeout.
DEFAULT_ACTION="$(findLSBValue FACTORY_INSTALL_DEFAULT_ACTION)"

# Variables prepared by image_tool or netboot initramfs code.
NETBOOT_RAMFS="$(findLSBValue NETBOOT_RAMFS)"
FACTORY_INSTALL_FROM_USB="$(findLSBValue FACTORY_INSTALL_FROM_USB)"
RMA_AUTORUN="$(findLSBValue RMA_AUTORUN)"

# Global variables
DST_DRIVE=""
EC_PRESENT=0
DEVSW_PRESENT=1
COMPLETE_SCRIPT=""

# The ethernet interface to be used. It will be determined in
# check_ethernet_status and be passed to cros_payload_get_server_json_path as an
# environment variable.
ETH_INTERFACE=""

# Definition of ChromeOS partition layout
DST_FACTORY_KERNEL_PART=2
DST_FACTORY_PART=3
DST_RELEASE_KERNEL_PART=4
DST_STATE_PART=1

# Supported actions (a set of lowercase characters)
# Each action x is implemented in an action_$x handler (e.g.,
# action_i); see the handlers for more information about what
# each option is.
SUPPORTED_ACTIONS=cdefimrstuvyz

GSCTOOL="gsctool"
PROD_CR50_PATH="opt/google/cr50/firmware/cr50.bin.prod"

# Define our own logging function.
log() {
  echo "$*"
}

# Change color by ANSI escape sequence code
colorize() {
  set +x
  local code="$1"
  case "${code}" in
    "red" )
      code="1;31"
      ;;
    "green" )
      code="1;32"
      ;;
    "yellow" )
      code="1;33"
      ;;
    "white" )
      code="0;37"
      ;;
    "boldwhite" )
      code="1;37"
      ;;
  esac
  printf "\033[%sm" "${code}"
  set -x
}

# Checks if 'cros_debug' is enabled.
is_allow_debug() {
  grep -qw "cros_debug" /proc/cmdline
}

# Checks if the system has been boot by Ctrl-U.
is_dev_firmware() {
  crossystem "mainfw_type?developer" 2>/dev/null
}

explain_cros_debug() {
  log "To debug with a shell, boot factory shim in developer firmware (Ctrl-U)
   or add 'cros_debug' to your kernel command line:
    - Factory shim: Add cros_debug into --boot_args or make_dev_ssd
    - Netboot: Change kernel command line config file on TFTP."
}

# Error message for any unexpected error.
on_die() {
  set +x
  kill_bg_jobs
  colorize red
  echo
  log "ERROR: Factory installation has been stopped."
  if [ -n "${LOG_TTY}" ]; then
    local tty_num="${LOG_TTY##*[^0-9]}"
    log "See ${LOG_TTY} (Ctrl-Alt-F${tty_num}) for detailed information."
    log "(The F${tty_num} key is ${tty_num} keys to the right of 'esc' key.)"
  else
    log "See ${LOG_FILE} for detailed information."
  fi

  # Open a terminal if the kernel command line allows debugging.
  if is_allow_debug; then
    while true; do sh; done
  else
    explain_cros_debug
  fi

  exit 1
}

kill_bg_jobs() {
  local pids=$(jobs -p)
  # Disown all background jobs to avoid terminated messages
  disown -a
  # Kill the jobs
  echo "${pids}" | xargs -r kill -9 2>/dev/null || true
}

exit_success() {
  trap - EXIT
  kill_bg_jobs
  exit 0
}

trap on_die EXIT

die() {
  set +x
  colorize red
  set +x
  log "ERROR: $*"
  kill_bg_jobs
  exit 1
}

copy_prod_cr50_firmware() {
  # Create a copy of prod cr50 firmware in rootfs to a temporary file.
  # The caller is responsible for deleting the temp file.
  local real_usb_dev="$(findLSBValue REAL_USB_DEV)"
  [ -n "${real_usb_dev}" ] ||
    die "Unknown media source. Please define REAL_USB_DEV."
  local rootfs_dev=${real_usb_dev%[0-9]*}3
  local mount_point="$(mktemp -d)"
  local firmware_path="${mount_point}/${PROD_CR50_PATH}"
  local temp_firmware="$(mktemp)"

  mount -o ro "${rootfs_dev}" "${mount_point}"
  cp "${firmware_path}" "${temp_firmware}"
  umount "${rootfs_dev}"
  rmdir "${mount_point}"

  echo "${temp_firmware}"
}

get_cr50_rw_version() {
  ${GSCTOOL} -a -f | grep '^RW' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+'
}

get_cr50_image_rw_version() {
  local image="$1"
  ${GSCTOOL} -b "$image" | grep -oE 'RW_A:[0-9]+\.[0-9]+\.[0-9]+' | cut -c6-
}

check_need_update_cr50() {
  local temp_firmware="$(copy_prod_cr50_firmware)"
  local image_version="$(get_cr50_image_rw_version "${temp_firmware}")"
  local image_version_major=$(echo "${image_version}" | cut -d '.' -f 2)
  local image_version_minor=$(echo "${image_version}" | cut -d '.' -f 3)
  rm "${temp_firmware}"

  local device_version="$(get_cr50_rw_version)"
  local device_version_major=$(echo "${device_version}" | cut -d '.' -f 2)
  local device_version_minor=$(echo "${device_version}" | cut -d '.' -f 3)

  # Update only if the cr50 in install shim has version 0.3.*
  if ! [ "${image_version_major}" -eq "3" ]; then
    return 1
  fi

  # Update only if cr50 version on the device is smaller than the cr50 version
  # in install shim. Some older devices may have cr50 version 0.0.*, 0.1.* or
  # 0.2.*, and we also update these devices to 0.3.*.
  # See go/cr50-release-notes for more information.
  if [ "${device_version_major}" -ne "${image_version_major}" ]; then
    [ "${device_version_major}" -lt "${image_version_major}" ]
  else
    [ "${device_version_minor}" -lt "${image_version_minor}" ]
  fi
}

is_cr50_factory_mode_enabled() {
  # If the cr50 RW version is 0.0.*, the device is booted to install shim
  # straight from factory. The cr50 firmware does not support '-I' option and
  # factory mode, so we treat it as factory mode enabled to avoid turning on
  # factory mode.
  local rw_version="$(get_cr50_rw_version)"
  if [[ "${rw_version}" = '0.0.'* ]]; then
    echo "Cr50 version is ${rw_version}. Assume factory mode enabled."
    return 0
  fi
  # The pattern of output is:
  # State: Locked
  # Password: None
  # Flags: 000000
  # Capabilities, current and default:
  # ...
  # CCD caps bitmap: 0x1ffff
  #
  # TODO(b/117200472) The current way to query factory mode is done by checking
  # CCD caps bitmap but this value will be changed if new CCD capability is
  # introduced. For example, bitpmap becomes 0x7ffff started from 0.4.10. The
  # long term plan is to ask gsctool/cr50 to report factory mode status directly
  # ; for short term plan 0x?ffff would be checked.
  ${GSCTOOL} -a -I 2>/dev/null | \
    grep '^CCD caps bitmap: 0x[0-9a-z]ffff$' >/dev/null
  return $?
}

enable_cr50_factory_mode() {
  if crossystem 'wpsw_cur?1' 2>/dev/null; then
    die "The hardware write protection should be disabled first."
  fi

  log "Starting to enable factory mode and will reboot automatically."
  ret=0
  ${GSCTOOL} -a -F enable 2>&1 || ret=$?

  if [ ${ret} != 0 ]; then
    ver=$(${GSCTOOL} -a -f)
    die "Failed to enable factory mode; cr50 version:
      ${ver}"
  fi

  # Once enabling factory mode, system should reboot automatically.
  log "Successfully to enable factory mode and should reboot soon."
  # sleep indefinitely to avoid re-spawning rather than reboot.
  sleep 1d
}

is_pvt_phase() {
  # If there is any error then pvt phase is returned as a safer default
  # option.
  output=$(${GSCTOOL} -a -i 2>&1) || return 0

  board_id="$(echo "${output}" | awk '/Board ID/ {gsub(/.*: /,""); print}')"
  board_flags="0x$(echo "${board_id}" | sed 's/.*://')"

  # If board phase is not 0x0 then this is a development board.
  pre_pvt=$(( board_flags & 0x7F ))
  if (( pre_pvt > 0 )); then
    return ${pre_pvt}
  fi

  return 0
}

config_tty() {
  stty opost

  # Turn off VESA blanking
  setterm -blank 0 -powersave off -powerdown 0
}

clear_fwwp() {
  log "Firmware Write Protect disabled, clearing status registers."
  if [ ${EC_PRESENT} -eq 1 ]; then
    flashrom -p ec --wp-disable
  fi
  flashrom -p host --wp-disable
  log "WP registers should be cleared now"
}

ensure_fwwp_consistency() {
  local ec_wp main_wp

  if [ ${EC_PRESENT} -eq 0 ]; then
    return
  fi

  ec_wp="$(flashrom -p ec --wp-status 2>/dev/null)" || return
  main_wp="$(flashrom -p host --wp-status 2>/dev/null)"
  ec_wp="$(echo "${ec_wp}" | sed -nr 's/WP.*(disabled|enabled).$/\1/pg')"
  main_wp="$(echo "${main_wp}" | sed -nr 's/WP.*(disabled|enabled).$/\1/pg')"
  if [ "${ec_wp}" != "${main_wp}" ]; then
    die "Inconsistent firmware write protection status: " \
        "main=${main_wp}, ec=${ec_wp}." \
        "Please disable Hardware Write Protection and restart again."
  fi
}

# Checks if firmware software write protection is enabled.
# Args
#   target: a "flashrom -p" descriptor. Defaults to "host".
check_fw_swwp() {
  local target="${1:-host}"
  # Note "crossystem sw_wpsw_boot" only works on Baytrail systems, so we have to
  # use flashrom for better compatibility.
  flashrom -p "${target}" --wp-status 2>/dev/null |
    grep -q "write protect is enabled"
}

set_time() {
  log "Setting time from:"
  # Extract only the server and port.
  local time_server_port="${OMAHA#http://}"

  log " Server ${time_server_port}."
  local result="$(htpdate -s -t "${time_server_port}" 2>&1)"
  if ! echo "${result}" | grep -Eq "(failed|unavailable)"; then
    log "Success, time set to $(date)"
    hwclock -w 2>/dev/null
    return 0
  fi

  log "Failed to set time: $(echo "${result}" | grep -E "(failed|unavailable)")"
  return 1
}

check_ethernet_status() {
  local link i
  local result=1
  link=$(ip -f link addr | sed 'N;s/\n/ /' | grep -w 'ether' |
    cut -d ' ' -f 2 | sed 's/://')
  for i in ${link}; do
    if ip -f inet addr show "${i}" | grep -q inet; then
      if ! iw "${i}" info >/dev/null 2>&1; then
        log "$(ip -f inet addr show "${i}" | grep inet)"
        ETH_INTERFACE=${i}
        result=0
      fi
    fi
  done
  return ${result}
}

clear_block_devmode() {
  # Try our best to clear block_devmode.
  crossystem block_devmode=0 || true
  vpd -i RW_VPD -d block_devmode -d check_enrollment || true
}

reset_chromeos_device() {
  log "Clearing NVData."
  if ! mosys nvram clear; then
    # Not every platforms really need this - OK if nvram is not cleared.
    log "Warning: NVData not cleared."
  fi

  clear_block_devmode

  if grep -q cros_netboot /proc/cmdline; then
    log "Device is network booted."
    return
  fi

  if crossystem "mainfw_type?nonchrome"; then
    # Non-ChromeOS firmware devices can stop now.
    log "Device running Non-ChromeOS firmware."
    return
  fi

  log "Request to clear TPM owner at next boot."
  # No matter if whole TPM (see below) is cleared or not, we always
  # want to clear TPM ownership (safe and easy) so factory test program and
  # release image won't start with unknown ownership.
  crossystem clear_tpm_owner_request=1 || true

  log "Checking if TPM should be recovered (for version and owner)"
  # To clear TPM, we need it unlocked (only in recovery boot).
  # Booting with USB in developer mode (Ctrl-U) does not work.
  if crossystem "mainfw_type?recovery"; then
    if ! chromeos-tpm-recovery; then
      colorize yellow
      log " - TPM recovery failed.

      This is usually not a problem for devices on manufacturing line,
      but if you are using factory shim to reset TPM (for antirollback issue),
      there's something wrong.
      "
      sleep 3
    else
      log "TPM recovered."
    fi
  else
    mainfw_type="$(crossystem mainfw_type)"
    colorize yellow
    log " - System was not booted in recovery mode (current: ${mainfw_type}).

    WARNING: TPM won't be cleared. To enforce clearing TPM, make sure you are
    using correct image signed with same key (MP, Pre-MP, or DEV), turn on
    developer switch if you haven't, then hold recovery button and reboot the
    system again.  Ctrl-U won't clear TPM.
    "
    # Alert for a while
    sleep 3
  fi
}

get_dst_drive() {
  load_base_vars
  DST_DRIVE="$(get_fixed_dst_drive)"
  if [ -z "${DST_DRIVE}" ]; then
    die "Cannot find fixed drive."
  fi
}

lightup_screen() {
  # Always backlight on factory install shim.
  ectool forcelidopen 1 || true
  # Light up screen in case you can't see our splash image.
  backlight_tool --set_brightness_percent=100 || true
}

load_modules() {
  # Required kernel modules might not be loaded. Load them now.
  modprobe i2c-dev || true
}

prepare_disk() {
  log "Factory Install: Setting partition table"

  local pmbr_code="/root/.pmbr_code"
  [ -r ${pmbr_code} ] || die "Missing ${pmbr_code}; please rebuild image."

  write_base_table "${DST_DRIVE}" "${pmbr_code}" 2>&1
  reload_partitions "${DST_DRIVE}"

  log "Done preparing disk"
}

ufs_init() {
  local ufs_init_file="/usr/sbin/factory_ufs_init.sh"
  if [ -x "${ufs_init_file}" ]; then
    ${ufs_init_file}
  fi
}

select_board() {
  # Prompt the user if USER_SELECT is true.
  local user_select="$(findLSBValue USER_SELECT | tr '[:upper:]' '[:lower:]')"
  if [ "${user_select}" = "true" ]; then
    echo -n "Enter the board you want to install (ex: x86-mario): "
    read BOARD
  fi
}

find_var() {
  # Check kernel commandline for a specific key value pair.
  # Usage: omaha=$(find_var omahaserver)
  # Assume values are space separated, keys are unique within the commandline,
  # and that keys and values do not contain spaces.
  local key="$1"

  # shellcheck disable=SC2013
  for item in $(cat /proc/cmdline); do
    if echo "${item}" | grep -q "${key}"; then
      echo "${item}" | cut -d'=' -f2
      return 0
    fi
  done
  return 1
}

override_from_firmware() {
  # Check for Omaha URL or Board type from kernel commandline.
  local omaha=""
  if omaha="$(find_var omahaserver)"; then
    OMAHA="$(normalize_server_url "${omaha}")"
    log " Kernel cmdline OMAHA override to ${OMAHA}"
  fi

  local board=""
  if board="$(find_var cros_board)"; then
    log " Kernel cmdline BOARD override to ${board}"
    BOARD="${board}"
  fi
}

override_from_board() {
  # Call into any board specific configuration settings we may need.
  # The file should be installed in factory-board/files/installer/usr/sbin/.
  local lastboard="${BOARD}"
  local board_customize_file="/usr/sbin/factory_install_board.sh"
  if [ -f "${board_customize_file}" ]; then
    . "${board_customize_file}"
  fi

  # Let's notice if BOARD has changed and print a message.
  if [ "${lastboard}" != "${BOARD}" ]; then
    colorize red
    log " Private overlay customization BOARD override to ${BOARD}"
    sleep 1
  fi
}

override_from_tftp() {
  # Check for Omaha URL from tftp server.
  local tftp=""
  local omahaserver_config="omahaserver.conf"
  local tftp_output=""
  # Use board specific config if ${BOARD} is not null.
  [ -z "${BOARD}" ] || omahaserver_config="omahaserver_${BOARD}.conf"
  tftp_output="/tmp/${omahaserver_config}"

  if tftp="$(find_var tftpserverip)"; then
    log "override_from_tftp: kernel cmdline tftpserverip ${tftp}"
    # Get omahaserver_config from tftp server.
    # Use busybox tftp command with options: "-g: Get file",
    # "-r FILE: Remote FILE" and "-l FILE: local FILE".
    rm -rf "${tftp_output}"
    tftp -g -r "${omahaserver_config}" -l "${tftp_output}" "${tftp}" || true
    if [ -f "${tftp_output}" ]; then
      OMAHA="$(normalize_server_url "$(cat "${tftp_output}")")"
      log "override_from_tftp: OMAHA override to ${OMAHA}"
    fi
  fi
}

overrides() {
  override_from_firmware
  override_from_board
}

disable_release_partition() {
  # Release image is not allowed to boot unless the factory test is passed
  # otherwise the wipe and final verification can be skipped.
  if ! cgpt add -i "${DST_RELEASE_KERNEL_PART}" -P 0 -T 0 -S 0 "${DST_DRIVE}"
  then
    # Destroy kernels otherwise the system is still bootable.
    dst="$(make_partition_dev "${DST_DRIVE}" "${DST_RELEASE_KERNEL_PART}")"
    dd if=/dev/zero of="${dst}" bs=1M count=1
    dst="$(make_partition_dev "${DST_DRIVE}" "${DST_FACTORY_KERNEL_PART}")"
    dd if=/dev/zero of="${dst}" bs=1M count=1
    die "Failed to lock release image. Destroy all kernels."
  fi
  # cgpt changed partition table, so we have to make sure it's notified.
  reload_partitions "${DST_DRIVE}"
}

run_postinst() {
  local install_dev="$1"
  local mount_point="$(mktemp -d)"
  local result=0

  mount -t ext2 -o ro "${install_dev}" "${mount_point}"
  IS_FACTORY_INSTALL=1 "${mount_point}"/postinst \
    "${install_dev}" 2>&1 || result="$?"

  umount "${install_dev}" || true
  rmdir "${mount_point}" || true
  return ${result}
}

stateful_postinst() {
  local stateful_dev="$1"
  local mount_point="$(mktemp -d)"

  mount "${stateful_dev}" "${mount_point}"
  mkdir -p "$(dirname "${output_file}")"

  # Update lsb-factory on stateful partition.
  local lsb_factory="${mount_point}/dev_image/etc/lsb-factory"
  if [ -z "${FACTORY_INSTALL_FROM_USB}" ]; then
    log "Save active factory server URL to stateful partition lsb-factory."
    echo "FACTORY_OMAHA_URL=${OMAHA}" >>"${lsb_factory}"
  else
    log "Clone lsb-factory to stateful partition."
    cat "${LSB_FACTORY_FILE}" >>"${lsb_factory}"
  fi

  umount "${mount_point}" || true
  rmdir "${mount_point}" || true
}

omaha_greetings() {
  if [ -n "${FACTORY_INSTALL_FROM_USB}" ]; then
    return
  fi

  local message="$1"
  local uuid="$2"
  curl "${OMAHA}/greetings/${message}/${uuid}" >/dev/null 2>&1 || true
}

factory_on_complete() {
  if [ ! -s "${COMPLETE_SCRIPT}" ]; then
    return 0
  fi

  log "Executing completion script... (${COMPLETE_SCRIPT})"
  if ! sh "${COMPLETE_SCRIPT}" "${DST_DRIVE}" 2>&1; then
    die "Failed running completion script ${COMPLETE_SCRIPT}."
  fi
  log "Completion script executed successfully."
}

disable_dev_switch() {
  # Turn off developer mode on devices without physical developer switch.
  if [ ${DEVSW_PRESENT} -eq 0 ]; then
    crossystem disable_dev_request=1
  # When physical switch exists, force user to turn it off.
  elif [ ${DEVSW_PRESENT} -eq 1 -a "$(crossystem devsw_cur)" = "1" ]; then
    while [ "$(crossystem devsw_cur)" = "1" ]; do
      log "Please turn off developer switch to continue"
      sleep 5
    done
  fi
}

factory_reset() {
  # Turn off developer mode on devices without physical developer switch.
  if [ ${DEVSW_PRESENT} -eq 0 ]; then
    crossystem disable_dev_request=1
  fi

  log "Performing factory reset"
  if ! /usr/sbin/factory_reset.sh "${DST_DRIVE}"; then
    die "Factory reset failed."
  fi

  log "Done."
  # TODO(hungte) shutdown or reboot once we decide the default behavior.
  exit_success
}

# Call reset code on the fixed driver.
#
# Assume the global variable DST_DRIVE contains the drive to operate on.
#
# Args:
#   action: describe how to erase the drive.
#     Allowed actions:
#     - wipe: action Z
#     - secure: action C
#     - verify: action Y
factory_disk_action() {
  local action="$1"
  log "Performing factory disk ${action}"
  if ! /usr/sbin/factory_reset.sh "${DST_DRIVE}" "${action}"; then
    die "Factory disk ${action} failed."
  fi
  log "Done."
  exit_success
}

enlarge_partition() {
  local dev="$1"
  local block_size="$(dumpe2fs -h "${dev}" | sed -n 's/Block size: *//p')"
  local minimal="$(resize2fs -P "${dev}" | sed -n 's/Estimated .*: //p')"

  # Try to allocate 1G if possible.
  if [ "${minimal}" -gt 0 ] && [ "${block_size}" -gt 0 ]; then
    e2fsck -f -y "${dev}"
    resize2fs "${dev}" "$((minimal + (1024 * 1048576 / block_size)))" || true
  fi
}

reload_partitions() {
  # Some devices, for example NVMe, may need extra time to update block device
  # files via udev. We should do sync, partprobe, and then wait until partition
  # device files appear again.
  local drive="$1"
  log "Reloading partition table changes..."
  sync

  # Reference: src/platform2/installer/chromeos-install#reload_partitions
  udevadm settle || true  # Netboot environment may not have udev.
  blockdev --rereadpt "${drive}"
}

cros_payload_get_server_json_path() {
  local server_url="$1"
  local eth_interface="$2"

  # Try to get resource map from Umpire.
  local sn="$(vpd -i RO_VPD -g serial_number)" || sn=""
  local mlb_sn="$(vpd -i RO_VPD -g mlb_serial_number)" || mlb_sn=""
  local mac_addr="$(ip link show ${eth_interface} | grep link/ether |
    tr -s ' '| cut -d ' ' -f 3)"
  local resourcemap=""
  local mac="mac.${eth_interface}=${mac_addr};"
  local values="sn=${sn}; mlb_sn=${mlb_sn}; board=${BOARD}; ${mac}"
  local empty_values="firmware=; ec=; stage=;"
  local header="X-Umpire-DUT: ${values} ${empty_values}"
  local target="${server_url}/resourcemap"
  # This is following Factory Server/Umpire protocol.
  echo "Header: ${header}" >&2

  resourcemap="$(curl -f --header "${header}" "${target}")"
  if [ -z "${resourcemap}" ]; then
    echo "Missing /resourcemap - please upgrade Factory Server." >&2
    return 1
  fi
  echo "resourcemap: ${resourcemap}" >&2
  local json_name="$(echo "${resourcemap}" | grep "^payloads: " |
    cut -d ' ' -f 2)"
  if [ -n "${json_name}" ]; then
    echo "res/${json_name}"
  else
    echo "'payloads' not in resourcemap, please upgrade Factory Server." >&2
    return 1
  fi
}

cros_payload_install_optional() {
  local json_url="$1"
  local dest="$2"
  local component="$3"
  local remote="$4"
  local remote_component

  for remote_component in ${remote}; do
    if [ "${remote_component}" = "${component}" ]; then
      cros_payload install "${json_url}" "${dest}" "${component}"
      return
    fi
  done
  log "Optional component ${component} does not exist, ignored."
}

factory_install_cros_payload() {
  local src_media="$1"
  local json_path="$2"
  local src_mount=""
  local tmp_dir="$(mktemp -d)"
  local json_url="${src_media}/${json_path}"

  if [ -b "${src_media}" ]; then
    src_mount="$(mktemp -d)"
    colorize yellow
    mount -o ro "${src_media}" "${src_mount}"
    json_url="${src_mount}/${json_path}"
  fi

  # Generate the uuid for current install session
  local uuid="$(uuidgen 2>/dev/null)" || uuid="Not_Applicable"

  # Say hello to server if available.
  omaha_greetings "hello" "${uuid}"

  cros_payload install "${json_url}" "${DST_DRIVE}" test_image release_image

  # Test image stateful partition may pretty full and we may want more space,
  # before installing toolkit (which may be huge).
  enlarge_partition "$(make_partition_dev "${DST_DRIVE}" "${DST_STATE_PART}")"

  cros_payload install "${json_url}" "${DST_DRIVE}" toolkit

  # Install optional components.
  local remote="$(cros_payload list "${json_url}")"
  cros_payload_install_optional "${json_url}" "${DST_DRIVE}" \
    release_image.crx_cache "${remote}"
  cros_payload_install_optional "${json_url}" "${DST_DRIVE}" hwid "${remote}"
  cros_payload_install_optional "${json_url}" "${tmp_dir}" firmware "${remote}"
  cros_payload_install_optional "${json_url}" "${tmp_dir}" complete "${remote}"

  if [ -n "${src_mount}" ]; then
    umount "${src_mount}"
  fi
  colorize green

  # Notify server that all downloads are completed.
  omaha_greetings "download_complete" "${uuid}"

  # Disable release partition and activate factory partition
  disable_release_partition
  run_postinst "$(make_partition_dev "${DST_DRIVE}" "${DST_FACTORY_PART}")"
  stateful_postinst "$(make_partition_dev "${DST_DRIVE}" "${DST_STATE_PART}")"

  if [ -s "${tmp_dir}/firmware" ]; then
    log "Found firmware updater."
    # TODO(hungte) Check if we need to run --mode=recovery if WP is enabled.
    sh "${tmp_dir}/firmware" --force --mode=factory_install ||
      die "Firmware updating failed."
  fi
  if [ -s "${tmp_dir}/complete" ]; then
    log "Found completion script."
    COMPLETE_SCRIPT="${tmp_dir}/complete"
  fi

  # After post processing, notify server a installation session has been
  # successfully completed.
  omaha_greetings "goodbye" "${uuid}"
}

factory_install_usb() {
  local src_dev="$(findLSBValue REAL_USB_DEV)"
  [ -n "${src_dev}" ] || src_dev="$(rootdev -s 2>/dev/null)"
  [ -n "${src_dev}" ] ||
    die "Unknown media source. Please define REAL_USB_DEV."

  # Switch to stateful partition.
  # shellcheck disable=SC2001
  src_dev="$(echo "${src_dev}" | sed 's/[0-9]\+$/1/')"

  factory_install_cros_payload "${src_dev}" "cros_payloads/${BOARD}.json"
}

factory_install_network() {
  # Register to Overlord if haven't.
  if [ -z "${OVERLORD_READY}" ]; then
    register_to_overlord "${OMAHA}" "${TTY_FILE}" "${LOG_FILE}"
  fi

  # Get path of cros_payload json file from server (Umpire or Mini-Omaha).
  local json_path="$(cros_payload_get_server_json_path \
    "${OMAHA}" "${ETH_INTERFACE}" 2>/dev/null)"
  [ -n "${json_path}" ] || die "Failed to get payload json path from server."
  factory_install_cros_payload "${OMAHA}" "${json_path}"
}

test_ec_flash_presence() {
  # If "flashrom -p ec --get-size" command succeeds (returns 0),
  # then EC flash chip is present in system. Otherwise, assume EC flash is not
  # present or supported.
  if flashrom -p ec --get-size >/dev/null 2>&1; then
    EC_PRESENT=1
  else
    EC_PRESENT=0
  fi
}

test_devsw_presence() {
  local VBSD_HONOR_VIRT_DEV_SWITCH="0x400"
  local vdat_flags="$(crossystem vdat_flags || echo 0)"

  if [ "$((vdat_flags & VBSD_HONOR_VIRT_DEV_SWITCH))" = "0" ]; then
    DEVSW_PRESENT=1
  else
    DEVSW_PRESENT=0
  fi
}

# Echoes "on" or "off" based on the value of a crossystem Boolean flag.
crossystem_on_or_off() {
  local value
  if value="$(crossystem "$1" 2>/dev/null)"; then
    case "${value}" in
    "0")
      echo off
      ;;
    "1")
      echo on
      ;;
    *)
      echo "${value}"
      ;;
    esac
  else
    echo "(unknown)"
  fi
}

# Echoes "yes" or "no" based on a Boolean argument (0 or 1).
bool_to_yes_or_no() {
  [ "$1" = 1 ] && echo yes || echo no
}

command_to_yes_or_no() {
  "$@" >/dev/null 2>&1 && echo yes || echo no
}

# Prints a header (a title, plus all the info in print_device_info)
print_header() {
    colorize boldwhite
    echo CrOS Factory Shim
    colorize white
    echo -----------------
    print_device_info
}

# Prints various information about the device.
print_device_info() {
    echo "Factory shim version: $(findLSBValue CHROMEOS_RELEASE_DESCRIPTION)"
    local bios_version="$(crossystem ro_fwid 2>/dev/null)"
    echo "BIOS version: ${bios_version:-(unknown)}"
    for type in RO RW; do
      echo -n "EC ${type} version: "
      ectool version | grep "^${type} version" | sed -e 's/[^:]*: *//'
    done
    echo
    echo System time: "$(date)"
    local hwid="$(crossystem hwid 2>/dev/null)"
    echo "HWID: ${hwid:-(not set)}"
    echo -n "Dev mode: $(crossystem_on_or_off devsw_boot); "
    echo -n "Recovery mode: $(crossystem_on_or_off recoverysw_boot); "
    echo -n "HW write protect: $(crossystem_on_or_off wpsw_boot); "
    echo "SW write protect: $(command_to_yes_or_no check_fw_swwp host)"
    echo -n "EC present: $(bool_to_yes_or_no "${EC_PRESENT}"); "
    if [ "${EC_PRESENT}" = "1" ]; then
      echo -n "EC SW write protect: $(command_to_yes_or_no check_fw_swwp ec); "
    fi
    echo "Dev switch present: $(bool_to_yes_or_no "${DEVSW_PRESENT}")"
    echo "Cr50 version: $(get_cr50_rw_version)"
    echo
}

# Displays a line in the menu.  Used in the menu function.
#
# Args:
#   $1: Single-character option name ("I" for install)
#   $2: Brief description
#   $3: Further explanation
menu_line() {
  echo -n "  "
  colorize boldwhite
  echo -n "$1  "
  colorize white
  printf "%-22s%s\n" "$2" "$3"
}

# Checks if the given action is valid and supported.
is_valid_action() {
  echo "$1" | grep -q "^[${SUPPORTED_ACTIONS}]$"
}

check_devmode_is_allowed() {
  # Check block_devmode flag
  echo "Checking block_devmode flags"
  if crossystem 'block_devmode?1' 'wpsw_boot?1' 2>/dev/null; then
    echo
    echo "crossystem flag 'block_devmode' is set on a write protected device."
    echo
    echo "You need to disable hardware write protection to bypass this check."
    echo

    # Run cr50-reset.sh if available
    if command -v /usr/share/cros/cr50-reset.sh >/dev/null; then
      echo "Defaulting to RMA reset"
      sleep 2
      # Perform an RMA reset
      action_e
    fi
    return 1
  fi
  return 0
}

# Displays a menu, saving the action (one of ${SUPPORTED_ACTIONS}, always
# lowercase) in the "ACTION" variable.  If no valid action is chosen,
# ACTION will be empty.
menu() {
  # Clear up terminal
  stty sane echo
  # Enable cursor (if tput is available)
  tput cnorm 2>/dev/null || true

  echo
  echo
  echo Please select an action and press Enter.
  echo

  menu_line I "Install" "Performs a network or USB install"
  menu_line R "Reset" "Performs a factory reset; finalized devices only"
  menu_line S "Shell" "Opens bash; available only with developer firmware"
  menu_line V "View configuration" "Shows crossystem, VPD, etc."
  menu_line D "Debug info and logs" \
              "Shows useful debugging information and kernel/firmware logs"
  menu_line Z "Zero (wipe) storage" "Makes device completely unusable"
  menu_line C "SeCure erase" \
              "Performs full storage erase, write a verification pattern"
  menu_line Y "VerifY erase" \
              "Verifies the storage has been erased with option C"
  menu_line T "Reset TPM" "Call chromeos-tpm-recovery"
  menu_line F "Update TPM Firmware" "Call tmp-firmware-update-factory"
  menu_line U "Update Cr50" \
              "Update Cr50 fw from ROOTFS_PARTITION/${PROD_CR50_PATH}"
  menu_line E "Reset Cr50" "Perform a Cr50 reset"
  menu_line M "Cr50 factory mode" "Enable Cr50 factory mode"

  echo
  read -p 'action> ' ACTION
  echo
  # busybox tr may not have '[:upper:]'.
  # shellcheck disable=SC2019 disable=SC2018
  ACTION="$(echo "${ACTION}" | tr 'A-Z' 'a-z')"

  if is_valid_action "${ACTION}"; then
    return
  fi
  echo "Invalid action; please select an action from the menu."
  ACTION=
}

#
# Action handlers
#

# F = tpm-firmware-update-factory
action_f() {
  /usr/share/cros/init/tpm-firmware-update-factory.sh
}

# I = Install.
action_i() {
  reset_chromeos_device

  log "Checking for Firmware Write Protect"
  # Check for physical firmware write protect. We'll only
  # clear this stuff if the case is open.
  if [ "$(crossystem wpsw_cur)" = "0" ]; then
    # Clear software firmware write protect.
    clear_fwwp
  fi
  ensure_fwwp_consistency

  if [ -z "${FACTORY_INSTALL_FROM_USB}" ]; then

    colorize yellow
    log "Waiting for ethernet connectivity to install"

    while true; do
      if [ -n "${NETBOOT_RAMFS}" ]; then
        # For initramfs network boot, there is no upstart job. We have to
        # bring up network interface and get IP address from DHCP on our own.
        # The network interface may not be ready, so let's ignore any
        # error here.
        bringup_network || true
      fi
      if check_ethernet_status; then
        break
      else
        sleep 1
      fi
    done

    # Check for factory server override from tftp server.
    override_from_tftp

    # TODO(hungte) how to set time in RMA?
    set_time || die "Please check if the server is configured correctly."
  fi

  colorize green
  ufs_init
  get_dst_drive
  prepare_disk
  select_board

  if [ -n "${FACTORY_INSTALL_FROM_USB}" ]; then
    factory_install_usb
  else
    factory_install_network
  fi

  log "Factory Installer Complete."
  sync
  sleep 3
  factory_on_complete

  # Some installation procedure may clear or reset NVdata, so we want to ensure
  # TPM will be cleared again.
  crossystem clear_tpm_owner_request=1 || true

  # Default action after installation: reboot.
  trap - EXIT
  sync
  sleep 3

  # Cr50 factory mode can only be enabled when hardware write protection is
  # disabled. Assume we only do netboot in factory, so that in netboot
  # environment we don't need to enable factory mode because the device should
  # already be in factory mode.
  # TODO(chenghan) Figure out the use case of netboot besides factory process.
  if [ -z "${NETBOOT_RAMFS}" ] && ! is_cr50_factory_mode_enabled \
                               && [ "$(crossystem wpsw_cur)" = "0" ]; then
    # Enabling cr50 factory mode would trigger a reboot automatically and be
    # halt inside this function until reboots.
    enable_cr50_factory_mode
  fi

  # Try to do EC reboot. If it fails, do normal reboot.
  if [ -n "${NETBOOT_RAMFS}" ]; then
    # There is no 'shutdown' and 'init' in initramfs.
    ectool reboot_ec cold at-shutdown && busybox poweroff -f ||
      busybox reboot -f
  else
    ectool reboot_ec cold at-shutdown && shutdown -h now || shutdown -r now
  fi

  # sleep indefinitely to avoid re-spawning rather than shutting down
  sleep 1d
}

# R = Factory reset.
action_r() {
  if [ -n "${NETBOOT_RAMFS}" ]; then
    # factory_reset.sh script is not available in netboot mode.
    colorize red
    log "Not available in netboot."
    return
  fi

  # First check to make sure that the factory software has been wiped.
  MOUNT_POINT=/tmp/stateful
  mkdir -p /tmp/stateful
  get_dst_drive
  mount -o ro "$(make_partition_dev "${DST_DRIVE}" "${DST_STATE_PART}")" \
    "${MOUNT_POINT}"

  local factory_exists=false
  [ -e ${MOUNT_POINT}/dev_image/factory ] && factory_exists=true
  umount "${MOUNT_POINT}"

  if ${factory_exists}; then
    colorize red
    log "Factory software is still installed (device has not been finalized)."
    log "Unable to perform factory reset."
    return
  fi

  check_fw_swwp host && check_fw_swwp ec || ! is_pvt_phase || \
    die "SW write protect is not enabled in the device with PVT phase."

  reset_chromeos_device
  factory_reset
}

# S = Shell.
action_s() {
  if ! is_allow_debug && ! is_dev_firmware; then
    colorize red
    echo "Cannot open a shell (need devfw [Ctrl-U] or cros_debug build)."
    explain_cros_debug
    return
  fi

  log "Trying to bring up network..."
  if bringup_network 2>/dev/null; then
    colorize green
    log "Network enabled."
    colorize white
  else
    colorize yellow
    log "Unable to bring up network (or it's already up).  Proceeding anyway."
    colorize white
  fi

  echo Entering shell.
  bash || true
}

# V = View configuration.
action_v() {
  (
    print_device_info

    for partition in RO_VPD RW_VPD; do
      echo
      echo "${partition} contents:"
      vpd -i "${partition}" -l || true
    done

    echo
    echo "crossystem:"
    crossystem || true

    echo
    echo "lsb-factory:"
    cat /mnt/stateful_partition/dev_image/etc/lsb-factory || true
  ) 2>&1 | secure_less.sh
}

# D = Debug info and logs.
action_d() {
  (
    echo "## Information in this command:"
    echo "##   dev_debug_vboot"
    echo "##     date"
    echo "##     crossystem --all"
    echo "##     rootdev -s"
    echo "##     la -aCF /root"
    echo "##     ls -aCF /mnt/stateful_partition"
    local devs=$(awk \
        '/(mmcblk[0-9])$|(sd[a-z])$|(nvme[0-9]+n[0-9]+)$/ {print "/dev/"$4}' \
        /proc/partitions)
    for dev in ${devs}; do
      echo "##     cgpt show ${dev}"
    done
    echo "##     etc..."
    echo "##   firmware event log"
    echo "##   /sys/firmware/log"
    echo "##   kernel log"
    echo "##   Storage Information"
    echo "##   checksums"

    echo
    echo "## dev_debug_vboot:"
    dev_debug_vboot || true

    echo
    echo "## debug_vboot_noisy.log:"
    cat /var/log/debug_vboot_noisy.log || true

    echo
    echo "## firmware event log:"
    mosys eventlog list || true

    echo
    echo "## /sys/firmware/log:"
    cat /sys/firmware/log || true

    echo
    echo "## kernel log:"
    dmesg || true

    echo
    echo "## Storage information:"
    get_storage_info || true

    echo
    echo "## checksums:"
    local parts=$(sed -n 's/.* \([^ ]*[^0-9][24]$\)/\1/p' /proc/partitions)
    for part in ${parts}; do
      md5sum "/dev/${part}" || true
    done
  ) 2>&1 | secure_less.sh
}

# Confirm and erase the fixed drive.
#
# Identify the fixed drive, ask confirmation and call
# factory_disk_action function.
#
# Args:
#   action: describe how to erase the drive.
erase_drive() {
  local action="$1"
  if [ -n "${NETBOOT_RAMFS}" ]; then
    # factory_reset.sh script is not available in netboot mode.
    colorize red
    log "Not available in netboot."
    return
  fi

  colorize red
  get_dst_drive
  echo "!!"
  echo "!! You are about to wipe the entire internal disk."
  echo "!! After this, the device will not boot anymore, and you"
  echo "!! need a recovery USB disk to bring it back to life."
  echo "!!"
  echo "!! Type 'yes' to do this, or anything else to cancel."
  echo "!!"
  colorize white
  local yes_or_no
  read -p "Wipe the internal disk? (yes/no)> " yes_or_no
  if [ "${yes_or_no}" = yes ]; then
    factory_disk_action "${action}"
  else
    echo "You did not type 'yes'. Cancelled."
  fi
}

# Z = Zero
action_z() {
  erase_drive wipe
}

# C = SeCure
action_c() {
  erase_drive secure
}

# Y = VerifY
action_y() {
  if [ -n "${NETBOOT_RAMFS}" ]; then
    # factory_reset.sh script is not available in netboot mode.
    colorize red
    log "Not available in netboot."
    return
  fi
  get_dst_drive
  factory_disk_action verify
}

# T = Reset TPM
action_t() {
  chromeos-tpm-recovery
}

# U = Update Cr50
action_u() {
  local temp_firmware="$(copy_prod_cr50_firmware)"

  local result=0
  "${GSCTOOL}" -a -u "${temp_firmware}" || result="$?"

  rm "${temp_firmware}"

  # Allow 0(no-op), 1(all_updated), 2(rw_updated), other return values are
  # considered fail.
  # See trunk/src/platform/ec/extra/usb_updater/gsctool.h for more detail.
  case "${result}" in
    "0" )
      log "Cr50 not updated. Returning to shim menu."
      # sleep for a while to show the messages
      sleep 3
      return 0
      ;;
    "1" | "2" )
      log "Cr50 updated. System will reboot shortly."
      # sleep for a while to show the messages
      sleep 3
      reboot
      sleep 1d
      return 0
      ;;
    *)
      die "gsctool execution failed as ${result}."
      ;;
  esac
}

# E = Reset Cr50
action_e() {
  /usr/share/cros/cr50-reset.sh
}

# M = Enable Cr50 factory mode
action_m() {
  if is_cr50_factory_mode_enabled; then
    log "Factory mode was already enabled."
  else
    enable_cr50_factory_mode
  fi
}

main() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "You must run this as root."
    exit 1
  fi
  config_tty || true  # Never abort if TTY has problems.

  log "Starting Factory Installer."
  # TODO: do we still need this call now that the kernel was tweaked to
  # provide a good light level by default?
  lightup_screen

  load_modules

  colorize white
  clear

  test_ec_flash_presence
  test_devsw_presence

  # Check for any configuration overrides.
  overrides

  # Read default options
  if [ "${NETBOOT_RAMFS}" = 1 ]; then
    log "Netbooting. Set default action to (I) Install."
    DEFAULT_ACTION=i
  elif [ "${RMA_AUTORUN}" = "true" ]; then
    if crossystem 'wpsw_cur?1' 2>/dev/null; then
      log "Hardware write protect on."
      if check_need_update_cr50; then
        log "Cr50 version is old. Set default action to (U) Update Cr50."
        DEFAULT_ACTION=u
      else
        log "Do not need to update cr50. Set default action to (E) Reset Cr50."
        DEFAULT_ACTION=e
      fi
    else
      log "Hardware write protect off. Set default action to (I) Install."
      DEFAULT_ACTION=i
    fi
  fi

  # Sanity check default action
  if [ -n "${DEFAULT_ACTION}" ]; then
    log "Default action: [${DEFAULT_ACTION}]."
    if ! is_valid_action "${DEFAULT_ACTION}"; then
      log "Action [${DEFAULT_ACTION}] is invalid."
      log "Only support ${SUPPORTED_ACTIONS}. Will fallback to normal menu..."
      DEFAULT_ACTION=""
      sleep 3
    fi
  fi

  while true; do
    clear
    print_header

    local do_default_option=false
    if [ -n "${DEFAULT_ACTION}" ]; then
      do_default_option=true
      # Give the user the chance to press any key to display the menu.
      log "Will automatically perform action [${DEFAULT_ACTION}]."
      log "Or press any key to show menu instead..."
      local timeout_secs=3
      for i in $(seq ${timeout_secs} -1 1); do
        # Read with timeout doesn't reliably work multiple times without
        # a sub shell.
        if ( read -N 1 -p "Press any key within ${i} sec> " -t 1 ); then
          echo
          do_default_option=false
          break
        fi
        echo
      done
    fi

    if ${do_default_option}; then
      # Default action is set and no key pressed: perform the default action.
      action_${DEFAULT_ACTION}
    else
      # Display the menu for the user to select an option.
      if check_devmode_is_allowed; then
        menu

        if [ -n "${ACTION}" ]; then
          # Perform the selected action.
          "action_${ACTION}"
        fi
      fi
    fi

    colorize white
    read -N 1 -p "Press any key to continue> "
  done
}
main "$@"
