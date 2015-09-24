#!/bin/sh

# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'

RMI4UPDATE="/usr/sbin/rmi4update"
SYNAPTICS_VENDOR_ID="06CB"


# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  local i
  local ret

  for i in $(seq 5); do
    ${RMI4UPDATE} -f -d "$1" "$2"

    ret=$?
    if [ ${ret} -eq 0 ]; then
      return 0
    fi
    log_msg "FW update attempt #${i} failed... retrying."
  done
  die "Error updating touch firmware. ${ret}"
}

get_active_firmware_version() {
  local touch_device_path="$1"
  ${RMI4UPDATE} -p -d "${touch_device_path}"
}

find_fw_path() {
  local hw_version="$1"
  local fw_link_name="$2"
  local fw_link_path="$(find_fw_link_path $hw_version $fw_link_name)"
  local fw_path="$(readlink "${fw_link_path}")"

  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${FLAGS_device} found."
  fi

  echo "${fw_path}"
}


update_needed=${FLAGS_FALSE}
compute_if_update_is_needed() {
  local fw_version="$1"
  local fw_version_major=""
  local fw_version_minor=""
  local fw_version_build_hex=""
  local fw_version_build=""

  local active_fw_version="$2"
  local active_fw_version_major=""
  local active_fw_version_minor=""
  local active_fw_version_build=""

  local minor_build_tmp=""
  local verbose="$3"

  # Synaptics FWs are in the format major.minor.build (eg: 1.7.1e4aa0) so
  # the next step is to parse those values out.
  # Note: that due to an unfortunate quirk, the "active" build number is in hex
  #       but the other is not, so we must covert it here to compare them
  active_fw_version_major=${active_fw_version%%.*}
  minor_build_tmp=${active_fw_version#$active_fw_version_major.}
  active_fw_version_minor=${minor_build_tmp%.*}
  active_fw_version_build_hex=${minor_build_tmp#*.}
  active_fw_version_build=$(hex_to_decimal "${active_fw_version_build_hex}")

  fw_version_major=${fw_version%%.*}
  minor_build_tmp=${fw_version#$fw_version_major.}
  fw_version_minor=${minor_build_tmp%.*}
  fw_version_build=${minor_build_tmp#*.}

  # Print out the values into the debug logs
  if [ -n "${verbose}" ]; then
    log_msg "Current FW: ${active_fw_version_major}.${active_fw_version_minor}.${active_fw_version_build}"
    log_msg "Updater FW: ${fw_version_major}.${fw_version_minor}.${fw_version_build}"
  fi

  # Compare the version numbers in order of decreasing significance
  update_needed=${FLAGS_FALSE}
  if [ "${active_fw_version_major}" -lt "${fw_version_major}" ]; then
    update_needed=${FLAGS_TRUE}
  elif [ "${active_fw_version_major}" -eq "${fw_version_major}" ]; then
    if [ "${active_fw_version_minor}" -lt "${fw_version_minor}" ]; then
      update_needed=${FLAGS_TRUE}
    elif [ "${active_fw_version_minor}" -eq "${fw_version_minor}" ]; then
      if [ "${active_fw_version_build}" -lt "${fw_version_build}" ]; then
        update_needed=${FLAGS_TRUE}
      elif [ "${active_fw_version_build}" -eq "${fw_version_build}" ]; then
        if [ -n "${verbose}" ]; then
          log_msg "FW up-to-date."
        fi
        return 0
      fi
    fi
  fi
  if [ ${update_needed} -eq ${FLAGS_TRUE} ]; then
    if [ -n "${verbose}" ]; then
      log_msg "FW out of date."
    fi
  elif [ ${FLAGS_recovery} -eq ${FLAGS_TRUE} ]; then
    if [ -n "${verbose}" ]; then
      log_msg "Recovery firmware update. Rolling back to ${fw_version}."
    fi
    update_needed=${FLAGS_TRUE}
  fi
}

main() {
  local trackpad_device_name="${FLAGS_device}"
  local touch_device_path=""
  local active_product_id=""
  local active_fw_version=""
  local product_id=""
  local fw_link_path=""
  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi

  # Find the device path if it exists "/dev/hidrawX"
  touch_device_path="$(find_i2c_hid_device ${trackpad_device_name##*-})"
  log_msg "touch_device_path: '${touch_device_path}'"
  if [ -z "${touch_device_path}" ]; then
    die "${trackpad_device_name} not found on system. Aborting update."
  fi

  # Find the active fw version and the product ID currently in use
  active_product_id="${trackpad_device_name##*_}"
  log_msg "active_product_id: '${active_product_id}'"
  active_fw_version="$(get_active_firmware_version "${touch_device_path}")"
  log_msg "active_fw_version: '${active_fw_version}'"

  # Find the fw version and product ID on disk
  fw_path="$(find_fw_path ${active_product_id} ${FLAGS_device})"
  fw_name="$(basename "${fw_path}" | sed "s/.bin$//")"

  log_msg "fw path: '${fw_path}'"
  product_id=${fw_name%_*}
  fw_version=${fw_name#"${product_id}_"}

  # Check to make sure we found the device we're expecting.  If the product
  # IDs don't match, abort immediately to avoid flashing the wrong device.
  if [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "Current product id : ${active_product_id}"
    log_msg "Updater product id  : ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Check if we need to do an update.  If not, exit immediately
  compute_if_update_is_needed "${fw_version}" "${active_fw_version}" "verbose"
  if [ "${update_needed}" -eq ${FLAGS_FALSE} ]; then
    log_msg "No update needed."
    return 0
  fi

  # Since we're still here, we need an update.  Start it now.
  log_msg "Attempting to update FW to ${fw_name}"
  update_firmware "${touch_device_path}" "${fw_path}"

  # Confirm that the FW was updated by checking the current FW version again
  fw_version_after_update="$(get_active_firmware_version "${touch_device_path}")"
  log_msg "After update, FW version: '${fw_version_after_update}'"
  compute_if_update_is_needed "${fw_version}" "${fw_version_after_update}"

  if [ "${update_needed}" -eq ${FLAGS_TRUE} ]; then
    die "Firmware update failed! Current Firmware: ${fw_version_after_update}"
  fi
  log_msg "Update FW succeded."

  exit 0
}

main "$@"
