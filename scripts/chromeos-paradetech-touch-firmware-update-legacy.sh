#!/bin/sh

# Copyright 2024 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This isn't the exact copy that will be used in production, but it's better
# than pointing shellcheck at /dev/null.
# shellcheck source=../../../scripts/lib/shflags/shflags
. /usr/share/misc/shflags
# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_string 'device_name' '' "device name" 'd'
DEFINE_string 'i2c_path' '' "I2C device path" 'p'
DEFINE_string 'device_pid' '' 'device pid' 'i'
DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

PARADETECH_VENDOR_ID="1DA0"
PARADE_FW_UPDATE_USER="fwupdate-hidraw"
PARADE_FW_UPDATE_GROUP="fwupdate-hidraw"
PARADE_FIRMWARE_NAME="paradetech.bin"

CONSOLETOOL_DIR="/usr/sbin"
PARADE_UPDATER_TOOL="${CONSOLETOOL_DIR}/ptupdater"

minijail_tool() {
  minijail0 -u "${PARADE_FW_UPDATE_USER}" -g "${PARADE_FW_UPDATE_GROUP}" \
            -G -N -n -p -v --uts -S "$@"
}

get_vendor_name() {
  echo "Parade Technologies"
}

check_applicability() {
  exit 0
}

get_active_fw_version() {
  local hidraw_path="$1"

  local ptupdater_log=""
  ptupdater_log="$(minijail_tool \
                /opt/google/touch/policies/paradetech.query.policy \
                "${PARADE_UPDATER_TOOL}" "${hidraw_path}" \
                "--check-active" "--verbose=5")"
  local ret="$?"
  if [ "${ret}" -eq 0 ]; then
    # Parse active firmware version.
    local version_text
    version_text="$(echo "${ptupdater_log}" \
       | grep "INFO: Active Version: " | head -1)"

    echo "${version_text##*"INFO: Active Version: "}"
    exit 0
  else
    die "ptupdater get active version failed, code=${ret}"
  fi
}

compare_fw_versions() {
  local active_fw_ver="$1"
  local target_fw_ver="$2"

  # Parse the active version parts.
  local active_fw_ver_unparsed="${active_fw_ver}"
  local active_fw_ver_major="${active_fw_ver_unparsed%%.*}"
  local active_fw_ver_unparsed="${active_fw_ver_unparsed#*.}"
  local active_fw_ver_minor="${active_fw_ver_unparsed%%.*}"
  local active_fw_ver_unparsed="${active_fw_ver_unparsed#*.}"
  local active_fw_ver_revision="${active_fw_ver_unparsed%%.*}"
  local active_fw_ver_unparsed="${active_fw_ver_unparsed#*.}"
  local active_fw_ver_config_ver="${active_fw_ver_unparsed%%.*}"

  # Parse the target version parts.
  local target_fw_ver_unparsed="${target_fw_ver}"
  local target_fw_ver_major="${target_fw_ver_unparsed%%.*}"
  local target_fw_ver_unparsed="${target_fw_ver_unparsed#*.}"
  local target_fw_ver_minor="${target_fw_ver_unparsed%%.*}"
  local target_fw_ver_unparsed="${target_fw_ver_unparsed#*.}"
  local target_fw_ver_revision="${target_fw_ver_unparsed%%.*}"
  local target_fw_ver_unparsed="${target_fw_ver_unparsed#*.}"
  local target_fw_ver_config_ver="${target_fw_ver_unparsed%%.*}"

  compare_multipart_version \
    "${active_fw_ver_major}"      "${target_fw_ver_major}" \
    "${active_fw_ver_minor}"      "${target_fw_ver_minor}" \
    "${active_fw_ver_revision}"   "${target_fw_ver_revision}" \
    "${active_fw_ver_config_ver}" "${target_fw_ver_config_ver}"
}

update_firmware() {
  local hidraw_path="$1"
  local fw_filepath="$2"

  local ptupdater_log=""
  ptupdater_log="$(minijail_tool \
                /opt/google/touch/policies/paradetech.update.policy \
                "${PARADE_UPDATER_TOOL}" "${hidraw_path}" \
                "--update=${fw_filepath}" "--verbose=5")"
  local ret="$?"
  if [ "${ret}" -eq 0 ]; then
    log_msg "ptupdater succeeded"
  else
    log_msg "error: ptupdater failed, code=${ret}"
  fi
}

