#!/bin/sh
# Copyright 2026 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# shellcheck source=../../../scripts/lib/shflags/shflags
. /usr/share/misc/shflags
# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_string 'device_path' '' "device path in /sys" 'p'
DEFINE_string 'fw_link_name' '' "firmware link name, e.g. ilitek.bin" 'f'
DEFINE_string 'updater_name' '' "updater name" 'n'
DEFINE_string 'product_id' '' "product id reported by the kernel" 'i'

FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

main() {
  local fw_link_path=""
  local fw_path=""
  local fw_filename=""
  local fw_name=""
  local product_id=""
  local product_id_lowercase=""
  local fw_version=""
  local active_fw_version=""

  if [ -z "${FLAGS_device_path}" ]; then
    die "Device path is empty."
  fi
  if [ -z "${FLAGS_fw_link_name}" ]; then
    die "Firmware link name is empty."
  fi
  if [ -z "${FLAGS_updater_name}" ]; then
    die "Updater name is empty."
  fi
  if [ -z "${FLAGS_product_id}" ]; then
    die "Product ID is empty."
  fi

  log_msg "${FLAGS_updater_name} device detected. Kernel handles firmware update natively."

  # The kernel driver natively flashes the firmware during boot.
  # Read and report the active firmware version running on the hardware first.
  # The helper runs in a subshell, so its die() only exits that subshell. Check
  # the exit status too, so an error message is never reported as the version.
  if ! active_fw_version="$(get_active_firmware_version_from_sysfs \
      "firmware_version" "${FLAGS_device_path}")" ||
     [ -z "${active_fw_version}" ]; then
    die "Could not read firmware_version from ${FLAGS_device_path}"
  fi

  log_msg "Current Firmware: ${active_fw_version}"
  report_initial_version "${FLAGS_device_path}" "${FLAGS_updater_name}" \
    "${active_fw_version}"

  # chromeos-config doesn't enforce a case for the product ID in firmware file
  # names, but the kernel reports it in upper case, so look for both.
  product_id_lowercase="$(echo "${FLAGS_product_id}" | tr '[:upper:]' \
    '[:lower:]')"
  fw_link_path="$(find_fw_link_path "${FLAGS_fw_link_name}" \
    "${FLAGS_product_id}" "${product_id_lowercase}")"
  fw_path="$(readlink -f "${fw_link_path}")"
  log_msg "Attempting to load FW: '${fw_link_path}' link to '${fw_path}'"
  if [ ! -e "${fw_link_path}" ] || [ ! -e "${fw_path}" ]; then
    die "No valid firmware found at ${fw_link_path}"
  fi

  fw_filename="${fw_path##*/}"
  fw_name="${fw_filename%.*}"
  product_id="${fw_name%_*}"
  fw_version="${fw_name#"${product_id}_"}"
  product_id="$(echo "${product_id##*_}" | tr '[:upper:]' '[:lower:]')"

  if [ "${product_id}" != "${product_id_lowercase}" ]; then
    log_msg "Current product id: ${FLAGS_product_id}"
    log_msg "Updater product id: ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  if [ -z "${fw_version}" ] || [ "${fw_version}" = "${fw_name}" ]; then
    die "Unable to parse firmware version from ${fw_filename}"
  fi

  log_msg "Updater Firmware: ${fw_version}"

  # REPORT_RESULT_* are defined in chromeos-touch-common.sh. The ":?" makes
  # the script exit with an error if they are unset or empty.
  if [ "${active_fw_version}" = "${fw_version}" ]; then
    log_msg "Firmware is up-to-date. Reporting success."
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_SUCCESS:?}" \
      "${active_fw_version}"
  else
    report_update_result "${FLAGS_device_path}" "${REPORT_RESULT_FAILURE:?}" \
      "${fw_version}"
    die "Firmware version mismatch! Expected ${fw_version}, got ${active_fw_version}."
  fi

  exit 0
}

main "$@"
