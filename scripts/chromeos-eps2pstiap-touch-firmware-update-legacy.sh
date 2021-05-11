#!/bin/sh
#
# Copyright 2021 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'

TRACKPOINT_PATH="/sys/bus/serio/devices/serio1/"

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
    minijail0 -u fwupdate-serio -g fwupdate-serio \
      -G -I -N -n -p -v --uts \
      -S /opt/google/touch/policies/eps2pstiap.update.policy -- \
      /usr/sbin/epstps2_updater ${fw_link} -u 2>&1
  )"

  ret="$?"
  if [ "${ret}" -ne 0 ]; then
    report_update_result "${TRACKPOINT_PATH}" "${REPORT_RESULT_FAILURE}" \
      "${fw_version}"
    remove_serio_node
    die "Exit status ${ret} updating trackpoint firmware: ${cmd_log}"
  fi
  return "${ret}"
}

# The on-disk firmware version is determined by parsing the filename of the
# actual firmware file passed as $1, after resolving any symlinks. The filename
# should be in the format format "{module_id}_{rank}_{fw_ver}.bin"
# e.g "13.0_a_129.0.bin". The 0x prefix is preserved, e.g. if the file is named
# "13.0_a_129.0.bin" the function will print "0x129" to stdout.
get_fw_version_from_disk() {
  local fw_link="$1"
  local fw_filepath=
  local fw_filename=
  local fw_ver=

  [ -L "${fw_link}" ] || return
  fw_filepath="$(realpath -e "${fw_link}")" || return
  [ -n "${fw_filepath}" ] || return

  fw_filename="$(basename "${fw_filepath}")"
  fw_ver="${fw_filename##*_}"
  fw_ver="${fw_ver%%.*}"
  printf '0x%X\n' "${fw_ver}"
}

# Create serio raw driver
create_serio_node() {
  local serio_raw=

  chown root:fwupdate-serio ${TRACKPOINT_PATH}drvctl
  chmod g+w ${TRACKPOINT_PATH}drvctl
  echo -n "serio_raw" > ${TRACKPOINT_PATH}drvctl
  trap remove_serio_node EXIT

  serio_raw=$(ls ${TRACKPOINT_PATH}misc/)
  if [ -e "${TRACKPOINT_PATH}misc/${serio_raw}" ]; then
    chown root:fwupdate-serio "/dev/${serio_raw}"
    chmod g+rw "/dev/${serio_raw}"
  fi

}

# Remove serio raw driver, rebind psmouse driver
remove_serio_node() {
  echo -n "rescan" > ${TRACKPOINT_PATH}drvctl
}

# Query the trackpoint controller for information about its firmware or hardware.
get_active_info() {
  local description="$1"
  local output=
  local ret=

  output="$(
    minijail0 -u fwupdate-serio -g fwupdate-serio \
      -G -I -N -n -p -v --uts \
      -S /opt/google/touch/policies/eps2pstiap.query.policy -- \
      /usr/sbin/epstps2_updater "$@" 2>&1
  )"

  ret="$?"
  if [ "${ret}" -eq 0 ]; then
    if [ "${output}" = "-1" ]; then
      printf '0xFFFFFFFF\n'
    else
      printf '0x%X\n' "0x${output}"
    fi
  else
    log_msg 1>&2 "Exit status ${ret} retrieving trackpoint ${description}: ${output}"
  fi
  return "${ret}"
}

# Query the trackpoint controller for its current firmware version.
get_active_fw_version() {
  get_active_info "firmware version" -g
}

# Query the trackpoint controller for its hardware module identifier.
get_device_module_id() {
  get_active_info "module ID" -m
}

main() {
  local active_fw_ver=
  local new_fw_ver=
  local update_type=
  local update_needed=
  local fw_link_a=
  local fw_link_b=
  local fw_link_c=
  local fw_link=
  local device_module_id=
  local chassis_id=
  local board_rev=

  chassis_id="$(get_chassis_id)"
  log_msg "Chassis identifier detected as: ${chassis_id}"

  board_rev="$(get_platform_ver)"
  log_msg "Platform version detected as: ${board_rev}"

  create_serio_node
  device_module_id="$(get_device_module_id)"
  [ -n "${device_module_id}" ] || die \
    "Unable to determine hardware module of the trackpoint device."
  log_msg "Hardware module of the trackpoint device: ${device_module_id}"

  active_fw_ver="$(get_active_fw_version)"
  [ -n "${active_fw_ver}" ] || die \
    "Unable to determine active firmware version."
  log_msg "Active firmware version: ${active_fw_ver}"

  report_initial_version "${TRACKPOINT_PATH}" "Elan Trackpoint PS2" \
    "${active_fw_ver}"

  module_id=$((device_module_id))
  remove_serio_node

  fw_basename_a="elan_ps2_a_${module_id}.0.bin"
  fw_basename_b="elan_ps2_b_${module_id}.0.bin"
  fw_basename_c="elan_ps2_c_${module_id}.0.bin"

  fw_link_a="$(find_fw_link_path "${fw_basename_a}")"
  [ -n "${fw_link_a}" ] || die "Unable to determine path of on-disk firmware."
  log_msg "Attempting to load on-disk firmware: ${fw_link_a}"

  fw_link_b="$(find_fw_link_path "${fw_basename_b}")"
  [ -n "${fw_link_b}" ] || die "Unable to determine path of on-disk firmware."
  log_msg "Attempting to load on-disk firmware: ${fw_link_b}"

  fw_link_c="$(find_fw_link_path "${fw_basename_c}")"
  [ -n "${fw_link_c}" ] || die "Unable to determine path of on-disk firmware."
  log_msg "Attempting to load on-disk firmware: ${fw_link_c}"

  new_fw_ver="$(get_fw_version_from_disk "${fw_link_a}")"
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

    fw_link="-a ${fw_link_a} -b ${fw_link_b} -c ${fw_link_c}"

    create_serio_node
    chromeos-boot-alert update_trackpoint_firmware
    run_cmd_and_block_powerd update_firmware "${fw_link}" "${new_fw_ver}"

    # Check if update was successful
    active_fw_ver="$(get_active_fw_version)"
    update_type="$(compare_multipart_version "${active_fw_ver}" \
      "${new_fw_ver}")"

    remove_serio_node
    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${TRACKPOINT_PATH}" "${REPORT_RESULT_FAILURE}" \
        "${new_fw_ver}"
      die "Firmware update failed.  Current firmware version: ${active_fw_ver}"
    fi
    log_msg "Updating firmware succeded.  Firmware version is now: " \
      "${active_fw_ver}"
    report_update_result "${TRACKPOINT_PATH}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_ver}"

  fi
}

main "$@"
