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
    $APP [tp|ts] r[efs]|d[eltas] [d|h] [y] [watch ...]
        Dumps out the ref or delta values, either as decimal (default) or hex.
        Specify the smaller dimension (y) to override the detected value.
        If watch is specified, the remaining arguments are passed to watch.
    $APP [tp|ts] c[alibrate]
        Calibrates the device.
    $APP [tp|ts] w[rite] [config-file]
        Writes a config file to the device, updating the checksum field.
        If config-file is unspecified, uses stdin.
        Prints the updated checksum on stdout and writes them to files.
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
         start && /^\$/ { exit 1 }
         start && (NR-start-1) == $(($2)) { print \$NF; exit 0 }" "$state" \
             | tr -d '()'
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
DEVICE="atmel_mxt_${DEVICE#atmel_mxt_}"

# Must have a command and must be root
if [ "$#" = 0 ] || [ "$USER" != root -a "$UID" != 0 ]; then
    usage
fi

# Detect the input and output object files
for write in '/sys/bus/i2c/devices/'*'/object'; do
    if grep -q "^$DEVICE\$" "${write%/*}/name"; then
        break
    fi
    write=''
done
state="${write%/*}"
state="/sys/kernel/debug/atmel_mxt_ts/${state##*/}/object"
if [ ! -f "$state" -o ! -f "$write" ]; then
    echo "Unable to find device $DEVICE" 1>&2
    exit 2
fi

# Process commands
if [ "${1#[oO]}" != "$1" ]; then
    shift
    if [ "$#" = 0 ]; then
        # Print all objects
        cat "$state"
    elif [ "$#" = 1 ]; then
        # Print specified object
        if ! awk "/^Type: $(($1))\$/ { ok=1 }
                 ok && /^\$/ { exit 0 }
                 ok
                 END { if (!ok) exit 1 }" "$state"; then
            echo "Object not found." 1>&2
            exit 1
        fi
    elif [ "$#" = 2 ]; then
        # Print datum
        value="`getbyte "$1" "$2"`"
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
            value="`bintodec "$value"`"
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
            cur="`getbyte "$1" "$2"`"
            if [ -z "$cur" ]; then
                echo "Object/byte not found." 1>&2
                exit 1
            fi
            value="$(($cur $op $value))"
        fi
        if ! printf '%02x00%02x%02x\n' "$(($1))" "$(($2))" "$value" \
                | tee "$write" 2>/dev/null; then
            echo "Object/byte not found." 1>&2
            exit 1
        fi
    else
        usage
    fi
elif [ "${1#[rRdD]}" != "$1" ]; then
    # Dump refs/deltas
    if [ "${1#[rR]}" != "$1" ]; then
        data="${state%/*}/refs"
        int=u
    else
        data="${state%/*}/deltas"
        int=d
    fi
    shift
    # Generate format. Default to integer if unspecified or invalid.
    format='-An -vt'
    case "${1:-d}" in
        h|x) format="${format}x2";;
        *) format="${format}${int}2";;
    esac
    # Grab the dimension if specified
    dim=''
    if [ "${1#[0-9]}" != "$1" ]; then
        dim="$1"
    elif [ "${2#[0-9]}" != "$2" ]; then
        dim="$2"
    fi
    if [ -z "$dim" ]; then
        local nodes="`wc -c "$data" | awk '{print $1}'`"
        nodes="$(($nodes/2))"
        case "$nodes" in
            209) dim=11;;
            *) echo "No known default dimension for $nodes nodes" 1>&2; exit 2;;
        esac
    fi
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
    echo > "${write%/*}/calibrate"
elif [ "${1#[wW]}" != "$1" ]; then
    # Copy the config onto the device; update and print checksum
    input="${2:-"-"}"
    if [ "$input" != '-' -a ! -f "$input" ]; then
        echo "Unable to find $input" 1>&2
        exit 2
    fi
    if ! mount -o remount,rw /; then
        echo \
'You need to run `make_dev_ssd.sh --remove_rootfs_verification` and reboot.
You may want to run `crossystem dev_boot_signed_only=0` as well.' 1>&2
        exit 2
    fi
    # Determine the destination file
    cfg="`readlink -m "/lib/firmware/maxtouch-${DEVICE##*_}.cfg"`"
    # Make a backup
    if [ -f "$cfg" -a ! -f "$cfg.bak" ]; then
        cp "$cfg" "$cfg.bak"
        echo "Configuration backed up to $cfg.bak" 1>&2
    fi
    # Copy in the new file, assuming the source is not the destination
    if [ "$input" = '-' -o ! -f "$cfg" ] \
            || [ "`stat -Lc '%i' "$input"`" != "`stat -Lc '%i' "$cfg"`" ]; then
        cat "$input" > "$cfg"
    fi
    # Write the config and grab the checksum
    if ! echo > "${write%/*}/update_config"; then
        echo "Failed to write config. Does the firmware checksum match?" 1>&2
        exit 1
    fi
    checksum="`tr [:lower:] [:upper:] < "${write%/*}/config_csum"`"
    echo "$checksum"
    # Update the files with the correct checksum
    sed -i "4s/.*/$checksum/" "$cfg"
    if [ "$input" != '-' ]; then
        sed -i "4s/.*/$checksum/" "$input"
    fi
else
    usage
fi
