#!/bin/sh
#
# Copyright 2017 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

. /opt/google/touch/scripts/chromeos-touch-common.sh

LOGGER_TAG="chromeos-touch-update"

# Touch firmware and config updater for Chromebooks
WACOM_VENDOR_ID_1="056A"
WACOM_VENDOR_ID_2="2D1F"
ELAN_VENDOR_ID="04F3"
SYNAPTICS_VENDOR_ID="06CB"
WEIDA_VENDOR_ID="2575"
GOOGLE_VENDOR_ID="18D1"
GOODIX_VENDOR_ID="27C6"
SIS_VENDOR_ID="0457"
PIXART_VENDOR_ID="093A"
G2TOUCH_VENDOR_ID="2A94"
ST_VENDOR_ID="0483"
EMRIGHT_VENDOR_ID="2C68"

check_update() {
  local dev="$1"
  local driver_name="$(basename "$(readlink -f "${dev}/driver")")"
  local device_name="$(cat "${dev}/name")"

  if [ "${driver_name}" = "i2c_hid" ]; then
    local hidpath="$(echo "${dev}"/*:*:*.*)"
    local hidname="hid-$(echo "${hidpath##*/}" | \
                         awk -F'[:.]' '{ print $2 "_" $3 }')"
    local vendor_id="${hidname#*-}"
    local product_id="${vendor_id#*_}"
    vendor_id="${vendor_id%_*}"

    # Make sure the HID driver successfully bound to the device.
    if [ ! -d "${hidpath}" ]; then
      return
    fi
    local link_path="${hidpath%/*}"
    local i2c_path="$(readlink -f "${link_path}")"
    local i2c_device="${i2c_path%/*}"
    i2c_device="${i2c_device##*/}"

    case "${vendor_id}" in
    "${WACOM_VENDOR_ID_1}"|"${WACOM_VENDOR_ID_2}")
      /opt/google/touch/scripts/chromeos-wacom-touch-firmware-update.sh \
        -d "${i2c_device}" -p "${i2c_path}" -r || \
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${ELAN_VENDOR_ID}")
      # Select Elan Device
      local elan_device=
      product_id=$((0x${product_id}))
      if [ ${product_id} -eq $((0x0732)) ] ; then
        elan_device="touchscreen"
      elif [ ${product_id} -ge $((0x0400)) ] && [ ${product_id} -le $((0x04FF)) ] ; then
        elan_device="touchpad"
      elif [ ${product_id} -ge $((0x2000)) ] && [ ${product_id} -le $((0x2FFF)) ] ; then
        elan_device="touchscreen"
      elif [ ${product_id} -ge $((0x3000)) ] && [ ${product_id} -le $((0x3FFF)) ] ; then
        elan_device="touchpad"
      elif [ ${product_id} -ge $((0x4000)) ] && [ ${product_id} -le $((0x4FFF)) ] ; then
        elan_device="touchscreen"
      fi

      # Run appropriate script with device type
      echo Update elan device: "${elan_device}"
      case "${elan_device}" in
      "touchpad")
        /opt/google/touch/scripts/chromeos-etphidiap-touch-firmware-update.sh \
          -d "${i2c_device}" -p "${i2c_path}" -r || \
        logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
        ;;
      "touchscreen")
        /opt/google/touch/scripts/chromeos-elan-hid-touch-firmware-update.sh \
          -d "${dev}" -p "${product_id}" || \
        logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
        ;;
      *)
        logger -t "${LOGGER_TAG}" "${device_name}: i2c_hid device with "\
                "unknown pid '${product_id}'"
      esac
      ;;
    "${SYNAPTICS_VENDOR_ID}")
      /opt/google/touch/scripts/chromeos-synaptics-touch-firmware-update.sh \
        -d "${hidname}" -r || \
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${WEIDA_VENDOR_ID}")
      /opt/google/touch/scripts/chromeos-weida-hid-touch-firmware-update.sh \
        -d "${i2c_device}" -p "${i2c_path}" -r || \
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${GOOGLE_VENDOR_ID}")
      /opt/google/touch/scripts/chromeos-google-touch-firmware-update.sh \
        -p "${i2c_path}" -r || \
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${GOODIX_VENDOR_ID}")
      /opt/google/touch/scripts/chromeos-goodix-touch-firmware-update.sh \
        -d "${hidname}" -p "${i2c_path}" -r || \
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${PIXART_VENDOR_ID}")
      /opt/google/touch/scripts/chromeos-pixart-hid-touch-firmware-update.sh \
        -h "${hidname}" -i "${i2c_path}" -r || \
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${ST_VENDOR_ID}")
      /opt/google/touch/scripts/chromeos-st-touch-firmware-update.sh \
        -d "${i2c_device}" -r || \
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${EMRIGHT_VENDOR_ID}")
      /opt/google/touch/scripts/chromeos-emright-touch-firmware-update.sh \
        -d "${hidname}" -p "${i2c_path}" -r || \
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    *)
      logger -t "${LOGGER_TAG}" "${device_name}: i2c_hid device with "\
                "unknown vid '${vendor_id}'"
    esac

    return
  fi

  if [ "${driver_name}" = "hid-multitouch" ] \
        || [ "${driver_name}" = "hid-generic" ]; then
    local hidpath="$(echo "${dev}")"
    local hidname="hid-$(echo "${hidpath##*/}" | \
                         awk -F'[:.]' '{ print $2 "_" $3 }')"
    local vendor_id="${hidname#*-}"
    vendor_id="${vendor_id%_*}"

    # Make sure the HID driver successfully bound to the device.
    if [ ! -d "${hidpath}" ]; then
      return
    fi
    local hid_link_path="$(readlink -f "${hidpath}")"
    hid_link_path="${hid_link_path%/*}"

    case "${vendor_id}" in
    "${SIS_VENDOR_ID}")
      /opt/google/touch/scripts/chromeos-sis-touch-firmware-update.sh \
        -p "${hid_link_path}" -r || \
      logger -t "${LOGGER_TAG}" "${hidname} firmware update failed."
      ;;
     "${G2TOUCH_VENDOR_ID}")
      /opt/google/touch/scripts/chromeos-g2touch-touch-firmware-update.sh \
        -p "${hid_link_path}" -r || \
      logger -t "${LOGGER_TAG}" "${hidname} firmware update failed."
      ;;
    *)
      logger -t "${LOGGER_TAG}" "${hidname}: ${driver_name} device with "\
                "unknown vid '${vendor_id}'"
    esac

    return
  fi

  # Skip over any bogus devices.
  if [ ! -e "${dev}/update_fw" ]; then
    return
  fi

  case "${driver_name}" in
  raydium_ts)
    /opt/google/touch/scripts/chromeos-raydium-touch-firmware-update.sh \
      -d "${device_name}" -r ||
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  cyapa)
    /opt/google/touch/scripts/chromeos-cyapa-touch-firmware-update.sh \
      -d "${device_name}" -r ||
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  elan_i2c)
    /opt/google/touch/scripts/chromeos-elan-touch-firmware-update.sh \
      -d "${device_name}" -n elan_i2c -r ||
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  elants_i2c)
    /opt/google/touch/scripts/chromeos-elan-touch-firmware-update.sh \
      -d "${device_name}" -n elants_i2c -r ||
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  mip4_ts)
    /opt/google/touch/scripts/chromeos-melfas-touch-firmware-update.sh \
      -d "${device_name}" -r ||
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  wdt87xx_i2c)
    /opt/google/touch/scripts/chromeos-weida-touch-firmware-update.sh \
      -d "${device_name}" -r ||
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed.";
    /opt/google/touch/scripts/chromeos-weida-touch-config-update.sh \
      -d "${device_name}" ||
      logger -t "${LOGGER_TAG}" "${device_name} config update failed."
    ;;
  atmel_mxt_ts)
    # Both Atmel screens and pads use the same driver.  Use the device name
    # to differentiate the two
    local fw_name=""

    case "${device_name}" in
    *tp*|ATML0000*)
      fw_name="maxtouch-tp.fw"
      ;;
    *ts*|ATML0001*)
      fw_name="maxtouch-ts.fw"
      ;;
    *)
      logger -t "${LOGGER_TAG}" "No valid touch device name ${device_name}"
      exit 1
      ;;
    esac

    # Atmel mXT touchpad firmware and config must be updated in tandem.
    /opt/google/touch/scripts/chromeos-atmel-touch-firmware-update.sh \
      -d "${device_name}" -r -n "${fw_name}" ||
      logger -t "${LOGGER_TAG}" "${device_name} firmware update failed.";
    /opt/google/touch/scripts/chromeos-atmel-touch-config-update.sh \
      -d "${device_name}" ||
      logger -t "${LOGGER_TAG}" "${device_name} config update failed."
    ;;
  esac
}

