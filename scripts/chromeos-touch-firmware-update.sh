#!/bin/sh

# Copyright (c) 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
#
# Chrome OS Touch Firmware Update Script
# This script checks whether a payload firmware in rootfs should be applied
# to the touch device. If so, this will trigger the update_fw mechanism in
# the kernel driver.
#

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'force' ${FLAGS_FALSE} "Force update" 'f'
DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'
DEFINE_string 'device' '' "device name" 'd'
DEFINE_string 'firmware_name' '' "firmware name (in /lib/firmware)" 'n'

RMI4UPDATE="/usr/sbin/rmi4update"
SYNAPTICS_VENDOR_ID="06CB"

log_msg() {
  logger -t "chromeos-touch-firmware-update[${PPID}]-${FLAGS_device}" "$@"
  echo "$@"
}

die() {
  log_msg "error: $*"
  exit 1
}

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

update_firmware() {
  local i
  local ret
  local use_rmi4update=0

  if [ "${1%%[0-9]*}" = "/dev/hidraw" ] && [ "${2%%_*}" = "hid-${SYNAPTICS_VENDOR_ID}" ] && \
    [ -x "${RMI4UPDATE}" ]; then
    use_rmi4update=1
  fi

  for i in $(seq 5); do
    if [ ${use_rmi4update} -eq 1 ]; then
      local opts=" -d $1 $3"
      if [ ${FLAGS_force} -eq ${FLAGS_TRUE} ]; then
        opts=" -f ${opts}"
      fi
      ${RMI4UPDATE} ${opts}
    else
      printf 1 > "$1/update_fw"
    fi
    ret=$?
    if [ ${ret} -eq 0 ]; then
      return 0
    fi
    log_msg "update_firmware try #${i} failed... retrying."
  done
  die "Error updating touch firmware. ${ret}"
}

get_active_firmware_version() {
  local touch_device_path="$1"
  local fw_version_sysfs_prop=""
  if [ -e "${touch_device_path}/firmware_version" ]; then
    fw_version_sysfs_prop="firmware_version"
  elif [ -e "${touch_device_path}/fw_version" ]; then
    fw_version_sysfs_prop="fw_version"
  elif [ "${2%%_*}" = "hid-${SYNAPTICS_VENDOR_ID}" ] && [ -x "${RMI4UPDATE}" ]; then
    ${RMI4UPDATE} -p -d "${touch_device_path}"
    return 0
  else
    die "No firmware version sysfs in ${touch_device_path}."
  fi
  echo "$(cat "${touch_device_path}/${fw_version_sysfs_prop}")"
}

hex_to_decimal() {
  printf "%d" "0x""$1"
}

