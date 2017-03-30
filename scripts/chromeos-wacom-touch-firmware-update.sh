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
WACOMFLASH="/usr/sbin/wacom_flash"
GET_ACTIVE_FIRMVER="-a"

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

i2c_chardev_present() {
  # This function tests to see if there are any i2c char devices on the system.
  # It returns 0 iff /dev/i2c-* matches at least one file.
  local f=""
  for f in /dev/i2c-*; do
    if [ -e "${f}" ]; then
      return 0
    fi
  done
  return 1
}

main() {
  # Check to make sure the required drivers are already availible.  This script
  # runs early at bootup, so if the touch driver is mistakenly included as a
  # module (as opposed to being compiled directly in) the i2c device may not be
  # present yet.
  if ! i2c_chardev_present; then
    modprobe i2c-dev
    log_msg "Please compile I2C_CHARDEV into the kernel"
    log_msg "Sleeping 15s to wait for them to show up"

    # Pause long enough for for people to notice and fix the kernel config.
    # Without this the added delay is small enough that a human might not
    # notice that they had just slowed down the boot time by removing the
    # driver from the kernel.
    sleep 15
  fi

  local active_fw_ver=""
  local new_fw_ver=""
  local update_type=""
  local update_needed=""

  local chassis_id="$(get_chassis_id)"
  log_msg "Chassis identifier detected as '${chassis_id}'"
  local fw_link="$(find_fw_link_path "${chassis_id}" "${FW_LINK_BASE}")"
  log_msg "Attempting to Load FW: '${fw_link}'"

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
    update_firmware "${fw_link}"

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
