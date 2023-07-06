#!/bin/sh

# Copyright 2023 The ChromiumOS Authors.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This isn't the exact copy that will be used in production, but it's better
# than pointing shellcheck at /dev/null.
# shellcheck source=../../../scripts/lib/shflags/shflags
. /usr/share/misc/shflags
# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_string 'device_pid' '' 'device pid' 'i'
DEFINE_string 'device_path' '' "device path" 'p'
DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

ILITEK_TDDI_FIRMWARE_NAME='ilitddi.hex'

# Ilitek daemon tool path.
ILITEK_TDDI_TOOL_PATH="/usr/sbin/ilitek_tddi"
ILITEK_TDDI_QUERY_POLICY_PATH="/opt/google/touch/policies/ilitek_tddi.query.policy"
ILITEK_TDDI_UPDATE_POLICY_PATH="/opt/google/touch/policies/ilitek_tddi.update.policy"

minijail_tool() {
  minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
            -G -I -N -n -p -v -e --uts -S "$@"
}

compare_fw_versions() {
  local active_fw_version="$1"
  local active_fw_version_a="${active_fw_version%%.*}"
  local active_fw_version_b=""
  local active_fw_version_c=""
  local active_fw_version_d="${active_fw_version##*.}"
  local latest_fw_version="$2"
  local latest_fw_version_a="${latest_fw_version%%.*}"
  local latest_fw_version_b=""
  local latest_fw_version_c=""
  local latest_fw_version_d="${latest_fw_version##*.}"

  active_fw_version="${active_fw_version#"${active_fw_version_a}".}"
  active_fw_version_b="${active_fw_version%%.*}"
  active_fw_version="${active_fw_version#"${active_fw_version_b}".}"
  active_fw_version_c="${active_fw_version%%.*}"
  latest_fw_version="${latest_fw_version#"${latest_fw_version_a}".}"
  latest_fw_version_b="${latest_fw_version%%.*}"
  latest_fw_version="${latest_fw_version#"${latest_fw_version_b}".}"
  latest_fw_version_c="${latest_fw_version%%.*}"

  active_fw_version_a="$(hex_to_decimal "${active_fw_version_a}")"
  active_fw_version_b="$(hex_to_decimal "${active_fw_version_b}")"
  active_fw_version_c="$(hex_to_decimal "${active_fw_version_c}")"
  active_fw_version_d="$(hex_to_decimal "${active_fw_version_d}")"
  latest_fw_version_a="$(hex_to_decimal "${latest_fw_version_a}")"
  latest_fw_version_b="$(hex_to_decimal "${latest_fw_version_b}")"
  latest_fw_version_c="$(hex_to_decimal "${latest_fw_version_c}")"
  latest_fw_version_d="$(hex_to_decimal "${latest_fw_version_d}")"

  compare_multipart_version "${active_fw_version_a}" "${latest_fw_version_a}" \
                            "${active_fw_version_b}" "${latest_fw_version_b}" \
                            "${active_fw_version_c}" "${latest_fw_version_c}" \
                            "${active_fw_version_d}" "${latest_fw_version_d}"
}

get_fw_version() {
  local ilitek_log=""
  local fw_version=""
  local ret=""

  ilitek_log="$(minijail_tool \
             "${ILITEK_TDDI_QUERY_POLICY_PATH}" \
             "${ILITEK_TDDI_TOOL_PATH}" "GetFWVer")"

  ret="$?"
  if [ "${ret}" -eq "0" ]; then
    # Parse fw version.
    fw_version="$(echo "${ilitek_log}" \
      | grep "fw-version-tag:" | head -1)"
    fw_version="${fw_version##*[}"
    fw_version="${fw_version%]}"
    echo "${fw_version}"
  else
    # Some error occurred when executing "get_fw_version".
    die "'get_fw_version' failed, ret:${ret}"
  fi
}

check_fw_mode() {
  local ilitek_log=""
  local fw_mode=""
  local ret=""

  ilitek_log="$(minijail_tool \
             "${ILITEK_TDDI_QUERY_POLICY_PATH}" \
             "${ILITEK_TDDI_TOOL_PATH}" "check_bl_mode")"

  ret="$?"
  if [ "${ret}" -eq "0" ]; then
    # Parse fw mode.
    fw_mode="$(echo "${ilitek_log}" \
      | grep "fw-mode-tag:" | head -1)"
    fw_mode="${fw_mode##*[}"
    fw_mode="${fw_mode%]}"
    echo "${fw_mode}"
  else
    # Some error occurred when executing "check_fw_mode".
    die "'check_fw_mode' failed, ret=${ret}"
  fi
}

