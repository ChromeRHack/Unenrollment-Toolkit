#!/bin/sh
# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Prepares system environment to start ChromeOS factory shim.

# We want to print the console UI to TTY_FILE, redirect its contents into TTY,
# and print bash trace logs to LOG_FILE (via LOG_TTY if available).
# shellcheck disable=SC2034
TTY_CONSOLE=""
TTY_FILE=/var/log/factory_shim.output
LOG_FILE=/var/log/factory_shim.log
OVERLORD_READY=1
# This must be using a different file name from LOG_FILE because /var/log may be
# a symlink to /log.
: "${INITRAMFS_LOG_FILE:=/log/factory_initramfs.log}"
export TTY_FILE LOG_FILE OVERLORD_READY

. "$(dirname "$0")/factory_common.sh"
. "$(dirname "$0")/factory_tty.sh"

main() {
  tty_init

  # Setup and display log files
  mkdir -p "$(dirname "${TTY_FILE}")" "$(dirname "${LOG_FILE}")"
  touch "${TTY_FILE}" "${LOG_FILE}"

  local omahaserver="$(kernel_get_var omahaserver)"
  if [ -n "${omahaserver}" ]; then
    # Should be netboot-ready environment. Try to start Overlord service.
    if ! bringup_network ||
       ! register_to_overlord "${omahaserver}" "${TTY_FILE}" "${LOG_FILE}"; then
      OVERLORD_READY=
    fi
  fi

  if [ -n "${LOG_TTY}" ]; then
    echo "
        ---------------------------------------------------------
        ChromeOS Factory Shim - $(date)

         Press [q] to refresh, [g/G] to begin/end of logs, [b/f]
         to backward/forward pages, or navigation keys to scroll.
        ---------------------------------------------------------" >${LOG_FILE}
    if [ -e "${INITRAMFS_LOG_FILE}" ]; then
      cat "${INITRAMFS_LOG_FILE}" >>"${LOG_FILE}"
    fi
    LOG_VIEWER_COMMAND="while true; do secure_less.sh <${LOG_FILE}; done"
    # 'script' here helps to reset control terminal environment on LOG_TTY.
    setsid sh -c \
      "script -afqc '${LOG_VIEWER_COMMAND}' /dev/null <${LOG_TTY} >${LOG_TTY}" &
  fi

  # Use the System-V way to specify controlling TTY (CTTY): create a new session
  # (setsid) and the first opened TTY will be CTTY. 'script' is used (instead of
  # redirection) to keep input and output stream in terminal type.
  # Service may be executed as 'exec' so we have to explicitly sleep here
  # otherwise kernel will panic with 'init aborted' and hard to debug.
  exec setsid sh -c \
    "exec script -afqc 'factory_install.sh || sleep 1d' ${TTY_FILE} \
     <${TTY} >>${TTY} 2>&1"
}

main "$@"
