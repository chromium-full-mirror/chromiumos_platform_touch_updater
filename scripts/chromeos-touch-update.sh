#!/bin/sh
#
# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /opt/google/touch/scripts/chromeos-touch-common.sh

LOGGER_TAG="chromeos-touch-update"

# Touch firmware and config updater for Chromebooks
WACOM_VENDOR_ID_1="056A"
WACOM_VENDOR_ID_2="2D1F"
SYNAPTICS_VENDOR_ID="06CB"
WEIDA_VENDOR_ID="2575"
GOOGLE_VENDOR_ID="18D1"
GOODIX_VENDOR_ID="27C6"
SIS_VENDOR_ID="0457"
PIXART_VENDOR_ID="093A"
G2TOUCH_VENDOR_ID="2A94"
ST_VENDOR_ID="0483"

# Current firmware status returned by compare_fw_versions in vendor scripts
UP_TO_DATE="0"
OUTDATED="1"
ROLLBACK="2"
CORRUPTED="3"

# For devices supporting runtime power managment, the "auto" mode would have
# chance to let device go into runtime_suspend state. Which will prevent
# touch updater from accessing that device. Here tries to move i2c devices's
# state from "auto" to "on" then restoring them in the end of update
# process.
power_on() {
  local dev="$1"
  local power_path="${dev}/power/control"
  if [ -e "${power_path}" ] && [ "auto" = "$(cat "${power_path}")" ]; then
    echo "on" > "${power_path}"
    echo "${power_path}"
  else
    echo ""
  fi
}

power_auto() {
  local power_path="$1"
  if [ ! -z "${power_path}" ]; then
    echo "auto" > "${power_path}" ||
    logger -t "${LOGGER_TAG}" "Restore ${power_path} to auto failed."
  fi
}

run() {
  local vendor_scripts="\
    $(echo /opt/google/touch/scripts/chromeos-*-touch-firmware-update.sh)"
  local script=""
  local action="$1"
  local dev="$2"
  local vendor=""

  if [ ! -e "${dev}" ]; then
    printf "Device not found: %s\n" "${dev}"
    return 1
  fi

  # Find the applicable vendor script for the device.
  for script in ${vendor_scripts}; do
    source "${script}"
    if check_applicability "${dev}"; then
      vendor="$(get_vendor_name)"
      break
    fi
  done

  if [ -z "${vendor}" ]; then
    printf "No applicable script found for device: %s\n" "${dev}"
    return 1
  fi

  local active="$(get_active_fw_version "${dev}")"
  local latest="$(get_latest_fw_version "${dev}")"
  local firmware_status="$(compare_fw_versions "${active}" "${latest}")"

  if [ "${action}" = "update" -a "${firmware_status}" != "${UP_TO_DATE}" ]; then
    local power_path="$(power_on "${dev}")"
    update "${dev}"
    config "${dev}"
    power_auto "${power_path}"
  fi

  # TODO(b/129671661): Determine output format.
  # Should not use logger if called manually.
  # Should not use multiple `echo`s because of concurrent execution.
}

main() {
  local action="update"  # Default action
  local devices=""
  local dev=""

  # TODO(frankbozar): Use `getopts` or `shflags`.
  if [ "$1" = "--info" ]; then
    action="info"
    shift
  fi

  if [ "$#" -eq 0 ]; then
    devices="$(get_dev_list)"
  else
    devices="$@"
  fi

  for dev in ${devices}; do
    run "${action}" "${dev}" &
  done

  wait
}

# main "$@"
/opt/google/touch/scripts/chromeos-touch-update-legacy.sh

