#!/bin/sh

# Copyright 2026 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# The shellcheck source for shflags isn't the exact copy that will be used in production,
# but it is good enough for linting.
# shellcheck source=../../../scripts/lib/shflags/shflags
. /usr/share/misc/shflags
# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_string 'device_path' '' "device path in /sys" 'p'
DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'
DEFINE_string 'product_id' '' "Touch product ID" 'i'


# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

LXS_UPDATER="/usr/bin/lxs_touch_updater"
LXS_FW_LINK_BASE="lxs_touch.img"
LXS_USER="fwupdate-hidraw"
LXS_GROUP="fwupdate-hidraw"
LXS_POLICY="/opt/google/touch/policies/lxs.update.policy"
LXS_QUERY_POLICY="/opt/google/touch/policies/lxs.query.policy"

minijail_tool() {
  minijail0 -u "${LXS_USER}" -g "${LXS_GROUP}" \
    -G -v -P /mnt/empty -b / -b /dev,,1 -b /sys -b /proc/ \
    -t --uts -e -l -p -N -n -S "$@"
}

# Get the target firmware version from the firmware filename.
# Filename format: LXS_TouchFW_<model>_C_<cc>_<cc>_A_<aa>_<aa>_P_<pp>_<pp>.img
# Version string returned: C_<cc>_<cc>_A_<aa>_<aa>_P_<pp>_<pp>
# Example: LXS_TouchFW_140WU_C_01_00_A_01_00_P_A0_01.img
#          -> C_01_00_A_01_00_P_A0_01
get_fw_version_from_disk() {
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
  # Extract version portion after the model field.
  fw_ver="${fw_filename#LXS_TouchFW_*_}"
  fw_ver="${fw_ver%.img}"
  echo "${fw_ver}"
}