find_fw_link_path() {
  # Given a hardware version (or product ID depending on the device)
  # determine which fw symlink in /lib/firmware it should try to load
  hw_version="$1"
  fw_link_name="$2"
  fw_link_name_extension="`expr "$fw_link_name" : ".*\(\..*\)"`"
  fw_link_name_base="${fw_link_name%$fw_link_name_extension}"

  case ${fw_link_name_base} in
  /*) fw_link_path="${fw_link_name_base}" ;;
  *)  fw_link_path="/lib/firmware/${fw_link_name_base}" ;;
  esac

  specific_fw_link_path="${fw_link_path}_${hw_version}${fw_link_name_extension}"
  generic_fw_link_path="${fw_link_path}${fw_link_name_extension}"

  if [ -e "${specific_fw_link_path}" ]; then
    echo "${specific_fw_link_path}"
  else
    echo "${generic_fw_link_path}"
  fi
}

main() {
  local trackpad_device_name="${FLAGS_device}"
  local touch_device_path=""
  local update_needed=${FLAGS_FALSE}
  local fw_link_name=""
  local active_product_id=""
  local active_fw_version=""
  local active_fw_version_major=""
  local active_fw_version_minor=""
  local active_fw_version_build=""
  local minor_build=""
  local fw_path=""
  local fw_link_path=""
  local fw_filename=""
  local fw_name=""
  local product_id=""
  local fw_version=""
  local fw_version_major=""
  local fw_version_minor=""
  local board=`grep CHROMEOS_RELEASE_BOARD= /etc/lsb-release | awk -F = '{print $2}'`

  if [ -z "${FLAGS_device}" ]; then
    die "Please specify a device using -d"
  fi

  if [ "${trackpad_device_name%%-*}" = "hid" ]; then
    touch_device_path="$(find_i2c_hid_device ${trackpad_device_name##*-})"
  else
    touch_device_path="$(find_i2c_device_by_name "${trackpad_device_name}" \
                         "update_fw")"
  fi
  if [ -z "${touch_device_path}" ]; then
    die "${trackpad_device_name} not found on system. Aborting update."
  fi

  if [ "${trackpad_device_name%%-*}" = "hid" ]; then
    active_product_id="${trackpad_device_name##*_}"
  elif [ -e "${touch_device_path}/product_id" ]; then
    active_product_id=$(cat ${touch_device_path}/product_id)
  elif [ -e "${touch_device_path}/hw_version" ]; then
    active_product_id=$(cat ${touch_device_path}/hw_version)
  else
    die "No product_id/hw_version found in ${touch_device_path}."
  fi

  fw_link_name="${FLAGS_firmware_name:-${FLAGS_device}}"
  fw_link_path="$(find_fw_link_path ${active_product_id} ${fw_link_name})"
  log_msg "Attempting to load FW: '${fw_link_path}'"
  fw_path="$(readlink -f "${fw_link_path}")"


  if [ ! -e "${fw_link_path}" ] ||
     [ ! -e "${fw_path}" ]; then
    die "No valid firmware for ${trackpad_device_name} found."
  fi
  fw_filename=${fw_path##*/}
  fw_name=${fw_filename%.bin}
  product_id=${fw_name%_*}

  fw_version=${fw_name#"${product_id}_"}
  fw_version_major=${fw_version%%.*}
  minor_build=${fw_version#${fw_version_major}.}
  fw_version_minor=${minor_build%.*}
  fw_version_build=${minor_build#*.}
  # no build number
  if [ "${minor_build}" = "${fw_version_build}" ]; then
    fw_version_build=0
  fi

  if [ -z "${active_product_id}" ] ||
     [ "${active_product_id}" = "0.0" ] ||
     [ "${active_product_id}" = "1.0" ] ||
     [ "${active_product_id}" = "255.0" ]; then
    log_msg "Touch device in non operational state. Updating."
    update_needed=${FLAGS_TRUE}
  fi

  if [ -n "${active_product_id}" ] &&
     [ ${update_needed} -eq ${FLAGS_FALSE} ] &&
     [ "${product_id}" != "${active_product_id}" ] &&
     [ "${active_product_id}" != "CYTRA-119001-TD" ] &&
     [ "${active_product_id}" != "57.0" -o "${product_id}" != "69.0" ] &&
     [ "${active_product_id}" != "CYTRA-103001-00" -o "${product_id}" != "CYTRA-101003-00" ] &&
     [ "${active_product_id}" != "232d" -o "${product_id}" != "280d" ]; then
    log_msg "Hardware product id : ${active_product_id}"
    log_msg "Updater product id  : ${product_id}"
    die "Touch firmware updater: Product ID mismatch!"
  fi

  active_fw_version="$(get_active_firmware_version "${touch_device_path}" \
                     "${trackpad_device_name}")"
  active_fw_version_major=${active_fw_version%%.*}
  minor_build=${active_fw_version#$active_fw_version_major.}
  active_fw_version_minor=${minor_build%.*}
  build_hex=${minor_build#*.}
  # no build number
  if [ "${minor_build}" = "${build_hex}" ]; then
    build_hex=0
  fi
  active_fw_version_build="$(hex_to_decimal "${build_hex}")"

  log_msg "Product ID : ${product_id}"
  log_msg "Current Firmware: ${active_fw_version}"
  log_msg "Updater Firmware: ${fw_version}"

  if [ "${active_fw_version_major}" -lt "${fw_version_major}" ] ||
     ([ "${active_fw_version_major}" -eq "${fw_version_major}" ] &&
      [ "${active_fw_version_minor}" -lt "${fw_version_minor}" ]) ||
     ([ "${active_fw_version_major}" -eq "${fw_version_major}" ] &&
      [ "${active_fw_version_minor}" -eq "${fw_version_minor}" ] &&
      [ "${active_fw_version_build}" -lt "${fw_version_build}" ]); then
    log_msg "Update needed."
    update_needed=${FLAGS_TRUE}
  elif [ "${active_fw_version_major}" -eq "${fw_version_major}" ] &&
       [ "${active_fw_version_minor}" -eq "${fw_version_minor}" ] &&
       [ "${active_fw_version_build}" -eq "${fw_version_build}" ]; then
    log_msg "Firmware up to date."
  elif [ ${FLAGS_recovery} -eq ${FLAGS_TRUE} ]; then
    log_msg "Recovery firmware update. Rolling back to ${fw_version}."
    update_needed=${FLAGS_TRUE}
  fi

  # Prevent Squawks user on 5.0 FW from running FW update because it may brick
  # the device.
  if [ "${board}" = "squawks" ] &&
     [ "${active_fw_version}" = "5.0" ]; then
    log_msg "Skipping FW update for Squawks 5.0 FW users."
    update_needed=${FLAGS_FALSE}
  fi

  if [ ${FLAGS_force} -eq ${FLAGS_TRUE} ]; then
    log_msg "Forcing update."
  fi

  if [ ${FLAGS_force} -eq ${FLAGS_TRUE} ] ||
     [ ${update_needed} -eq ${FLAGS_TRUE} ]; then
    log_msg "Update FW to ${fw_name}"

    if [ -e "${touch_device_path}/fw_file" ]; then
      printf "${fw_link_name}" > "${touch_device_path}/fw_file"
      if [ "$(cat "${touch_device_path}/fw_file")" != "${fw_link_name}" ]
      then
        die "Can't set firmware file name to ${fw_link_name}"
      fi
    fi

    update_firmware "${touch_device_path}" "${trackpad_device_name}" "${fw_path}"

    active_fw_version="$(get_active_firmware_version "${touch_device_path}" \
                        "${trackpad_device_name}")"
    active_fw_version_major=${active_fw_version%%.*}
    minor_build=${active_fw_version#$active_fw_version_major.}
    active_fw_version_minor=${minor_build%.*}
    build_hex=${minor_build#*.}
    # no build number
    if [ "${minor_build}" = "${build_hex}" ]; then
      build_hex=0
    fi
    active_fw_version_build="$(hex_to_decimal "${build_hex}")"

    if [ "${active_fw_version_major}" -ne "${fw_version_major}" ] ||
       [ "${active_fw_version_minor}" -ne "${fw_version_minor}" ] ||
       [ "${active_fw_version_build}" -ne "${fw_version_build}" ]; then
      die "Firmware update failed. Current Firmware: ${active_fw_version}"
    fi
    log_msg "Update FW succeded. Current Firmware: ${active_fw_version}"
  fi

  exit 0
}

main "$@"
