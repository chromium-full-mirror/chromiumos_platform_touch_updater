#!/bin/sh

# Copyright 2018 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_string 'device_path' '' "device path" 'p'
DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

G2TOUCH_FW_UPDATE_USER="g2touch"
G2TOUCH_FW_UPDATE_GROUP="g2touch"
G2TOUCH_TOUCH_I2C_HIDRAW="/dev/g2touch_touch_i2c_hidraw"
G2TOUCH_FIRMWARE_NAME='g2touch.bin'
G2TOUCH_VID="2A94"

# g2touch tool path
CONSOLETOOL_DIR="/usr/sbin"
GET_FIRMWARE_ID="${CONSOLETOOL_DIR}/g2fwcheck"
UPDATE_FW="${CONSOLETOOL_DIR}/g2updater"

get_active_product_id() {
  local hidpath
  local hidname

  hidpath="$(echo "${FLAGS_device_path}"/*:${G2TOUCH_VID}:*.*)"
  hidname="hid-$(echo "${hidpath##*/}" | \
                       awk -F'[:.]' '{ print $2 "_" $3 }')"
  local product_id="${hidname#*_}"
  echo "${product_id}"
}

get_active_firmware_version() {
  local g2touch_touch_hidraw="$1"
  local g2touch_log=""

  g2touch_log="$(minijail0 -u "${G2TOUCH_FW_UPDATE_USER}" \
              -g "${G2TOUCH_FW_UPDATE_GROUP}" \
              -n -S /opt/google/touch/policies/g2touch.query.policy \
              ${GET_FIRMWARE_ID} "-n=${g2touch_touch_hidraw}")"
  local ret="$?"

  if [ "${ret}" -eq 0 ]; then
    # Parse active firmware version
    local version_text
    version_text="$(echo "${g2touch_log}" \
       | grep "G2TOUCH Touch Firmware Version : " | head -1)"

    echo "${version_text##*"G2TOUCH Touch Firmware Version : "}"
    exit 0
  else
    # Some error occurred when executing "getFirmwareId"
    die "g2fwcheck get version failed, code=${ret}"
  fi
}

