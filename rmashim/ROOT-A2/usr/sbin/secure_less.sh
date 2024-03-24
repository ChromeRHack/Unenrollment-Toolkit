#!/bin/bash

# Copyright (c) 2014 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Opens "less" securely as the "nobody" user.  Only piping from stdin
# is supported (there may be no command line arguments).

set -e

if [ $# -ne 0 ]; then
  echo "Usage: secure_less.sh" >& 2
  echo "(no command-line arguments are allowed)" >& 2
  exit 1
fi

# Disable EDITOR and SHELL, just in case.  Always use busybox less,
# since it has no fancy features that could enable exploits.

# We can switch back to only su if either of these bugs get fixed:
# https://bugs.debian.org/663200
# https://bugs.busybox.net/9231
if sudo -h >/dev/null 2>&1; then
  set -x
  exec sudo -u nobody -s /bin/sh \
    -c "EDITOR=/bin/false SHELL=/bin/false busybox less"
else
  set -x
  exec su -s /bin/sh \
    -c "EDITOR=/bin/false SHELL=/bin/false busybox less" - nobody
fi
