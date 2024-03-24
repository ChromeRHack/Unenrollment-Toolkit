#!/bin/sh -e
# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -e

DEVICE='tp'

usage() {
    local APP="${0##*/}"
    echo "USAGE:
    $APP
        Prints help (this text).
    $APP [tp|ts] o[bject] [number [offset [value]]]
        Prints all objects, a specific object, or a specific byte.
        Provide value to set the specific byte.
        Value can take the form of [+|-|^][0x|0b][digits].
        + means add the bit(s) to the current value.
        - means remove the bit(s) from the current value.
        ^ means toggle the bit(s) in the current value.
        0x interprets the digits as hex.
        0b interprets the digits as binary.
        Only one byte can be written at a time.
    $APP [tp|ts] r[efs]|d[eltas] [d|h] [watch ...]
        Dumps out the ref or delta values, either as decimal (default) or hex.
        If watch is specified, the remaining arguments are passed to watch.
    $APP [tp|ts] c[alibrate]
        Calibrates the device.
    $APP [tp|ts] w[rite] [config-file]
        Writes a config file to the device, updating the checksum field.
        If config-file is unspecified, uses stdin.
        Prints the updated checksum on stdout and writes them to files.
        Can handle both xcfg and raw files; xcfg files will not be modified.
        Needs rootfs verification to be off.

Commands can be prefixed with with tp or ts to specify trackpad or touchscreen.
Defaults to $DEVICE.

$APP must be run as root." 1>&2
    exit 2
}

# Expects "state" to be set.
# $1 = object number, $2 = byte offset
# Outputs to STDOUT; errors out if not available
getbyte() {
    awk "/^Type: $(($1))\$/ { start=NR }
         /^T$(($1))\$/ { start=NR }
         start && /^Instance:/ { start+=1 }
         start && /^\$/ { exit 1 }
         start && (NR-start-1) == $(($2)) { print \$NF; exit 0 }" \
        "$state/object" | tr -d '()'
}

# Converts a binary value in the form 0bxxxx into decimal and outputs on STDOUT.
bintodec() {
    local bin="${1#0b}" out=0 pow=1
    while [ -n "$bin" ]; do
        if [ "${bin%1}" != "$bin" ]; then
            out="$(($out + $pow))"
        fi
        pow="$(($pow * 2))"
        bin="${bin%?}"
    done
    echo "$out"
}

# Choose the device if specified
case "$1" in
    tp|atmel_mxt_tp) DEVICE='tp'; shift;;
    ts|atmel_mxt_ts) DEVICE='ts'; shift;;
esac

# Must have a command and must be root
if [ "$#" = 0 ] || [ "$(whoami)" != root -a "$(id -u)" != 0 ]; then
    usage
fi

# Detect the input and output object files
for write in '/sys/bus/i2c/devices/'*'/object'; do
    write="${write%/object}"
    if grep -q -- "-$DEVICE\.cfg\$" "$write/config_file"; then
        break
    fi
    write=''
done
state="/sys/kernel/debug/atmel_mxt_ts/${write##*/}"
if [ ! -f "$state/object" -o ! -f "$write/object" ]; then
    echo "Unable to find device $DEVICE" 1>&2
    exit 2
fi

# Process commands
if [ "${1#[oO]}" != "$1" ]; then
    shift
    if [ "$#" = 0 ]; then
        # Print all objects
        cat "$state/object"
    elif [ "$#" = 1 ]; then
        # Print specified object
        if ! awk "/^Type: $(($1))\$/ { ok=1 }
                 /^T$(($1))\$/ { ok=1 }
                 ok && /^\$/ { exit 0 }
                 ok
                 END { if (!ok) exit 1 }" "$state/object"; then
            echo "Object not found." 1>&2
            exit 1
        fi
    elif [ "$#" = 2 ]; then
        # Print datum
        value="$(getbyte "$1" "$2")"
        if [ -n "$value" ]; then
            echo "$value"
        else
            echo "Object/byte not found." 1>&2
            exit 1
        fi
    elif [ "$#" = 3 ]; then
        # Set datum
        op="${3%"${3#[-+^]}"}"
        value="${3#"$op"}"
        if [ "${value#0b}" != "$value" ]; then
            value="$(bintodec "$value")"
        else
            value="$(($value))"
        fi
        if [ -n "$op" ]; then
            case "$op" in
                +|\|) op='|';;
                -|\&~) op='&~';;
                ^) op='^';;
                *) usage;;
            esac
            cur="$(getbyte "$1" "$2")"
            if [ -z "$cur" ]; then
                echo "Object/byte not found." 1>&2
                exit 1
            fi
            value="$(($cur $op $value))"
        fi
        if ! printf '%02X00%02X%02X\n' "$(($1))" "$(($2))" "$value" \
                | tee "$write/object" 2>/dev/null; then
            echo "Object/byte not found." 1>&2
            exit 1
        fi
    else
        usage
    fi

elif [ "${1#[rRdD]}" != "$1" ]; then
    # Dump refs/deltas
    if [ "${1#[rR]}" != "$1" ]; then
        data="$state/refs"
        int=u
    else
        data="$state/deltas"
        int=d
    fi
    shift
    # Generate format. Default to integer if unspecified or invalid.
    format='-An -vt'
    case "${1:-d}" in
        h|x) format="${format}x2";;
        *) format="${format}${int}2";;
    esac
    # Grab the Y so we can wrap the dump
    dim="$(cut -d' ' -f2 "$write/matrix_size")"
    # Support prefixing the watch command
    while [ "$#" != 0 ]; do
        if [ "$1" = 'watch' ]; then
            break
        fi
        shift
    done
    # "$@" will be nothing if watch wasn't specified
    "$@" od $format -w"$(($dim*2))" "$data"

