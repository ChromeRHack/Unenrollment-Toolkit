#!/bin/sh
# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Finds and prepares (if needed) best terminal consoles for factory software.
# Usage:
#  . /usr/sbin/factory_tty.sh
#  tty_init
#  echo something >>"${TTY}"
#  [ -n "${LOG_TTY}" ] && echo "some log" >"${LOG_TTY}"

# TTY_CONSOLE will be changed by build script (values from make.conf).
TTY_CONSOLE="ttyS0"
export TTY=""
export LOG_TTY=""
export INFO_TTY=""
export DEBUG_TTY=""

: ${FRECON_LITE_PATH:=/sbin/frecon-lite}
: ${FRECON_PATH:=/sbin/frecon}
: ${FRECON_TTY:=/run/frecon/vt0}
: ${FRECON_PID:=/run/frecon/pid}
: ${FRECON_EXTRA_TTY:=/run/frecon/vt1}
: ${FBDEV:=/sys/class/graphics/fb0}
: ${FBCON:=/sys/class/graphics/fbcon}

# Prints to kernel message (for debugging before TTY is setup).
kernel_msg () {
  if [ -e "/dev/kmsg" ]; then
    echo "$0: $*" >>/dev/kmsg || true
  fi
}

# Extracts tokens from kernel command line.
kernel_get_var() {
  local token="$1="
  local entry="$(cat /proc/cmdline)"
  local result=""

  while echo "${entry}" | grep -q "${token}" ; do
    entry="${entry#*${token}}"
    result="${entry%%[ ,]*} ${result}"
    entry="${entry#* }"
  done
  echo "${result}"
}

# Checks if given parameter is a valid TTY (or PTS) device file.
tty_is_valid() {
  [ -c "$1" ] && (echo "" >"$1") 2>/dev/null
}

# Kills running frecon sessions.
kill_frecon() {
  kill "$(cat "${FRECON_PID}")" || true
  killall frecon-lite || true
  killall frecon || true
}

# Starts the 'frecon' daemon.
tty_start_frecon() {
  if [ -e "${FRECON_TTY}" ]; then
    # There is a limitation about frecon[-lite] (created in initramfs stage)
    # can't detect new input device by udev monitor after switch_root is called.
    # The workaround is to re-create frecon[-lite] in new rootfs so udev
    # monitor can be re-started again. Finally new input device can be detected.
    kill_frecon
  fi

  kernel_msg "Starting frecon..."

  udevd --daemon
  udevadm trigger
  udevadm settle
  "${FRECON_PATH}" --enable-vt1 --daemon --no-login --enable-vts \
    --pre-create-vts --num-vts=8 --enable-gfx

  local loop_time=30
  while [ ! -e "${FRECON_TTY}" -a ${loop_time} -gt 0 ]; do
    kernel_msg " ${FRECON_TTY} does not exist. Retry for ${loop_time} seconds."
    sleep 1s
    loop_time=$((loop_time - 1))
  done

  if [ ! -e "${FRECON_TTY}" ]; then
    kernel_msg "Frecon failed to start."
  else
    kernel_msg "Frecon is ready."
  fi
}

# Finds if the TTY can be enumerated with given index.
tty_find_relative() {
  local tty="$1"
  local offset="$2"

  # dash does not support [^0-9].
  local tty_num="${tty##*[a-zA-Z_/]}"
  local tty_base="${tty%${tty_num}}"

  if [ -z "${tty_num}" ]; then
    return
  fi
  local new_tty="${tty_base}$((tty_num + offset))"

  if tty_is_valid "${new_tty}"; then
    echo "${new_tty}"
  fi
}

# Determine and setup (if needed) TTYs (TTY, LOG_TTY, INFO_TTY, DEBUG_TTY).
# TTY is detected by following order:
#  - The last non-empty console= from cmdline.
#  - If fbdev and fbcon both exist, try /dev/tty1.
#  - ${FRECON_TTY} if available.
#  - If frecon-lite is available, start frecon-lite and try ${FRECON_TTY}.
#  - ${TTY_CONSOLE} if non-empty (which may be a list).
#  - /dev/null if nothing else.
tty_init() {
  local ttys="$(kernel_get_var console)"
  local tty_name="" tty_path=""

  TTY=""
  LOG_TTY=""

  # Always use frecon-lite if possible.
  if [ -x "${FRECON_LITE_PATH}" ]; then
    FRECON_PATH="${FRECON_LITE_PATH}"
  fi

  # /dev/tty1 should be tried earlier if the device has fbdev and fbcon.
  if [ -e ${FBDEV} ] && [ -e ${FBCON} ]; then
    ttys="${ttys} tty1"
  elif [ -e ${FRECON_TTY} ] || [ -x ${FRECON_PATH} ]; then
    tty_start_frecon
    local frecon_tty="$(readlink -f ${FRECON_TTY})"
    ttys="${ttys} ${frecon_tty#/dev/}"
  fi

  ttys="${ttys} ${TTY_CONSOLE} null"

  kernel_msg "Finding best TTY from ${ttys}..."
  for tty_name in ${ttys}; do
    tty_path="/dev/${tty_name}"
    if tty_is_valid "${tty_path}"; then
      TTY="${tty_path}"
      break
    fi
  done

  # Devices using tty2 are actually using tty1 as default console.
  [ "${TTY}" = /dev/tty2 ] && TTY=/dev/tty1

  LOG_TTY="$(tty_find_relative "${TTY}" 1)"
  INFO_TTY="$(tty_find_relative "${TTY}" 2)"
  DEBUG_TTY="$(tty_find_relative "${TTY}" 3)"

  kernel_msg "TTY=${TTY} LOG=${LOG_TTY} INFO=${INFO_TTY} DEBUG=${DEBUG_TTY}"
}
