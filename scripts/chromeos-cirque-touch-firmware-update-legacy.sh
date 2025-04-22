#!/bin/sh

# Copyright 2025 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This isn't the exact copy that will be used in production, but it's better
# than pointing shellcheck at /dev/null.
# shellcheck source=../../../scripts/lib/shflags/shflags
. /usr/share/misc/shflags
# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' "${FLAGS_FALSE}" "Recovery. Allows for rollback" 'r'
DEFINE_string 'device_path' '' "device path" 'p'
DEFINE_string 'device_pid' '' "device pid" 'i'

CIRQUE_FW_LINK_BASE="cirque_firmware.hex"
CIRQUE_FW_UPDATER="/usr/sbin/cirque_touch_fw_update"
GET_ACTIVE_FWVER="-a"

# Parse command line.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  # Run the Cirque firmware updater in minijail.
  local fw_link="$1"
  local dev_path="$2"
  local cmd_log=""
  if ! cmd_log="$(
    minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -v -P /mnt/empty -b / -b /dev,,1 -b /sys -b /proc/ \
      -t --uts -e -l -p -N -n -S \
      /opt/google/touch/policies/cirque.update.policy \
      "${CIRQUE_FW_UPDATER}" "${fw_link}" "${dev_path}" 2>&1
  )"; then
    log_msg "error: Cirque firmware updater returned failure:\n${cmd_log}"
    return 1
  fi
  return 0
}

get_fw_version_from_disk() {
  # The on-disk FW version is determined by reading the filename which
  # is in the format "VID_PID_FWmajor.FWminor.hex".  We follow the fw's
  # link to the actual file then strip away everything in the FW's
  # filename but the FW version.
  local fw_link="$1"
  local fw_filepath=""
  local fw_filename=""
  local fw_ver=""

  if [ ! -L "${fw_link}" ]; then
    return
  fi
  fw_filepath="$(readlink -f "${fw_link}")"
  if [ ! -e "${fw_filepath}" ]; then
    return
  fi

  fw_filename="$(basename "${fw_filepath}")"
  if [ "${fw_filename%%_*}" != "0488" ]; then
    return
  fi
  fw_ver="${fw_filename#*_}"
  fw_ver="${fw_ver#*_}"
  fw_ver="${fw_ver%.*}"
  echo "${fw_ver}"
}

get_active_fw_version() {
  local dev_path="$1"
  local active_fw_ver

  if active_fw_ver="$(
    minijail0 -u fwupdate-hidraw -g fwupdate-hidraw \
      -G -v -P /mnt/empty -b / -b /dev,,1 -b /sys -b /proc/ \
      -t --uts -e -l -p -N -n -S \
      /opt/google/touch/policies/cirque.query.policy \
      "${CIRQUE_FW_UPDATER}" "${GET_ACTIVE_FWVER}" "${dev_path}"
  )"; then
    echo "${active_fw_ver}"
  fi
}

cirque_rebind_driver() {
  # Unbind and then bind the driver for this touchpad.
  local touch_device_path="$1"
  local bus_id=""
  local driver_path
  driver_path="$(readlink -f "${touch_device_path}"/driver)"

  # If the driver is not hid-multitouch, we need
  # to rebind the driver to the parent device.
  if [ "$(basename "${driver_path}")" = "hid-multitouch" ]; then
    bus_id="$(basename "${touch_device_path}")"
  else
    bus_id="$(readlink -f "${touch_device_path}")"
    bus_id="${bus_id%/*}"
    driver_path="$(readlink -f "${bus_id}/driver")"
    bus_id="$(basename "${bus_id}")"
  fi

  log_msg \
    "Attempting to re-bind Cirque device '${bus_id}' to driver '${driver_path}'"
  if ! (echo "${bus_id}" > "${driver_path}/unbind")
  then
    log_msg "Unable to unbind Cirque device."
  fi
  local retry_cnt=1
  local bind_result=1
  if (echo "${bus_id}" > "${driver_path}/bind")
  then
    bind_result=0
  fi
  # For some boards, the device will be powered off when the kernel driver
  # unbinds. Bind the driver immediately after powering off will fail.
  while [ "${bind_result}" -ne "0" ] && [ "${retry_cnt}" -le "4" ]; do
    retry_cnt="$((retry_cnt + 1))"
    log_msg "Failed to bind driver to Cirque device, will retry."
    sleep "${retry_cnt}"
    if (echo "${bus_id}" > "${driver_path}/bind")
    then
      bind_result=0
    fi
  done

  if [ "${bind_result}" -ne "0" ]; then
    log_msg "Unable to bind Cirque device back to the driver."
    return 1
  else
    log_msg "Cirque device successfully bound to the driver."
    return 0
  fi
}