main() {
  if [ $# -ne 0 ]; then
    logger -t "${LOGGER_TAG}" "This script should not have any argument."
    exit 1
  fi

  local dev
  local power_path
  for dev in $(get_dev_list); do
    # For devices supported runtime power managment, the "auto" mode would have
    # chance to let device go into runtime_suspend state. Which will prevent
    # touch updater from accessing that device. Here tries to move i2c devices's
    # state from "auto" to "on" then restoring them in the end of update
    # process.
    power_path="${dev}/power/control"
    if [ -e "${power_path}" ] && [ "auto" = "$(cat "${power_path}")" ]; then
      echo on > "${power_path}"
    fi

    ( check_update "${dev}" ) &
  done

  wait

  # To restore runtime power management state from "on" to "auto" if they are
  # changed by this script in the begining.
  # Since rebinding a device to i2c_hid driver makes a new i2chid device created and the original one terminated,
  # thus get_dev_list is needed to get existed devices after firmware update process.
  for dev in $(get_dev_list); do
    power_path="${dev}/power/control"
    if [ -e "${power_path}" ] && [ "on" = "$(cat "${power_path}")" ]; then
      echo auto > "${power_path}" ||
      logger -t "${LOGGER_TAG}" "Restore ${power_path} to auto failed."
    fi
  done
}

main "$@"
