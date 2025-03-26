#!/bin/sh
# Copyright 2021 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh
DEFINE_string 'device' '' "device name" 'd'
DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'
DEFINE_string 'dev_i2c_path' '' "device i2c path" 'p'
DEFINE_string 'product_id' '' "product id" 'i'

FW_LINK_BASE="zinitix_firmware.bin"
ZINITIXUPDATE="/usr/sbin/Zinitix_FWupdate"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

minijail_version() {
  local policy="/opt/google/touch/policies/zinitixupdate.query.policy"
  minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
    -G -v -P /mnt/empty -b / -b /dev,,1 -b /sys -b /proc/ -t \
    --uts -e -l -p -N -n -S "${policy}" "${ZINITIXUPDATE}" "$@"
}

minijail_update() {
  local policy="/opt/google/touch/policies/zinitixupdate.update.policy"
  minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
    -G -v -P /mnt/empty -b / -b /dev,,1 -b /sys -b /proc/ -t \
    --uts -e -l -p -N -n -S "${policy}" "${ZINITIXUPDATE}" "$@"
}

update_firmware() {
  local i=""
  local ret=""
  local fw_path="$2"
  local dev_path="$1"
  local update_fw_ver="$3"
  local update_option_ver="$4"

  for i in $(seq 3); do
    minijail_update "${update_option_ver}" "${dev_path}" "${fw_path}"
    ret="$?"
    if [ "${ret}" -eq "0" ]; then
      return 0
    fi
    log_msg "FW update attempt #${i} failed... retrying. ${ret}"
  done
  report_update_result "${FLAGS_dev_i2c_path}" "${REPORT_RESULT_FAILURE}" \
    "${update_fw_ver}"
  die "Error updating zinitix firmware. ${ret}"
}

get_active_firmware_version() {
  local dev_path="$1"
  minijail_version "1" "${dev_path}"
}

get_update_firmware_version() {
  local fw_path="$1"
  minijail_version "2" "${fw_path}"
}

main() {
  local touch_dev_name="${FLAGS_device}"
  local touch_dev_path=""
  local active_fw_ver=""
  local update_fw_ver=""
  local update_type=""
  local fw_link_path=""
  local fw_path=""
  local fw_name=""
  local hardware_id=""
  local update_needed="${FLAGS_FALSE}"
  local update_option_ver=""

  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi

  if [ -z "${FLAGS_product_id}" ]; then
    die "Please provide a product id using -i"
  fi

  # Find the device path if it exists "/dev/hidrawX".
  touch_dev_path="$(find_i2c_hid_device "${touch_dev_name##*-}")"
  log_msg "touch_dev_path:${touch_dev_path}"
  if [ -z "${touch_dev_path}" ]; then
    die "${touch_dev_name} not found on system. Aborting update."
  fi

  # Find the active fw version and the product ID currently in use.
  active_fw_ver="$(get_active_firmware_version "${touch_dev_path}")"
  log_msg "active_fw_version:${active_fw_ver}"
  if [ -z "${active_fw_ver}" ]; then
    die "Failed to get the active version. Aborting update."
  fi

  report_initial_version "${FLAGS_dev_i2c_path}" "Zinitix" "${active_fw_ver}"

  # Boxster/chromeos-config does not enforce a case for hexadecimal values.
  # The product id in boxster is manually entered by a human. Unfortunately
  # boxster/chromeos-config does not enforce a case for hexadecimal values.
  # The values entered in the config are used directly to generate firmware
  # file names. Since there is no case requirement, the product id and
  # associated filenames might be in lower case.
  # Kernel standardized on upper case. We create a lowercase version of the
  # product id from the kernel and pass it as the third optional argument to
  # `find_fw_link_path`; This allows for `find_fw_link_path` to find firmware
  # files for the product id, irrespective of the case used by device/project.
  product_id_lowercase="$(echo "${FLAGS_product_id}" | tr '[:upper:]' \
    '[:lower:]')"

  fw_link_path="$(find_fw_link_path "${FW_LINK_BASE}" "${FLAGS_product_id}" \
    "${product_id_lowercase}")"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  fw_path="$(readlink -f "${fw_link_path}")"

  if [ -z "${fw_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${FLAGS_device} found."
  fi

  update_fw_ver="$(get_update_firmware_version "${fw_path}")"
  fw_name="$(basename "${fw_path}" ".bin")"

  # Make sure the product ID is what the updater expects.
  update_major_ver=$( echo "${update_fw_ver}" | cut -c 1-2 )
  active_major_ver=$( echo "${active_fw_ver}" | cut -c 1-2 )
  update_minor_ver=$((0x$( echo "${update_fw_ver}" | cut -c 3-4)))
  active_minor_ver=$((0x$( echo "${active_fw_ver}" | cut -c 3-4)))
  log_msg "update version:${update_minor_ver}"
  log_msg "active version:${active_minor_ver}"

  if [ "${FLAGS_recovery}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Firmware Recovery!!"
  elif [ "${update_major_ver}" != "${active_major_ver}" ] \
     || [ "${update_minor_ver}" -le "${active_minor_ver}" ]; then
    die "Product ID mismatch!"
  fi

  # Compare the two versions, and see if an update is needed.
  # If active_fw_ver is "BD01" or "BD03" always update to cover programming mode.
  # Programming mode version are  "BD01" or "BD03".
  if [ "${active_fw_ver}" = "BD01" ] || [ "${active_fw_ver}" = "BD03" ]; then
    update_needed="${FLAGS_TRUE}"
  else
    update_type="$(compare_multipart_version "${active_minor_ver}" \
                "${update_minor_ver}")"
    log_update_type "${update_type}"
    update_needed="$(is_update_needed "${update_type}")"
  fi

  if [ "${active_major_ver}" = "33" ] || [ "${active_major_ver}" = "2C" ]; then
    update_option_ver="33"
  else
    update_option_ver="32"
  fi

  #If the device number is the same, the update proceeds.
  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${fw_name} ${touch_dev_path} ${fw_path}"
    run_cmd_and_block_powerd update_firmware "${touch_dev_path}" "${fw_path}" \
      "${update_fw_ver}" "${update_option_ver}"

    # Check if update was successful
    active_fw_ver="$(get_active_firmware_version "${touch_dev_path}")"
    active_minor_ver=$((0x$( echo "${active_fw_ver}" | cut -c 3-4)))
    update_type="$(compare_multipart_version "${active_minor_ver}" \
                "${update_minor_ver}")"
    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      report_update_result "${FLAGS_dev_i2c_path}" "${REPORT_RESULT_FAILURE}" \
        "${update_fw_ver}"
      die "Firmware update failed. Current Firmware: ${active_fw_ver}"
    fi
    log_msg "Update FW succeeded. Current Firmware: ${active_fw_ver}"
    report_update_result "${FLAGS_dev_i2c_path}" "${REPORT_RESULT_SUCCESS}" \
      "${active_fw_ver}"
  fi

  rebind_driver "${FLAGS_dev_i2c_path}"

  exit 0
}

main "$@"
