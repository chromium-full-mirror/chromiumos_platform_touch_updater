#!/bin/sh
#
# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

overlay_sh_exist=0
OVERLAY_FILE=/opt/google/touch/scripts/chromeos-etphidiap-overlay.sh
if [ -f "${OVERLAY_FILE}" ]; then
  overlay_sh_exist=1
  # shellcheck source=/opt/google/touch/scripts/chromeos-etphidiap-overlay.sh
  . "${OVERLAY_FILE}"
fi

DEFINE_string 'device' '' "i2c-dev device name e.g. i2c-7" 'd'
DEFINE_string 'device_path' '' "device path in /sys" 'p'
DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Actually trigger a firmware update by running the ELAN update tool in minijail
# to limit the syscalls it can access.
update_firmware() {
  local fw_link="$1"
  local fw_version="$2"
  local cmd_log=
  local ret=

  cmd_log="$(
    minijail0 -u fwupdate-i2c -g fwupdate-i2c \
      -G -I -N -n -p -v --uts \
      -S /opt/google/touch/policies/etphidiap.update.policy -- \
      /usr/sbin/etphid_updater -i "${FLAGS_device#i2c-}" -b "${fw_link}" 2>&1
  )"

  ret="$?"
  if [ "${ret}" -ne 0 ]; then
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
      "${fw_version}"
    die "Exit status ${ret} updating touchpad firmware: ${cmd_log}"
  fi
  return "${ret}"
}

update_eeprom_firmware() {
  local fw_link="$1"
  local fw_version="$2"
  local cmd_log=
  local ret=

  cmd_log="$(
    minijail0 -u fwupdate-i2c -g fwupdate-i2c \
      -G -I -N -n -p -v --uts \
      -S /opt/google/touch/policies/etphidiap.update.policy -- \
      /usr/sbin/etphid_updater -i "${FLAGS_device#i2c-}" -E "${fw_link}" 2>&1
  )"

  ret="$?"
  if [ "${ret}" -ne 0 ]; then
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
      "${fw_version}"
    die "Exit status ${ret} updating touchpad EEPROM firmware: ${cmd_log}"
  fi
  return "${ret}"
}

update_firmware_region() {
  local region_id="$1"
  local cmd_log=
  local ret=

  cmd_log="$(
    minijail0 -u fwupdate-i2c -g fwupdate-i2c \
      -G -I -N -n -p -v --uts \
      -S /opt/google/touch/policies/etphidiap.update.policy -- \
      /usr/sbin/etphid_updater -i "${FLAGS_device#i2c-}" -R "${region_id}" 2>&1
  )"

  ret="$?"
  if [ "${ret}" -ne 0 ]; then
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
      "${region_id}"
    die "Exit status ${ret} updating touchpad firmware region: ${cmd_log}"
  fi
  return "${ret}"
}

# The on-disk firmware version is determined by parsing the filename of the
# actual firmware file passed as $1, after resolving any symlinks. The filename
# should be in the format "elan_0xVER.bin" e.g. "elan_0x0A.bin", or without
# board overlay script file then compatible with elan_i2c driver firmware file
# format "{module_id}_{fw_ver}.bin" e.g "182.0_1.0.bin".
# The 0x prefix is preserved, e.g. if the file is named "elan_0x0A.bin" this
# function will print "0x0A" to stdout, or if the file is named
# "182.0_1.0.bin" the function will print "0x1" to stdout.
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
  if [ "${overlay_sh_exist}" -eq 0 ]; then
    fw_ver="${fw_ver%.*}"
  fi
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
    if [ "${output}" = "-1" ]; then
      printf '0xFFFFFFFF\n'
    elif [ -z "${output##*-*}" ]; then
      printf '%d\n' "${output}"
    else
      printf '0x%X\n' "0x${output}"
    fi
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

# Query the touchpad controller for its current EEPROM firmware version.
get_active_eeprom_fw_version() {
  get_active_info "eeprom firmware version" -G
}

# Query the touchpad controller for its current region id.
get_device_region_id() {
  get_active_info "region ID" -r
}

