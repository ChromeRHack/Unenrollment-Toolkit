#!/bin/sh
# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Set margin for low-memory notifier (for tab discarder)
# Configure and start swap if SWAP_ENABLE_FILE exists.
# SWAP_ENABLE_FILE may optionally contain the uncompressed swap size (in Mb).
# Otherwise it is set to 1.5 times total RAM.

PER_BOARD_OVERRIDE_DIR=/etc/swap
PER_DEVICE_OVERRIDE_DIR=/var/lib/swap

SWAP_SIZE_BOARD_OVERRIDE_FILE="${PER_BOARD_OVERRIDE_DIR}/swap_size_mb"
SWAP_ENABLE_FILE="${PER_DEVICE_OVERRIDE_DIR}/swap_enabled"
DISK_BASED_SWAP_FILE="/proc/sys/vm/disk_based_swap"
SWAP_DIR="/mnt/stateful_partition/unencrypted/swap"

MARGIN_MAX=20000  # MiB
MARGIN_CONVERSION=1
MARGIN_OVERRIDE_FILE="${PER_DEVICE_OVERRIDE_DIR}/lowmem_margin"
MARGIN_BOARD_OVERRIDE_FILE="${PER_BOARD_OVERRIDE_DIR}/lowmem_margin"
MARGIN_SPECIAL_FILE="/sys/kernel/mm/chromeos-low_mem/margin"

margin_default_generator() {
  default_low_memory_margin "$(get_mem_total)"  # MiB
}

MIN_FILELIST_MAX=1000  # MiB
MIN_FILELIST_CONVERSION=1024
MIN_FILELIST_OVERRIDE_FILE="${PER_DEVICE_OVERRIDE_DIR}/min_filelist_kbytes"
MIN_FILELIST_BOARD_OVERRIDE_FILE="${PER_BOARD_OVERRIDE_DIR}/min_filelist_kbytes"
MIN_FILELIST_SPECIAL_FILE="/proc/sys/vm/min_filelist_kbytes"

min_filelist_default_generator() {
  # Check if ARC++ is running.  But don't check if it's not installed.
  if grep -q CHROMEOS_ARC_VERSION /etc/lsb-release && \
      [ "$(initctl status arc-boot-continue)" = \
           "arc-boot-continue start/running" ]; then
    echo 400000  # KiB
  else
    echo 100000  # KiB
  fi
}

EXTRA_FREE_MAX=20000  # MiB
EXTRA_FREE_CONVERSION=1024
EXTRA_FREE_OVERRIDE_FILE="${PER_DEVICE_OVERRIDE_DIR}/extra_free_kbytes"
EXTRA_FREE_BOARD_OVERRIDE_FILE="${PER_BOARD_OVERRIDE_DIR}/extra_free_kbytes"
EXTRA_FREE_SPECIAL_FILE="/proc/sys/vm/extra_free_kbytes"

extra_free_default_generator() {
  echo 0
}

HIST_MIN=100
HIST_MAX=10000
HIST_BUCKETS=50
HIST_ARGS="${HIST_MIN} ${HIST_MAX} ${HIST_BUCKETS}"
# Upstart sets JOB, but we're not always called by upstart,
# so set it here too.
JOB="swap"

# Takes a string S and returns the value of ${S}.
expand_var() {
  eval echo "\"\$$1\""
}

get_mem_total() {
  # Extract second field of MemTotal entry in /proc/meminfo.
  # NOTE: this could be done with "read", "case", and a function
  # that sets ram=$2, for a savings of about 3ms on an Alex.
  local mem_total
  mem_total=$(awk '/MemTotal/ { print $2; }' /proc/meminfo)
  if [ -z "${mem_total}" ]; then
    logger -t "${JOB}" "could not get MemTotal"
    exit 1
  fi
  echo "${mem_total}"
}

default_low_memory_margin() {
  # compute fraction of total RAM used for low-mem margin.  The fraction is
  # given in bips.  A "bip" or "basis point" is 1/100 of 1%.
  local margin
  MARGIN_BIPS=520
  margin=$(( $1 / 1024 * MARGIN_BIPS / 10000 ))  # MiB
  echo "${margin}"
}


