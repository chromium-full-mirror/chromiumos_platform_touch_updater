#!/bin/sh
#
# Copyright 2017 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# This isn't the exact copy that will be used in production, but it's better
# than pointing shellcheck at /dev/null.
# shellcheck source=../common/scripts/chromeos-touch-common.sh
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
ZINITIX_VENDOR_ID="14E5"
HIMAX_VENDOR_ID_1="3558"
HIMAX_VENDOR_ID_2="4858"
NVT_VENDOR_ID="0603"
ILITEK_VENDOR_ID="222A"
FOCALTECH_VENDOR_ID="2808"
PARADETECH_VENDOR_ID="1DA0"
CIRQUE_VENDOR_ID="0488"

# Determines if a device is a touch device based on the driver name. It matches
# the driver name against all the supported cases in `check_update`. This means
# that any additional drivers to `check_update` will also need to be included
# here.
is_touch_device() {
  local driver_name="$1"
  case "${driver_name}" in
    # Generic drivers.
    i2c_hid* | hid-multitouch | hid-generic | psmouse)
      true
      return
      ;;
    # Vendor specific drivers.
    atmel_mxt_ts | cyapa | elan_i2c | elants_i2c | mip4_ts | raydium_ts | \
      wdt87xx_i2c)
      true
      return
      ;;
    # Vendor specific drivers on the SPI bus.
    goodix-spi-hid)
      true
      return
      ;;
  esac
  false
}

# Determines if a device is a panel follower.
# A panel follower is a device that is powered on and off with the screen.
# Typically these are touchscreens that are embedded in the display panel.
# This function checks if the device is a panel follower by checking if
# the device tree node has a "panel" property.
is_panel_follower() {
  local dev="$1"
  local device_tree_path
  local driver_name

  device_tree_path="$(readlink -f "${dev}/of_node")"
  driver_name="$(basename "$(readlink -f "${dev}/driver")")"

  case "${driver_name}" in
    i2c_hid*)
      if [ -e "${device_tree_path}/panel" ]; then
        true
      else
        false
      fi
      ;;
    *)
      false
      ;;
  esac
}

# Wait up to 1 second for the HID driver to bind to the device.
# This is needed for devices that are powered on only when the screen is on
# The HID driver should bind to the device when the panel is powered on. If
# the HID driver is not bound to the device, the firmware update will likely
# fail.
wait_hid_driver_ready() {
  local dev="$1"
  local timeout=10 # in 1/10 second
  local elapsed=0 # in 1/10 second
  local hid_path
  local hidraw_sysfs_path

  hidpath="$(echo "${dev}"/*:[0-9A-F][0-9A-F][0-9A-F][0-9A-F]:*.*)"

  # If the HID driver is already bound to the device, return immediately.
  if [ -d "${hidpath}" ]; then
    hidraw_sysfs_path="$(echo "${hidpath}"/hidraw/hidraw*)"
    if [ -e "${hidraw_sysfs_path}" ]; then
      return
    fi
  fi

  # Wait up to `timeout` for the HID driver to bind to the device.
  # The HID driver should bind to the device when the panel is powered on.
  # The wait interval is 100ms.
  while [ "${elapsed}" -lt "${timeout}" ]; do
    sleep 0.1
    elapsed=$((elapsed + 1))
    hidpath="$(echo "${dev}"/*:[0-9A-F][0-9A-F][0-9A-F][0-9A-F]:*.*)"
    if [ -d "${hidpath}" ]; then
      hidraw_sysfs_path="$(echo "${hidpath}"/hidraw/hidraw*)"
      if [ -e "${hidraw_sysfs_path}" ]; then
        break
      fi
    fi
  done

  logger -t "${LOGGER_TAG}" "waited ${elapsed}00ms for hid driver ready."

  # Make sure the HID driver successfully bound to the device.
  if [ ! -d "${hidpath}" ] || [ ! -e "${hidraw_sysfs_path}" ]; then
    logger -t "${LOGGER_TAG}" "HID driver is not ready and update might fail."
  fi
}

