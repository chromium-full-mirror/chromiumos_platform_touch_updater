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

DEFINE_string 'device_path' '' "device path" 'p'
DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

ILITEK_ITS_FIRMWARE_NAME='ilitek.bin'

# Ilitek daemon tool path.
ILITEK_TOOL_DIR="/usr/sbin"
ILITEK_ITS_TOOL_PATH="${ILITEK_TOOL_DIR}/ilitek_ld"
ILITEK_ITS_QUERY_POLICY_PATH="/opt/google/touch/policies/ilitek_ld.query.policy"
ILITEK_ITS_UPDATE_POLICY_PATH="/opt/google/touch/policies/ilitek_ld.update.policy"
ILITEK_ITS_FWID_MAPPING_FILE="/usr/share/ilitek_ld_tool/ilitek_fwid_map.csv"

minijail_tool() {
  minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
            -G -I -N -n -p -v -e --uts -S "$@"
}

get_ilitek_protocol() {
  local protocol_version="$1"
  local protocol_version_major=""
  local protocol_version_minor=""

  protocol_version_major=${protocol_version%.*}
  protocol_version_minor=${protocol_version#*.}
  if [ "${protocol_version_major}" -eq "1" ]; then
    if [ "${protocol_version_minor}" -eq "8" ]; then
      echo "V6"
    elif [ "${protocol_version_minor}" -eq "6" ] || \
         [ "${protocol_version_minor}" -eq "7" ]; then
      echo "V3"
    else
      echo "Unknown"
    fi
  elif [ "${protocol_version_major}" -eq "3" ]; then
    echo "V3"
  elif [ "${protocol_version_major}" -eq "6" ]; then
    echo "V6"
  else
    echo "Unknown"
  fi
}

get_active_controller_info() {
  local ilitek_log=""
  local protocol_version=""
  local protocol_version_string=""
  local fw_mode=""
  local fw_version=""
  local ret=""

  ilitek_log="$(minijail_tool \
              "${ILITEK_ITS_QUERY_POLICY_PATH}" \
              "${ILITEK_ITS_TOOL_PATH}" "PanelInfor" "I2C-HID" \
              "V6" "null" "null")"
  ret="$?"

  if [ "${ret}" -eq "0" ]; then
    # Parse protocol version in format "protocol version: [%02X.%02X]".
    protocol_version="$(echo "${ilitek_log}" \
      | grep "protocol-version-tag:" | head -1)"
    protocol_version="${protocol_version##*[}"
    protocol_version="${protocol_version%]}"
    protocol_version_string="$(get_ilitek_protocol "${protocol_version}")"

    if [ "${protocol_version_string}" != "V6" ] && \
       [ "${protocol_version_string}" != "V3" ]; then
      die "unrecognized protocol version: ${protocol_version}"
    fi

    # Parse fw mode in format "fw mode: [%s]".
    fw_mode="$(echo "${ilitek_log}" | grep "fw-mode-tag:" | head -1)"
    fw_mode="${fw_mode##*[}"
    fw_mode="${fw_mode%]}"

    fw_version="$(echo "${ilitek_log}" \
      | grep "fw-version-tag:" | head -1)"
    fw_version="${fw_version##*[}"
    fw_version="${fw_version%]}"

    echo "${protocol_version_string}:${fw_mode}:${fw_version}"
    return 0
  fi

  # Some error occurred when executing "get_active_protocol_version".
  die "'get_active_protocol_info' failed, ret:${ret}"
}

get_active_product_id() {
  local ilitek_protocol="$1"
  local ilitek_log=""
  local product_id=""
  local ret=""

  ilitek_log="$(minijail_tool \
              "${ILITEK_ITS_QUERY_POLICY_PATH}" \
              "${ILITEK_ITS_TOOL_PATH}" "FWID" "I2C-HID" \
              "${ilitek_protocol}" "null" "null" \
              --fwid-map-file="${ILITEK_ITS_FWID_MAPPING_FILE}")"
  ret="$?"
  if [ "${ret}" -eq "0" ]; then
    # Parse active product id.
    product_id="$(echo "${ilitek_log}" \
      | grep "fwid-tag:" | head -1)"
    product_id="${product_id#*[}"
    product_id="${product_id%%]*}"
    echo "${product_id}"
    exit 0
  else
    # Some error occurred when executing "get_active_product_id".
    die "'get_active_product_id' failed, ret=${ret}"
  fi
}

get_active_firmware_version() {
  local ilitek_protocol="$1"
  local ilitek_log=""
  local ret=""
  local firmware_version=""

  ilitek_log="$(minijail_tool  \
              "${ILITEK_ITS_QUERY_POLICY_PATH}" \
              "${ILITEK_ITS_TOOL_PATH}" "Chrome" "I2C-HID" \
              "${ilitek_protocol}" "null" "null")"

  ret="$?"
  if [ "${ret}" -eq "0" ]; then
    # Parse active firmware version.
    firmware_version="$(echo "${ilitek_log}" \
      | grep "fw-version-tag:" | head -1)"
    firmware_version="${firmware_version##*[}"
    firmware_version="${firmware_version%]}"
    echo "${firmware_version}"
    exit 0
  else
    # Some error occurred when executing "get_active_firmware_version".
    die "'get_active_firmware_version' failed, ret=${ret}"
  fi
}

update_firmware() {
  local ilitek_protocol="$1"
  local fw_path="$2"
  local fw_version="$3"
  local ilitek_log=""

  ilitek_log="$(minijail_tool \
              "${ILITEK_ITS_UPDATE_POLICY_PATH}" \
              "${ILITEK_ITS_TOOL_PATH}" "FWUpgrade" "I2C-HID" \
              "${ilitek_protocol}" "null" "null" "${fw_path}")"

  # Show info for the exit-value of executing "update_firmware".
  if [ "$?" -eq "0" ]; then
    log_msg "'update_firmware' succeeded"
    return 0
  fi

  # Some error occurred when executing "FWUpgrade".
  report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
    "${fw_version}"
  die "error: 'update_firmware' failed, log: ${ilitek_log}"
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

main() {
  local active_product_id=""
  local fw_link_path=""
  local fw_filename=""
  local fw_version=""
  local active_fw_version=""
  local update_type=""
  local update_needed="${FLAGS_FALSE}"
  local ilitek_controller_info=""
  local ilitek_protocol=""
  local fw_mode=""
  local fw_path=""
  local ret=""

  # Get controller info in format <V6 or V3>:<AP or BL>:<FW version>.
  ilitek_controller_info="$(get_active_controller_info)"
  ilitek_protocol="${ilitek_controller_info%%:*}"
  fw_mode="${ilitek_controller_info#*:}"
  fw_mode="${fw_mode%%:*}"
  active_fw_version="${ilitek_controller_info##*:}"
  log_msg "Ilitek IC protocol: '${ilitek_protocol}', mode: '${fw_mode}'."

  # Get active product id.
  active_product_id="$(get_active_product_id "${ilitek_protocol}")"
  ret="$?"
  if [ "${ret}" -ne "0" ]; then
    log_msg "Unable to determine active product id, ret=${ret}"
    die "Aborting. Can not continue safely without knowing active product id"
  elif [ -z "${active_product_id}" ]; then
    log_msg "Got empty active product id"
    die "Aborting.  Can not continue safely without knowing active product id"
  fi

  # Make sure the product id is what the updater expects.
  log_msg "Product ID (FWID) : ${active_product_id}"

  # Find the fw that the updater is considering flashing on the touch device.
  # Fw name should be "ilitek_<active_product_id>.bin".
  fw_link_path="$(find_fw_link_path "${ILITEK_ITS_FIRMWARE_NAME}" \
                "${active_product_id}")"
  fw_path="$(readlink -f "${fw_link_path}")"
  log_msg "Attempting to load FW: '${fw_link_path}' link to '${fw_path}'"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware found."
  fi

  # Parse product_id and latest fw version,
  # filename should be <product_id %04x>_<fw_version %04x.%04x.%04x.%04x>.bin,
  # for example: "8888_0000.0000.0000.0000.bin".
  fw_filename=${fw_path##*/}
  fw_version=${fw_filename%.bin}
  fw_version=${fw_version##*_}

  # Check if device in bootloader mode due to fw upgrade failed previously.
  # Fw upgrade forcely would be required to switch device back to normal mode.
  if [ "${fw_mode}" = "AP" ]; then

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

  # If an update is needed, start it now and confirm it worked.
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${fw_filename}"
    update_firmware "${ilitek_protocol}" "${fw_path}" "${fw_version}"

    # Confirm that the fw was updated by checking the current fw version again.
    active_fw_version="$(get_active_firmware_version "${ilitek_protocol}")"
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