check_crc() {
  local fw_path="$1"
  local ilitek_log=""
  local check_crc_result=""
  local ret=""

  ilitek_log="$(minijail_tool \
             "${ILITEK_TDDI_QUERY_POLICY_PATH}" \
             "${ILITEK_TDDI_TOOL_PATH}" "CheckCRC" "path=${fw_path}")"

  ret="$?"
  if [ "${ret}" -eq "0" ]; then
    # Parse check crc result.
    check_crc_result="$(echo "${ilitek_log}" \
      | grep "fw-crc-tag:" | head -1)"
    check_crc_result="${check_crc_result##*[}"
    check_crc_result="${check_crc_result%]}"
    echo "${check_crc_result}"
  else
    # Some error occurred when executing "check_crc".
    die "'check_crc' failed, ret=${ret}"
  fi
}

update_firmware() {
  local fw_path="$1"
  local fw_version="$2"
  local ilitek_log=""
  local ret=""

  ilitek_log="$(minijail_tool \
             "${ILITEK_TDDI_UPDATE_POLICY_PATH}" \
             "${ILITEK_TDDI_TOOL_PATH}" "FWUpgrade" "path=${fw_path}")"

  # Show info for the exit-value of executing "update_firmware".
  ret="$?"
  if [ "${ret}" -eq "0" ]; then
    log_msg "'update_firmware' succeeded"
    return 0
  fi
  # Some error occurred when executing "update_firmware".
  report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
    "${fw_version}"
  die "error: 'update_firmware' failed, log: ${ilitek_log}"
}

main() {
  local active_product_id=""
  local fw_link_path=""
  local fw_filename=""
  local fw_version=""
  local active_fw_version=""
  local update_type=""
  local update_needed="${FLAGS_FALSE}"
  local fw_mode=""
  local fw_path=""
  local check_crc_result

  # Check fw mode.
  fw_mode="$(check_fw_mode)"
  log_msg "FW Mode : '${fw_mode}'"

  # Get active product id.
  active_product_id="${FLAGS_device_pid}"
  log_msg "Product ID : '${active_product_id}'"

  # Find the fw that the updater is considering flashing on the touch device.
  # Fw name should be "ilitddi_<active_product_id>.hex".
  fw_link_path="$(find_fw_link_path "${ILITEK_TDDI_FIRMWARE_NAME}" \
                "${active_product_id}")"
  fw_path="$(readlink -f "${fw_link_path}")"
  log_msg "Attempting to load FW: '${fw_link_path}' link to '${fw_path}'"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware found."
  fi

  # Parse product_id and latest fw version,
  # filename should be <product_id %04x>_<fw_version %02x.%02x.%02x.%02x>.hex,
  # for example: "8888_00.00.00.00.hex".
  fw_filename=${fw_path##*/}
  fw_version=${fw_filename%.hex}
  fw_version=${fw_version##*_}

  # Check if device in bootloader mode due to fw upgrade failed previously.
  # Fw upgrade forcely would be required to switch device back to normal mode.
  if [ "${fw_mode}" != "BL" ]; then

    # Get fw version.
    active_fw_version="$(get_fw_version)"
    log_msg "FW Version : '${active_fw_version}'"

    # Abort if get empty active_fw_version.
    if [ -z "${active_fw_version}" ]; then
      log_msg "Got empty active firmware version"
      die "Aborting. Can not continue safely without knowing active FW version"
    fi

    # Compare the two versions, and see if an update is needed.
    report_initial_version "${FLAGS_device_path}" "Ilitek" \
      "${active_fw_version}"
    log_msg "Current Firmware: ${active_fw_version}"
    log_msg "Updater Firmware: ${fw_version}"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  else
    report_initial_version "${FLAGS_device_path}" "Ilitek" \
      "${REPORT_VERSION_RECOVERY}"
    log_msg "In bootloader mode, should fw upgrade forcely"
    update_type="${UPDATE_NEEDED_RECOVERY}"
  fi
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # Check crc between hex and flash fw.
  if [ "${update_type}" -eq "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
    log_msg "The available version is equal to current fw version."
    check_crc_result="$(check_crc "${fw_path}")"
    log_msg "check_crc_result : ${check_crc_result}"
    if [ "${check_crc_result}" != "CRC_PASS" ]; then
      update_needed="${FLAGS_TRUE}"
      log_msg "CRC fail."
    fi
  fi

  # If an update is needed, start it now and confirm it worked.
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${fw_filename}"
    update_firmware "${fw_path}" "${fw_version}"
    # Confirm that the fw was updated by checking the current fw version again.
    active_fw_version="$(get_fw_version)"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_version}"
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_version}"
    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"
    rebind_driver "${FLAGS_device_path}"
  fi
}

main "$@"