# Query the System firmware for its current region id.
get_system_region_id() {
  local ret=

  if [ ! -f "/sys/firmware/vpd/ro/region" ]; then
    printf '-1\n'
    return
  fi

  ret="$(cat /sys/firmware/vpd/ro/region)"
  ret=$(
  case "${ret}" in
    ("fr") echo "1" ;;
    ("be") echo "1" ;;
    ("cz") echo "2" ;;
    (*) echo "0" ;;
  esac)
  printf '%d\n' "${ret}"
}

# Touchpad Firmware Region ID Update
region_id_update() {
  local active_fw_ver=
  local update_type=
  local update_needed=
  local system_region_id=
  local device_region_id=
  local region_id=
  local firmware_ver=

  log_msg "We are now attempting to update touchpad firmware region."

  active_fw_ver="$(get_active_fw_version)"
  [ -n "${active_fw_ver}" ] || die \
    "Unable to determine active firmware version."
  log_msg "Active firmware version: ${active_fw_ver}"

  firmware_ver="$((active_fw_ver))"
  if [ "${firmware_ver}" -lt "8" ]; then
    log_msg "Unable to support the region id update of touchpad firmware."
    return 0
  fi

  system_region_id="$(get_system_region_id)"
  if [ "${system_region_id}" -lt "0" ]; then
    log_msg "Unable to determine active region id of system firmware."
    return 0
  fi
  log_msg "Active System firmware region id: ${system_region_id}"

  device_region_id="$(get_device_region_id)"
  region_id="$((device_region_id))"
  if [ -z "${device_region_id}" ] || [ "${region_id}" -lt "0" ]; then
    log_msg "Unable to determine active region id of touchpad firmware."
    return 0
  fi
  log_msg "Active Touchpad firmware region id: ${region_id}"

  if [ "${system_region_id}" -ne "${region_id}" ]; then
    log_msg "Updating touchpad firmware region id to ${system_region_id}"
    run_cmd_and_block_powerd update_firmware_region "${system_region_id}"

    # Check if update was successful
    device_region_id="$(get_device_region_id)"
    region_id="$((device_region_id))"
    update_type="$(compare_multipart_version "${region_id}" \
      "${system_region_id}")"

    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${system_region_id}"
      log_msg \ "Touchpad firmware region id update failed. " \
        "Current firmware region id: ${region_id}"
    else
      log_msg "Updating touchpad firmware region id succeeded. " \
        "Current firmware region id is now: ${region_id}"
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS}" \
        "${region_id}"

      rebind_driver "$(cd -P "${FLAGS_device_path}/../.." && pwd)"
    fi
  fi
}

assert_is_function_from_overlay() {
  local func_name=

  # POSIX allows, but does not require, shift to exit a non-interactive shell.
  func_name="$1"; [ "$#" -gt 0 ] || return; shift

  type "${func_name}" | head -n 1 | grep -q -E ' ?function$' || die \
    "No ${func_name}() function is defined, this is a bug in the board overlay."
}


# Touchpad EEPROM Firmware Update
eeprom_update() {
  local active_fw_ver=
  local new_fw_ver=
  local update_type=
  local update_needed=
  local fw_link=
  local chassis_id=$1
  local module_id=$2

  log_msg "We are now attempting to update EEPROM firmware."

  fw_basename="elan_eeprom_${module_id}.0.bin"

  fw_link="$(find_fw_link_path "${fw_basename}" "${chassis_id}")"
  if [ -z "${fw_link}" ]; then
    log_msg "Unable to determine path of on-disk EEPROM firmware."
    return 0
  fi
  log_msg "Attempting to load on-disk EEPROM firmware: ${fw_link}"

  new_fw_ver="$(get_fw_version_from_disk "${fw_link}")"
  log_msg "On-disk EEPROM firmware version: ${new_fw_ver}"
  if [ -z "${new_fw_ver}" ]; then
    log_msg "Unable to determine version of on-disk EEPROM firmware."
    return 0
  fi

  active_fw_ver="$(get_active_eeprom_fw_version)"
  [ -n "${active_fw_ver}" ] || die \
    "Unable to determine active EEPROM firmware version."
  log_msg "Active EEPROM firmware version: ${active_fw_ver}"

  report_initial_version "${FLAGS_device_path}" \
    "Elan Touchpad EEPROM I2C HID" "${active_fw_ver}"

  update_type="$(compare_multipart_version "${active_fw_ver}" \
    "${new_fw_ver}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Updating EEPROM firmware to ${new_fw_ver}"
    chromeos-boot-alert update_touchpad_firmware
    run_cmd_and_block_powerd update_eeprom_firmware "${fw_link}" "${new_fw_ver}"

    # Check if update was successful
    active_fw_ver="$(get_active_eeprom_fw_version)"
    update_type="$(compare_multipart_version "${active_fw_ver}" \
      "${new_fw_ver}")"

    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${new_fw_ver}"
      die "EEPROM firmware update failed. Current EEPROM firmware version: " \
      "${active_fw_ver}"
    fi
    log_msg \
      "Updating EEPROM firmware succeeded. EEPROM firmware version is now: " \
      "${active_fw_ver}"
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_ver}"
  fi
}