# Get the active firmware version from the touch device.
# Returns: C_<cc>_<cc>_A_<aa>_<aa>_P_<pp>_<pp>
# Boot version is intentionally excluded from comparison.
get_active_fw_version() {
  local output=""
  local core_ver="" app_ver="" para_ver=""

  if ! output="$(minijail_tool "${LXS_QUERY_POLICY}" -- \
    "${LXS_UPDATER}" --get_current_version 2>&1)"; then
    log_msg "Failed to retrieve LXS touch firmware version: ${output}"
    return 1
  fi

  core_ver="$(echo "${output}" | sed -n 's/^Core : \([0-9A-Fa-f]*\)\.\([0-9A-Fa-f]*\)/\1_\2/p' | head -n 1)"
  app_ver="$(echo "${output}"  | sed -n 's/^App : \([0-9A-Fa-f]*\)\.\([0-9A-Fa-f]*\)/\1_\2/p'  | head -n 1)"
  para_ver="$(echo "${output}" | sed -n 's/^Param : \([0-9A-Fa-f]*\)\.\([0-9A-Fa-f]*\)/\1_\2/p' | head -n 1)"

  if [ -z "${core_ver}" ] || [ -z "${app_ver}" ] || [ -z "${para_ver}" ]; then
    log_msg "Failed to parse LXS firmware version. Raw output: ${output}"
    return 1
  fi

  echo "C_${core_ver}_A_${app_ver}_P_${para_ver}"
}
# Perform the firmware update.
update_firmware() {
  local fw_path="$1"
  local cmd_log=""

  if ! cmd_log="$(minijail_tool "${LXS_POLICY}" -- \
    "${LXS_UPDATER}" --update "${fw_path}" 2>&1)"; then
    log_msg "LXS touch firmware update failed: ${cmd_log}"
    return 1
  fi
}
main() {
  local active_fw_ver=""
  local target_fw_ver=""
  local fw_link=""
  local active_core_ver=""
  local active_app_ver=""
  local active_para_ver=""
  local target_core_ver=""
  local target_app_ver=""
  local target_para_ver=""
  local update_type=""
  local update_needed=""

  local active_core_major=""
  local active_core_minor=""
  local target_core_major=""
  local target_core_minor=""

  local active_app_major=""
  local active_app_minor=""
  local target_app_major=""
  local target_app_minor=""

  local active_para_major=""
  local active_para_minor=""
  local target_para_major=""
  local target_para_minor=""

  # Always read and report the active firmware version before looking for the
  # upgrade firmware.
  active_fw_ver="$(get_active_fw_version)"
  report_initial_version "${FLAGS_device_path}" "LXS Touch" "${active_fw_ver}"
  if [ -z "${active_fw_ver}" ]; then
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
      "unknown"
    die "Unable to determine active LXS touch firmware version."
  fi
  log_msg "Active firmware version: ${active_fw_ver}"

  # Find the firmware file via the standard symlink mechanism.
  fw_link="$(find_fw_link_path "${LXS_FW_LINK_BASE}" "${FLAGS_product_id}")"
  if [ ! -e "${fw_link}" ]; then
    die "No LXS firmware file found at ${fw_link}"
  fi

  target_fw_ver="$(get_fw_version_from_disk "${fw_link}")"
  if [ -z "${target_fw_ver}" ]; then
    die "Unable to determine target LXS firmware version from: ${fw_link}"
  fi
  log_msg "Target firmware version: ${target_fw_ver}"

  active_core_ver="$(echo "${active_fw_ver}" | sed -n 's/^C_\([^_]*\)_\([^_]*\)_A_.*/0x\1 0x\2/p')"
  active_app_ver="$(echo "${active_fw_ver}" | sed -n 's/^C_[^_]*_[^_]*_A_\([^_]*\)_\([^_]*\)_P_.*/0x\1 0x\2/p')"
  active_para_ver="$(echo "${active_fw_ver}" | sed -n 's/^C_[^_]*_[^_]*_A_[^_]*_[^_]*_P_\([^_]*\)_\([^_]*\)$/0x\1 0x\2/p')"
  target_core_ver="$(echo "${target_fw_ver}" | sed -n 's/^C_\([^_]*\)_\([^_]*\)_A_.*/0x\1 0x\2/p')"
  target_app_ver="$(echo "${target_fw_ver}" | sed -n 's/^C_[^_]*_[^_]*_A_\([^_]*\)_\([^_]*\)_P_.*/0x\1 0x\2/p')"
  target_para_ver="$(echo "${target_fw_ver}" | sed -n 's/^C_[^_]*_[^_]*_A_[^_]*_[^_]*_P_\([^_]*\)_\([^_]*\)$/0x\1 0x\2/p')"
  active_core_major=$(echo ${active_core_ver} | cut -d" " -f1)
  active_core_minor=$(echo ${active_core_ver} | cut -d" " -f2)
  target_core_major=$(echo ${target_core_ver} | cut -d" " -f1)
  target_core_minor=$(echo ${target_core_ver} | cut -d" " -f2)
  active_app_major=$(echo ${active_app_ver} | cut -d" " -f1)
  active_app_minor=$(echo ${active_app_ver} | cut -d" " -f2)
  target_app_major=$(echo ${target_app_ver} | cut -d" " -f1)
  target_app_minor=$(echo ${target_app_ver} | cut -d" " -f2)
  active_para_major=$(echo ${active_para_ver} | cut -d" " -f1)
  active_para_minor=$(echo ${active_para_ver} | cut -d" " -f2)
  target_para_major=$(echo ${target_para_ver} | cut -d" " -f1)
  target_para_minor=$(echo ${target_para_ver} | cut -d" " -f2)

  update_type="$(compare_multipart_version \
    ${active_core_major} ${target_core_major} \
    ${active_core_minor} ${target_core_minor} \
    ${active_app_major} ${target_app_major} \
    ${active_app_minor} ${target_app_minor} \
    ${active_para_major} ${target_para_major} \
    ${active_para_minor} ${target_para_minor})"
  log_update_type "${update_type}"

  update_needed="$(is_update_needed "${update_type}")"

  if [ "${update_needed}" -ne "${FLAGS_TRUE}" ]; then
    log_msg "LXS touch firmware is up to date: ${active_fw_ver}"
    exit 0
  fi

  log_msg "Updating LXS touch firmware to ${target_fw_ver}."
  if ! run_cmd_and_block_powerd update_firmware "${fw_link}"; then
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
      "${target_fw_ver}"
    die "LXS touch firmware update failed."
  fi

  # Verify the update succeeded.
  active_fw_ver=""
  for i in $(seq 10); do
    active_fw_ver="$(get_active_fw_version)"
    if [ "${active_fw_ver}" != "C_FF_FF_A_FF_FF_P_FF_FF" ]; then
      break
    fi
    sleep 1
  done

  if [ -z "${active_fw_ver}" ]; then
    report_update_result "${FLAGS_device_path}" \
      "${REPORT_RESULT_FAILURE}" \
      "${target_fw_ver}"
    die "Unable to determine active LXS touch firmware version after update."
  fi

  if [ "${active_fw_ver}" != "${target_fw_ver}" ]; then
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
      "${target_fw_ver}"
    die "LXS touch firmware update failed. Current version: ${active_fw_ver}"
  fi

  report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS}" \
    "${active_fw_ver}"
  log_msg "LXS touch firmware update succeeded. Version is now: ${active_fw_ver}"

  rebind_driver "${FLAGS_device_path}"
}

main "$@"
