#!/bin/sh

# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device_path' '' "device path" 'p'

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

FW_LINK="/lib/firmware/st_touch.bin"

# Sysfs entry created by cros_ec driver.
CROS_TP_SYSFS="/sys/class/chromeos/cros_tp"

# Flashrom programmer argument, we are type "tp"
PROGRAMMER="ec:type=tp"

# ACPI device sysfs entry for touchpad
CROS_TP_ACPI_PATH="/sys/bus/acpi/devices/ACPI0C50:00"

extract_numerical_fw_version() {
  # FW version string has the following format:
  # rose_v1.1.6371-3fc259f2c
  # This function extract the "numerical" part, which is "1.1.6371"
  echo $1 | sed -n "s/^.*_v\(.*\)-.*$/\1/p"
}

get_minor_version() {
  local major_minor=${1%.*}
  echo ${major_minor#*.}
}

compare_fw_versions() {
  # FW version string has the following format:
  # rose_v1.1.6371-3fc259f2c
  # We only need to compare the numeric part of the version string.
  local active_fw_ver_raw="$1"
  local updater_fw_ver_raw="$2"
  local active_fw_ver="$(extract_numerical_fw_version "${active_fw_ver_raw}")"
  local updater_fw_ver="$(extract_numerical_fw_version "${updater_fw_ver_raw}")"

  local active_fw_ver_major="${active_fw_ver%%.*}"
  local active_fw_ver_minor="$(get_minor_version "${active_fw_ver}")"
  local active_fw_ver_revision="${active_fw_ver##*.}"

  local updater_fw_ver_major="${updater_fw_ver%%.*}"
  local updater_fw_ver_minor="$(get_minor_version "${updater_fw_ver}")"
  local updater_fw_ver_revision="${updater_fw_ver##*.}"

  compare_multipart_version "${active_fw_ver_major}" "${updater_fw_ver_major}" \
                            "${active_fw_ver_minor}" "${updater_fw_ver_minor}" \
                            "${active_fw_ver_revision}" "${updater_fw_ver_revision}"
}

get_fw_version_from_disk() {
  # The on-disk FW version is determined by reading the filename which
  # is in the format "st_FWVERSION.hex" where the fw version is a hex
  # number preceeded by 0x and using lower case letters. We follow the fw's
  # link to the actual file then strip away everything in the FW's filename
  # but the FW version.
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
  fw_ver="${fw_filename#*_}"
  fw_ver="${fw_ver%.*}"
  echo "${fw_ver}"
}

get_active_fw_version() {
  local fw_copy=$(cat "${CROS_TP_SYSFS}"/version | awk 'NR==3 { print $3 }')

  # If we TP firmware is still in RO, wait 1 second for it to jump to RW.
  if [ "${fw_copy}" = "RO" ]; then
    sleep 1
    fw_copy=$(cat "${CROS_TP_SYSFS}"/version | awk 'NR==3 { print $3 }')
  fi

  cat "${CROS_TP_SYSFS}"/version | grep ${fw_copy} | awk 'NR==1 { print $3 }'
}

prepare_message() {
  # Prepare image for displaying in frecon.
  local message="
    <span font=\"Noto Sans UI 16\"
          foreground=\"black\">"

  printf "${message}\n"
  # Append messages with newline.
  for message in "$@"; do
    printf "${message}\n"
  done
  printf "</span>"
}

display_message() {
  # Display message in frecon.
  local message_file="$(mktemp --tmpdir)"
  prepare_message "$@" >"${message_file}"
  SPINNER_INTERVAL=25 display_boot_message "show_spinner" "${message_file}"
  rm -rf ${message_file}  # show be safe to delete this.
}

display_splash() {
  display_message "Touchpad firmware update in progress..."\
                  "Please keep your hands off the touchpad."\
                  "This will take around 2 minutes."
}

clear_splash() {
  # Clear screen by killing frecon
  pkill -9 -f frecon
}

force_flash() {
  display_splash

  st_flash --board=eve "${FW_LINK}"

  if [ "$?" -ne "0" ]; then
    die "Unable to flash new touchpad firmware, abort."
  fi

  # We need a reboot so the cros_ec kernel driver get reloaded. This should
  # only happen once when device is transiting from old firmware to EC
  # firmware.
  log_msg "========================== WARNING =========================="
  log_msg "Reboot to reload touchpad driver, this will only happen once."
  log_msg "============================================================="
  reboot
  exit 0  # Reboot is not a blocking call, so we need to explicity exit.
}

main() {
  local ret

  # TODO(wnhuang): remove the following code once the transition is completed
  # and we no longer have TP using the old firmware.

  # If we are not running EC firmware, use st_flash to flash EC firmware.
  if [ ! -e "${CROS_TP_SYSFS}" ]; then
    # If we have device with old AP firmware, abort firmware update completely.
    if [ ! -e "${CROS_TP_ACPI_PATH}" ]; then
      die "Old AP firmware detected, update aborted."
    fi

    log_msg "Transiting to new touchpad firmware, forcing an update."
    force_flash
  fi

  # Active firmware version (RW version)
  local active_fw_ver="$(get_active_fw_version)"
  local updater_fw_ver="$(get_fw_version_from_disk "${FW_LINK}")"
  log_msg "Current active fw version is: '${active_fw_ver}'"
  log_msg "Current updater fw version is: '${updater_fw_ver}'"
  if [ -z "${active_fw_ver}" ]; then
    log_msg "Unable to detect the active FW version, forcing a reflash."
    force_flash
  fi
  if [ -z "${updater_fw_ver}" ]; then
    die "Unable to detect the updater's FW version on disk."
  fi

  update_type="$(compare_fw_versions "${active_fw_ver}" "${updater_fw_ver}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${updater_fw_ver}"

    display_splash

    # Determine if WP is enabled
    local extra_flashrom_arg=""
    local wp_status="$(flashrom -p "${PROGRAMMER}" --wp-status | \
                       sed -n 's/WP: status: \(.*\)/\1/p' 2>/dev/null)"

    # Only update RW section if WP is enabled
    if [ "${wp_status}" != "0x00" ]; then
      extra_flashrom_arg="-i EC_RW"
    fi

    # Run the actual firmware update
    flashrom -p "${PROGRAMMER}" ${extra_flashrom_arg} -w "${FW_LINK}"

    # Check if update was successful
    active_fw_ver="$(get_active_fw_version)"
    update_type="$(compare_fw_versions "${active_fw_ver}" "${updater_fw_ver}")"
    if [ "${update_type}" -ne "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_ver}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_ver}"

    rebind_driver "${FLAGS_device_path}"
    if [ "$?" -ne "0" ]; then
      log_msg "Driver rebind failed, doing a reboot to reload driver."
      reboot
      exit 0
    fi

    clear_splash
  fi
}

main "$@"
