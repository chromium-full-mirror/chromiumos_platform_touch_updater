#!/bin/sh

# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device_name" 'd'

FW_LINK_PATH="/lib/firmware/wacom_firmware.hex"
WACOMFLASH="/usr/sbin/wacom_flash"
GET_ACTIVE_FIRMVER="-a"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  # Actually trigger a firmware update by running the Wacom update tool
  # in minijail to limit the syscalls it can access.
  local cmd_log=""
  cmd_log="$(
    minijail0 -S /opt/google/touch/policies/wacom_flash.update.policy \
      "${WACOMFLASH}" "${FW_LINK_PATH}" \
      ${FLAGS_recovery} ${FLAGS_device} \
      2>&1
  )"

  if [ "$?" -ne 0 ]; then
    die "Error updating touch firmware: ${cmd_log}"
  fi
}

get_fw_version_from_disk() {
  # The on-disk FW version is determined by reading the filename which
  # is in the format "wacom_FWVERSION.hex".  This function just
  # strips away everything but the FW version.
  local fw_filepath=""
  local fw_filename=""
  local fw_ver=""

  if [ ! -L "${FW_LINK_PATH}" ]; then
    return
  fi
  fw_filepath="$(readlink -f "${FW_LINK_PATH}")"
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
      "${WACOMFLASH}" "${FW_LINK_PATH}" "${GET_ACTIVE_FIRMVER}" \
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

  log_msg "Attempting to Load FW: '${FW_LINK_PATH}'"

  active_fw_ver="$(get_active_fw_version)"
  new_fw_ver="$(get_fw_version_from_disk)"
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
    update_firmware

    # Check if update was successful
    active_fw_ver="$(get_active_fw_version)"
    update_type="$(compare_multipart_version "${active_fw_ver}" "${new_fw_ver}")"

    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_ver}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_ver}"
  fi
}

main "$@"
