#!/bin/sh
# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# This is loaded and executed by
# src/platform/initramfs/factory_shim/bootstrap.sh for patching rootfs in tmpfs.
# Note that this script may be executed by busybox shell (not bash, not dash).

# Usage: check_exists path new_root_prefix
# Returns if the path exists, and prints if path (without new_root_prefix)
# exists by adding a + or - prefix.
check_exists() {
  local file="$1"
  local new_root="$2"

  if [ -e "${file}" ]; then
    printf " +%s" "${file#${new_root}}"
    return 0
  else
    printf " -%s" "${file#${new_root}}"
    return 1
  fi
}

# Usage: patch_new_root new_root
# Patches new_root for booting into factory shim environment.
patch_new_root() {
  local new_root="$1"
  local file job
  printf "Patching new root in %s..." "${new_root}"

  # Copy essential binaries that are in the initramfs, but not in the root FS.
  cp /bin/busybox "${new_root}/bin"
  "${new_root}/bin/busybox" --install "${new_root}/bin"

  # Never execute the firmware updater from shim.
  touch "${new_root}"/root/.leave_firmware_alone

  # Modify some files that does not work (and not required) in tmpfs chroot.
  # This may be removed when we can build factory installer in "embedded" mode.
  file="${new_root}/usr/sbin/mount-encrypted"
  if check_exists "${file}" "${new_root}"; then
    echo '#!/bin/sh' >"${file}"
    echo 'echo "Sorry, $0 is disabled on factory installer image."' >>"${file}"
  fi

  # Set network to start up another way
  file="${new_root}/etc/init/boot-complete.conf"
  if check_exists "${file}" "${new_root}"; then
    sed -i 's/login-prompt-visible/started boot-services/' "${file}"
  fi

  # Disable upstart jobs that will block execution for factory shim environment.
  # syslog is disabled because it expects rsyslogd exists,
  # but we don't have rsyslogd in factory shim.
  local disabled_jobs
  disabled_jobs="arc-oemcrypto powerd swap syslog tpm-probe ui update-engine"

  for job in ${disabled_jobs}; do
    file="${new_root}/etc/init/${job}.conf"
    if check_exists "${file}" "${new_root}"; then
      # Upstart honors the last 'start on' clause it finds.
      echo "start on never" >>"${file}"
    fi
  done

  # Dummy jobs are empty single shot tasks because there may be services waiting
  # them to finish.
  # - pre-startup.conf: will mount new /tmp and /run, which we want to preserve.
  # - boot-splash.conf: will try to invoke another frecon instance.
  local dummy_jobs="pre-startup boot-splash"

  for job in ${dummy_jobs}; do
    file="${new_root}/etc/init/${job}.conf"
    if check_exists "${file}" "${new_root}"; then
      sed -i '/^start /!d' "${file}"
      echo "exec true" >>"${file}"
    fi
  done

  # We don't want any consoles to be executed.
  # To debug using servo, please comment this line.
  rm -f "${new_root}"/etc/init/console-*.conf

  # The laptop_mode may be triggered from udev
  rm -f "${new_root}/etc/udev/rules.d/99-laptop-mode.rules"

  printf ""
}

# Usage: patch_new_root new_root
# Patches new /run (tmpfs) under new_root for booting into factory shim
# environment.
patch_new_run() {
  local new_root="$1"
  printf "Patching new /run..."

  # /run by initramfs is sharing same tmpfs with root without having its own
  # mounted tmpfs so we can't use `mount --bind` or `mount --move`; so
  # duplicating /run is needed.

  # Replicate running data (/run).
  tar -cf - /run | tar -xf - -C "${new_root}"

  # frecon[-lite] creates TTY files in /dev/pts and have symlinks in
  # /run/frecon. However, /dev/pts will be re-created by chromeos_startup after
  # switch_root. As a result, we want to keep a copy of /dev/pts in /dev/frecon
  # and change symlinks to use them.
  if check_exists "${new_root}/run/frecon"; then
    local new_pts="/dev/frecon-lite"
    mkdir -p "${new_pts}"
    mount --bind /dev/pts "${new_pts}"
    for vt in "${new_root}"/run/frecon/vt*; do
      # It is assumed all vt* should refer to /dev/pts/*.
      file="$(basename $(readlink -f "${vt}"))"
      rm -f "${vt}"
      ln -s "${new_pts}/${file}" "${vt}"
    done
  fi
  printf ""
}

main() {
  patch_new_root "$1"
  patch_new_run "$1"
}
set -e
main "$@"
