#!/bin/sh

# Copyright 2013 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Touch firmware vendor ids.
ELAN_VENDOR_ID="04F3"
PIXART_VENDOR_ID="093A"

I2C_DEVICES_PATH="/sys/bus/i2c/devices"

# powerd will check this lock file and block device suspension.
POWERD_LOCK_FILE="/run/lock/power_override/touch_updater.lock"

# Get the sysfs paths of all I2C and HID devices that might be a touch device.
get_dev_list() {
  # Filter failed glob expansion.
  local failed_glob_pattern='/\*$'
  # Filter Pixart HID because it also shows up in I2C list.
  local pixart_pattern=':'"${PIXART_VENDOR_ID}"':[0-9A-F]{4}\.'
  # Include the psmouse/trackpoint devices in serio bus driver.
  find /sys/bus/i2c/devices /sys/bus/hid/devices /sys/bus/serio/devices -mindepth 1 -maxdepth 1 \
    | grep --invert-match -E \
      "(${failed_glob_pattern}|${pixart_pattern})"
}

# The function will run the cmd and block powerd from suspending the system.
# It's done by creating the lock file while the cmd is running. Remove the lock
# file once it returns.
run_cmd_and_block_powerd() {
  trap 'rm -f "${POWERD_LOCK_FILE}"' EXIT
  echo $$ > "${POWERD_LOCK_FILE}"
  "$@"
  rm -f "${POWERD_LOCK_FILE}"
  trap - EXIT
}

# Find touchscreen/pad path in /sys/bus/i2c/devices given its device name and a
# list of the sysfs entries it is expect to have (this can help skip over some
# bogus devices that have already been disconnected).
# The required sysfs filenames should be supplied as a space-delimited string.
find_i2c_device_by_name() {
  local dev=""
  local name_to_find="$1"
  local required_sysfs="$2"

  for dev in "${I2C_DEVICES_PATH}"/*/name; do
    local dev_name
    dev_name="$(cat "${dev}")"
    if [ "${name_to_find}" = "${dev_name}" ]; then
      local missing_sysfs_entry=0
      local path="${dev%/name}"

      for sysfs in ${required_sysfs}; do
        if [ ! -e "${path}/${sysfs}" ]; then
          missing_sysfs_entry=1
        fi
      done

      if [ "${missing_sysfs_entry}" -eq 0 ]; then
        echo "${path}"
        return 0
      fi
    fi
  done
  return 1
}

find_i2c_hid_device() {
  local dev=""
  local path=""
  local vid="${1%_*}"
  local pid="${1#*_}"
  local preferred_search_path="${2}"

  for dev in ${preferred_search_path} "${I2C_DEVICES_PATH}"/*/; do
    local driver_name
    driver_name="$(readlink -f "${dev}"/driver | xargs basename)"
    case "${driver_name}" in
    i2c_hid*)
      local hid_path
      hid_path=$(echo "${dev}"/*:"${vid}":"${pid}".*)
      if [ -d "${hid_path}" ]; then
        local hidraw_sysfs_path
        hidraw_sysfs_path=$(echo "${hid_path}"/hidraw/hidraw*)
        path="/dev/${hidraw_sysfs_path##*/}"
        break
      fi
      ;;
    esac
  done
  echo "${path}"
}

