#!/bin/sh

# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device_name" 'd'
DEFINE_string 'device_path' '' "device path" 'p'

FW_LINK_BASE="wacom_firmware.hex"
FW_LINK_BASE_V2="wacom2_firmware.hex"
WACOMFLASH="/usr/sbin/wacom_flash"
GET_ACTIVE_FIRMVER="-a"
GET_TOUCH_HWID="-h"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  # Actually trigger a firmware update by running the Wacom update tool
  # in minijail to limit the syscalls it can access.
  local fw_link="$1"
  local cmd_log=""
  cmd_log="$(
    minijail0 -S /opt/google/touch/policies/wacom_flash.update.policy \
      "${WACOMFLASH}" "${fw_link}" ${FLAGS_recovery} ${FLAGS_device} 2>&1
  )"

  if [ "$?" -ne 0 ]; then
    die "Error updating touch firmware: ${cmd_log}"
  fi
}

get_fw_version_from_disk() {
  # The on-disk FW version is determined by reading the filename which
  # is in the format "wacom_FWVERSION.hex".  We follow the fw's link
  # to the actual file then strip away everything in the FW's filename
  # but the FW version.
  local fw_link="$1"
  local fw_filepath=""
  local fw_filename=""
  local fw_ver=""

  if [ ! -L "${fw_link}" ]; then
    return
  fi
  fw_filepath="$(readlink -f "${fw_link}")"
  if [ ! -e "${fw_filepath}" ]; then
    return
  fi

  fw_filename="$(basename "${fw_filepath}")"
  fw_ver="${fw_filename#*_}"
  fw_ver="${fw_ver%.*}"
  echo "${fw_ver}"
}

get_active_fw_version() {
  # Query the touchscreen and see what the current FW version it's running.
  local active_fw_ver=""

  active_fw_ver="$(
    minijail0 -S /opt/google/touch/policies/wacom_flash.query.policy \
      "${WACOMFLASH}" "dummy_unused_argument" "${GET_ACTIVE_FIRMVER}" \
      "${FLAGS_device}"
  )"
  if [ "$?" -eq 0 ]; then
    echo "${active_fw_ver}"
  fi
}

get_product_id() {
  # Query the touchscreen and get the product id
  local product_id=""
  local cmd_log=""

  cmd_log="$(
    minijail0 -S /opt/google/touch/policies/wacom_flash.query.policy \
      "${WACOMFLASH}" "dummy_unused_argument" "${GET_ACTIVE_FIRMVER}" \
      "${FLAGS_device}" 2>&1
  )"
  product_id="${cmd_log#*PID:0x}"
  product_id="${product_id%% *}"

  if [ "$?" -eq 0 ]; then
    echo "${product_id}"
  fi
}

get_hardware_id() {
  # Query the touchscreen and get the hardware id (vendor_id+product_id).
  local hardware_id=""

  hardware_id="$(
    minijail0 -S /opt/google/touch/policies/wacom_flash.query.policy \
      "${WACOMFLASH}" "dummy_unused_argument" "${GET_TOUCH_HWID}" \
      "${FLAGS_device}" 2>/dev/null
  )"

  if [ "$?" -eq 0 ] && [ "${hardware_id}" != "0000_0000" ]; then
    echo "${hardware_id}"
  fi
}

main() {
  # This script runs early at bootup, so if the touch driver is mistakenly
  # included as a module (as opposed to being compiled directly in) the i2c
  # device may not be present yet. Pause long enough for for people to notice
  # and fix the kernel config.
  check_i2c_chardev_driver

  local active_fw_ver=""
  local new_fw_ver=""
  local update_type=""
  local update_needed=""
  local fw_link=""
  local product_id=""

  local hardware_id="$(get_hardware_id)"
  local chassis_id="$(get_chassis_id)"
  local board_rev="$(get_platform_ver)"

  log_msg "Chassis identifier detected as: ${chassis_id}"
  log_msg "Platform version detected as: ${board_rev}"
  log_msg "Wacom device hardware ID dectected as: ${hardware_id}"

  if [ "${hardware_id}" = "2d1f_4876" ] && [ "${chassis_id}" = "SORAKA" ] \
       && [ "${board_rev}" -lt "5" ]; then
    # Special case: Soraka < rev5 with Laibao panel cannot handle latest fw.
    log_msg "Soraka legacy (Laibao) special case"
    fw_link="/lib/firmware/wacom2_firmware_4876_evt2_or_below.hex"
    log_msg "Attempting to find special FW: ${fw_link}"

  elif [ -z "${hardware_id}" ]; then
    product_id="$(get_product_id)"
    log_msg "Device product id dectected as: ${product_id}"

    fw_link="$(find_fw_link_path "${FW_LINK_BASE_V2}" "${product_id}")"
    log_msg "Attempting to find FW_V2: ${fw_link}"

    if [ -L "${fw_link}" ]; then
      log_msg "Wacom fw v2 found."
    else
      log_msg "Wacom fw v2 not found. Will use v1."
      fw_link="$(find_fw_link_path "${FW_LINK_BASE}" "${chassis_id}")"
      log_msg "Attempting to Load FW: '${fw_link}'"
    fi
  else
    product_id=${hardware_id#*_}
    log_msg "Wacom device Product ID (derived from hardware ID): ${product_id}"
    fw_link="$(find_fw_link_path "${FW_LINK_BASE_V2}" "${hardware_id}" \
      "${product_id}")"
    log_msg "Attempting to find FW_V2: ${fw_link}"

    if [ -L "${fw_link}" ]; then
      log_msg "Wacom fw v2 found."
    else
      log_msg "Wacom fw v2 not found. Will use v1."
      fw_link="$(find_fw_link_path "${FW_LINK_BASE}" "${hardware_id}" \
        "${product_id}")"
      log_msg "Attempting to Load FW: '${fw_link}'"
    fi
  fi

  active_fw_ver="$(get_active_fw_version)"
  new_fw_ver="$(get_fw_version_from_disk "${fw_link}")"
  log_msg "Active firmware version: ${active_fw_ver}"
  log_msg "New firmware version: ${new_fw_ver}"
  if [ -z "${active_fw_ver}" ]; then
    die "Unable to determine active FW version."
  fi
  if [ -z "${new_fw_ver}" ]; then
    die "Unable to find new FW version on disk."
  fi

  update_type="$(compare_multipart_version "${active_fw_ver}" "${new_fw_ver}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${new_fw_ver}"
    run_cmd_and_block_powerd update_firmware "${fw_link}"

    # Check if update was successful
    active_fw_ver="$(get_active_fw_version)"
    update_type="$(compare_multipart_version "${active_fw_ver}" "${new_fw_ver}")"

    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_ver}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_ver}"

    rebind_driver "${FLAGS_device_path}"
  fi

  exit 0
}

main "$@"
