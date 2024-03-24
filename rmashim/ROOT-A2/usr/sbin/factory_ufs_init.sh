#!/bin/sh
# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This script is run in the factory, and provisions a UFS disk with a single
# LUN that spans the entire region.

# Try to find a UFS controller.
UFS_DEV="$(find /sys/devices -name '*.ufshc' -type d)"

# Set a default for bRefClkFreq, which can be one of 0 (19.2MHz),
# 1 (26MHz), 2 (38.4MHz), or 3 (52MHz). The default is arbitrary.
: ${REF_CLK:=0}

# Read in the board-specific file if supplied.
DIRNAME="$(dirname "$(readlink -f "$0")")"
if [ -s "${DIRNAME}/factory_ufs_config.sh" ]; then
  . "${DIRNAME}/factory_ufs_config.sh"
fi

if [ -z "${UFS_DEV}" ]; then
  echo "No UFS devices present."
  exit 0
fi

if ! [ -d "${UFS_DEV}" ]; then
  echo "Error: No UFS host controller found at: ${UFS_DEV}"
  exit 1
fi

# Helper function: Convert a number like 0x12345678 into its big endian
# hex bytes 12 34 56 78.
int_to_bytes_be32() {
  printf "%02x %02x %02x %02x" $((${1} >> 24)) $(((${1} >> 16) & 0xFF)) \
    $(((${1} >> 8) & 0xFF)) $((${1} & 0xFF))
}

# First set the reference clock frequency, since if this isn't set, nothing
# else will work.
if [ $(($(cat "${UFS_DEV}"/attributes/reference_clock_frequency))) -ne \
     "${REF_CLK}" ]; then
  echo "${REF_CLK}" >"${UFS_DEV}"/attributes/reference_clock_frequency || {
    echo "Failed to set reference clock frequency"
    exit 1
  }
fi

# Get the raw device capacity in 512B units.
TOTAL_CAPACITY="$(cat "${UFS_DEV}"/geometry_descriptor/raw_device_capacity)"

echo "UFS Capacity: $((TOTAL_CAPACITY / 0x200000))GB"

# The segment size reports the number of 512B units in a segment.
SEGMENT_SIZE="$(cat "${UFS_DEV}"/geometry_descriptor/segment_size)"

# Get the allocation unit size, expressed in segments.
SEGMENTS_PER_ALLOCATION_UNIT="$(cat \
  "${UFS_DEV}"/geometry_descriptor/allocation_unit_size)"

# Dimensional analysis helps with understanding how the units convert from
# sectors to allocation units.
#
# TOTAL (sectors) |          (segments) | (allocation units)    allocation units
# ----------------------------------------------------------- =
#                 | SEG_SIZE (sectors)  | S_PER_A_U (segments)

TOTAL_ALLOCATION_UNITS=$((TOTAL_CAPACITY / SEGMENT_SIZE / \
  SEGMENTS_PER_ALLOCATION_UNIT))

# Just allocate the entire disk to the first unit.
ALLOC_UNITS="$(int_to_bytes_be32 ${TOTAL_ALLOCATION_UNITS})"

# Build the configuration descriptor as a sequence of bytes.
# This is the point at which things might change depending on
# how the kernel support for this shapes out. The way it's looking
# now I'm expecting a configfs file that a sequence of binary bytes
# containing the provisioning data.
HEADER="90 01 00 01 00 01 7F 00 00 00 00 00 00 00 00 00"
UNIT0="01 00 00 00 ${ALLOC_UNITS} 00 0C 00 00 00 00 00 00"
EMPTY="00 00 00 00 00 00 00 00 00 0C 00 00 00 00 00 00"
CONFIG_DESCRIPTOR="${HEADER} ${UNIT0} ${EMPTY} ${EMPTY} ${EMPTY} ${EMPTY}\
 ${EMPTY} ${EMPTY} ${EMPTY}"

# Create an ASCII representation of the bytes
CONFIG_ASCII="$(echo "0x${CONFIG_DESCRIPTOR}" | sed 's/ / 0x/g')"

# Write the descriptor out to the configfs provisioning file.
CONFIG_PROVISION="/sys/kernel/config/$(basename ${UFS_DEV})/ufs_provision"
echo "${CONFIG_ASCII}" >"${CONFIG_PROVISION}"

# Perform a SCSI rescan to bring the device online
echo "- - -" >"${UFS_DEV}"/host0/scsi_host/host0/scan

# Sync write and partprobe
sync
partprobe
