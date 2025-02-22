#!/bin/sh

# Copyright 2018 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This isn't the exact copy that will be used in production, but it's better
# than pointing shellcheck at /dev/null.
# shellcheck source=../../../scripts/lib/shflags/shflags
. /usr/share/misc/shflags
# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'
DEFINE_string 'dev_path' '' "device path" 'p'

GOODIX_FW_UPDATE_USER="goodixfwupdate"
GOODIX_FW_UPDATE_GROUP="goodixfwupdate"
GOODIX_TOUCHSCREEN_HIDRAW="/dev/goodix_ts_hidraw"
GOODIX_NODE_NAME=""
FW_LINK_NAME="goodix_firmware.bin"
GDIXUPDATE="/usr/sbin/gdixupdate"
GET_BOARD_SPECIFIC_PID="/opt/google/touch/scripts/get_board_goodix_pid.sh"
GOODIX_TOUCH_VID="27C6"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  local fw_version="$4"
  local i
  local ret

  for i in $(seq 3); do
    minijail0 -u "${GOODIX_FW_UPDATE_USER}" -g "${GOODIX_FW_UPDATE_GROUP}" \
        -n -S /opt/google/touch/policies/gdixupdate.update.policy \
        "${GDIXUPDATE}" -f -t "$3" -d "$1" "$2"

    ret=$?
    if [ "${ret}" -eq 0 ]; then
      return 0
    fi
    log_msg "FW update attempt #${i} failed... retrying."
  done
  report_update_result "${FLAGS_dev_path}" "${REPORT_RESULT_FAILURE}" \
    "${fw_version}"
  die "Error updating touch firmware. ${ret}"
}

get_active_firmware_version() {
  local touch_device_path="$1"
  minijail0 -u "${GOODIX_FW_UPDATE_USER}" -g "${GOODIX_FW_UPDATE_GROUP}" \
      -n -S /opt/google/touch/policies/gdixupdate.query.policy \
      "${GDIXUPDATE}" -p -d "${touch_device_path}" -t "$2"
}

compare_fw_versions() {
  local active_fw_version="$1"
  local fw_version="$2"

  local fw_version_major=""
  local fw_version_minor=""

  local active_fw_version_major=""
  local active_fw_version_minor=""

  active_fw_version_major=${active_fw_version%%.*}
  active_fw_version_minor=${active_fw_version##*.}

  fw_version_major=${fw_version%%.*}
  fw_version_minor=${fw_version##*.}

  compare_multipart_version "${active_fw_version_major}" "${fw_version_major}" \
                            "${active_fw_version_minor}" "${fw_version_minor}"
}

create_goodix_hidraw() {
  local touch_device="$1"
  local dev_t_major=""
  local dev_t_minor=""

  if [ -c "${touch_device}" ]; then
    # create a device node for touchscreen firmware update
    dev_t_major="$(stat -c "%t" "${touch_device}")"
    dev_t_minor="$(stat -c "%T" "${touch_device}")"
    GOODIX_NODE_NAME="${GOODIX_TOUCHSCREEN_HIDRAW}${dev_t_minor}"

    if [ -e "${GOODIX_NODE_NAME}" ]; then
        log_msg "${GOODIX_NODE_NAME} already exist, remove it."
        rm "${GOODIX_NODE_NAME}"
    fi

    if ! mknod "${GOODIX_NODE_NAME}" \
        c "0x${dev_t_major}" "0x${dev_t_minor}"; then
      die "Failed create node: '${GOODIX_NODE_NAME}'."
    fi

    # Change ownership and access mode for goodix touchscreen device
    if ! chown "${GOODIX_FW_UPDATE_USER}":"${GOODIX_FW_UPDATE_GROUP}" \
        "${GOODIX_NODE_NAME}"; then
      die "Failed change owner of node: '${GOODIX_NODE_NAME}'."
    fi

    if ! chmod 0660 "${GOODIX_NODE_NAME}"; then
      die "Failed change mode of node: '${GOODIX_NODE_NAME}'."
    fi
  else
    die "Not a legal node: '${touch_device}'."
  fi
  return 0
}

main() {
  local touch_device_name="${FLAGS_device}"
  local touch_device_path="${FLAGS_dev_path}"
  local active_product_id=""
  local active_fw_version=""
  local update_type=""
  local update_needed="${FLAGS_FALSE}"
  local product_id=""
  local fw_link_path=""
  local fw_path=""
  local fw_name=""
  local customize_product_id=""

  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi

  if [ -z "${FLAGS_dev_path}" ]; then
    die "Please specify a device path using -p"
  fi

  # Find the active fw version and the product ID currently in use.
  active_product_id="${touch_device_name##*_}"

  # Find the device path if it exists "/dev/hidrawX".
  touch_device_path="$(
    echo "${FLAGS_dev_path}"/*:"${GOODIX_TOUCH_VID}":*.*/hidraw/hidraw*
  )"
  touch_device_path="/dev/${touch_device_path##*/}"
  if [ -z "${touch_device_path}" ]; then
    die "${touch_device_name} not found on system. Aborting update."
  fi
  create_goodix_hidraw "${touch_device_path}"
  touch_device_path="${GOODIX_NODE_NAME}"

  # Wait 500ms to allow firmware to get ready to provide version number.
  # TODO(teravest): Remove this once firmware no longer needs this delay.
  sleep 0.5
  active_fw_version="$(get_active_firmware_version "${touch_device_path}" \
      "${active_product_id}")"
  log_msg "Product ID: ${active_product_id}"
  log_msg "Current Firmware: ${active_fw_version}"
  report_initial_version "${FLAGS_dev_path}" "Goodix" "${active_fw_version}"

  log_msg "Touch device path: '${touch_device_path}'"

  if [ -x "${GET_BOARD_SPECIFIC_PID}" ]; then
    customize_product_id="$(${GET_BOARD_SPECIFIC_PID} -d "${FLAGS_device}")"
    if [ -n "${customize_product_id}" ]; then
      log_msg "Change the active_product_id from ${active_product_id}" \
          "to ${customize_product_id}"
      active_product_id="${customize_product_id}"
    fi
  fi

  # Find the fw version and product ID on disk.
  fw_link_path="$(find_fw_link_path "${FW_LINK_NAME}" "${active_product_id}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"

  fw_path="$(readlink -f "${fw_link_path}")"
  if [ -z "${fw_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${FLAGS_device} found."
  fi

  fw_name="$(basename "${fw_path}" ".bin")"

  product_id=${fw_name%_*}
  fw_version=${fw_name#"${product_id}_"}
  # Check to make sure we found the device we're expecting. If the product
  # IDs don't match, abort immediately to avoid flashing the wrong device.
  if [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "Current product id: ${active_product_id}"
    log_msg "Updater product id: ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Compare the two versions, and see if an update is needed.
  log_msg "Updater Firmware: ${fw_version}"

  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${fw_name}"
    update_firmware "${touch_device_path}" "${fw_path}" "${active_product_id}" \
      "${fw_version}"

    rebind_driver "${FLAGS_dev_path}"
    sleep 0.3
    # Confirm that the FW was updated by checking the current FW version again.
    active_fw_version="$(get_active_firmware_version "${touch_device_path}" \
         "${active_product_id}")"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"

    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_dev_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_version}"
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeeded. Current Firmware: ${active_fw_version}"
    report_update_result "${FLAGS_dev_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_version}"
  fi
  exit 0
}

main "$@"
