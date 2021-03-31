#!/bin/sh
# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

# shellcheck disable=SC2034
# shellcheck disable=SC2248
DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "Hidraw device node path. Checks a specific hidraw \
  device to update" 'd'

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

MELFAS_FW_UPDATE_USER="fwupdate-hidraw"
MELFAS_FW_UPDATE_GROUP="hidraw"
FW_LINK_NAME="melfas_mip4.bin"
MELFAS_TOOL="/usr/sbin/melfas_update_tool"
MELFAS_PRODUCT_ID="8103"
MELFAS_VID="1FD2"

minijail_tool() {
  local policy="/opt/google/touch/policies/mfsupdate.${1}.policy"
  shift
  minijail0 -u "${MELFAS_FW_UPDATE_USER}" -g "${MELFAS_FW_UPDATE_GROUP}" \
            -v -P /mnt/empty -b / -b /proc -t -b /dev,,1 -b /sys \
            --uts -e -l -p -N -G -n -S "${policy}" "${MELFAS_TOOL}" "$@"
}

update_firmware() {
  local fw_path="$1"
  local melfas_hidraw_path="$2"
  local ret
  local cmd_log=""
  local i

  for i in $(seq 3); do
    cmd_log="$(minijail_tool update -fw_update "${MELFAS_PRODUCT_ID}" \
                             "${melfas_hidraw_path}" "${fw_path}" "1")"

    ret=$?
    # shellcheck disable=SC2248
    if [ ${ret} -eq 0 ]; then
      return 0
    fi
    log_msg "FW update attempt #${i} failed: ${cmd_log}"
  done
  die "Error updating touch firmware. ${ret}"
}

get_active_fw_version() {
  local mfs_log=""
  local melfas_hidraw_path="$1"

  # Get the fw version of this device.
  mfs_log="$(minijail_tool query -fw_version "${MELFAS_PRODUCT_ID}" \
                           "${melfas_hidraw_path}")"

  echo "${mfs_log}" | cut -d " " -f 3
}

compare_fw_versions() {
  local active_fw_version="$1"
  local fw_version="$2"

  compare_multipart_version "${active_fw_version}" "${fw_version}"
}

melfas_mode_change() {
  local mode="$1"
  local melfas_hidraw_path="$2"

  minijail_tool query "${mode}" "${MELFAS_PRODUCT_ID}" "${melfas_hidraw_path}"
}

find_hid_link_path() {
  # Finds the attached Melfas device in the USB part of sysfs, and returns the
  # path to that. An example path is
  # /sys/devices/pci0000:00/0000:00:14.0/usb1/1-10/1-10:1.1/0003:1FD2:8103.0006

  local dev
  for dev in /sys/bus/hid/devices/*; do
    # Skip failed glob expansion.
    if [ "${dev}" = '/sys/bus/hid/devices/*' ]; then
      continue
    fi

    # shellcheck disable=SC2155
    local hidname="$(echo "${dev##*/}" | awk -F'[:.]' '{ print $2 "_" $3 }')"
    local vendor_id="${hidname%_*}"
    local product_id="${hidname#*_}"
    # shellcheck disable=SC2155
    local hid_link_path="$(readlink -f "${dev}")"

    # The 8103 product exposes two USB interfaces, of which we need the second.
    local interface_id="${hid_link_path%/*}"
    interface_id="${interface_id##*.}"

    if [ "${vendor_id}" = "${MELFAS_VID}" ] && \
       [ "${product_id}" = "${MELFAS_PRODUCT_ID}" ] && \
       [ "${interface_id}" -eq 1 ]; then
      echo "${hid_link_path}"
      return
    fi
  done
  die "Could not find HID device with matching vendor and input IDs."
}

