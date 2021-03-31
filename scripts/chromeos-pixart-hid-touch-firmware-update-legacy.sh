#!/bin/sh
# Copyright 2017 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh
DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'dev_hidname' '' "device hid name" 'h'
DEFINE_string 'dev_i2c_path' '' "device i2c path" 'i'

PIXART_TOUCH_I2C_HIDRAW="/dev/pix_tp_i2c_hidraw"
FW_LINK_NAME="pix_tp2xxx.bin"

CONSOLETOOL_DIR="/usr/sbin"
FWUP_TOOL="${CONSOLETOOL_DIR}/pixtpfwup"

GET_ACTIVE_FW_VER="get_fwver"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  local hidraw="$1"
  local fw_path="$2"
  local fw_version="$3"
  local ret

  for i in $(seq 3); do
    cmd_log="$(
      minijail0 -n -u pixfwupdate -g pixfwupdate \
          -S /opt/google/touch/policies/pixtpfwup.update.policy \
          "${FWUP_TOOL}" "${hidraw}" up "${fw_path}"
    )"
    ret=$?
    if [ ${ret} -eq 1 ]; then
      return 0
    fi
    log_msg "FW update attempt #${i} failed: ${cmd_log}"
    sleep 1
  done
  report_update_result "${FLAGS_dev_i2c_path}" "${REPORT_RESULT_FAILURE}" \
    "${fw_version}"
  die "Error updating touch firmware. ${ret}"
}
get_active_fw_ver() {
  local hidraw="$1"
  # Get the fw & param version of this device.
  cmd_log="$(
   minijail0 -n -u pixfwupdate -g pixfwupdate \
    -S /opt/google/touch/policies/pixtpfwup.query.policy \
    "${FWUP_TOOL}" "${hidraw}" "${GET_ACTIVE_FW_VER}"
  )"
  local ret="$?"
  if [ "${ret}" -eq "1" ]; then
    # Parse firmware version
    local version_text="$(echo "${cmd_log}" \
      | grep "Firmware Version: " | head -1)"

    echo "${version_text##*"Firmware Version: "}"
    exit 0
  else
    # Some error occurred when executing get_fwver
    die "'get_fwver' failed, code=${ret}"
  fi
}
get_active_product_id() {
  pid="${1#*_}"
  echo "${pid}"
}
compare_fw_versions() {
  # Pixart firmware version is a 2 byte number, just compare it.
  local decimal_active_fw_ver="$(hex_to_decimal "$1")"
  local decimal_fw_ver="$(hex_to_decimal "$2")"
  compare_multipart_version "${decimal_active_fw_ver}" "${decimal_fw_ver}"
}

create_own_hidraw() {
  local pix_touch_hidraw=${PIXART_TOUCH_I2C_HIDRAW}
  local touch_device=""
  local dev_t_major=""
  local dev_t_minor=""

  # Remove pix_touch_hidraw if it exists. The det_t_major/minor may be changed.
  if [ -e "${pix_touch_hidraw}" ]; then
    rm -rf ${pix_touch_hidraw}
  fi

  touch_device="$1"

  if [ -c "${touch_device}" ]; then
    # Create a device node for touch firmware update
    dev_t_major="$(ls -l "${touch_device}" | awk '{print $5}')"
    dev_t_major=${dev_t_major%%,}
    dev_t_minor="$(ls -l "${touch_device}" | awk '{print $6}')"
    mknod "${pix_touch_hidraw}" c "${dev_t_major}" "${dev_t_minor}"
    if [ $? -ne 0 ]; then
      die "[Pix TP]Failed create node: '${pix_touch_hidraw}'."
    fi

    # Change ownership for Pixart touch device
    chown pixfwupdate:pixfwupdate \
          "${pix_touch_hidraw}"
    if [ $? -ne 0 ]; then
      die "[Pix TP]Failed change owner of node: '${pix_touch_hidraw}'."
    fi

    # Change access mode for Pixart touch device
    chmod 0660 ${pix_touch_hidraw}
    if [ $? -ne 0 ]; then
      die "[Pix TP]Failed change mode of node: '${pix_touch_hidraw}'."
    fi

  else
    die "[Pix TP]Not a legal node: '${touch_device}'."
  fi
  echo "${pix_touch_hidraw}"
}

