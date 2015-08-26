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

standard_update_firmware() {
  # Update a touch device by piping a "1" into a sysfs entry called update_fw
  # This is a common method for triggering a FW update, and it used by several
  # different touch vendors.
  local touch_device_path="$1"
  local i=""
  local ret=""

  for i in $(seq 5); do
    printf 1 > "${touch_device_path}/update_fw"
    ret=$?
    if [ ${ret} -eq 0 ]; then
      return 0
    fi
    log_msg "update_firmware try #${i} failed... retrying."
  done
  die "Error updating touch firmware. ${ret}"
}

rebind_driver() {
  # Unbind and then bind the driver for this touchpad incase the recent FW
  # update changed the way it talks to the OS.
  local touch_device_path="$1"
  local bus_id="$(basename ${touch_device_path})"
  local driver_path="$(readlink -f ${touch_device_path}/driver)"

  log_msg "Attempting to re-bind '${bus_id}' to driver '${driver_path}'"
  echo "${bus_id}" > "${driver_path}/unbind"
  if [ "$?" -ne "0" ]; then
    log_msg "Unable to unbind."
  else
    echo "${bus_id}" > "${driver_path}/bind"
    if [ "$?" -ne "0" ]; then
      log_msg "Unable to bind the device back to the driver."
    else
      log_msg "Success."
    fi
  fi
}

hex_to_decimal() {
  printf "%d" "0x""$1"
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