# Gets the target value of a kernel memory manager parameter, whose name is
# passed in $1.
#
# Each parameter <P> has a default value, computed by <P>_default_generator.
# The default value can be overridden by a board-specific value contained
# in <P>_BOARD_OVERRIDE_FILE, or (with higher priority) a device-specific file,
# <P>_OVERRIDE_FILE which a user may have set, typically for the purpose of
# experimentation.
get_target_value() {
  local PARAM="$(echo "$1" | tr '[a-z]' '[A-Z]')"
  local value
  local board_override_file="$(expand_var "${PARAM}_BOARD_OVERRIDE_FILE")"
  local override_file="$(expand_var "${PARAM}_OVERRIDE_FILE")"
  local default_generator="$1"_default_generator

  if [ -e "${override_file}" ]; then
    value=$(cat "${override_file}")
  elif [ -e "${board_override_file}" ]; then
    value=$(cat "${board_override_file}")
  else
    value=$(${default_generator})
  fi
  echo "${value}"
}


# Sets the kernel value of a memory manager parameter, whose name is passed in
# $1, via a procfs or sysfs entry.
initialize_parameter() {
  local value="$(get_target_value "$1")"
  local PARAM="$(echo "$1" | tr '[:lower:]' '[:upper:]')"
  local special_file="$(expand_var "${PARAM}_SPECIAL_FILE")"

  # Older kernels don't support all parameters.
  if [ ! -e "${special_file}" ]; then
    return 0
  fi

  echo "${value}" > "${special_file}"
}


create_write_file() {
  file="$1"
  dir=$(dirname "${file}")
  content="$2"
  # Delete the file first in case its permissions have gotten ... weird.
  rm -f "${file}"
  mkdir -p -m 0755 "${dir}"
  echo "${content}" > "${file}"
}


# TODO(semenzato): Remove this after R65
migrate_old_swap_setting() {
  OLD_SWAP_ENABLE_FILE=/home/chronos/.swap_enabled
  if [ -e "${OLD_SWAP_ENABLE_FILE}" ]; then
    old_content="$(cat "${OLD_SWAP_ENABLE_FILE}")"
    create_write_file "${SWAP_ENABLE_FILE}" "${old_content}"
    rm -f "${OLD_SWAP_ENABLE_FILE}"
  fi
}

disk_based_swap_supported() {
  # Can be set in the ebuild.
  local disk_based_swap_enabled=false

  # Return true if kernel supports disk based swap.
  if [ "${disk_based_swap_enabled}" = "true" ] &&
     [ -e "${DISK_BASED_SWAP_FILE}" ]; then
    echo 1 > "${DISK_BASED_SWAP_FILE}"
  else
    disk_based_swap_enabled=false
  fi

  ${disk_based_swap_enabled}
}

die() {
  message="$1"
  logger -t "${JOB}" "${message}"
  exit 1
}

