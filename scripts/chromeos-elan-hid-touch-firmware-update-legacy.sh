#!/bin/sh
#
# Copyright 2019 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# USAGE: ./chromeos-elan-hid-touch-firmware-update-legacy.sh -p ${product_id}
# The value of product_id is HID PID of touch device.
# For example: (if HID PID of touch device is 732)
# ./chromeos-elan-hid-touch-firmware-update-legacy.sh -p 732

# This isn't the exact copy that will be used in production, but it's better
# than pointing shellcheck at /dev/null.
# shellcheck source=../../../scripts/lib/shflags/shflags
. /usr/share/misc/shflags
# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

# Define parameters to pass to script.

DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'

# ${device_path}: Device path of the touch device, e.g. "/sys/bus/i2c/devices/i2c-ELAN900C:00"
# Example:
#  ./chromeos-elan-hid-touch-firmware-update-legacy.sh -d "/sys/bus/i2c/devices/i2c-ELAN900C:00" -p 2A03
DEFINE_string 'device_path' '' "device path of the touch device, e.g. /sys/bus/i2c/devices/i2c-ELAN900C:00" "d"

# ${hid_pid}: HID product ID of the touch device, in heximal (e.g. 2A03)
# Example:
#  ./chromeos-elan-hid-touch-firmware-update-legacy.sh -d "/sys/bus/i2c/devices/i2c-ELAN900C:00" -p 2A03 (with INX panel)
#  ./chromeos-elan-hid-touch-firmware-update-legacy.sh -d "/sys/bus/i2c/devices/i2c-ELAN900C:00" -p 2FCA (with AUO panel)
#  ./chromeos-elan-hid-touch-firmware-update-legacy.sh -d "/sys/bus/i2c/devices/i2c-ELAN900C:00" -p 732  (Device in recovery mode)
DEFINE_string "hid_pid" "" "HID product ID of the touch device, in hexadecimal (e.g. 2A03)" "p"

CONSOLETOOL_DIR=/usr/sbin
FWREAD_TOOL="${CONSOLETOOL_DIR}/elan_i2chid_read_fwid"
FWWRITE_TOOL="${CONSOLETOOL_DIR}/elan_i2chid_iap"
FWID_MAPPING_FILE=/usr/share/elan_i2chid_tools/fwid_mapping_table.txt
FW_LINK_NAME_BASE=elants_i2chid.bin

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  # Attempt to update touch-screen device with the provided firmware.
  # Args:
  #  $1: hid_pid of touch device
  #  $2: Path of firmware file in Elan EKT format
  # Returns:
  #  0x000: Success
  #  0x003: I/O timeout
  #  0x005: Invalid data pattern
  #  0x008: Invalid parameter
  #  0x009: I/O error
  #  0x104: Device not found
  #  0x105: File not found
  local hid_pid="$1"
  local fw_file="$2"

  minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -I -N -n -p -v --uts \
      -c 'cap_dac_override+eip' --ambient \
      -S /opt/google/touch/policies/elani2chid.update.policy -- \
      "${FWWRITE_TOOL}" -P "${hid_pid}" -f "${fw_file}" 2>&1
}

get_active_product_id() {
  # Query the touchscreen and see what the current FW version it's running.
  # Args:
  #  $1: hid_pid of touch device
  #  $2: Path of firmware ID mapping file
  # Returns:
  #  0x000: Success
  #  0x008: Invalid parameter
  #  0x104: Device not found
  #  0x105: File not found
  #  0x701: System command fail
  # Outputs:
  #  ${active_product_id}: A string of hexadecimal value, e.g.: 30e4, 2fca.
  local hid_pid="$1"
  local fw_map_file="$2"
  local command_output=
  local active_product_id=
  local ret=

  command_output="$(
    minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -I -N -n -p -v --uts \
      -c 'cap_dac_override+eip' --ambient \
      -S /opt/google/touch/policies/elani2chid.query.policy -- \
      "${FWREAD_TOOL}" -P "${hid_pid}" -f "${fw_map_file}" -s chrome -q 2>&1
  )"
  ret="$?"

  # Remove Carriage Return
  active_product_id="$( echo "${command_output}" | sed -e 's/\r//g' )"

  if [ "${ret}" -eq 0 ] ; then
    echo "${active_product_id}"
  else
    echo 1>&2 "Exit status ${ret} retrieving touchscreen product ID: ${active_product_id}"
  fi
}

get_fw_version_from_filename() {
  # Get firmware version from firmware filename
  # Args:
  #  $1: Path of firmware file
  # Outputs:
  #  ${fw_version}: Firmware version of this firmware file, e.g.: 5914, 5915
  # Filename format:
  #  ${product_id}_${firmware_version}.bin
  #  ${product_id}: A string of hexadecimal value, e.g.: 30e4, 2fca.
  #  ${firmware_version}: A string of hexadecimal value, e.g.: 5914, 5915.
  # How to parse firmware version form file name:
  #  Get ${firmware_version} part of firename
  # Example:
  #  30e4_5914.bin => 5914
  local fw_filepath=
  local fw_filename=
  local fw_ver=

  # POSIX allows, but does not require, shift to exit a non-interactive shell.
  fw_filepath="$1"; [ "$#" -gt 0 ] || return; shift

  fw_filename="${fw_filepath##*/}"
  fw_ver="${fw_filename#*_}"
  fw_ver="${fw_ver%.*}"

  echo "${fw_ver}"
}

