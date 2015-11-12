#!/bin/sh
# Copyright 2015 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'
DEFINE_string 'driver_name' '' "Which Elan driver (elan_i2c elants_i2c)" 'n'

ELAN_I2C_FW_NAME="elan_i2c.bin"
ELAN_I2C_FW_VERSION_SYSFS="firmware_version"
ELAN_I2C_PRODUCT_ID_SYSFS="product_id"
ELANTS_I2C_FW_NAME="elants_i2c.bin"
ELANTS_I2C_FW_VERSION_SYSFS="fw_version"
ELANTS_I2C_PRODUCT_ID_SYSFS="hw_version"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

# Confirm that a device was specified
if [ -z "${FLAGS_device}" ]; then
  die "Please specify a device using -d"
fi

# Select the right sysfs entries depending on which Elan driver was selected
if [ -z "${FLAGS_driver_name}" ]; then
  die "Please specify a driver name using -n (elants_i2c or elan_i2c)"
elif [ "${FLAGS_driver_name}" = "elan_i2c" ]; then
  FW_NAME="${ELAN_I2C_FW_NAME}"
  FW_VERSION_SYSFS="${ELAN_I2C_FW_VERSION_SYSFS}"
  PRODUCT_ID_SYSFS="${ELAN_I2C_PRODUCT_ID_SYSFS}"
elif [ "${FLAGS_driver_name}" = "elants_i2c" ]; then
  FW_NAME="${ELANTS_I2C_FW_NAME}"
  FW_VERSION_SYSFS="${ELANTS_I2C_FW_VERSION_SYSFS}"
  PRODUCT_ID_SYSFS="${ELANTS_I2C_PRODUCT_ID_SYSFS}"
else
  die "This script only supports two drivers (elants_i2c and elan_i2c)"
fi


main() {
  local touch_device_name="${FLAGS_device}"
  local touch_device_path=""
  local update_needed=${FLAGS_FALSE}
  local active_product_id=""
  local active_fw_version=""
  local fw_path=""
  local fw_link_path=""
  local fw_filename=""
  local fw_name=""
  local product_id=""
  local fw_version=""
  local board=`grep CHROMEOS_RELEASE_BOARD= /etc/lsb-release | awk -F = '{print $2}'`

  # Find the device in the filesystem.
  required_sysfs="update_fw ${FW_VERSION_SYSFS} ${PRODUCT_ID_SYSFS}"
  touch_device_path="$(find_i2c_device_by_name "${touch_device_name}" \
  					       "${required_sysfs}")"
  if [ -z "${touch_device_path}" ]; then
    die "${touch_device_name} not found on system. Aborting update."
  fi

  # Find the product ID that the touch device is reporting itself as.
  active_product_id="$(cat ${touch_device_path}/${PRODUCT_ID_SYSFS})"
  if [ -z "${active_product_id}" ]; then
    log_msg "Unable to determine active product id"
    die "Aborting.  Can not continue safely without knowing active product ID"
  fi

  # Find the FW that the updater is considering flashing on the touch device.
  fw_link_path="$(find_fw_link_path ${active_product_id} ${FW_NAME})"
  fw_path="$(readlink "${fw_link_path}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${touch_device_name} found."
  fi
  fw_filename=${fw_path##*/}
  fw_name=${fw_filename%.bin}
  product_id=${fw_name%_*}
  fw_version=${fw_name#"${product_id}_"}

  # Make sure the product ID is what the updater expects.
  local product_id_matches=${FLAGS_FALSE}
  log_msg "Hardware product id : ${active_product_id}"
  log_msg "Updater product id  : ${product_id}"
  if [ "${product_id}" = "${active_product_id}" ]; then
     product_id_matches=${FLAGS_TRUE}
  elif [ -n "$(echo ${board} | grep "^blaze")" ] &&
     [ "${FLAGS_driver_name}" = "elants_i2c" ] &&
     [ "${active_product_id}" == "232d" -a "${product_id}" == "280d" ]; then
     # Hack to support Blaze's touchscreen -- chrome-os-partner:29794
     product_id_matches=${FLAGS_TRUE}
  elif [ -n "$(echo ${board} | grep "^enguarde")" ] &&
     [ "${FLAGS_driver_name}" = "elan_i2c" ] &&
     [ "${active_product_id}" == "57.0" -a "${product_id}" == "69.0" ]; then
     # Hack to support Enguarde's touchpad -- chrome-os-partner:28165
     product_id_matches=${FLAGS_TRUE}
  fi
  if [ "${product_id_matches}" -ne ${FLAGS_TRUE} ]; then
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Check the touch device's FW version and compare to the updater's.
  active_fw_version="$(get_active_firmware_version_from_sysfs \
                     "${FW_VERSION_SYSFS}" "${touch_device_path}")"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"
  local min_version="$(echo ${active_fw_version} ${fw_version} |
                             awk '{if ($1 < $2) print $1; else print $2}')"
  if [ "${active_fw_version}" = "${fw_version}" ]; then
    log_msg "Firmware up to date."
  elif [ "${active_fw_version}" = "${min_version}" ]; then
    log_msg "Update needed."
    update_needed=${FLAGS_TRUE}
  elif [ ${FLAGS_recovery} -eq ${FLAGS_TRUE} ]; then
    log_msg "Recovery firmware update. Rolling back to ${fw_version}."
    update_needed=${FLAGS_TRUE}
  fi

  # Hack to prevent Squawks users with FW 5.0 from updating.  It may brick
  # the device -- chrome-os-partner:41066
  if [ -n "$(echo ${board} | grep "^squawks")" ] &&
     [ "${active_fw_version}" = "5.0" ]; then
    log_msg "Skipping FW update for Squawks 5.0 FW users."
    update_needed=${FLAGS_FALSE}
  fi

  # If the touch device needs an update, trigger it now and confirm it worked.
  if [ ${update_needed} -eq ${FLAGS_TRUE} ]; then
    log_msg "Update FW to ${fw_name}"
    standard_update_firmware "${touch_device_path}"

    active_fw_version="$(get_active_firmware_version_from_sysfs \
                       "${FW_VERSION_SYSFS}" "${touch_device_path}")"
    if [ "${active_fw_version}" != "${fw_version}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"

    rebind_driver "${touch_device_path}"
  fi

  exit 0
}

main "$@"