start() {
  local mem_total param
  mem_total=$(get_mem_total)

  # TODO(semenzato): Remove this after R65
  migrate_old_swap_setting

  for param in margin min_filelist extra_free; do
    initialize_parameter "${param}"
  done

  # Allocate zram (compressed ram disk) for swap.
  # SWAP_ENABLE_FILE contains the zram size in MB.
  # Empty or missing SWAP_ENABLE_FILE means use default size.
  # 0 size means do not enable zram.
  # Calculations are in Kb to avoid 32 bit overflow.

  local requested_size_mb size_kb
  # For security, only read first few bytes of SWAP_ENABLE_FILE.
  requested_size_mb="$(head -c 5 "${SWAP_ENABLE_FILE}")" || :
  # If SWAP_ENABLE_FILE does not exist or is empty, try the board override.
  if [ -z "${requested_size_mb}" ]; then
    requested_size_mb=$(cat "${SWAP_SIZE_BOARD_OVERRIDE_FILE}") || :
  fi
  # If still empty, compute swap based on RAM size.
  if [ -z "${requested_size_mb}" ]; then
    # Default multiplier for zram size. (Shell math is integer only.)
    local multiplier="3 / 2"
    # On ARM32 / ARM64 CPUs graphics memory is not reclaimable, so use a smaller
    # size.
    if arch | grep -qiE "arm|aarch64"; then
      multiplier="1"
    fi
    # The multiplier may be an expression, so it MUST use the $ expansion.
    size_kb=$(( mem_total * ${multiplier} ))
  elif [ "${requested_size_mb}" = "0" ]; then
    metrics_client Platform.CompressedSwapSize 0 ${HIST_ARGS}
    exit 0
  else
    size_kb=$(( requested_size_mb * 1024 ))
  fi

  if disk_based_swap_supported; then
    if [ -e "${SWAP_DIR}" ]; then
      rm -r "${SWAP_DIR}"
    fi
    mkdir -p "${SWAP_DIR}"
    dd if=/dev/urandom bs=1 count=32 2> /dev/null |
        e4crypt add_key "${SWAP_DIR}"
    fallocate -l 20G "${SWAP_DIR}/swapfile" ||
        die "failed to create swapfile"
    chmod 600 "${SWAP_DIR}/swapfile" ||
        die "failed to set swapfile permissions"
    mkswap "${SWAP_DIR}/swapfile" ||
        die "mkswap "${SWAP_DIR}/swapfile" failed"
    swapon "${SWAP_DIR}/swapfile" ||
        die "swapon "${SWAP_DIR}/swapfile" failed"
    echo 1 > /sys/module/zswap/parameters/enabled
  else
    # Load zram module.  Ignore failure (it could be compiled in the kernel).
    modprobe zram || logger -t "${JOB}" "modprobe zram failed (compiled?)"

    logger -t "${JOB}" "setting zram size to ${size_kb} Kb"
    # Approximate the kilobyte to byte conversion to avoid issues
    # with 32-bit signed integer overflow.
    echo "${size_kb}000" >/sys/block/zram0/disksize ||
        logger -t "${JOB}" "failed to set zram size"

    mkswap /dev/zram0 || logger -t "${JOB}" "mkswap /dev/zram0 failed"
    # Swapon may fail because of races with other programs that inspect all
    # block devices, so try several times.
    local tries=0
    while [ ${tries} -le 10 ]; do
      swapon /dev/zram0 && break
      : $(( tries += 1 ))
      logger -t "${JOB}" "swapon /dev/zram0 failed, try ${tries}"
      sleep 0.1
    done
  fi

  local swaptotalkb
  swaptotalkb=$(awk '/SwapTotal/ { print $2 }' /proc/meminfo)
  metrics_client Platform.CompressedSwapSize \
                $(( swaptotalkb / 1024 )) ${HIST_ARGS}
}

stop() {
  logger -t "${JOB}" "turning off swap"

  # This is safe to call even if no swap is turned on.
  swapoff -av

  if [ -b "/dev/zram0" ]; then
    # When we start up, we try to configure zram0, but it doesn't like to
    # be reconfigured on the fly.  Reset it so we can changes its params.
    echo 1 > /sys/block/zram0/reset || :
  fi
}

status() {
  # Show general swap info first.
  cat /proc/swaps

  # Show tunables.
  printf "low-memory margin (MiB): "
  cat "${MARGIN_SPECIAL_FILE}"
  printf "min_filelist_kbytes (KiB): "
  cat "${MIN_FILELIST_SPECIAL_FILE}"
  if [ -e "${EXTRA_FREE_SPECIAL_FILE}" ]; then
    printf "extra_free_kbytes (KiB): "
    cat "${EXTRA_FREE_SPECIAL_FILE}"
  fi

  if [ -b "/dev/zram0" ]; then
    # Then spam various zram settings.
    local dir="/sys/block/zram0"
    printf '\ntop-level entries in %s:\n' "${dir}"
    cd "${dir}"
    grep -s '^' * || :
  elif [ -e "/sys/kernel/debug/zswap" ]; then
    local dir="/sys/kernel/debug/zswap"
    printf '\ntop-level entries in %s:\n' "${dir}"
    cd "${dir}"
    grep -s '^' * || :
  fi
}

