#!/bin/sh
# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

exec /sbin/minijail0 -u bluetooth -g bluetooth -Nniplrvdt --uts -c2000 \
  --profile=minimalistic-mountns \
  -k tmpfs,/var,tmpfs,0xe -b /var/log/bluetooth,,1 \
  -- /usr/bin/btmon -Sc0 -w /var/log/bluetooth/log.bz2