elif [ "${1#[cC]}" != "$1" ]; then
    # Calibrate the device
    echo > "$write/calibrate"

elif [ "${1#[wW]}" != "$1" ]; then
    # Copy the config onto the device; update and print checksum
    configfile="${2:-"-"}"
    if [ "$configfile" != '-' -a ! -f "$configfile" ]; then
        echo "Unable to find $configfile" 1>&2
        exit 2
    fi
    if ! mount -o remount,rw /; then
        echo \
'You need to run `make_dev_ssd.sh --remove_rootfs_verification` and reboot.
You may want to run `crossystem dev_boot_signed_only=0` as well.' 1>&2
        exit 2
    fi
    # Determine the destination file
    cfg="$(cat "$write/config_file")"
    cfg="$(readlink -m "/lib/firmware/$cfg")"
    # Make a backup
    if [ -f "$cfg" -a ! -f "$cfg.bak" ]; then
        cp "$cfg" "$cfg.bak"
        echo "Configuration backed up to $cfg.bak" 1>&2
    fi
    # Copy in the new file, assuming the source is not the destination
    if [ "$configfile" = '-' -o ! "$configfile" -ef "$cfg" ]; then
        if [ "$configfile" != '-' ]; then
            exec < "$configfile"
        fi
        # Determine if it's raw or xcfg
        read firstline
        if [ "${firstline#OBP_RAW}" != "$firstline" ]; then
            type='raw'
            # Raw file header gets copied straight-out
            read family variant version build xsize ysize numobjects
            read checksum
            read _
        else
            type='xcfg'
            firstline='OBP_RAW V1'
            # family_id, variant, version, build are from
            # the .xcfg's VERSION_INFO_HEADER
            while read header; do
                case "$header" in
                    "[VERSION_INFO_HEADER]"*) break;;
                esac
            done
            while IFS="=$IFS" read key data; do
                case "$key" in
                    FAMILY_ID) family="$(printf '%02X' "$data")";;
                    VARIANT) variant="$(printf '%02X' "$data")";;
                    VERSION) version="$(printf '%02X' "$data")";;
                    BUILD) build="$(printf '%02X' "$data")";;
                    INFO_BLOCK_CHECKSUM) checksum="${data#0x}";;
                    "["*) break;;
                esac
            done
            # Grab x, y, and info block checksum from the device
            xsize="$(cut -d' ' -f1 "$write/matrix_size")"
            xsize="$(printf '%02X' "$xsize")"
            ysize="$(cut -d' ' -f2 "$write/matrix_size")"
            ysize="$(printf '%02X' "$ysize")"
            if [ "$((0x${checksum:-0}))" -eq 0 ]; then
                checksum="$(head -c6 "$write/info_csum")"
            fi
            # Grab numobjects from the current cfg.
            if [ -f "$cfg" ]; then
                numobjects="$(sed -n '2s/.* //p' "$cfg")"
            fi
        fi
        # Sanity checks
        if ! grep -q "^$((0x$xsize)) $((0x$ysize))\$" "$write/matrix_size"; then
            echo "Config X and Y do not match the device's." 1>&2
            exit 1
        fi
        checksum="${checksum%"${checksum#??????}"}"
        if ! grep -qi "^$checksum\$" "$write/info_csum"; then
            echo "Info block checksum doesn't match the device's." 1>&2
            echo "Proceeding anyway with correct checksum." 1>&2
            checksum="$(head -c6 "$write/info_csum")"
        fi
        # Write the raw file
        {
            # OBP_RAW V1
            echo "$firstline"
            # family_id variant_id version build x_size y_size num_objects
            echo -n "${family:-00} ${variant:-00} ${version:-00}"
            echo    " ${build:-00} ${xsize:-00} ${ysize:-00} ${numobjects:-00}"
            # info_block_crc
            echo "${checksum:-000000}"
            # config_crc
            echo '000000'
            # Write the objects out
            if [ "$type" = 'raw' ]; then
                cat
            else
                # Convert xcfg
                # <type> <instance> <num_bytes> <object_bytes...>
                awk '
                    /^\[/ {
                        # Get object number
                        sub(".*_T", "", $1);
                        # Ignore DEBUG_DIAGNOSTIC_T37
                        if ($1 == 37) {
                            object=0
                        } else {
                            if (object) {
                                printf("\n");
                            }
                            object=int($1)
                            if (object) {
                                printf("%04X %04X", object, $3);
                            }
                        }
                        next
                    }
                    /^OBJECT_SIZE/ && object {
                        sub(".*=", "", $1);
                        printf(" %04X", $1);
                        next
                    }
                    /^[0-9]/ && object {
                        sub(".*=", "", $3);
                        if ($2 == 1) {
                            printf(" %02X", $3);
                        } else {
                            printf(" %02X %02X", $3 % 256, $3 / 256);
                        }
                        next
                    }
                    END {
                        if (object) {
                            printf("\n");
                        }
                    }
                '

                # Don't update the xcfg with the checksum
                configfile='-'
            fi
        } | tr -d '' > "$cfg"
    fi
    # Write the config and grab the checksum
    if ! echo > "$write/update_config"; then
        echo "Failed to write config. Does the firmware checksum match?" 1>&2
        exit 1
    fi
    checksum="$(tr [:lower:] [:upper:] < "$write/config_csum")"
    echo "$checksum"
    # Update the files with the correct checksum
    sed -i "4s/.*/$checksum/" "$cfg"
    if [ "$configfile" != '-' ]; then
        sed -i "4s/.*/$checksum/" "$configfile"
    fi

else
    usage
fi