main() {
  # This script runs early at bootup, so if the touch driver is mistakenly
  # included as a module (as opposed to being compiled directly in) the i2c
  # device may not be present yet. Pause long enough for for people to notice
  # and fix the kernel config.
  check_i2c_chardev_driver

  local active_fw_ver=""
  local new_fw_ver=""
  local fw_link="/lib/firmware/${CIRQUE_FW_LINK_BASE}"
  local dev_path
  dev_path=$(echo "${FLAGS_device_path}"/hidraw/hidraw*)
  if [ ! -d "${dev_path}" ]; then
    die "Unable to find Cirque device path."
  fi
  dev_path="/dev/${dev_path##*/}"
  if [ ! -c "${dev_path}" ]; then
    die "Unable to find Cirque device file."
  fi
  log_msg "Updating Cirque device with product ID ${FLAGS_device_pid}"

  active_fw_ver="$(get_active_fw_version "${dev_path}")"
  report_initial_version "${FLAGS_device_path}" "Cirque" "${active_fw_ver}"
  # If we cannot determine the active firmware version, force an update.
  if [ -z "${active_fw_ver}" ]; then
    log_msg "warning: Could not determine the active firmware version."
    log_msg "You may need to reboot the computer to reload touchpad driver."
    FLAGS_recovery="${FLAGS_TRUE}"
  else
    log_msg "Active firmware version of the Cirque device: ${active_fw_ver}"
  fi

  fw_link="$(find_fw_link_path "${CIRQUE_FW_LINK_BASE}" "${FLAGS_device_pid}")"
  # Quit if no firmware is found for the specified product ID.
  if [ "${fw_link}" = "/lib/firmware/${CIRQUE_FW_LINK_BASE}" ]; then
    die "No firmware found for this device."
  fi

  new_fw_ver="$(get_fw_version_from_disk "${fw_link}")"
  # If we cannot determine the new firmware version, we fail the update.
  if [ -z "${new_fw_ver}" ]; then
    die "Unable to find new Cirque FW version on disk."
  fi

  log_msg "New firmware version for the Cirque device: ${new_fw_ver}"

  # Compare firmware versions.
  local active_fw_ver_major="${active_fw_ver%%.*}"
  local active_fw_ver_minor="${active_fw_ver##*.}"

  local new_fw_ver_major="${new_fw_ver%%.*}"
  local new_fw_ver_minor="${new_fw_ver##*.}"

  # Log update type.
  local update_type
  update_type="$(compare_multipart_version \
     "${active_fw_ver_major}" "${new_fw_ver_major}" \
     "${active_fw_ver_minor}" "${new_fw_ver_minor}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"
  if [ "${update_needed}" -ne "${FLAGS_TRUE}" ]; then
    log_msg \
    "Cirque firmware update not required. Current firmware: ${active_fw_ver}"
    exit 0
  fi

  log_msg "Updating Cirque firmware to ${new_fw_ver}"
  if ! run_cmd_and_block_powerd update_firmware "${fw_link}" "${dev_path}" ;
  then
    report_update_result "${FLAGS_device_path}" \
      "${REPORT_RESULT_FAILURE}" "${new_fw_ver}"
    die "Cirque firmware update failed. Current firmware: ${active_fw_ver}"
  fi

  # Check if update was successful
  active_fw_ver="$(get_active_fw_version "${dev_path}")"
  if [ -z "${active_fw_ver}" ] || \
    [ "${active_fw_ver%%.*}" -ne "${new_fw_ver%%.*}" ] || \
    [ "${active_fw_ver##*.}" -ne "${new_fw_ver##*.}" ]; then
    report_update_result "${FLAGS_device_path}" \
      "${REPORT_RESULT_FAILURE}" "${new_fw_ver}"
    die "Cirque firmware update failed. Current firmware: ${active_fw_ver}"
  fi

  report_update_result "${FLAGS_device_path}" \
    "${REPORT_RESULT_SUCCESS}" "${active_fw_ver}"
  log_msg \
    "Cirque firmware update successful. Current firmware: ${active_fw_ver}"

  cirque_rebind_driver "${FLAGS_device_path}"

  exit 0
}

main "$@"