get_active_fw_ver() {
  # Query the touchscreen and see what the current FW version it's running.
  # Args:
  #  $1: hid_pid of touch device
  # Returns:
  #  0x000: Success
  #  0x003: I/O timeout
  #  0x005: Invalid data pattern
  #  0x008: Invalid parameter
  #  0x009: I/O error
  #  0x104: Device not found
  #  0x105: File not found
  # Outputs:
  #  ${active_fw_ver}: A string of hexadecimal value, e.g.: 5914, 5915.
  #  "In Recovery Mode." if touch device is in recovery mode
  local hid_pid="$1"
  local command_output=
  local active_fw_ver=
  local ret=

  command_output="$(
    minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -I -N -n -p -v --uts \
      -c 'cap_dac_override+eip' --ambient \
      -S /opt/google/touch/policies/elani2chid.query.policy -- \
      "${FWWRITE_TOOL}" -P "${hid_pid}" -i -q 2>&1
  )"
  ret="$?"

  # Remove Carriage Return
  active_fw_ver="$( echo "${command_output}" | sed -e 's/\r//g' )"

  if [ "${ret}" -eq 0 ]; then
    echo "${active_fw_ver}"
  else
    echo 1>&2 "Exit status ${ret} retrieving touchscreen firmware version: ${active_fw_ver}"
  fi
}

get_calibration_counter() {
  # Query the touchscreen and see the current counter of calibration.
  # Args:
  #  $1: hid_pid of touch device
  # Returns:
  #  0x000: Success
  #  0x003: I/O timeout
  #  0x005: Invalid data pattern
  #  0x008: Invalid parameter
  #  0x009: I/O error
  #  0x104: Device not found
  #  0x105: File not found
  # Outputs:
  #  ${calibration_counter}: A string of hexadecimal value, e.g.: 0000, 0001, 001e, ffff(not calibrated).
  local hid_pid="$1"
  local command_output=
  local calibration_counter=
  local ret=

  command_output="$(
    minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -I -N -n -p -v --uts \
      -c 'cap_dac_override+eip' --ambient \
      -S /opt/google/touch/policies/elani2chid.query.policy -- \
      "${FWWRITE_TOOL}" -P "${hid_pid}" -c -q 2>&1
  )"
  ret="$?"

  # Remove Carriage Return
  calibration_counter="$( echo "${command_output}" | sed -e 's/\r//g' )"

  if [ "${ret}" -eq 0 ]; then
    echo "${calibration_counter}"
  else
    echo 1>&2 "Exit status ${ret} retrieving touchscreen calibration counter: ${calibration_counter}"
  fi
}

calibrate() {
  # Attempt to calibrate touch-screen device.
  # Args:
  #  $1: hid_pid of touch device
  # Returns:
  #  0x000: Success
  #  0x003: I/O timeout
  #  0x005: Invalid data pattern
  #  0x008: Invalid parameter
  #  0x009: I/O error
  #  0x104: Device not found
  #  0x105: File not found
  # Outputs:
  #  "Re-Calibration success." if calibration is successful.
  #  "Re-Calibration failed! err=${error_code}." if calibration failed.
  local hid_pid="$1"

  minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -I -N -n -p -v --uts \
      -c 'cap_dac_override+eip' --ambient \
      -S /opt/google/touch/policies/elani2chid.query.policy -- \
      "${FWWRITE_TOOL}" -P "${hid_pid}" -k 2>&1
}