get_melfas_hidraw() {
  # Returns the path to the hidraw device node for the Melfas device, for
  # example "/dev/hidraw2". This function also ensures that the permissions of
  # the device are correct.

  local touch_device=""

  # shellcheck disable=SC2155
  local hid_link_path="$(find_hid_link_path)"

  # Find the device path if it exists "/dev/hidrawX".
  # shellcheck disable=SC2155
  local hid_path="$(echo "${hid_link_path}"/hidraw/hidraw*)"
  touch_device="/dev/${hid_path##*/}"

  # Detect failed glob expansion.
  if [ "${touch_device}" = '/dev/hidraw*' ]; then
    die "Failed to locate hidraw device node for ${hid_link_path}."
  fi

  fix_melfas_hidraw_permissions "${touch_device}"

  echo "${touch_device}"
}

fix_melfas_hidraw_permissions() {
  # Modifies the ownership and group of the provided hidraw touch device.
  # Initially, the udev rule takes care of this, but the mode changes and the
  # firmware update step appear to cause the hidraw node to be re-enumerated,
  # resetting its permissions and ownership. The udev rule is not applied when
  # this happens, we think because a udev trigger (this script) is still
  # running, so we have to set them again ourselves.
  local melfas_touch_hidraw="$1"

  chgrp hidraw "${melfas_touch_hidraw}"
  chown root "${melfas_touch_hidraw}"
  chmod 660 "${melfas_touch_hidraw}"
}


main() {
  local active_product_id=""
  local active_fw_version=""
  local fw_link_path=""
  local fw_path=""
  local fw_filename=""
  local fw_name=""
  local update_type=""
  local update_needed=${FLAGS_FALSE}
  local product_id=""
  local fw_version=""
  local hidraw_node="${FLAGS_device}"

  active_product_id="${MELFAS_PRODUCT_ID}"

  # Check if the hidraw node passed to the script is equal to the melfas hidraw
  # node. If not return early.
  melfas_touch_hidraw="$(get_melfas_hidraw)"
  if [ "${melfas_touch_hidraw}" != "${hidraw_node}" ]; then
    log_msg "Melfas hidraw update device does not match: ${melfas_touch_hidraw}"
    exit 1
  fi
  log_msg "Found hidraw node: ${melfas_touch_hidraw}"

  # Find the firmware version and product ID
  fw_link_path="$(find_fw_link_path "${FW_LINK_NAME}" "${active_product_id}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  fw_path="$(readlink "${fw_link_path}")"
  log_msg "fw_path: '${fw_path}'"

  if [ ! -e "${fw_link_path}" ] ||
     [ ! -e "${fw_path}" ]; then
    die "No valid firmware for melfas-${active_product_id} found."
  fi

  fw_filename=${fw_path##*/}
  fw_name=${fw_filename%.bin}

  product_id=${fw_name##*_}

  fw_version=${fw_name%_*}
  fw_version=${fw_version##*_}

  if [ -n "${active_product_id}" ] &&
     [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "Current product id: ${active_product_id}"
    log_msg "Updater product id: ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Get the current FW version that's loaded on the touch IC.
  active_fw_version="$(get_active_fw_version "${melfas_touch_hidraw}")"
  log_msg "Product ID: ${product_id}"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"

  # Determine if an update is needed, and if we do, trigger it now.
  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Updating FW to ${fw_filename}..."

    # mode to boot
    melfas_mode_change "-bl_mode" "${melfas_touch_hidraw}"
    sleep 2

    melfas_touch_hidraw="$(get_melfas_hidraw)"
    update_firmware "${fw_path}" "${melfas_touch_hidraw}"
    sleep 2

    # mode to app
    melfas_touch_hidraw="$(get_melfas_hidraw)"
    melfas_mode_change "-app_mode" "${melfas_touch_hidraw}"
    sleep 2

    melfas_touch_hidraw="$(get_melfas_hidraw)"
    active_fw_version="$(get_active_fw_version "${melfas_touch_hidraw}")"

    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
    # shellcheck disable=SC2154
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeeded. Current Firmware: ${active_fw_version}"
  fi

  exit 0
}

main "$@"