# **NOTE**: Make sure to also add any new drivers to `is_touch_device`.
check_update() {
  local dev="$1"
  local driver_name="$2"
  local device_name
  device_name="$(cat "${dev}/name")"
  local device_description
  device_description="$(cat "${dev}/description")"

  if [ "${driver_name}" = "psmouse" ] || \
    [ "${device_description}" = "i8042 AUX port" ]; then
    /opt/google/touch/scripts/chromeos-eps2pstiap-touch-firmware-update-legacy.sh \
    -r \
    || logger -t "${LOGGER_TAG}" "elan trackpoint firmware update failed.";
    return
  fi

  case "${driver_name}" in
  i2c_hid*)
    local hidpath
    hidpath="$(echo "${dev}"/*:[0-9A-F][0-9A-F][0-9A-F][0-9A-F]:*.*)"
    local hidname
    hidname="hid-$(echo "${hidpath##*/}" | \
                         awk -F'[:.]' '{ print $2 "_" $3 }')"
    local vendor_id="${hidname#*-}"
    local product_id="${vendor_id#*_}"
    vendor_id="${vendor_id%_*}"

    # Make sure the HID driver successfully bound to the device.
    if [ ! -d "${hidpath}" ]; then
      return
    fi
    local link_path="${hidpath%/*}"
    local i2c_path
    i2c_path="$(readlink -f "${link_path}")"
    local i2c_device="${i2c_path%/*}"
    i2c_device="${i2c_device##*/}"

    case "${vendor_id}" in
    "${WACOM_VENDOR_ID_1}"|"${WACOM_VENDOR_ID_2}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_device}" "Wacom"
      /opt/google/touch/scripts/chromeos-wacom-touch-firmware-update-legacy.sh \
        -d "${i2c_device}" -p "${i2c_path}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${ELAN_VENDOR_ID}")
      # Select Elan Device
      local elan_device=
      local product_id_decimal=$((0x${product_id}))
      if [ "${product_id_decimal}" -eq $((0x0732)) ] ; then
        elan_device="touchscreen"
      elif [ "${product_id_decimal}" -ge $((0x0400)) ] \
        && [ "${product_id_decimal}" -le $((0x04FF)) ] ; then
        elan_device="touchpad"
      elif [ "${product_id_decimal}" -ge $((0x2000)) ] \
        && [ "${product_id_decimal}" -le $((0x2FFF)) ] ; then
        elan_device="touchscreen"
      elif [ "${product_id_decimal}" -ge $((0x3000)) ] \
        && [ "${product_id_decimal}" -le $((0x3FFF)) ] ; then
        # Specially case of a touscreen PID assigned by mistake in this section
        if [ "${product_id_decimal}" -eq $((0x3FDD)) ] ; then
          elan_device="touchscreen"
        else
          elan_device="touchpad"
        fi
      elif [ "${product_id_decimal}" -ge $((0x4000)) ] \
        && [ "${product_id_decimal}" -le $((0x4FFF)) ] ; then
        elan_device="touchscreen"
      fi

      # Run appropriate script with device type
      echo Update elan device: "${elan_device}"
      case "${elan_device}" in
      "touchpad")
        log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
          "${i2c_device}" "Elan Touchpad EEPROM I2C HID"
        /opt/google/touch/scripts/chromeos-etphidiap-touch-firmware-update-legacy.sh \
          -d "${i2c_device}" -p "${i2c_path}" -r \
          || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
        ;;
      "touchscreen")
        log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
          "${dev}" "Elan HID"
        /opt/google/touch/scripts/chromeos-elan-hid-touch-firmware-update-legacy.sh \
          -d "${dev}" -p "${product_id}" -r \
          || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
        ;;
      *)
        logger -t "${LOGGER_TAG}" "${device_name}: i2c_hid device with "\
                "unknown pid '${product_id}'"
      esac
      ;;
    "${SYNAPTICS_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "Synaptics"
      /opt/google/touch/scripts/chromeos-synaptics-touch-firmware-update-legacy.sh \
        -d "${hidname}" -p "${i2c_path}" -e "${dev}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${WEIDA_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "Weida HID"
      /opt/google/touch/scripts/chromeos-weida-hid-touch-firmware-update-legacy.sh \
        -d "${i2c_device}" -p "${i2c_path}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${GOOGLE_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "Google"
      /opt/google/touch/scripts/chromeos-google-touch-firmware-update-legacy.sh \
        -p "${i2c_path}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${PIXART_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "PixArt"
      /opt/google/touch/scripts/chromeos-pixart-hid-touch-firmware-update-legacy.sh \
        -h "${hidname}" -i "${i2c_path}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${ST_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "ST"
      /opt/google/touch/scripts/chromeos-st-touch-firmware-update-legacy.sh \
        -d "${i2c_device}" -p "${i2c_path}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${EMRIGHT_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "EMRight"
      /opt/google/touch/scripts/chromeos-emright-touch-firmware-update-legacy.sh \
        -d "${hidname}" -p "${i2c_path}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${ZINITIX_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "Zinitix"
      /opt/google/touch/scripts/chromeos-zinitix-tp-firmware-update-legacy.sh \
        -d "${hidname}" -p "${i2c_path}" -i "${product_id}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${HIMAX_VENDOR_ID_1}"|"${HIMAX_VENDOR_ID_2}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "Himax HID"
      /opt/google/touch/scripts/chromeos-himax-touch-firmware-update-legacy.sh \
        -d "${i2c_device}" -p "${i2c_path}" -i "${product_id}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${NVT_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "nvt_ts"
      /opt/google/touch/scripts/chromeos-nvt-touch-firmware-update-legacy.sh \
        -d "${hidname}" -p "${i2c_path}" -i "${product_id}" \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${ILITEK_VENDOR_ID}")
      local product_id_decimal=$((0x${product_id}))
      if [ "${product_id_decimal}" -ge $((0x0000)) ] \
        && [ "${product_id_decimal}" -le $((0x2FFF)) ] ; then
        log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
          "${i2c_path}" "Ilitek(tddi)"
        /opt/google/touch/scripts/chromeos-ili-tddi-touch-firmware-update-legacy.sh \
          -i "${product_id}" -p "${i2c_path}" -r \
          || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      else
        log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
          "${i2c_path}" "Ilitek(its)"
        /opt/google/touch/scripts/chromeos-ili-its-touch-firmware-update-legacy.sh \
          -p "${i2c_path}" -r \
          || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      fi
      ;;
    "${PARADETECH_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "Paradetech"
