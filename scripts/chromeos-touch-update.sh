#!/bin/sh
#
# Copyright 2019 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

LOGGER_TAG="chromeos-touch-update"

# Current firmware status returned by compare_fw_versions in vendor scripts
UP_TO_DATE="0"
# shellcheck disable=SC2034  # Unused variables pending TODO(b/129671661).
OUTDATED="1"
# shellcheck disable=SC2034  # Unused variables pending TODO(b/129671661).
ROLLBACK="2"
# shellcheck disable=SC2034  # Unused variables pending TODO(b/129671661).
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
  if [ -n "${power_path}" ]; then
    echo "auto" > "${power_path}" ||
    logger -t "${LOGGER_TAG}" "Restore ${power_path} to auto failed."
  fi
}

run() {
  local active
  local firmware_status
  local latest
  local vendor_scripts

  local action="$1"
  local dev="$2"
  local script=""
  local vendor=""

  vendor_scripts="\
    $(echo /opt/google/touch/scripts/chromeos-*-touch-firmware-update.sh)"

  if [ ! -e "${dev}" ]; then
    printf "Device not found: %s\n" "${dev}"
    return 1
  fi

  # Find the applicable vendor script for the device.
  for script in ${vendor_scripts}; do
    . "${script}"
    if check_applicability "${dev}"; then
      vendor="$(get_vendor_name)"
      break
    fi
  done

  if [ -z "${vendor}" ]; then
    printf "No applicable script found for device: %s\n" "${dev}"
    return 1
  fi

  active="$(get_active_fw_version "${dev}")"
  latest="$(get_latest_fw_version "${dev}")"
  firmware_status="$(compare_fw_versions "${active}" "${latest}")"

  if [ "${action}" = "update" ] && [ "${firmware_status}" != "${UP_TO_DATE}" ];
  then
    local power_path
    power_path="$(power_on "${dev}")"
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
    devices="$*"
  fi

  for dev in ${devices}; do
    run "${action}" "${dev}" &
  done

  wait
}

# main "$@"
/opt/google/touch/scripts/chromeos-touch-update-legacy.sh
