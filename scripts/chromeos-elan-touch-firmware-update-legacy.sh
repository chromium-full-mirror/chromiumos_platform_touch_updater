#!/bin/sh
# Ignore the fact that `local`` is undefined in POSIX sh.
# shellcheck disable=SC3043

# Copyright 2015 The ChromiumOS Authors
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
DEFINE_string 'driver_name' '' "Which Elan driver (elan_i2c elants_i2c)" 'n'

ELAN_I2C_FW_NAME="elan_i2c"
ELAN_I2C_FW_VERSION_SYSFS="firmware_version"
ELAN_I2C_PRODUCT_ID_SYSFS="product_id"
ELANTS_I2C_FW_NAME="elants_i2c"
ELANTS_I2C_FW_VERSION_SYSFS="fw_version"
ELANTS_I2C_PRODUCT_ID_SYSFS="hw_version"
ELANTS_I2C_CALIBRATE_SYSFS="calibrate"
ELANTS_I2C_CALIBRATION_COUNT_SYSFS="calibration_count"

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

compare_fw_versions() {
  local active_fw_version="$1"
  local fw_version="$2"

  # Compare the two version numbers and see which is ahead of the other
  # Elan FW versions are given as floating point numbers, so to compare
  # them we must use awk.
  local min_version
  min_version="$(echo "${active_fw_version}" "${fw_version}" |
                             awk '{if ($1 < $2) print $1; else print $2}')"

  if [ "${active_fw_version}" = "${fw_version}" ]; then
    echo "${UPDATE_NOT_NEEDED_UP_TO_DATE}"
  elif [ "${active_fw_version}" = "${min_version}" ]; then
    echo "${UPDATE_NEEDED_OUT_OF_DATE}"
  elif [ "${FLAGS_recovery}" -eq "${FLAGS_TRUE}" ]; then
    echo "${UPDATE_NEEDED_RECOVERY}"
  else
    echo "${UPDATE_NOT_NEEDED_AHEAD_OF_DATE}"
  fi
}