/opt/google/touch/scripts/chromeos-paradetech-touch-firmware-update-legacy.sh \
        -d "${hidname}" -p "${i2c_path}" -i "${product_id}" -r \
        || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
      ;;
    "${FOCALTECH_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${i2c_path}" "FocalTech"
      /opt/google/touch/scripts/chromeos-focal-hid-touch-firmware-update-legacy.sh \
        -d "${i2c_path}" -p "${product_id}" -r \
        || logger -t "${LOGGER_TAG}" "${hidname} firmware update failed."
      ;;
    *)
      logger -t "${LOGGER_TAG}" "${device_name}: i2c_hid device with "\
                "unknown vid '${vendor_id}'"
    esac

    return
    ;;
  esac

  if [ "${driver_name}" = "hid-multitouch" ] \
        || [ "${driver_name}" = "hid-generic" ]; then
    local hidpath="${dev}"
    local hidname
    hidname="hid-$(echo "${hidpath##*/}" | \
                         awk -F'[:.]' '{ print $2 "_" $3 }')"
    local vendor_id="${hidname#*-}"
    local product_id="${vendor_id#*_}"
    vendor_id="${vendor_id%_*}"

    # Make sure the HID driver successfully bound to the device.
    if [ ! -d "${hidpath}" ]; then
      return
    fi
    local hid_link_path
    hid_link_path="$(readlink -f "${hidpath}")"
    hid_link_path="${hid_link_path%/*}"

    case "${vendor_id}" in
    "${CIRQUE_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${hidpath}" "Cirque"
     /opt/google/touch/scripts/chromeos-cirque-touch-firmware-update-legacy.sh \
       -p "${hidpath}"  -i "${product_id}" -r \
       || logger -t "${LOGGER_TAG}" "${hidname} firmware update failed."
     ;;
     "${SIS_VENDOR_ID}")
       log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
         "${hid_link_path}" "SiS"
      /opt/google/touch/scripts/chromeos-sis-touch-firmware-update-legacy.sh \
        -p "${hid_link_path}" -r \
        || logger -t "${LOGGER_TAG}" "${hidname} firmware update failed."
      ;;
    "${G2TOUCH_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${hid_link_path}" "G2Touch"
      /opt/google/touch/scripts/chromeos-g2touch-touch-firmware-update-legacy.sh \
        -p "${hid_link_path}" -r \
        || logger -t "${LOGGER_TAG}" "${hidname} firmware update failed."
      ;;
    "${ILITEK_VENDOR_ID}")
      logger -t "${LOGGER_TAG}" "${device_name}: ${driver_name} device with"\
                "pid ${product_id} should be supported as an i2c-hid device."
      ;;
    "${GOODIX_VENDOR_ID}")
      log_updater_run "${vendor_id}" "${product_id}" "${device_name}" \
        "${hid_link_path}" "Goodix"
      /opt/google/touch/scripts/chromeos-goodix-touch-firmware-update-legacy.sh \
        -d "${hidname}" -p "${hid_link_path}" -r \
        || logger -t "${LOGGER_TAG}" "${hidname} firmware update failed."
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
    /opt/google/touch/scripts/chromeos-raydium-touch-firmware-update-legacy.sh \
      -d "${device_name}" -r \
      || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  cyapa)
    /opt/google/touch/scripts/chromeos-cyapa-touch-firmware-update-legacy.sh \
      -d "${device_name}" -r \
      || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  elan_i2c)
    /opt/google/touch/scripts/chromeos-elan-touch-firmware-update-legacy.sh \
      -d "${device_name}" -n elan_i2c -r \
      || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  elants_i2c)
    /opt/google/touch/scripts/chromeos-elan-touch-firmware-update-legacy.sh \
      -d "${device_name}" -n elants_i2c -r \
      || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  mip4_ts)
    /opt/google/touch/scripts/chromeos-melfas-touch-firmware-update-legacy.sh \
      -d "${device_name}" -r \
      || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed."
    ;;
  wdt87xx_i2c)
    /opt/google/touch/scripts/chromeos-weida-touch-firmware-update-legacy.sh \
      -d "${device_name}" -r \
      || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed.";
    /opt/google/touch/scripts/chromeos-weida-touch-config-update-legacy.sh \
      -d "${device_name}" \
      || logger -t "${LOGGER_TAG}" "${device_name} config update failed."
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
    /opt/google/touch/scripts/chromeos-atmel-touch-firmware-update-legacy.sh \
      -d "${device_name}" -r -n "${fw_name}" \
      || logger -t "${LOGGER_TAG}" "${device_name} firmware update failed.";
    /opt/google/touch/scripts/chromeos-atmel-touch-config-update-legacy.sh \
      -d "${device_name}" \
      || logger -t "${LOGGER_TAG}" "${device_name} config update failed."
    ;;
  esac
}