main() {
  # Get the HID PID value from the device on the system
  local hid_pid=
  # Hardcode or parameterize the fw_map_file
  local fw_map_file="${FWID_MAPPING_FILE}"
  local active_product_id=
  local active_fw_ver=
  local fw_link_path=
  local fw_version=
  local fw_filename=
  local fw_path=
  local update_type=
  local update_needed="${FLAGS_FALSE}"
  local recovery_mode=
  local ret=
  local not_support_calibration_counter=
  local calibration_counter=

  hid_pid="${FLAGS_hid_pid}"
  echo "hid_pid: ${hid_pid}"
  echo "update_needed: ${update_needed}"

  # This script runs early at bootup, so if the touch driver is mistakenly
  # included as a module (as opposed to being compiled directly in) the i2c
  # device may not be present yet. Pause long enough for for people to notice
  # and fix the kernel config.
  check_i2c_chardev_driver

  # Determine the product ID of the device we're considering updating"
  active_product_id="$(get_active_product_id "${hid_pid}" "${fw_map_file}")"
  echo "active_product_id: ${active_product_id}"

  # Make sure there is a FW that looks like it's for the same product ID
  echo "FW_LINK_NAME_BASE: ${FW_LINK_NAME_BASE}, active_product_id: ${active_product_id}"
  fw_link_path="$(find_fw_link_path "${FW_LINK_NAME_BASE}" "${active_product_id}")"
  log_msg "Attempting to load FW: ${fw_link_path}"
  fw_path="$(readlink "${fw_link_path}")"
  echo "fw_path: \"${fw_path}\""
  if [ ! -e "${fw_link_path}" ] ||
     [ ! -e "${fw_path}" ]; then
    die "No valid firmware for Elan i2chid ${active_product_id} found."
  fi

  # Log "Product ID: <Product ID>" to /var/log/messages for test case parsing
  log_msg "Product ID: ${active_product_id}"

  # Parse out the file name and firmware version from the fw_path.
  fw_version="$(get_fw_version_from_filename "${fw_path}")"
  log_msg "FW version of file: ${fw_version}"
  if [ -z "${fw_version}" ] ; then
    die "Format of fW file name is invalid for Elan i2chid ${active_product_id}."
  fi

  # Select update type
  # Check if device in recovery mode.
  # If previous update process failed, touch device will switch to recovery mode due to its firmware defective.
  # In recovery mode, boot code (boot loader) only serves with firmware update function.
  # And it can enumerate touch device as a HID device with PID 0x732 if system reboots.
  # Thus check for device's HID_PID becoming 0x732 is needed to make sure if it's a recovery update.
  # Besides, touch device will recover its finger report function after system reboot again.
  if [ $((0x${hid_pid})) -eq $((0x0732)) ] ; then
    log_msg "Switch to recovery flow."
    update_type="${UPDATE_NEEDED_RECOVERY}"
    log_update_type "${update_type}"

    report_initial_version "${FLAGS_device_path}" "Elan HID" \
      "${REPORT_VERSION_RECOVERY}"
  else
    # Query the device to get the active FW version.
    active_fw_ver="$(get_active_fw_ver "${hid_pid}")"

    # Sometimes fw update fails but system does not reboot.
    # The touch device will stay in recovery mode.
    # However, if requesting fw version in recovery mode,
    # this tool will only output a string containing of "In Recovery Mode."
    recovery_mode="$( echo "${active_fw_ver}" | grep -c "In Recovery Mode." )"

    if [ "${recovery_mode}" -eq 1 ] ; then
      log_msg "Switch to recovery flow."
      update_type="${UPDATE_NEEDED_RECOVERY}"
      log_update_type "${update_type}"

      report_initial_version "${FLAGS_device_path}" "Elan HID" \
        "${REPORT_VERSION_RECOVERY}"
    else
      log_msg "Current Firmware: ${active_fw_ver}"
      log_msg "Updater Firmware: ${fw_version}"

      report_initial_version "${FLAGS_device_path}" "Elan HID" \
        "${active_fw_ver}"

      # Determine if an update is needed, and if we do, trigger it now
      update_type="$(compare_multipart_version "$((0x${active_fw_ver}))" "$((0x${fw_version}))")"
      log_update_type "${update_type}"
    fi
  fi

  # Update firmware if needed
  update_needed="$(is_update_needed "${update_type}")"
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    fw_filename="${fw_path##*/}"
    log_msg "Update FW with ${fw_filename}."
    update_firmware "${hid_pid}" "${fw_path}"

    # Check that the update was successful.
    ret="$?"
    if [ "${ret}" -ne 0 ] ; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_version}"
      die "Firmware update failed, error_code: ${ret}"
    fi

    # Confirm that the FW was updated by checking the current FW version again.
    active_fw_ver="$(get_active_fw_ver "${hid_pid}")"
    update_type="$(compare_multipart_version "$((0x${active_fw_ver}))" "$((0x${fw_version}))")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_version}"
      die "Firmware update failed. Current Firmware: ${active_fw_ver}"
    fi
    log_msg "Update FW succeeded. Current Firmware: ${active_fw_ver}"
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_ver}"

    # Reset touch with 300 ms for re-enumeration
    rebind_driver "${FLAGS_device_path}"
    sleep 0.3
  fi

  # Check if support calibration counter request function
  calibration_counter="$(get_calibration_counter "${hid_pid}")"
  not_support_calibration_counter="$( echo "${calibration_counter}" | grep -c "invalid option -- 'c'" )"
  if [ "${not_support_calibration_counter}" -eq 1 ] ; then
    log_msg "Not support calibration counter function."
  else
    log_msg "Current calibration counter: ${calibration_counter}"

    # Check if touch device has been calibrated
    if [ $((0x${calibration_counter})) -eq $((0xffff)) ] ; then
      log_msg "Re-calibration is needed since last calibration probably failed."
      calibrate "${hid_pid}"

      # Check that the update was successful.
      ret="$?"
      if [ "${ret}" -eq 0 ] ; then

        # Check if current calibration counter is 0
        calibration_counter="$(get_calibration_counter "${hid_pid}")"
        if [ "${calibration_counter}" -eq 0 ] ; then
          log_msg "Re-calibration is successful & current calibration counter: ${calibration_counter}"
        else
          log_msg "Re-calibration failed. Calibration counter: ${calibration_counter}"
        fi
      else
        log_msg "Re-calibration failed. Error code: ${ret}"
      fi
    fi
  fi
}

main "$@"
