#!/bin/sh
#
# Copyright 2024 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# USAGE: ./chromeos-focal-hid-forcepad-firmware-update-legacy.sh
# -d ${device_path} -p ${product_id}.
# The value of product_id is HID PID of touch device , in heximal(e.g. 0301).
# The value of device_path is path of the touch device(e.g. "/dev/hidraw0").
# Example:
# ./chromeos-focal-hid-forcepad-firmware-update-legacy.sh
# -d "/dev/hidraw0" -p 0301

# shellcheck source=../../../scripts/lib/shflags/shflags
. /usr/share/misc/shflags

# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

# Define parameters to pass to script.
# ${device_path}:path of the touch device,
# e.g."/sys/bus/hid/devices/0018:2808:0101.0002"
# ${hid_pid}: HID product ID of the touch device, in heximal (e.g. 2A03).

DEFINE_string 'device_path' '' "device path of the touch device" "d"
DEFINE_string "hid_pid" "" "HID product ID of the device,in hex(e.g.0101)" "p"
DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'

CONSOLETOOL_DIR=/usr/sbin
FOCALTECH_TOOL="${CONSOLETOOL_DIR}/ftphid_ezupg_ap"
FW_LINK_NAME_BASE=focal_hid.bin

FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  # Attempt to update hid device with the firmware file.
  # Args:
  #  $1: Path of firmware file.
  #  $2: Product ID.
  # Returns:
  #  0x000: Success.
  #  other: Fail.
  local fw_file="$1"
  local pid="$2"

  minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -v -P /mnt/empty -b / -b /dev,,1 -b /sys \
      -b /proc/ -t --uts -e -l -p -N -n \
      -S /opt/google/touch/policies/focaltech.update.policy -- \
      "${FOCALTECH_TOOL}" -u "${fw_file}" -P "${pid}" 2>&1
}


get_fw_version_from_filename() {
  # Get firmware version from firmware filename.
  # Args:
  #  $1: Path of firmware file
  # Filename format:
  #  ${product_id}_${firmware_version}.bin
  # Outputs:
  #  ${fw_version}: Firmware version of this firmware file, e.g.: 401 ,501
  # Example:
  #  2808_501.bin => 501

  # Check if the required parameter is provided before using it
  [ "$#" -gt 0 ] || return

  local fw_filepath="$1"
  local fw_filename=
  local fw_ver=

  fw_filename="${fw_filepath##*/}"
  fw_ver="${fw_filename#*_}"
  fw_ver="${fw_ver%.*}"
  echo "${fw_ver}"
}


get_active_fw_ver() {
  # Query the touch controllers and see what the current FW version it's running.
  # Args:
  #  $1: hid_pid of touch device.
  # Returns:
  #  0x000: Error.
  #  others: Fail.
  # Outputs:
  #  ${active_fw_ver}: A string of hexadecimal value, e.g.: 401 ,601.
  local command_output=
  local active_fw_ver=
  local ret=
  local pid="$1"
  command_output="$(
    minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -v -P /mnt/empty -b / -b /dev,,1 -b /sys \
      -b /proc/ -t --uts -e -l -p -N -n \
      -S /opt/google/touch/policies/focaltech.query.policy -- \
      "${FOCALTECH_TOOL}" -f -P "${pid}"  2>&1
  )"
  ret="$?"

  # Remove Carriage Return.
  active_fw_ver="$( echo "${command_output}" | sed -e 's/\r//g' )"

  if [ "${ret}" -eq 0 ]; then
    echo "${active_fw_ver}"
  else
    echo 1>&2 "Exit status ${ret} retrieving HID fw version:${active_fw_ver}"
  fi
}

get_tool_version() {
  # Get updater tool version.
  # Args:
  #  $1: hid_pid of touch device.
  # Outputs:
  #  ${tool_version}: Updater tool version, e.g.: 2.4_2025-02-25
  local tool_version
  local pid="$1"

  tool_version="$(
    minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -v -P /mnt/empty -b / -b /dev,,1 \
      -t --uts -e -l -p -N -n \
      -S /opt/google/touch/policies/focaltech.query.policy -- \
      "${FOCALTECH_TOOL}" -v -P "${pid}"  2>&1
  )"
  echo -n "${tool_version}" | tr -d '\n\r '
}

main() {

  local active_product_id=
  local active_fw_ver=
  local fw_link_path=
  local fw_version=
  local fw_filename=
  local fw_path=
  local update_type=
  local update_needed="${FLAGS_FALSE}"
  local ret=

  # Determine the product ID of the device we're considering updating.
  active_product_id="${FLAGS_hid_pid}"
  log_msg "active_product_id: ${active_product_id}"

  report_tool_version "${FLAGS_device_path}" "$(basename "${FOCALTECH_TOOL}")" \
    "$(get_tool_version "${active_product_id}")"


  # Find the firmware that the updater is considering flashing
  # on the touch device.
  log_msg "FW_LINK_NAME_BASE: ${FW_LINK_NAME_BASE}, active_product_id: ${active_product_id}"
  fw_link_path="$(find_fw_link_path "${FW_LINK_NAME_BASE}" "${active_product_id}")"
  log_msg "Attempting to load FW: ${fw_link_path}"
  fw_path="$(readlink "${fw_link_path}" "-f")"
  log_msg "fw_path: \"${fw_path}\""

  if [ ! -e "${fw_link_path}" ] ||
     [ ! -e "${fw_path}" ]; then
    die "No match firmware for FocalTech with pid = ${active_product_id} found."
  fi


  # Get file name and firmware version from the fw_path.
  fw_ver="$(get_fw_version_from_filename "${fw_path}")"

  if [ -z "${fw_ver}" ] ; then
    die "Format of FW file name is invalid for FocalTech i2chid ${active_product_id}."
  fi

  active_fw_ver="$(get_active_fw_ver "${active_product_id}")"

  report_initial_version "${FLAGS_device_path}" "FocalTech" \
    "${active_fw_ver}"

  # Compare the two versions, and see if an update is needed.
  log_msg "Current Firmware: ${active_fw_ver}"
  log_msg "Updater Firmware: ${fw_ver}"

  if [ "$((0x${active_fw_ver}))" -eq "$((0x6A00))" ] ||
     [ "$((0x${active_fw_ver}))" -eq "$((0x6B00))" ] ||
     [ "$((0x${active_fw_ver}))" -eq "$((0x0104))" ]; then
    log_msg "Stuck in Bootload mode, firmware update is required!"
    update_type="${UPDATE_NEEDED_RECOVERY}"
  else
    update_type="$(compare_multipart_version "$((0x${active_fw_ver}))" "$((0x${fw_ver}))")"
  fi

  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # Update firmware if needed.
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW with ${fw_path}"
    update_firmware "${fw_path}" "${active_product_id}"

    # Check that the update was successful.
    ret="$?"
    if [ "${ret}" -ne 0 ] ; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_ver}"
      die "Firmware update failed, error_code: ${ret}"
    fi

    # Reset touch with 50 ms for re-enumeration.
    rebind_driver "${FLAGS_device_path}"
    sleep 0.05

    # Confirm that the FW was updated by checking the current FW version again.
    active_fw_ver="$(get_active_fw_ver "${active_product_id}")"

    update_type="$(compare_multipart_version "$((0x${active_fw_ver}))" "$((0x${fw_ver}))")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_ver}"
      die "Firmware update failed. Current Firmware: ${active_fw_ver}"
    fi
    log_msg "Firmware update succeeded. Current Firmware: ${active_fw_ver}"
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_ver}"
  fi
}

main "$@"
