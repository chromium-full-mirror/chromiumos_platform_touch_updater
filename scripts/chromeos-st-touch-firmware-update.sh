#!/bin/sh

# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_boolean 'recovery' ${FLAGS_FALSE} "Recovery. Allows for rollback" 'r'

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

FW_LINK="/lib/firmware/st_touch.bin"

compare_fw_version() {
  # ST firmware versions are just hex numbers, so to compare them we can
  # convert them to decimal and use the standard comparison functions.
  local active_fw_ver_hex="$1"
  local updater_fw_ver_hex="$2"
  local active_fw_ver_dec="$(printf "%d" "${active_fw_ver_hex}")"
  local updater_fw_ver_dec="$(printf "%d" "${updater_fw_ver_hex}")"

  compare_multipart_version "${active_fw_ver_dec}" "${updater_fw_ver_dec}"
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

main() {
  # TODO(charliemooney): This firmware updater is quite naive and just forces
  # firmware update every time the fw versions aren't the same.  There's no
  # real follow up to make sure everything worked, nor does this support
  # multiple product IDs, which are all things we need.  This is just here
  # as a stop-gap solution to get things up at running, but will be replaced
  # very soon.
  local board="$(grep CHROMEOS_RELEASE_BOARD= /etc/lsb-release | \
                 awk -F = '{print $2}')"
  local ret;

  log_msg "WARNING: Using very simplified touch firmware updater logic!"
  log_msg "Forcing a firmware update with few checks..."

  if [ ! -e "${FW_LINK}" ]; then
    log_msg "Unable to proceed with update: '${FW_LINK}' not found."
    exit -2
  fi

  local active_fw_ver="$(st_flash --fw_version --board="${board}")"
  local updater_fw_ver="$(get_fw_version_from_disk "${FW_LINK}")"
  log_msg "Current active fw version is: '${active_fw_ver}'"
  log_msg "Current updater fw version is: '${updater_fw_ver}'"
  update_type="$(compare_fw_version "${active_fw_ver}" "${updater_fw_ver}")"
  log_update_type "${update_type}"
  update_needed="$(is_update_needed "${update_type}")"

  if [ "${update_needed}" -eq "${FLAGS_TRUE}" ]; then
    log_msg "Update FW to ${updater_fw_ver}"

    st_flash --board="${board}" "${FW_LINK}"
    ret=$?

    if [ "${ret}" -eq 0 ]; then
      # If everything looks right, check the FW version one last time.
      log_msg "Call to st_flash succeded!  The touchpad should work."
      exit 0
    else
      # If something went wrong with st_flash there's nothing we can do.
      die "Update failed! st_flash returned (${ret}) The touchpad might " \
          "not work, sorry."
    fi
  fi
}

main "$@"