# Touchpad Firmware Update
touchpad_update() {
  local active_fw_ver=
  local new_fw_ver=
  local update_type=
  local update_needed=
  local fw_link=
  local module_id=
  local chassis_id=$1
  local board_rev=$2
  local device_module_id=$3
  local device_hwid=$4

  module_id="$((device_module_id))"
  active_fw_ver="$(get_active_fw_version)"
  [ -n "${active_fw_ver}" ] || die \
    "Unable to determine active firmware version."
  log_msg "Active firmware version: ${active_fw_ver}"

  report_initial_version "${FLAGS_device_path}" "Elan Touchpad I2C HID" \
    "${active_fw_ver}"
  if [ "${overlay_sh_exist}" -ne 0 ]; then
    assert_is_function_from_overlay get_fw_basename
    fw_basename="$(get_fw_basename "${chassis_id}" "${board_rev}" \
      "${device_module_id}" "${device_hwid}" "${active_fw_ver}")"
    [ -n "${fw_basename}" ] || die \
      "Unable to determine which on-disk firmware to consider flashing."
  else
    fw_basename="elan_i2c_${module_id}.0.bin"
  fi

  fw_link="$(find_fw_link_path "${fw_basename}" "${chassis_id}")"

  if [ -z "${fw_link}" ]; then
    log_msg "Unable to determine path of on-disk firmware."
    return 0
  fi

  log_msg "Attempting to load on-disk firmware: ${fw_link}"

  new_fw_ver="$(get_fw_version_from_disk "${fw_link}")"
  log_msg "On-disk firmware version: ${new_fw_ver}"

  if [ -z "${new_fw_ver}" ]; then
    log_msg "Unable to determine version of on-disk firmware."
    return 0
  fi

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
    run_cmd_and_block_powerd update_firmware "${fw_link}" "${new_fw_ver}"

    # Check if update was successful
    active_fw_ver="$(get_active_fw_version)"
    update_type="$(compare_multipart_version "${active_fw_ver}" \
      "${new_fw_ver}")"

    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${new_fw_ver}"
      die "Firmware update failed.  Current firmware version: ${active_fw_ver}"
    fi
    log_msg \
      "Updating firmware succeeded.  Firmware version is now: ${active_fw_ver}"
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_ver}"

    # Rebind the whole I2C adapter.  https://issuetracker.google.com/142598087
    # Important: This touch device should be the only peripheral on its I2C bus!
    rebind_driver "$(cd -P "${FLAGS_device_path}/../.." && pwd)"
  fi
}

main() {
  local active_fw_ver=
  local new_fw_ver=
  local update_type=
  local update_needed=
  local fw_link=
  local device_hwid=
  local device_module_id=
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
  module_id="$((device_module_id))"

  device_hwid="$(get_device_hwid)"
  [ -n "${device_hwid}" ] || die \
    "Unable to determine hardware revision of the touchpad device."
  log_msg "Hardware revision of the touchpad device: ${device_hwid}"

  touchpad_update "${chassis_id}" "${board_rev}" \
      "${device_module_id}" "${device_hwid}"
  eeprom_update "${chassis_id}" "${module_id}"

  if [ "${module_id}" -eq "286" ]; then
      region_id_update
  fi
}

main "$@"