main() {
  if [ $# -ne 0 ]; then
    logger -t "${LOGGER_TAG}" "This script should not have any argument."
    exit 1
  fi

  local dev
  local driver_name
  local power_path

  for dev in $(get_dev_list); do
    # TODO(b/429327583): Add support for x86 devices.
    # The following code assumes the existence of of_node, which is not
    # supported on x86.
    if [ -e "${dev}/of_node" ] && is_panel_follower "${dev}"; then
      wait_hid_driver_ready "${dev}"
    fi
    driver_name="$(basename "$(readlink -f "${dev}/driver")")"
    # For devices supported runtime power managment, the "auto" mode would have
    # chance to let device go into runtime_suspend state. Which will prevent
    # touch updater from accessing that device. Here tries to move i2c devices's
    # state from "auto" to "on" then restoring them in the end of update
    # process.
    power_path="${dev}/power/control"
    if is_touch_device "${driver_name}" && [ -e "${power_path}" ] && \
        [ "auto" = "$(cat "${power_path}")" ]; then
      echo on > "${power_path}"
    fi

    ( check_update "${dev}" "${driver_name}" ) &
  done

  wait

  # To restore runtime power management state from "on" to "auto" if they are
  # changed by this script in the begining.
  # Since rebinding a device to i2c_hid driver makes a new i2chid device created and the original one terminated,
  # thus get_dev_list is needed to get existed devices after firmware update process.
  for dev in $(get_dev_list); do
    driver_name="$(basename "$(readlink -f "${dev}/driver")")"
    power_path="${dev}/power/control"
    if is_touch_device "${driver_name}" && [ -e "${power_path}" ] && \
        [ "on" = "$(cat "${power_path}")" ]; then
      echo auto > "${power_path}" ||
      logger -t "${LOGGER_TAG}" "Restore ${power_path} to auto failed."
    fi
  done
}

main "$@"