enable() {
  local size="$1"

  # Sizes of 0 or -1 mean restore factory default.
  # Don't confuse this with setting 0 in the file in the disable code path.
  if [ "${size}" = "0" -o  "${size}" = "-1" ]; then
    size=""
    logger -t "${JOB}" "enabling swap with default size"
  elif [ "${size}" -lt 100 -o "${size}" -gt 20000 ]; then
    echo "${JOB}: error: size ${size} is not between 100 and 20000" >&2
    exit 1
  else
    logger -t "${JOB}" "enabling swap via config with size ${size}"
  fi

  create_write_file "${SWAP_ENABLE_FILE}" "${size}"
}

disable() {
  logger -t "${JOB}" "disabling swap via config"
  create_write_file "${SWAP_ENABLE_FILE}" "0"
}

set_parameter() {
  local param="$1"
  local value="$2"
  case "${param}" in
  margin|min_filelist|extra_free)
    # We're good.
    ;;
  *)
    echo "invalid parameter ${param}" >&2
    exit 1
    ;;
  esac
  local PARAM="$(echo "${param}" | tr '[:lower:]' '[:upper:]')"
  local max="$(expand_var "${PARAM}_MAX")"
  local override_file="$(expand_var "${PARAM}_OVERRIDE_FILE")"
  local special_file="$(expand_var "${PARAM}_SPECIAL_FILE")"
  local conversion="$(expand_var "${PARAM}_CONVERSION")"
  local default_generator=${param}_default_generator

  # Don't try to set the parameter if the kernel doesn't support it.
  if [ ! -e "${special_file}" ]; then
    return 0
  fi

  if [ "${value}" -gt "${max}" ]; then
    echo "${JOB}: invalid set ${param} to ${value} (MiB), max is ${max}" >&2
    exit 1
  fi

  local system_value
  if [ "${value}" = "-1" ]; then
    rm -f "${override_file}"
    system_value=$(get_target_value "${param}")
  else
    # User units (always MiB) may differ from system units (sometimes KiB).
    system_value=$(( value * conversion ))
    create_write_file "${override_file}" "${system_value}"
  fi
  echo "${system_value}" > "${special_file}"
  value=$(( system_value / conversion ))
  logger "changed ${param} to ${value} MiB"
}

usage() {
  cat <<EOF
Usage: $0 <start|stop|status|enable <size>|disable|
           set_parameter <margin|min_filelist|extra_free> <value>>|
           get_target_value <margin|min_filelist|extra_free> <value>>

Start or stop the use of the compressed swap file, or persistently set
various memory manager tunable parameters, or get their chosen values.

A value of -1 for "enable" or "set_parameter <p>" results in removing any local
persistent setting of the parameter, thus reverting to its factory default.

The start phase is normally invoked by init during boot, but we never run the
stop phase when shutting down (since there's no point).  The stop phase is used
by developers via debugd to restart things on the fly.

Disabling changes the config, but doesn't actually turn on/off swap.
That will happen at the next reboot.

EOF
  exit $1
}

main() {
  set -e

  if [ $# -lt 1 ]; then
    usage 1
  fi

  # Make sure that the subcommand is one we know and that it has the right
  # number of arguments.
  local cmd="$1"
  shift
  case "${cmd}" in
  start|stop|status|disable)
    if [ $# -ne 0 ]; then
      usage 1
    fi
    ;;
  enable|get_target_value)
    if [ $# -ne 1 ]; then
      usage 1
    fi
    ;;
  set_parameter)
    if [ $# -ne 2 ]; then
      usage 1
    fi
    ;;
  *)
    usage 1
    ;;
  esac

  # Just call the func requested directly.
  ${cmd} "$@"
}
main "$@"