main() {
  local device_name="${FLAGS_dev_hidname}"
  local sys_touch_dev_hidraw=""
  local touch_dev_hidraw=""
  local active_product_id=""
  local active_fw_ver=""
  local fw_link_path=""
  local fw_path=""
  local fw_filename=""
  local fw_name=""
  local update_type=""
  local update_needed=${FLAGS_FALSE}
  local product_id=""
  local fw_version=""
  # This script runs early at bootup, so if the touch driver is mistakenly
  # included as a module (as opposed to being compiled directly in) the i2c
  # device may not be present yet. Pause long enough for for people to notice
  # and fix the kernel config.
  check_i2c_chardev_driver

  # Find the device path if it exists "/dev/hidrawX".
  sys_touch_dev_hidraw="$(find_i2c_hid_device "${device_name##*-}")"
  if [ -z "${sys_touch_dev_hidraw}" ]; then
    die "[Pix TP]${device_name} not found on system. Aborting update."
  fi
  # Create own hidraw interfaace.
  touch_dev_hidraw="$(create_own_hidraw "${sys_touch_dev_hidraw}")"
  if [ -z "${touch_dev_hidraw}" ]; then
    die "[Pix TP]Create own hidraw failed, Aborting update."
  fi

  # Determine the product ID of the device we're considering updating
  active_product_id="$(get_active_product_id "${device_name}")"
  # Make sure there is a FW that looks like it's for the same product ID
  log_msg "[Pix TP]Active product id: ${active_product_id}"
  fw_link_path="$(find_fw_link_path "${FW_LINK_NAME}" "${active_product_id}")"
  log_msg "[Pix TP]Attempting to load FW: '${fw_link_path}'"
  fw_path="$(readlink "${fw_link_path}")"
  if [ ! -e "${fw_link_path}" ] ||
     [ ! -e "${fw_path}" ]; then
    die "[Pix TP]No valid firmware for Pix TP-${active_product_id} found."
  fi
  # Parse out the version numbers for the new FW from it's filename
  # The filename is as following format: PID_FWVER.bin,
  # like 0101_0510.bin. 0101 is the product id, 0510 is fw version.
  fw_filename="${fw_path##*/}"
  fw_name="${fw_filename%.bin}"
  product_id="${fw_name%_*}"
  fw_version="${fw_name#*_}"
  if [ -n "${active_product_id}" ] &&
     [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "[Pix TP]Current product id: ${active_product_id}"
    log_msg "[Pix TP]Updater product id: ${product_id}"
    die "[Pix TP]Touch firmware updater: Product ID mismatch!"
  fi
  # Get the current FW version that's loaded on the touch IC
  active_fw_ver="$(get_active_fw_ver "${touch_dev_hidraw}")"
  log_msg "[Pix TP]Product ID: ${product_id}"
  log_msg "[Pix TP]Current Firmware: ${active_fw_ver}"
  log_msg "[Pix TP]Updater Firmware: ${fw_version}"

  report_initial_version "${FLAGS_dev_i2c_path}" "PixArt" "${active_fw_ver}"

  # Determine if an update is needed, and if we do, trigger it now
  update_type="$(compare_fw_versions "${active_fw_ver}" \
                                     "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"
  if [ ${update_needed} -eq ${FLAGS_TRUE} ]; then
    log_msg "[Pix TP]Updating FW to ${fw_filename}..."
    update_firmware "${touch_dev_hidraw}" "${fw_path}" "${fw_version}"
    active_fw_ver="$(get_active_fw_ver "${touch_dev_hidraw}")"
    log_msg "[Pix TP]Current Firmware (after update attempt): ${active_fw_ver}"
    update_type="$(compare_fw_versions "${active_fw_ver}" \
                                       "${fw_version}")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_dev_i2c_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_version}"
      die "[Pix TP]Firmware update failed. Current Firmware: ${active_fw_ver}"
    fi
    log_msg "[Pix TP]Update FW succeeded. Current Firmware: ${active_fw_ver}"
    report_update_result "${FLAGS_dev_i2c_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_ver}"
    rebind_driver "${FLAGS_dev_i2c_path}"
  fi
  exit 0
}
main "$@"
