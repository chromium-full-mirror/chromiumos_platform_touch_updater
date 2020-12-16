#!/bin/bash
# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

TRIGGER_DEDUP_FILE_PATH="/run/melfas-update-check-triggered"

if [ -e "${TRIGGER_DEDUP_FILE_PATH}" ]; then
  logger -t melfas-usb-udev-trigger "Skipping duplicate Melfas udev trigger."
  exit
fi

if [ -z "$1" ]; then
  logger -t melfas-usb-udev-trigger "No device node argument provided."
  exit
fi

logger -t melfas-usb-udev-trigger \
  "Running touch_updater after Melfas udev rule triggered."
/opt/google/touch/scripts/chromeos-melfas-hid-touch-firmware-update-legacy.sh -r \
  -d "$1"

# If the update is successful, write the dedup file to prevent further checks to
# update the firmware.
ret=$?
# shellcheck disable=SC2248
if [ ${ret} -eq 0 ]; then
  touch "${TRIGGER_DEDUP_FILE_PATH}"
fi
