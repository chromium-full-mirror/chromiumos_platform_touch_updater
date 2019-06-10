# Chromium OS Touch Firmware Updater

## Overview

This directory contains source codes for touch firmware updates.
For each touch device, we do the followings:

  - Loop through all vendor scripts to find the applicable one.
  - Determine current firmware status for the device.
  - Update the firmware(optional).
  - Display info.

## Status

  - [`Refactor platform/touch_updater`](http://b/129671661)
  - Files having suffix `legacy` will be removed gradually.

## Structue

  - `chromeos-touch-update.sh`
    - Usage: `./chromeos-touch-update.sh [--info] [device ...]`

  - `chromeos-touch-common.sh`
    - Shared utilities

  - `chromeos-VENDOR_NAME-firmware-update.sh`
    - Vendor scripts
    - Each should provide the following functions:
      - `get_vendor_name()`
        - Print the vendor name.
      - `check_applicability(device)`
        - Check if the script is applicable to the device.
      - `get_active_fw_version(device)`
        - Get the active firmware version of the device.
      - `get_latest_fw_version(device)`
        - Get the latest firmware version of the device.
      - `compare_fw_versions(active, latest)`
        - Determine current firmware status.
        - Returns one of:
          - `UP_TO_DATE`
          - `OUTDATED`
          - `ROLLBACK`
          - `CORRUPTED`
      - `update(device)`
        - Update the firmware for the device.
      - `config(device)`
        - Deprecated. For legacy use only.
    - Locally used helper functions must have prefix `VENDOR_NAME`