correct_reported_product_id() {
  local reported_product_id="$1"
  local board="$2"

  # Normally we simply rely on the reported product ID.  Unfortunately, for us
  # Kip and Kip+ are vulnerable to a bug that's makes them report 255.0.  When
  # we see that value and the device is Kip, we need to differentiate them
  # and manually set the product ID to recover the touchpad. crosbug.com/p/46266
  if [ "${reported_product_id}" = "255.0" ] ||
     [ "${reported_product_id}" = "65535.0" ]; then
    if echo "${board}" | grep -q '^kip'; then
      if [ "$(get_chassis_id)" = "KIP14" ]; then
        echo "72.0"
      else
        echo "75.0"
      fi
    # If an elan device is reporting 255.0 and there is only an elan_i2c.bin FW
    # in /lib/firmware (old-style without a product ID appended to the filename)
    # then it's reasonable to assume the touchpad got wiped and that we should
    # try to recover it with whatever the FW there happens to be.  To do this,
    # we can just correct the product_id with whatever is on disk.
    elif [ -f "/lib/firmware/elan_i2c.bin" ] &&
         [ "$(find /lib/firmware -name 'elan_i2c*.bin' | wc -l)" -eq 1 ]; then
      local fw_path
      local fw_filename
      local fw_name
      local product_id
      fw_path=$(readlink /lib/firmware/elan_i2c.bin)
      fw_filename=${fw_path##*/}
      fw_name=${fw_filename%.bin}
      product_id=${fw_name%_*}
      echo "${product_id}"
    fi

  # Otherwise, just rely on the product ID that the device reported
  else
    echo "${reported_product_id}"
  fi
}

elan_update_firmware() {
  local touch_device_path="$1"
  local reported_product_id="$2"
  local corrected_product_id="$3"
  local fw_path="$4"
  local fw_version="$5"

  if [ "${reported_product_id}" = "${corrected_product_id}" ]; then
    standard_update_firmware "${touch_device_path}" "${fw_version}"
  else
    log_msg "Warning - The product ID of this device has been corrected (it " \
            "reported ${reported_product_id}).  Attempting to recover now."
    local tmp_fw_dir=""
    local linked_fw_name=""
    local driver_fw_link="/lib/firmware/${FW_NAME}_${reported_product_id}.bin"
    if [ ! -f "${driver_fw_link}" ]; then
      driver_fw_link="/lib/firmware/${FW_NAME}.bin"
    fi
    linked_fw_name="$(readlink -f "${driver_fw_link}" | xargs basename)"

    # First make a temp directory where we can put custom symlinks to the right file
    tmp_fw_dir=$(mktemp -d)

    # Now the correct FW into the tmp directory and rename to match the symlink
    cp  "${fw_path}" "${tmp_fw_dir}/${linked_fw_name}"

    # Mount the temporary directory over the existing firmware directory
    mount --bind "${tmp_fw_dir}" /opt/google/touch/firmware

    # Now that the symlink is set up, continue as normal
    standard_update_firmware "${touch_device_path}" "${fw_version}"

    # Remove the newly mounted directory to return /lib/firmware to normal
    umount /opt/google/touch/firmware
    rm -rf "${tmp_fw_dir}"
  fi
}

main() {
  local touch_device_name="${FLAGS_device}"
  local touch_device_path=""
  local update_needed="${FLAGS_FALSE}"
  local reported_product_id=""
  local active_product_id=""
  local active_fw_version=""
  local fw_path=""
  local fw_link_path=""
  local fw_filename=""
  local fw_name=""
  local update_type=""
  local product_id=""
  local fw_version=""
  local calibration_count=""
  local board=""
  board=$(grep CHROMEOS_RELEASE_BOARD= /etc/lsb-release | awk -F = '{print $2}')
  log_msg "Board detected as '${board}'"

  # Find the device in the filesystem.
  required_sysfs="update_fw ${FW_VERSION_SYSFS} ${PRODUCT_ID_SYSFS}"
  touch_device_path="$(find_i2c_device_by_name "${touch_device_name}" \
    "${required_sysfs}")"
  if [ -z "${touch_device_path}" ]; then
    die "${touch_device_name} not found on system. Aborting update."
  fi

  # Find the product ID that the touch device is reporting itself as.
  reported_product_id="$(cat "${touch_device_path}"/"${PRODUCT_ID_SYSFS}")"
  log_msg "Touch controller reported Product ID: ${reported_product_id}"
  active_product_id="$(correct_reported_product_id "${reported_product_id}" \
    "${board}")"

  local product_id_for_logging="${active_product_id:-${reported_product_id}}"
  log_updater_run "${ELAN_VENDOR_ID}" "${product_id_for_logging}" \
    "${touch_device_name}" "${touch_device_path}" "Elan"

  if [ -z "${active_product_id}" ]; then
    log_msg "Unable to determine active product id"
    die "Aborting.  Can not continue safely without knowing active product ID"
  elif [ "${reported_product_id}" != "${active_product_id}" ]; then
    log_msg "Warning: reported product id ${reported_product_id} was corrected" \
            "to ${active_product_id} for this device."
  fi

  # Check the touch device's FW version and report it.
  active_fw_version="$(get_active_firmware_version_from_sysfs \
    "${FW_VERSION_SYSFS}" "${touch_device_path}")"

  report_initial_version "${touch_device_path}" "Elan" "${active_fw_version}" \
    "\"elan_product_id\": \"$(make_json_safe "${active_product_id}")\""

  # Find the FW that the updater is considering flashing on the touch device.
  fw_link_path="$(find_fw_link_path "${FW_NAME}.bin" "${active_product_id}")"
  fw_path="$(readlink "${fw_link_path}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  log_msg "(which points to '${fw_path}')"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${touch_device_name} found."
  fi
  fw_filename=${fw_path##*/}
  fw_name=${fw_filename%.bin}
  product_id=${fw_name%_*}
  fw_version=${fw_name#"${product_id}_"}

  # Make sure the product ID is what the updater expects.
  local product_id_matches="${FLAGS_FALSE}"
  log_msg "Hardware product id : ${active_product_id}"
  log_msg "Updater product id  : ${product_id}"
  if [ "${product_id}" = "${active_product_id}" ]; then
     product_id_matches=${FLAGS_TRUE}
  elif echo "${board}" | grep -q "^blaze" &&
     [ "${FLAGS_driver_name}" = "elants_i2c" ] &&
     [ "${active_product_id}" = "232d" ] &&
     [ "${product_id}" = "280d" ]; then
     # Hack to support Blaze's touchscreen -- chrome-os-partner:29794
     product_id_matches=${FLAGS_TRUE}
  elif echo "${board}" | grep -q "^enguarde" &&
     [ "${FLAGS_driver_name}" = "elan_i2c" ] &&
     [ "${active_product_id}" = "57.0" ] &&
     [ "${product_id}" = "69.0" ]; then
     # Hack to support Enguarde's touchpad -- chrome-os-partner:28165
     product_id_matches=${FLAGS_TRUE}
  fi
  if [ "${product_id_matches}" -ne "${FLAGS_TRUE}" ]; then
    die "Touch firmware updater: Product ID mismatch!"
  fi

  # Log "Product ID: <Product ID>" to /var/log/messages for test case parsing.
  log_msg "Product ID: ${active_product_id}"

  # Compare the touch device's FW version to the updater's.
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"

  update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  # If the touch device needs an update, trigger it now and confirm it worked.
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${fw_name}"
    elan_update_firmware "${touch_device_path}" "${reported_product_id}" \
                         "${active_product_id}" "${fw_path}" "${fw_version}"

    active_fw_version="$(get_active_firmware_version_from_sysfs \
                       "${FW_VERSION_SYSFS}" "${touch_device_path}")"
    update_type="$(compare_fw_versions "${active_fw_version}" "${fw_version}")"
    if  [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${touch_device_path}" "${REPORT_RESULT_FAILURE}" \
        "${fw_version}"
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeeded. Current Firmware: ${active_fw_version}"
    report_update_result "${touch_device_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_version}"

    rebind_driver "${touch_device_path}"
  fi

  if [ -f "${touch_device_path}/${ELANTS_I2C_CALIBRATION_COUNT_SYSFS}" ]; then
    calibration_count="$(cat "${touch_device_path}/${ELANTS_I2C_CALIBRATION_COUNT_SYSFS}")"
    log_msg "Current calibration count: ${calibration_count}"
    if [ "${calibration_count}" = "0xffff" ]; then
      log_msg "Calibration need, previous calibration fail"
      printf 1 > "${touch_device_path}/${ELANTS_I2C_CALIBRATE_SYSFS}"
      calibration_count="$(cat "${touch_device_path}/${ELANTS_I2C_CALIBRATION_COUNT_SYSFS}")"
      if [ "${calibration_count}" = "0x0000" ]; then
        log_msg "Calibrate success, Current calibration count: ${calibration_count}"
      else
        log_msg "Calibrate fail, Current calibration count: ${calibration_count}"
      fi
    fi
  fi

  exit 0
}

main "$@"
