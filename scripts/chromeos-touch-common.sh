#!/bin/sh

# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

I2C_DEVICES_PATH="/sys/bus/i2c/devices"

# Find touchscreen/pad path in i2c devices given it's device name and a list
# of the sysfs entries it is expect to have (this can help skip over some
# bogus devices that have already been disconnected)
# The required sysfs filenames could be supplied as a space-delimited string
find_i2c_device_by_name() {
  local dev=""
  local name_to_find="$1"
  local required_sysfs="$2"

  for dev in "${I2C_DEVICES_PATH}"/*/name; do
    local dev_name="$(cat "${dev}")"
    if [ "${name_to_find}" = "${dev_name}" ]; then
      local missing_sysfs_entry=0
      local path="${dev%/name}"

      for sysfs in $required_sysfs; do
        if [ ! -e "${path}/${sysfs}" ]; then
          missing_sysfs_entry=1
        fi
      done

      if [ "${missing_sysfs_entry}" -eq 0 ]; then
        echo "${path}"
        return 0
      fi
    fi
  done
  return 1
}

find_i2c_hid_device() {
  local dev=""
  local path=""
  local vid="${1%_*}"
  local pid="${1#*_}"

  for dev in "${I2C_DEVICES_PATH}"/*/; do
    local driver_name="$(readlink -f ${dev}/driver | xargs basename)"
    if [ "i2c_hid" = "${driver_name}" ]; then
      local hid_path=$(echo ${dev}/*:${vid}:${pid}.*)
      if [ -d "${hid_path}" ]; then
        local hidraw_sysfs_path=$(echo ${hid_path}/hidraw/hidraw*)
        path="/dev/${hidraw_sysfs_path##*/}"
        break
      fi
    fi
  done
  echo "${path}"
}

log_msg() {
  local script_filename="$(basename $0)"
  logger -t "${script_filename%.*}[${PPID}]-${FLAGS_device}" "$@"
  echo "$@"
}

die() {
  log_msg "error: $*"
  exit 1
}