main() {
  local preferred_search_path="${FLAGS_i2c_path}"
  local touch_device_name="${FLAGS_device_name}"
  local i2c_dev_name=""
  local hidraw_path=""
  local active_pid=""
  local target_pid=""
  local fw_link_path=""
  local active_fw_version=""
  local target_fw_version=""
  local update_type=""
  local update_needed="${FLAGS_FALSE}"
  local ret=""

  get_vendor_name

  # Check if specify the hid name.
  if [ -z "${FLAGS_device_name}" ]; then
    die "Please specify a 'hidname' using -d"
  fi

  # Check if specify the i2c path.
  if [ -z "${FLAGS_i2c_path}" ]; then
    die "Please specify a 'i2c_path' using -p"
  fi

  # Check if specify the device product id.
  if [ -z "${FLAGS_device_pid}" ]; then
    die "Please specify a 'product_id' using -i"
  fi

  hidraw_path="$(find_i2c_hid_device "${touch_device_name##*-}" \
                      "${preferred_search_path}")"
  log_msg "HIDRAW sysfs node path: '${hidraw_path}'"

  active_pid="${touch_device_name##*_}"

  # For the legacy module (PID 3001), it may report a default PID (3406)
  # when the touch firmware is wiped. It was initially assumed that the
  # bootloader would only respond with basic ACKs, which led to the adoption
  # of a default PID (3406). While the issue has been resolved, earlier
  # shipped products retain the default setting. Additionally, touch device
  # will recover its finger report function after system reboot again.
  if [ "${active_pid}" = "3406" ]; then
    log_msg "Correct PID from 3406 to 3001"
    log_msg "You may need to reboot the computer to reload touch driver."
    active_pid="3001"
    i2c_dev_name="$(cat "${FLAGS_i2c_path}/name")"
    report_updater_run "${FLAGS_i2c_path}" "Paradetech" \
      "${i2c_dev_name}" "${PARADETECH_VENDOR_ID}" "${active_pid}"
  fi

  # Make sure the product ID is what the updater expects.
  log_msg "Active product ID: ${active_pid}"

  active_fw_version="$(get_active_fw_version "${hidraw_path}")"
  ret="$?"
  if [ "${ret}" -ne 0 ]; then
    log_msg "Unable to determine active firmware version code=${ret}"
    die "Aborting. Can not continue safely without knowing active FW version"
  elif [ -z "${active_fw_version}" ]; then
    log_msg "Got empty active firmware version"
    die "Aborting. Can not continue safely without knowing active FW version"
  fi
  log_msg "Active firmware version: ${active_fw_version}"

  # Find the FW that the updater is considering flashing on the touch device.
  fw_link_path="$(find_fw_link_path "${PARADE_FIRMWARE_NAME}" "${active_pid}")"
  fw_path="$(readlink -f "${fw_link_path}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware found for Paradetech device."
  fi

  # Get PID,fw_version from file name.
  fw_name="$(basename "${fw_path}" | sed "s/.bin$//")"
  target_pid=${fw_name%_*}
  target_fw_version=${fw_name#"${target_pid}_"}

  # Check PID,fw_version from firmware file.
  log_msg "Target product ID: ${target_pid}"
  log_msg "Target firmware version: ${target_fw_version}"

  # Compare the two pids.
  if [ "${target_pid}" != "${active_pid}" ]; then
    die "Touch firmware updater: Product ID mismatch!"
  fi

  report_initial_version "${FLAGS_i2c_path}" "Paradetech" \
    "${active_fw_version}"
  # The active_fw_version "0.0.0.0" means the chip stays at programming mode.
  # Firmware update should be always performed.
  if [ "${active_fw_version}" = "0.0.0.0" ]; then
    log_msg "Stuck in programming mode, firmware update is required!"
    update_type="${UPDATE_NEEDED_RECOVERY}"
  else
    # Compare the two versions, and see if an update is needed.
    update_type="$(compare_fw_versions \
                  "${active_fw_version}" "${target_fw_version}")"
  fi
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # If an update is needed, start it now and confirm it worked.
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    update_firmware "${hidraw_path}" "${fw_path}"

    # Confirm that the FW was updated by checking the current FW version again.
    active_fw_version="$(get_active_fw_version "${hidraw_path}")"
    update_type="$(compare_fw_versions \
                  "${active_fw_version}" "${target_fw_version}")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_i2c_path}" "${REPORT_RESULT_FAILURE}" \
        "${target_fw_version}"
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi

    log_msg "Update FW succeeded. Current Firmware: ${active_fw_version}"
    report_update_result "${FLAGS_i2c_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_version}"
  fi
}

main "$@"
