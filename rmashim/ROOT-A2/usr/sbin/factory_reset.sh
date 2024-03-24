#!/bin/sh

# Copyright (c) 2011 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This runs from the factory install/reset shim. This MUST be run
# from USB, in developer mode. This script will wipe OQC activity and
# put the system back into factory fresh/shippable state.

# Preserve files in the CRX cache.  Largely copied from clobber-state.
# TODO(dgarrett,jsalz): Consolidate.
#

. "/usr/share/misc/chromeos-common.sh"
. "$(dirname "$0")/factory_common.sh"
. "$(dirname "$0")/factory_verify.sh"

# CUTOFF_DIR is provided from platform/factory/sh/cutoff, repacked by ebuild.
CUTOFF_DIR="/usr/share/cutoff"
CUTOFF_SCRIPT="${CUTOFF_DIR}/cutoff.sh"
INFORM_SHOPFLOOR_SCRIPT="${CUTOFF_DIR}/inform_shopfloor.sh"

usage() {
  echo "Usage: $0 disk [wipe|secure|verify]."
  echo "disk: device to operate on [for instance /dev/sda]"
  echo "If no argument, do a factory reset. Otherwise:"
  echo "wipe: write 0's on every LBA [backward compatibility]"
  echo "secure: use internal erase command in the device"
  echo "        and write a pattern on the disk"
  echo "verify: verify the disk has been erased properly"
  exit 1
}

# Note that some variables are shared with restore_crx_cache.
preserve_crx_cache() {
  PRESERVED_TAR="/tmp/preserve.tar"
  PRESERVED_FILES=""
  STATE_PATH="/mnt/stateful_partition"
  mkdir -p "${STATE_PATH}"
  mount "${STATE_DEV}" "${STATE_PATH}"
  IMPORT_FILES="$(cd ${STATE_PATH};
                  echo unencrypted/import_extensions/extensions/*.crx)"
  if [ "${IMPORT_FILES}" != \
       "unencrypted/import_extensions/extensions/*.crx" ]; then
    PRESERVED_FILES="${PRESERVED_FILES} ${IMPORT_FILES}"
  fi
  PRESERVED_LIST=""
  if [ -n "${PRESERVED_FILES}" ]; then
    # We want to preserve permissions and recreate the directory structure
    # for all of the files in the PRESERVED_FILES variable. In order to do
    # so we run tar --no-recurison and specify the names of each of the
    # parent directories. For example for home/.shadow/install_attributes.pb
    # we pass to tar home home/.shadow home/.shadow/install_attributes.pb
    for file in ${PRESERVED_FILES}; do
      if [ ! -e "${STATE_PATH}/${file}" ]; then
        continue
      fi
      path="${file}"
      while [ "${path}" != '.' ]; do
        PRESERVED_LIST="${path} ${PRESERVED_LIST}"
        path=$(dirname "${path}")
      done
    done
    tar cf ${PRESERVED_TAR} -C ${STATE_PATH} --no-recursion -- ${PRESERVED_LIST}
  fi
  # Try a few times to unmount the stateful partition.
  local unmounted=false
  for i in $(seq 5); do
    if umount ${STATE_DEV}; then
      unmounted=true
      break
    fi
    sleep 1
  done
  if ! ${unmounted}; then
    # Bail out: we may not be able to successfully mkfs.
    echo "Unable to unmount stateful partition. Aborting."
    exit 1
  fi
}

# Restores files previously preserved by preserve_crx_cache.
restore_crx_cache() {
  if [ -n "${PRESERVED_LIST}" ]; then
    # Copy files back to stateful partition
    mount ${STATE_DEV} ${STATE_PATH}
    tar xfp ${PRESERVED_TAR} -C ${STATE_PATH}
    sync  # Try as best we can, in case umount fails
    umount ${STATE_PATH}
    # Sleep for a bit, since we will shut down soon and want to give
    # the drive a chance to flush everything
    sleep 3
  fi
}

do_cutoff() {
  # TODO(hungte) Remove all the checks below since cutoff now reads its own
  # config.
  local cutoff_method=""
  local cutoff_ac_state=""
  local min_battery_percent="" max_battery_percent=""
  local min_battery_voltage="" max_battery_voltage=""
  local shopfloor_url=""

  cutoff_method="$(findLSBValue CUTOFF_METHOD)"
  cutoff_ac_state="$(findLSBValue CUTOFF_AC_STATE)"
  min_battery_percent="$(findLSBValue CUTOFF_BATTERY_MIN_PERCENTAGE)"
  max_battery_percent="$(findLSBValue CUTOFF_BATTERY_MAX_PERCENTAGE)"
  min_battery_voltage="$(findLSBValue CUTOFF_BATTERY_MIN_VOLTAGE)"
  max_battery_voltage="$(findLSBValue CUTOFF_BATTERY_MAX_VOLTAGE)"
  shopfloor_url="$(findLSBValue SHOPFLOOR_URL)"

  # inform_shopfloor will load right shopfloor URL if not given, or ignore the
  # request if none set.
  "${INFORM_SHOPFLOOR_SCRIPT}" "${shopfloor_url}" "factory_reset" || exit 1

  local args=""
  [ -n "${cutoff_method}" ] && args="--method ${cutoff_method}"
  [ -n "${cutoff_ac_state}" ] && args="${args} --check-ac ${cutoff_ac_state}"
  [ -n "${min_battery_percent}" ] &&
    args="${args} --min-battery-percent ${min_battery_percent}"
  [ -n "${max_battery_percent}" ] &&
    args="${args} --max-battery-percent ${max_battery_percent}"
  [ -n "${min_battery_voltage}" ] &&
    args="${args} --min-battery-voltage ${min_battery_voltage}"
  [ -n "${max_battery_voltage}" ] &&
    args="${args} --max-battery-voltage ${max_battery_voltage}"

  "${CUTOFF_SCRIPT}" ${args}
}

main() {
  if [ "$#" -lt 1 ]; then
    usage
  fi

  DEV="$1"
  if [ ! -b "${DEV}" ]; then
    echo "Invalid root disk ${DEV}."
    exit 1
  fi
  STATE_DEV=$(make_partition_dev "${DEV}" "1")
  DEV_SIZE=$(blockdev --getsize64 "${DEV}")
  shift

  # Tcsd will bring up the tpm and de-own it,
  # as we are in developer/recovery mode.
  start tcsd || true

  if [ $# -eq 1 ]; then
    case "$1" in
      wipe)
        # Nuke the disk.
        pv -etpr -s ${DEV_SIZE} -B 8M /dev/zero |
          dd bs=8M of="${DEV}" oflag=dsync iflag=fullblock
        ;;
      secure)
        # Erase using firmware feature first.
        secure_erase ${DEV} || exit 1
        perform_fio_op "${DEV}" "${DEV_SIZE}" "write" || exit 1
        ;;
      verify)
        perform_fio_op "${DEV}" "${DEV_SIZE}" "verify" || exit 1
        ;;
      *)
        usage
    esac
  else
    echo "Factory reset"
    if [ ! -b "${STATE_DEV}" ]; then
      echo "Failed to find stateful partition."
      exit 1
    fi

    # TODO(hungte) This should do same thing as what clobber-state did.
    preserve_crx_cache
    # Just wipe the start of the partition and remake the fs on
    # the stateful partition.
    dd bs=4M count=1 if=/dev/zero of=${STATE_DEV}
    /sbin/mkfs.ext4 "${STATE_DEV}"

    restore_crx_cache
  fi

  do_cutoff
  echo "Done"
}
main "$@"
