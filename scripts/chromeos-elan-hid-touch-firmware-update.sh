#!/bin/sh
#
# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# USAGE: ./chromeos-elan-hid-touch-firmware-update.sh -p ${product_id}
# The value of product_id is HID PID of touch device.
# For example: (if HID PID of touch device is 1842)
# ./chromeos-elan-hid-touch-firmware-update.sh -p 1842

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

# Define parameters to pass to script.
# ${device_path}: Device path of the touch device, e.g. "/sys/bus/i2c/devices/i2c-ELAN900C:00"
# Example:
#  ./chromeos-elan-hid-touch-firmware-update.sh -d "/sys/bus/i2c/devices/i2c-ELAN900C:00" -p 10755
DEFINE_string 'device_path' '' "device path of the touch device, e.g. /sys/bus/i2c/devices/i2c-ELAN900C:00" "d"
# ${hid_pid}: HID product ID of the touch device, in decimal (e.g. 10755)
# Example:
#  ./chromeos-elan-hid-touch-firmware-update.sh -d "/sys/bus/i2c/devices/i2c-ELAN900C:00" -p 10755 (with INX panel)
#  ./chromeos-elan-hid-touch-firmware-update.sh -d "/sys/bus/i2c/devices/i2c-ELAN900C:00" -p 12234 (with AUO panel)
#  ./chromeos-elan-hid-touch-firmware-update.sh -d "/sys/bus/i2c/devices/i2c-ELAN900C:00" -p 1842  (Device in recovery mode)
DEFINE_string "hid_pid" "" "HID product ID of the touch device, in decimal (e.g. 10755)" "p"

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

  fw_filepath="$1" || return; shift

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
  local update_needed=${FLAGS_FALSE}
  local recovery_mode=
  local ret=

  hid_pid="$( printf "%x" "${FLAGS_hid_pid}" )"
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
    else
      log_msg "Current Firmware: ${active_fw_ver}"
      log_msg "Updater Firmware: ${fw_version}"

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
      die "Firmware update failed, error_code: ${ret}"
    fi

    # Confirm that the FW was updated by checking the current FW version again.
    active_fw_ver="$(get_active_fw_ver "${hid_pid}")"
    update_type="$(compare_multipart_version "$((0x${active_fw_ver}))" "$((0x${fw_version}))")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_ver}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_ver}"

    # Reset touch with 300 ms for re-enumeration
    rebind_driver "${FLAGS_device_path}"
    sleep 0.3
  fi
}

main "$@"