# Given a generic name and one or two hardware versions (or product IDs
# depending on the device), determine which firmware symlink in /lib/firmware
# we should try to load. Checks for symlinks in this order:
#   <fw_link_name>_<hw_ver1>.<extension>
#   <fw_link_name>_<hw_ver2>.<extension>
#   <fw_link_name>.<extension>
#
# For example, `find_fw_link_path acme.bin alpha beta` will look for the
# following symlinks, in order:
#   /lib/firmware/acme_alpha.bin
#   /lib/firmware/acme_beta.bin
#   /lib/firmware/acme.bin
#
# It will then output the full path of the first of those which exists.
find_fw_link_path() {
  local fw_link_name="$1"
  local hw_ver1="$2"
  local hw_ver2="$3"
  local specific_fw_link_path=""
  local specific_fw_link_path2=""
  local generic_fw_link_path=""
  local fw_link_name_extension
  fw_link_name_extension="$(expr "${fw_link_name}" : ".*\(\..*\)")"
  local fw_link_name_base="${fw_link_name%"${fw_link_name_extension}"}"

  case ${fw_link_name_base} in
  /*) fw_link_path="${fw_link_name_base}" ;;
  *)  fw_link_path="/lib/firmware/${fw_link_name_base}" ;;
  esac

  specific_fw_link_path="${fw_link_path}_${hw_ver1}${fw_link_name_extension}"
  specific_fw_link_path2="${fw_link_path}_${hw_ver2}${fw_link_name_extension}"
  generic_fw_link_path="${fw_link_path}${fw_link_name_extension}"

  if [ -e "${specific_fw_link_path}" ]; then
    echo "${specific_fw_link_path}"
  elif [ -n "${hw_ver2}" ] && [ -e "${specific_fw_link_path2}" ]; then
    echo "${specific_fw_link_path2}"
  else
    echo "${generic_fw_link_path}"
  fi
}

standard_update_firmware() {
  # Update a touch device by piping a "1" into a sysfs entry called update_fw
  # This is a common method for triggering a FW update, and it used by several
  # different touch vendors.
  local touch_device_path="$1"
  local fw_version="$2"
  local i=""
  local ret=""

  for i in $(seq 5); do
    printf 1 > "${touch_device_path}/update_fw"
    ret=$?
    if [ "${ret}" -eq 0 ]; then
      return 0
    fi
    log_msg "update_firmware try #${i} failed... retrying."
  done
  report_update_result "${touch_device_path}" "${REPORT_RESULT_FAILURE}" \
    "${fw_version}"
  die "Error updating touch firmware. ${ret}"
}

get_active_firmware_version_from_sysfs() {
  local sysfs_name="$1"
  local touch_device_path="$2"
  local fw_version_sysfs_path="${touch_device_path}/${sysfs_name}"

  if [ -e "${fw_version_sysfs_path}" ]; then
    cat "${fw_version_sysfs_path}"
  else
    die "No firmware version sysfs at ${fw_version_sysfs_path}."
  fi
}

# Unbind and then re-bind the driver for this touch device, to ensure consistent
# state between the device and OS.
rebind_driver() {
  local touch_device_path=
  local driver_path=
  local bus_id=
  local ret=

  # Required args
  # POSIX allows, but does not require, shift to exit a non-interactive shell.
  touch_device_path="$1"; [ "$#" -gt 0 ] || return; shift

  # Optional: Specify the /sys driver path.  This is **REQUIRED** unless your
  # touch device is guaranteed to enumerate even with corrupted or erased
  # firmware!  Without driver_path specified, this function can only determine
  # it if the device is currently bound to its driver.
  driver_path="$1"; [ "$#" -eq 0 ] || shift

  # Fallback for updaters which do not specify the driver_path arg.
  if [ -z "${driver_path}" ]; then
    driver_path="$(readlink -f "${touch_device_path}/driver")"
  fi

  bus_id="$(basename "${touch_device_path}")"

  log_msg "Attempting to re-bind '${bus_id}' to driver '${driver_path}'"
  echo "${bus_id}" > "${driver_path}/unbind"
  ret="$?"
  if [ "${ret}" -ne 0 ]; then
    log_msg "Unable to unbind the device from the driver, error ${ret}. This " \
      "is sometimes expected when recovering from corrupted firmware. " \
      "Continuing with attempt to bind the device to the driver."
  fi

  echo "${bus_id}" > "${driver_path}/bind"
  ret="$?"
  if [ "${ret}" -ne 0 ]; then
    log_msg "Unable to bind the device to the driver."
    return 1
  fi

  log_msg "Device (re)bind to driver success."
}

hex_to_decimal() {
  printf "%d" "0x""$1"
}

# Disable SC2145 due to the fact that there is no way to fix it without
# side-effects. We would be guessing at the intent of the authors.
# SC2154 is also disabled so that all the fixes for this function
# can be done together.
#
# TODO: b/314386667 - Remove shellcheck disable.
# shellcheck disable=SC2145,SC2154
log_msg() {
  local script_filename
  script_filename="$(basename "$0")"
  logger -t "${script_filename%.*}" --id=$$ "${FLAGS_device} $@"
  echo "$@"
}

die() {
  log_msg "error: $*"
  exit 1
}


# These flags can be used as "update types" to indicate updater state
UPDATE_NEEDED_OUT_OF_DATE="1"
UPDATE_NEEDED_RECOVERY="2"
UPDATE_NOT_NEEDED_UP_TO_DATE="3"
UPDATE_NOT_NEEDED_AHEAD_OF_DATE="4"

log_update_type() {
  # Given the update type, print a corresponding message into the logs.
  local update_type="$1"
  if [ "${update_type}" -eq "${UPDATE_NEEDED_OUT_OF_DATE}" ]; then
    log_msg "Update needed, firmware out of date."
  elif [ "${update_type}" -eq "${UPDATE_NEEDED_RECOVERY}" ]; then
    log_msg "Recovery firmware update. Rolling back."
  elif [ "${update_type}" -eq "${UPDATE_NOT_NEEDED_UP_TO_DATE}" ]; then
    log_msg "Firmware up to date."
  elif [ "${update_type}" -eq "${UPDATE_NOT_NEEDED_AHEAD_OF_DATE}" ]; then
    log_msg "Active firmware is ahead of updater, no update needed."
  else
    log_msg "Unknow update type '${update_type}'."
  fi
}

is_update_needed() {
  # Given an update type, this function returns a boolean indicating if the
  # updater should trigger an update at all.
  local update_type="$1"
  if [ "${update_type}" -eq "${UPDATE_NEEDED_OUT_OF_DATE}" ] ||
     [ "${update_type}" -eq "${UPDATE_NEEDED_RECOVERY}" ]; then
    echo "${FLAGS_TRUE}"
  else
    echo "${FLAGS_FALSE}"
  fi
}

# This supports hexadecimal numbers (0x / 0X prefix) and decimal numbers (no
# prefix).  Currently leading zero (0) prefix is treated as decimal for
# compatibility with old updater scripts that might output them.
_canonicalize_ver_num() {
  echo "$(( $(echo "$1" | sed 's/^0\+\([^Xx]\)/\1/') ))"
}

compare_multipart_version() {
  # Compare firmware versions that are of the form A.B...Y.Z
  # The numbers may be hexadecimal (0x / 0X prefix) or decimal (no prefix).
  # octal (0 prefix).  Currently leading zero (0) prefix is treated as decimal
  # for compatibility with old updater scripts that might output them.
  #
  # To call this function interleave the two version strings by
  # importance, starting with the active FW version.
  # eg: If your active version is A.B.C and the fw updater is X.Y.Z
  #     you should call compare_multipart_version A X B Y C Z
  local update_type=
  local num_parts=
  local active_component=
  local updater_component=

  num_parts="$(($# / 2))"

  # Starting with the most significant values, compare them one
  # by one until we find a difference or run out of values.
  for i in $(seq "${num_parts}"); do
    active_component="$(_canonicalize_ver_num "$1")"; shift
    updater_component="$(_canonicalize_ver_num "$1")"; shift
    if [ "${active_component}" -lt "${updater_component}" ]; then
      update_type="${UPDATE_NEEDED_OUT_OF_DATE}"
    elif [ "${active_component}" -gt "${updater_component}" ]; then
      update_type="${UPDATE_NOT_NEEDED_AHEAD_OF_DATE}"
    else
      continue
    fi
    break
  done

  if [ -z "${update_type}" ]; then
    update_type="${UPDATE_NOT_NEEDED_UP_TO_DATE}"
  elif [ "${FLAGS_recovery:-}" -eq "${FLAGS_TRUE}" ] &&
       [ "${update_type}" = "${UPDATE_NOT_NEEDED_AHEAD_OF_DATE}" ]; then
    update_type="${UPDATE_NEEDED_RECOVERY}"
  fi

  echo "${update_type}"
}

get_chassis_id() {
  # Get an identifier of chassis that may need different touchpad firmware on
  # devices sharing same image, even same main logic board.
  # Note: chassis id is just the model name in uppercase.
  cros_config / name | tr '[:lower:]' '[:upper:]'
}

get_platform_ver() {
  # Get platform version, since different boards (EVT, DVT etc) may need
  # different touchpad firmware on devices sharing same image.
  crossystem board_id
}

i2c_chardev_present() {
  # This function tests to see if there are any i2c char devices on the system.
  # It returns 0 iff /dev/i2c-* matches at least one file.
  local f=""
  for f in /dev/i2c-*; do
    if [ -e "${f}" ]; then
      return 0
    fi
  done
  return 1
}

check_i2c_chardev_driver() {
  # Check to make sure the required drivers are already availible.
  if ! i2c_chardev_present; then
    modprobe i2c-dev
    log_msg "Please compile I2C_CHARDEV into the kernel"
    log_msg "Sleeping 15s to wait for them to show up"

    # Without this the added delay is small enough that a human might not
    # notice that they had just slowed down the boot time by removing the
    # driver from the kernel.
    sleep 15
  fi
}

REPORT_FILE="/run/touch-updater/firmware-versions"

# Adds an entry to the report file for a touch device. Update scripts should
# generally use the report_* functions below instead.
# Parameters (in order):
#   sysfs_path: the sysfs path for the entry, beginning either /sys/devices or
#               /sys/bus/i2c/devices.
#   json_fields: a string containing the JSON fields to include in the object,
#                without curly braces (e.g. "\"foo\": \"bar\"")
#   extra_json_fields: more JSON fields to be added to the object. Optional.
add_report_entry() {
  local sysfs_path="$1"
  local json_fields="$2"
  local extra_json_fields="$3"

  case "${sysfs_path}" in
  /sys/bus/i2c/devices/*) sysfs_path=$(readlink -f "${sysfs_path}");;
  esac

  if [ -n "${extra_json_fields}" ]; then
    json_fields="${json_fields}, ${extra_json_fields}"
  fi
  echo "${sysfs_path}" '{'"${json_fields}"'}' >> "${REPORT_FILE}"
}

# Makes an untrusted string safe to include in a JSON object (by removing
# quotes and newlines).
make_json_safe() {
  echo "$1" | tr --delete '\n"'
}

# The version value that represents a device being in recovery mode.
export REPORT_VERSION_RECOVERY="(recovery)"

# Adds a report entry giving the initial state of a touch device.
# Parameters:
#   sysfs_path: a path to the device in sysfs (see add_report_entry).
#   updater: a name identifying the updater in use.
#   initial_version: the firmware version found on the touch device.
#   optional_extra_fields: extra JSON fields to be added to the object. **When
#                          creating, use make_json_safe on any value from an
#                          untrusted binary (e.g. an updater).** Optional.
report_initial_version() {
  local sysfs_path="$1"
  local updater
  local initial_version
  local optional_extra_fields="$4"

  updater="$(make_json_safe "$2")"
  initial_version="$(make_json_safe "$3")"

  local json_fields="\"updater\": \"${updater}\","
  json_fields="${json_fields} \"initial_version\": \"${initial_version}\""
  add_report_entry "${sysfs_path}" "${json_fields}" "${optional_extra_fields}"
}

export REPORT_RESULT_FAILURE="FAILURE"
export REPORT_RESULT_SUCCESS="SUCCESS"

# Adds a report entry describing the result of an update attempt.
# Parameters:
#   sysfs_path: a path to the device in sysfs (see add_report_entry).
#   update_status: one of $REPORT_RESULT_{FAILURE,SUCCESS}
#   flashed_version: the firmware version that the updater attempted to flash
#                    (whether or not it was successful).
report_update_result() {
  local sysfs_path="$1"
  local update_status
  local flashed_version

  update_status="$(make_json_safe "$2")"
  flashed_version="$(make_json_safe "$3")"

  local json_fields="\"update_status\": \"${update_status}\","
  json_fields="${json_fields} \"flashed_version\": \"${flashed_version}\""
  add_report_entry "${sysfs_path}" "${json_fields}"
}

# Adds a report entry stating the config version found on a touch device.
# Parameters:
#   sysfs_path: a path to the device in sysfs (see add_report_entry).
#   initial_config: the config version or hash on the touch device initially.
report_initial_config() {
  local sysfs_path="$1"
  local initial_config
  initial_config="$(make_json_safe "$2")"
  add_report_entry "${sysfs_path}" "\"initial_config\": \"${initial_config}\""
}

# Adds a report entry describing the result of a config update attempt.
# Parameters:
#   sysfs_path: a path to the device in sysfs (see add_report_entry).
#   update_status: one of $REPORT_RESULT_{FAILURE,SUCCESS}
#   flashed_config: the config version that the updater attempted to flash
#                   (whether or not it was successful).
report_config_result() {
  local sysfs_path="$1"
  local update_status
  local flashed_config

  update_status="$(make_json_safe "$2")"
  flashed_config="$(make_json_safe "$3")"

  local extra_fields=""
  if [ "${update_status}" = "${REPORT_RESULT_FAILURE}" ]; then
    # We only want to override the update_status if the config flash failed (so
    # as not to hide firmware update failures with config update successes).
    extra_fields="\"update_status\": \"${REPORT_RESULT_FAILURE}\""
  fi

  add_report_entry "${sysfs_path}" "\"flashed_config\": \"${flashed_config}\"" \
    "${extra_fields}"
}

# Adds a report entry stating the tool name being run and its version.
# This could be executed at the beginning of a firmware updating script
# or a config updating script.
# Parameters:
#   sysfs_path: a path to the device in sysfs (see add_report_entry).
#   tool_name: the name of the tool being run (executable name).
#   tool_version: the tool version being run.
report_tool_version() {
  local sysfs_path="$1"
  local tool_name
  local tool_version

  tool_name="$(make_json_safe "$2")"
  tool_version="$(make_json_safe "$3")"

  local json_fields="\"tool\": \"${tool_name}\","
  json_fields="${json_fields} \"tool_version\": \"${tool_version}\""
  add_report_entry "${sysfs_path}" "${json_fields}"
}

# Adds a report entry indicating that the updater has run.
# Parameters:
#   sysfs_path: a path to the device in sysfs (see add_report_entry).
#   updater: a name identifying the updater in use.
#   name: the device name as reported by the device driver in sysfs.
#   vendor_id: the 16-bit vendor id for the HID device in hexadecimal format.
#   product_id: the 16-bit product id for the HID device in hexadecimal format.
report_updater_run() {
  local sysfs_path="${1}"
  local updater
  local name
  local vendor_id=""
  local product_id=""

  updater="$(make_json_safe "${2}")"
  name="$(make_json_safe "${3}")"
  if [ -n "${4}" ]; then
    vendor_id="$(make_json_safe "${4}")"
  fi
  if [ -n "${5}" ]; then
    product_id="$(make_json_safe "${5}")"
  fi

  local json_fields="\"updater\": \"${updater}\","
  json_fields="${json_fields} \"name\": \"${name}\","
  json_fields="${json_fields} \"vendor_id\": \"${vendor_id}\","
  json_fields="${json_fields} \"product_id\": \"${product_id}\""
  add_report_entry "${sysfs_path}" "${json_fields}"
}

log_updater_run() {
  local vendor_id="$1"
  local product_id="$2"
  local device_name="$3"
  local device_path="${4}"
  local updater_name="${5}"

  # This log message is load-bearing, in that the touch_UpdateErrors test
  # checks for this exact message to confirm that the updater has run.
  logger -t "chromeos-touch-update" \
    "Running updater for ${device_name} (${vendor_id}:${product_id})"
  # Add a report entry that will persist even if log is rotated.
  report_updater_run "${device_path}" "${updater_name}" "${device_name}" \
    "${vendor_id}" "${product_id}"
}
