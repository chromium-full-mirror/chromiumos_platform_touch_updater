#!/bin/sh
# Copyright 2023 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'
DEFINE_string 'device_path' '' "device path" 'p'
DEFINE_string 'product_id' '' "product id" 'i'

FW_LINK_NAME="himax_i2chid.bin"
HX_UTIL="/usr/sbin/hx_util"
I2C_GET_ACTIVE_FW_VER="-v"
I2C_GET_ACTIVE_PROD_ID="-p"
HID_GET_ACTIVE_FW_VER="-V"
HID_GET_ACTIVE_PROD_ID="-P"
I2C_ID="i2c"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

fw_update() {
  local bus_type="$1"
  local fw_path="$2"
  local force_flag="$3"
  local log=""
  local i2c_flash_opt="-u"
  local i2c_dev_opt="-d"
  local hid_flash_opt="-A"
  local hid_flash_log="-l"
  local hid_flash_force="-F"

  if [ "${bus_type}" = "i2c" ]; then
    log=$(minijail0 -u fwupdate-i2c -g fwupdate-i2c \
    -G -I -N -n -p -v --uts -e \
    -S /opt/google/touch/policies/hx_util.update.policy \
    "${HX_UTIL}" "${i2c_flash_opt}" "${fw_path}" "${i2c_dev_opt}" \
    "${FLAGS_device}")
  elif [ "${force_flag}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "with force flag..."
    log=$(minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
    -G -I -N -n -p -v --uts -e \
    -S /opt/google/touch/policies/hx_util.update.policy \
    "${HX_UTIL}" "${hid_flash_opt}" "${fw_path}" "${hid_flash_force}" \
    "${hid_flash_log}")
  else
    log=$(minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
    -G -I -N -n -p -v --uts -e \
    -S /opt/google/touch/policies/hx_util.update.policy \
    "${HX_UTIL}" "${hid_flash_opt}" "${fw_path}" "${hid_flash_log}")
  fi

  if [ -z "${log##*succeed*}" ]; then
    echo "fw_update by ${bus_type}: success"
    return 0
  else
    echo "fw_update by ${bus_type} error:${log}"
    return 1
  fi
}

update_firmware() {
  local fw_path="$1"
  local fw_param_ver="$2"
  local bus_type="$3"
  local force_flag="$4"
  local i
  local ret

  for i in $(seq 3); do
    fw_update "${bus_type}" "${fw_path}" "${force_flag}"

    ret="$?"
    if [ "${ret}" -eq 0 ]; then
      return 0
    else
      log_msg "FW update attempt #${i} failed"
    fi
    sleep 1
  done
  report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
    "${fw_param_ver}"
  die "Error updating touch firmware. ${ret}"
}

get_active_fw_param_ver() {
  local bus_type="$1"

  if [ "${bus_type}" = "${I2C_ID}" ]; then
    minijail0 -u fwupdate-i2c -g fwupdate-i2c \
      -G -I -N -n -p -v --uts -e \
      -S /opt/google/touch/policies/hx_util.query.policy \
      "${HX_UTIL}" "${I2C_GET_ACTIVE_FW_VER}" "-d" "${FLAGS_device}"
  else
    minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -I -N -n -p -v --uts -e \
      -S /opt/google/touch/policies/hx_util.query.policy \
      "${HX_UTIL}" "${HID_GET_ACTIVE_FW_VER}"
  fi
}

get_active_product_id() {
  local bus_type="$1"

  if [ "${bus_type}" = "${I2C_ID}" ]; then
    minijail0 -u fwupdate-i2c -g fwupdate-i2c \
      -G -I -N -n -p -v --uts -e \
      -S /opt/google/touch/policies/hx_util.query.policy \
      "${HX_UTIL}" "${I2C_GET_ACTIVE_PROD_ID}" -d "${FLAGS_device}"
  else
    minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -I -N -n -p -v --uts -e \
      -S /opt/google/touch/policies/hx_util.query.policy \
      "${HX_UTIL}" "${HID_GET_ACTIVE_PROD_ID}"
  fi
}

main() {
  local active_product_id=""
  local active_fw_param_ver=""
  local fw_link_path=""
  local fw_path=""
  local fw_filename=""
  local fw_name=""
  local update_type=""
  local update_needed="${FLAGS_FALSE}"
  local product_id=""
  local product_fw=""
  local fw_param_ver=""
  local bus_type=""
  local i2c_pid="121A"
  local force_update="${FLAGS_FALSE}"

  if [ "${FLAGS_product_id}" != "${i2c_pid}" ]; then
    bus_type="hidraw"
  else
    bus_type="i2c"
  fi

  # Determine the product ID of the device we're considering updating
  active_product_id="$(get_active_product_id "${bus_type}")"

  # Make sure there is a FW that looks like it's for the same product ID
  fw_link_path="$(find_fw_link_path "${FW_LINK_NAME}" "${active_product_id}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  fw_path="$(readlink "${fw_link_path}")"
  if [ ! -e "${fw_link_path}" ] ||
     [ ! -e "${fw_path}" ]; then
    die "No valid firmware for himax i2chid ${active_product_id} found."
  fi

  # Parse out the version numbers for the new FW from it's filename
  # The filename is as following format: product_fw_parameter.bin,
  # like 01017401_2082_0133c65b.bin. 01017401 is the product id,
  # 2082 is fw version and 0133c65b is the version of parameters.
  fw_filename="${fw_path##*/}"
  fw_name="${fw_filename%.bin}"
  product_fw="${fw_name%_*}"
  product_id="${product_fw%_*}"
  fw_param_ver="${fw_name#"${product_id}_"}"
  if [ -n "${active_product_id}" ] &&
     [ "${product_id}" != "${active_product_id}" ]; then
    log_msg "Current product id: ${active_product_id}"
    log_msg "Updater product id: ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Get the current FW version that's loaded on the touch IC
  active_fw_param_ver="$(get_active_fw_param_ver "${bus_type}")"
  log_msg "Product ID: ${product_id}"
  log_msg "Current Firmware_parameters: ${active_fw_param_ver}"
  log_msg "Updater Firmware_parameters: ${fw_param_ver}"
  report_initial_version "${FLAGS_device_path}" "Himax HID" \
    "${active_fw_param_ver}"

  # Determine if an update is needed, and if we do, trigger it now
  update_type="$(compare_multipart_version "$((0x${active_fw_param_ver}))" \
    "$((0x${fw_param_ver}))")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"
  if [ "${update_type}" -eq "${UPDATE_NEEDED_RECOVERY}" ]; then
    log_msg "Recovery mode. Forcing update..."
    force_update="${FLAGS_TRUE}"
  fi
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Updating FW to ${fw_filename}..."
    update_firmware "${fw_path}" "${fw_param_ver}" "${bus_type}" \
      "${force_update}"

    active_fw_param_ver="$(get_active_fw_param_ver "${bus_type}")"
    log_msg "Current Firmware (after update attempt): ${active_fw_param_ver}"

    update_type="$(compare_multipart_version "$((0x${active_fw_param_ver}))" \
      "$((0x${fw_param_ver}))")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_param_ver}"
      die "Firmware update failed. Current Firmware: ${active_fw_param_ver}"
    fi
    log_msg "Update FW succeeded. Current Firmware: ${active_fw_param_ver}"
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_param_ver}"

    rebind_driver "${FLAGS_device_path}"
  fi

  exit 0
}

main "$@"
