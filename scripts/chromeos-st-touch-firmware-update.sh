#!/bin/sh
#
# Copyright 2019 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /usr/share/misc/shflags
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_string 'device' '' "i2c-dev" 'd'
DEFINE_boolean 'recovery' $FLAGS_FALSE "Recovery. Allows for rollback" 'r'

# Parse command line
FLAGS "$@" || exit 1
eval set -- "$FLAGS_ARGV"

BINARY_PATH="/usr/sbin"
BINARY_NAME="st-touch-fw-updater"
BINARY_FULL_PATH="$BINARY_PATH"/"$BINARY_NAME"

FIRMWARE_FILE_PATH="/lib/firmware/st_touch_firmware.ftb"
TOUCH_IC_GPIO_PATH="/sys/class/gpio"
TOUCH_IC_POWER_GPIO_NUM="430"
TOUCH_IC_RESET_GPIO_NUM="467"
FLAG=0

I2C_HID_DRIVER_PATH="/sys/bus/i2c/drivers/i2c_hid"

STUPDATE_USER="fwupdate-i2c"
STUPDATE_GROUP="fwupdate-i2c"

update_firmware() {
  local i2c_dev_path=

  i2c_dev_path="$1" || return; shift

  ret="$(minijail0 -u "$STUPDATE_USER" -g "$STUPDATE_GROUP" -G -n \
    -S /opt/google/touch/policies/stupdate.update.policy \
    "$BINARY_FULL_PATH" "flash_program" "$i2c_dev_path" "$FIRMWARE_FILE_PATH")"

  if [ "$?" -ne 0 ]; then
    die "firmware update failed, error_code=$ret"
  fi
}

main() {
  local ftb_fw_version=
  local ftb_config_id=
  local device_hw_id=
  local device_fw_version=
  local device_config_id=
  local acpi_entry=
  local update_type=
  local update_needed=
  local ret=

  if [ -z "$FLAGS_device" ]; then
    die "please specify a device using -d"
  fi

  # Get the target firmware version and config id from the fw ftb file
  ret="$(minijail0 -u "$STUPDATE_USER" -g "$STUPDATE_GROUP" -G -n \
    -S /opt/google/touch/policies/stupdate.read.policy \
    "$BINARY_FULL_PATH" "get_firmware_file_info" "$FIRMWARE_FILE_PATH")"
  if [ "$?" -ne 0 ]; then
    die "exit status $ret from attempting to parse firmware file "\
"$FIRMWARE_FILE_PATH"
  fi

  ftb_fw_version="$(echo "$ret" | cut -d' ' -f 1 | cut -d':' -f 2)"
  ftb_config_id="$(echo "$ret" | cut -d' ' -f 2 | cut -d':' -f 2)"

  log_msg "firmware file info $FIRMWARE_FILE_PATH - FW:$ftb_fw_version "\
"CFG:$ftb_config_id"

  # Get the current firmware version and config id from the device
  local i2c_dev_path="/dev/$FLAGS_device"

  ret="$(minijail0 -u "$STUPDATE_USER" -g "$STUPDATE_GROUP" -G -n \
    -S /opt/google/touch/policies/stupdate.query.policy \
    "$BINARY_FULL_PATH" "get_device_info" "$i2c_dev_path")"


  if [ "$?" -ne 0 ]; then
    FLAG=1
    if [ ! -d "$TOUCH_IC_GPIO_PATH/gpio$TOUCH_IC_POWER_GPIO_NUM" ]; then
      echo "$TOUCH_IC_POWER_GPIO_NUM" > "$TOUCH_IC_GPIO_PATH/export"
      echo out > "$TOUCH_IC_GPIO_PATH/gpio$TOUCH_IC_POWER_GPIO_NUM/direction"
    fi
    if [ ! -d "$TOUCH_IC_GPIO_PATH/gpio$TOUCH_IC_RESET_GPIO_NUM" ]; then
      echo "$TOUCH_IC_RESET_GPIO_NUM" > "$TOUCH_IC_GPIO_PATH/export"
      echo out > "$TOUCH_IC_GPIO_PATH/gpio$TOUCH_IC_RESET_GPIO_NUM/direction"
    fi
    log_msg "Enabling Touch IC gpios"
    echo 1 > "$TOUCH_IC_GPIO_PATH/gpio$TOUCH_IC_POWER_GPIO_NUM/value"
    echo 1 > "$TOUCH_IC_GPIO_PATH/gpio$TOUCH_IC_RESET_GPIO_NUM/value"
    if [ "$?" -ne 0 ]; then
      die "could not enable Touch IC gpio"
    fi
    sleep 0.01
    ret="$(minijail0 -u "$STUPDATE_USER" -g "$STUPDATE_GROUP" -G -n \
      -S /opt/google/touch/policies/stupdate.query.policy \
      "$BINARY_FULL_PATH" "get_device_info" "$i2c_dev_path")"
    if [ "$?" -ne 0 ]; then
      die "could not get device info $i2c_dev_path $ret"
    fi
   fi

  device_hw_id="$(echo "$ret" | cut -d' ' -f 1 | cut -d':' -f 2)"
  device_fw_version="$(echo "$ret" | cut -d' ' -f 2 | cut -d':' -f 2)"
  device_config_id="$(echo "$ret" | cut -d' ' -f 3 | cut -d':' -f 2)"

  log_msg "device info $FLAGS_device - HW:$device_hw_id FW:$device_fw_version "\
"CFG:$device_config_id"

  # Compare fw and config version and perform the update if needed
  update_type="$(compare_multipart_version \
      "$device_fw_version" "$ftb_fw_version" \
      "$device_config_id" "$ftb_config_id")"
  log_update_type "$update_type"
  update_needed="$(is_update_needed "$update_type")"

  if [ "$update_needed" -ne "$FLAGS_TRUE" ]; then
    log_msg "firmware updated is not needed"
    return
  fi

  log_msg "version mismatch, performing firmware update..."
  chromeos-boot-alert update_touchscreen_firmware
  run_cmd_and_block_powerd update_firmware "$i2c_dev_path"

  if [ "$FLAG" -eq 1 ]; then
    #acpi_entry="$(echo /sys/bus/i2c/devices/$FLAGS_device/*ACPI*)"
    #acpi_entry="$(basename "$acpi_entry")"
    acpi_entry="$(basename /sys/bus/i2c/devices/$FLAGS_device/*ACPI*)"
    log_msg "acpi entry: $acpi_entry"
    # Rebind the i2c_hid drivers/i2c_hid
    echo -n "$acpi_entry" > "$I2C_HID_DRIVER_PATH/bind"
    if [ "$?" -ne 0 ]; then
      die "could not bind the i2c_hid driver, error_code=$?"
    fi
    log_msg "i2c_hid driver has been successfully binded"
  fi

  log_msg "firmware updated successfully"
}

main "$@"
