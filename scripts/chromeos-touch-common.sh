#!/bin/sh

# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

I2C_DEVICES_PATH="/sys/bus/i2c/devices"

# Find touchscreen/pad path in i2c devices.
find_i2c_device_by_name() {
  local dev=""
  local path=""
  local name_to_find="$1"
  local required_sysfs="$2"

  for dev in "${I2C_DEVICES_PATH}"/*/name; do
    local dev_name="$(cat "${dev}")"
    if [ "${name_to_find}" = "${dev_name}" ]; then
      path="${dev%/name}"

      # Skip over bogus nodes in /sys/bus/i2c/devices/ created
      # when the drivers of nonexistent devices exit from probe.
      if [ -n "${required_sysfs}" ] &&
         [ ! -e "${path}/${required_sysfs}" ]; then
        path=""
        continue
      fi
      break
    fi
  done
  echo "${path}"
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
