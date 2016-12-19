#!/bin/sh

# Copyright 2016 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /opt/google/touch/scripts/chromeos-touch-common.sh

FW_LINK="/lib/firmware/st_touch.bin"

main() {
  # TODO(charliemooney): This firmware updater is really naive and just forces
  # firmware update every time the Chromebook boots, which will wear out the
  # flash in no time, as well as adding a bunch of boot time.  This is just
  # added as a basic mechanism to push out firmware updates during the very
  # early development steps, and will be replaced as soon as we have a better
  # option which will be very soon.
  local board="$(grep CHROMEOS_RELEASE_BOARD= /etc/lsb-release | \
                 awk -F = '{print $2}')"
  local ret;

  log_msg "WARNING: Using overly simplified touch firmware updater logic!"
  log_msg "Forcing a firmware update without even checking the fw version..."

  if [ ! -e "${FW_LINK}" ]; then
    log_msg "Unable to proceed with update: '${FW_LINK}' not found."
    exit -2
  fi

  local fw_ver="$(st_flash --fw_version --board="${board}")"
  log_msg "It looks like the current version is '${fw_ver}'"

  st_flash --board="${board}" "${FW_LINK}"
  ret=$?

  if [ "${ret}" -eq 0 ]; then
    log_msg "Update succeded!  The touchpad should work."
    exit 0
  fi

  log_msg "Update failed! (${ret}) The touchpad might not work, sorry."
  exit ${ret}
}

main "$@"