compare_fw_versions() {
  local active_fw_ver="$1"
  local fw_ver="$2"
  local active_fw_ver_major=${active_fw_ver%%.*}
  local active_fw_ver_minor=${active_fw_ver#${active_fw_ver_major}.}
  local active_fw_ver_revision=${active_fw_ver##*.}
  active_fw_ver_minor=${active_fw_ver_minor%.*}
  local fw_ver_major=${fw_ver%%.*}
  local fw_ver_minor=${fw_ver#${fw_ver_major}.}
  local fw_ver_revision=${fw_ver##*.}
  fw_ver_minor=${fw_ver_minor%.*}

  compare_multipart_version "${active_fw_ver_major}" "${fw_ver_major}" \
                            "${active_fw_ver_minor}" "${fw_ver_minor}" \
                            "${active_fw_ver_revision}" "${fw_ver_revision}"
}

update_firmware() {
  local g2touch_touch_hidraw="$1"
  local fw_path="$2"

  minijail0 -u "${G2TOUCH_FW_UPDATE_USER}" -g "${G2TOUCH_FW_UPDATE_GROUP}" \
      -n -S /opt/google/touch/policies/g2touch.update.policy \
      ${UPDATE_FW} "-n=${g2touch_touch_hidraw}" "${fw_path}"
  local ret="$?"

  # Show info for the exit-value of executing "updateFW"
  if [ "${ret}" -eq 0 ]; then
    log_msg "UpdateFW succeeded"
  else
    # Some error occurred when executing "updateFW"
    log_msg "error: UpdateFW failed, code=${ret}"
  fi
}

create_g2touch_hidraw() {
  local g2touch_touch_hidraw=""
  local touch_device=""
  local dev_t_major=""
  local dev_t_minor=""

  # Check touch interface if i2c or usb
  g2touch_touch_hidraw=${G2TOUCH_TOUCH_I2C_HIDRAW}

  # Remove g2touch_touch_hidraw if exists. det_t_major/minor may be changed.
  rm -rf ${g2touch_touch_hidraw}

  # Find the device path if it exists "/dev/hidrawX".
  hid_path="$(echo "${FLAGS_device_path}"/*:${G2TOUCH_VID}:*.*/hidraw/hidraw*)"
  touch_device="/dev/${hid_path##*/}"

  if [ -c "${touch_device}" ]; then
    # create a device node for touch firmware update
    dev_t_major="$(stat -c "%t" "${touch_device}")"
    dev_t_minor="$(stat -c "%T" "${touch_device}")"
    mknod "${g2touch_touch_hidraw}" c "0x${dev_t_major}" "0x${dev_t_minor}"
    if [ $? -ne 0 ]; then
      die "Failed create node: '${g2touch_touch_hidraw}'."
    fi

    # Change ownership for g2touch touch device
    chown "${G2TOUCH_FW_UPDATE_USER}":"${G2TOUCH_FW_UPDATE_GROUP}" \
          "${g2touch_touch_hidraw}"
    if [ $? -ne 0 ]; then
      die "Failed change owner of node: '${g2touch_touch_hidraw}'."
    fi

    # Change access mode for g2touch touch device
    chmod 0660 ${g2touch_touch_hidraw}
    if [ $? -ne 0 ]; then
      die "Failed change mode of node: '${g2touch_touch_hidraw}'."
    fi

  else
    die "Not a legal node: '${touch_device}'."
  fi
  echo "${g2touch_touch_hidraw}"
}

main() {
  local g2touch_touch_hidraw=""
  local active_prod_id=""
  local fw_link_path=""
  local fw_filename=""
  local fw_name=""
  local product_id=""
  local fw_version=""
  local active_fw_version=""
  local update_type=""
  local update_needed="${FLAGS_FALSE}"
  local ret=""

  # Check if specify the hidraw_name.
  if [ -z "${FLAGS_device_path}" ]; then
    die "Please specify a hidraw_name using -p"
  fi

  # Get the active product-id.
  active_prod_id="$(get_active_product_id)"

  if [ -z "${active_prod_id}" ]; then
    log_msg "Unable to determine active product id"
    die "Aborting.  Can not continue safely without knowing active product id"
  fi

  # Find the FW that the updater is considering flashing on the touch device.
  fw_link_path="$(find_fw_link_path "${G2TOUCH_FIRMWARE_NAME}" "${active_prod_id}")"
  fw_path="$(readlink -f "${fw_link_path}")"

  log_msg "Attempting to load FW: '${fw_link_path}'"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${FLAGS_device_path} found."
  fi

  fw_filename=${fw_path##*/}
  fw_name=${fw_filename%.bin}
  product_id=${fw_name%_*}
  product_id=${product_id#*PID_}
  fw_version=${fw_name#PID_"${product_id}_R"}

  # Make sure the product ID is what the updater expects.
  log_msg "Hardware product id : ${active_prod_id}"
  log_msg "Updater product id  : ${product_id}"
  if [ "${product_id}" != "${active_prod_id}" ]; then
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Create g2touch hidraw
  g2touch_touch_hidraw="$(create_g2touch_hidraw)"
  log_msg "Create node succeeded: '${g2touch_touch_hidraw}'."

  # Get device's fw version.
  active_fw_version="$(get_active_firmware_version "${g2touch_touch_hidraw}")"
  ret="$?"

  if [ ${ret} -ne 0 ]; then
    log_msg "Unable to determine active firmware version code=${ret}"
    die "Aborting. Can not continue safely without knowing active FW version"
  elif [ -z "${active_fw_version}" ]; then
    log_msg "Get empty active firmware version"
    die "Aborting. Can not continue safely without knowing active FW version"
  fi
  # Compare the two versions, and see if an update is needed

  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"

  report_initial_version "${FLAGS_device_path}" "G2Touch" "${active_fw_version}"

  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # If an update is needed, start it now and confirm it worked.
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    update_firmware "${g2touch_touch_hidraw}" "${fw_path}"

    # Recreate hidraw. The /dev/hidrawX may be changed after device reset.
    g2touch_touch_hidraw="$(create_g2touch_hidraw)"
    log_msg "Recreate node succeeded: '${g2touch_touch_hidraw}'."

    # Confirm that the FW was updated by checking the current FW version again
    active_fw_version="$(get_active_firmware_version "${g2touch_touch_hidraw}")"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"

    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_version}"
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi

    log_msg "Update FW succeeded. Current Firmware: ${active_fw_version}"
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_version}"
  fi
}

main
