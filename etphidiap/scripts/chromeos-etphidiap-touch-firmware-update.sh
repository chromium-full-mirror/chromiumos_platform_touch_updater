#!/bin/sh
#
# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-etphidiap-overlay.sh

DEFINE_string 'device' '' "i2c-dev device name e.g. i2c-7" 'd'
DEFINE_string 'device_path' '' "device path in /sys" 'p'
DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Actually trigger a firmware update by running the ELAN update tool in minijail
# to limit the syscalls it can access.
update_firmware() {
  local fw_link=
  local cmd_log=
  local ret=

  # POSIX allows, but does not require, shift to exit a non-interactive shell.
  fw_link="$1"; [ "$#" -gt 0 ] || return; shift

  cmd_log="$(
    minijail0 -u fwupdate-i2c -g fwupdate-i2c \
      -G -I -N -n -p -v --uts \
      -S /opt/google/touch/policies/etphidiap.update.policy -- \
      /usr/sbin/etphid_updater -i "${FLAGS_device#i2c-}" -b "${fw_link}" 2>&1
  )"

  ret="$?"
  if [ "${ret}" -ne 0 ]; then
    die "Exit status ${ret} updating touchpad firmware: ${cmd_log}"
  fi
  return "${ret}"
}

# The on-disk firmware version is determined by parsing the filename of the
# actual firmware file passed as $1, after resolving any symlinks.  The filename
# should be in the format "elan_0xVER.bin" e.g. "elan_0x0A.bin".  The 0x prefix
# is preserved, e.g. if the file is named "elan_0x0A.bin" this function will
# print "0x0A" to stdout.
#
# TODO(https://issuetracker.google.com/79157488): Include hardware ID in the
# firmware filename once it is available.  See
# https://issuetracker.google.com/129152245 for more background.
get_fw_version_from_disk() {
  local fw_link=
  local fw_filepath=
  local fw_filename=
  local fw_ver=

  # POSIX allows, but does not require, shift to exit a non-interactive shell.
  fw_link="$1"; [ "$#" -gt 0 ] || return; shift

  [ -L "${fw_link}" ] || return
  fw_filepath="$(realpath -e "${fw_link}")" || return
  [ -n "${fw_filepath}" ] || return

  fw_filename="$(basename "${fw_filepath}")"
  fw_ver="${fw_filename#*_}"
  fw_ver="${fw_ver%.*}"
  printf '0x%X\n' "${fw_ver}"
}

# Query the touchpad controller for information about its firmware or hardware.
get_active_info() {
  local description=
  local output=
  local ret=

  # POSIX allows, but does not require, shift to exit a non-interactive shell.
  description="$1"; [ "$#" -gt 0 ] || return; shift

  output="$(
    minijail0 -u fwupdate-i2c -g fwupdate-i2c \
      -G -I -N -n -p -v --uts \
      -S /opt/google/touch/policies/etphidiap.query.policy -- \
      /usr/sbin/etphid_updater -i "${FLAGS_device#i2c-}" "$@" 2>&1
  )"

  ret="$?"
  if [ "${ret}" -eq 0 ]; then
    printf '0x%X\n' "0x${output}"
  else
    echo 1>&2 "Exit status ${ret} retrieving touchpad ${description}: ${output}"
  fi
  return "${ret}"
}

# Query the touchpad controller for its current firmware version.
get_active_fw_version() {
  get_active_info "firmware version" -g
}

# Query the touchpad controller for its hardware revision identifier.
get_device_hwid() {
  get_active_info "hardware revision" -w
}

# Query the touchpad controller for its hardware module identifier.
get_device_module_id() {
  get_active_info "module ID" -m
}

assert_is_function_from_overlay() {
  local func_name=

  # POSIX allows, but does not require, shift to exit a non-interactive shell.
  func_name="$1"; [ "$#" -gt 0 ] || return; shift

  type "${func_name}" | head -n 1 | grep -q -E ' ?function$' || die \
"No ${func_name}() function is defined, this is a bug in the board overlay."
}

main() {
  local active_fw_ver=
  local new_fw_ver=
  local update_type=
  local update_needed=
  local fw_link=
  local device_hwid=
  local device_module_id=
  local active_fw_hw_rev=
  local new_fw_hw_rev=
  local chassis_id=
  local board_rev=

  # This script runs early at bootup, so if the touch driver is mistakenly
  # included as a module (as opposed to being compiled directly in) the i2c
  # device may not be present yet. Pause long enough for for people to notice
  # and fix the kernel config.
  check_i2c_chardev_driver

  chassis_id="$(get_chassis_id)"
  log_msg "Chassis identifier detected as: ${chassis_id}"

  board_rev="$(get_platform_ver)"
  log_msg "Platform version detected as: ${board_rev}"

  device_module_id="$(get_device_module_id)"
  [ -n "${device_module_id}" ] || die \
"Unable to determine hardware module of the touchpad device."
  log_msg "Hardware module of the touchpad device: ${device_module_id}"

  device_hwid="$(get_device_hwid)"
  [ -n "${device_hwid}" ] || die \
"Unable to determine hardware revision of the touchpad device."
  log_msg "Hardware revision of the touchpad device: ${device_hwid}"

  active_fw_ver="$(get_active_fw_version)"
  [ -n "${active_fw_ver}" ] || die \
"Unable to determine active firmware version."
  log_msg "Active firmware version: ${active_fw_ver}"

  assert_is_function_from_overlay get_fw_basename
  fw_basename="$(get_fw_basename "${chassis_id}" "${board_rev}" \
"${device_module_id}" "${device_hwid}" "${active_fw_ver}")"
  [ -n "${fw_basename}" ] || die \
"Unable to determine which on-disk firmware to consider flashing."

  fw_link="$(find_fw_link_path "${fw_basename}" "${chassis_id}")"
  [ -n "${fw_link}" ] || die "Unable to determine path of on-disk firmware."
  log_msg "Attempting to load on-disk firmware: ${fw_link}"

  new_fw_ver="$(get_fw_version_from_disk "${fw_link}")"
  log_msg "On-disk firmware version: ${new_fw_ver}"
  [ -n "${new_fw_ver}" ] || die \
"Unable to determine version of on-disk firmware."

  if [ "$(( ${active_fw_ver} == 0xFFFFFFFF ))" -gt 0 ]; then
    log_msg "Active firmware appears to be corrupt, will update firmware."
    update_needed="${FLAGS_TRUE}"
  else
    update_type="$(compare_multipart_version "${active_fw_ver}" \
"${new_fw_ver}")"
    log_update_type "${update_type}"
    update_needed="$(is_update_needed "${update_type}")"
  fi

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Updating firmware to ${new_fw_ver}"
    chromeos-boot-alert update_touchpad_firmware
    run_cmd_and_block_powerd update_firmware "${fw_link}"

    # Check if update was successful
    active_fw_ver="$(get_active_fw_version)"
    update_type="$(compare_multipart_version "${active_fw_ver}" \
      "${new_fw_ver}")"

    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed.  Current firmware version: ${active_fw_ver}"
    fi
    log_msg "Updating firmware succeded.  Firmware version is now: "\
"${active_fw_ver}"

    rebind_driver "${FLAGS_device_path}" /sys/bus/i2c/drivers/i2c_hid
  fi
}

main "$@"
