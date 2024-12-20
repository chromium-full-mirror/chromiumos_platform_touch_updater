#!/bin/bash

# Copyright 2022 The ChromiumOS Authors
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# shellcheck source=../../../scripts/lib/shflags/shflags
. /usr/share/misc/shflags

# shellcheck source=../common/scripts/chromeos-touch-common.sh
. /opt/google/touch/scripts/chromeos-touch-common.sh

DEFINE_string 'dev_name' '' 'device name' 'd'
DEFINE_string 'dev_i2c_path' '' 'device i2c path' 'p'
DEFINE_string 'dev_pid' '' 'device pid' 'i'

NVT_BRIDGE_PID='F7FC'
NVT_TS_FW_PATH_BASE='/lib/firmware/nvt_ts'
NVT_BRIDGE_FW_PATH_BASE='/lib/firmware/nvt_bridge'
NVT_TS_FW_UPDATE_USER='fwupdate-hidraw'
NVT_TS_FW_UPDATE_GROUP='fwupdate-hidraw'
NVT_TOUCHSCREEN_HIDRAW='/dev/nvt_ts_hidraw'
BRIDGE_TOOL='/usr/sbin/Bdg_Cmd_M252'
TS_TOOL='/usr/sbin/NT36523_Cmd_HID_I2C'
PANEL_NODE_TABLE=(
    "/sys/firmware/devicetree/base/soc@0/mdss@ae00000\
/dsi@ae94000/panel@0/compatible" )

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

create_nvt_ts_hidraw() {
  local hidraw_path
  local dev_t_major
  local dev_t_minor

  if [ -e "${NVT_TOUCHSCREEN_HIDRAW}" ]; then
    log_msg "${NVT_TOUCHSCREEN_HIDRAW} already exist, skipping..."
    return 0
  fi

  hidraw_path="$(find_i2c_hid_device "${FLAGS_dev_name##*-}")"
  if [ -e  "${hidraw_path}" ]; then
    dev_t_major="$(stat -c "%t" "${hidraw_path}")"
    dev_t_minor="$(stat -c "%T" "${hidraw_path}")"
    if ! mknod "${NVT_TOUCHSCREEN_HIDRAW}" \
        c "0x${dev_t_major}" "0x${dev_t_minor}"; then
      die "Failed create node: '${NVT_TOUCHSCREEN_HIDRAW}'."
    fi
    if ! chown "${NVT_TS_FW_UPDATE_USER}":"${NVT_TS_FW_UPDATE_GROUP}" \
        "${NVT_TOUCHSCREEN_HIDRAW}"; then
      die "Failed change owner of node: ${NVT_TOUCHSCREEN_HIDRAW}."
    fi
    if ! chmod 0660 "${NVT_TOUCHSCREEN_HIDRAW}"; then
      die "Failed change mode of node: ${NVT_TOUCHSCREEN_HIDRAW}."
    fi
  else
    die "No hidraw device found"
  fi
}

# set 0/1 to disable/enable bridge handling interrupt requests
bridge_interrupt_handle() {
  minijail0 -u "${NVT_TS_FW_UPDATE_USER}" -g "${NVT_TS_FW_UPDATE_GROUP}" \
      -n -N -l --uts -e \
      -S /opt/google/touch/policies/nvt_bridge_interrupt_handle.policy \
      "${BRIDGE_TOOL}" "${NVT_TOUCHSCREEN_HIDRAW}" "-z" "$1"
}

get_bridge_fw_ver() {
  minijail0 -u "${NVT_TS_FW_UPDATE_USER}" -g "${NVT_TS_FW_UPDATE_GROUP}" \
      -n -N -l --uts -e \
      -S /opt/google/touch/policies/nvt_bridge_update.query.policy \
      "${BRIDGE_TOOL}" "${NVT_TOUCHSCREEN_HIDRAW}" "-vs"
}

get_ts_fw_ver() {
  minijail0 -u "${NVT_TS_FW_UPDATE_USER}" -g "${NVT_TS_FW_UPDATE_GROUP}" \
      -n -N -l --uts -e \
      -S /opt/google/touch/policies/nvt_ts_update.query.policy \
      "${TS_TOOL}" "${NVT_TOUCHSCREEN_HIDRAW}" "-vs"
}

update_bridge_fw() {
  if minijail0 -u "${NVT_TS_FW_UPDATE_USER}" -g "${NVT_TS_FW_UPDATE_GROUP}" \
      -n -N -l --uts -e \
      -S /opt/google/touch/policies/nvt_bridge_update.update.policy \
      "${BRIDGE_TOOL}" "${NVT_TOUCHSCREEN_HIDRAW}" "-u" "$1" "$2"; then
    log_msg 'Bridge fw update pass'
  else
    die 'Bridge fw update fail'
  fi
}

update_ts_fw() {
  chromeos-boot-alert update_touchscreen_firmware
  if minijail0 -u "${NVT_TS_FW_UPDATE_USER}" -g "${NVT_TS_FW_UPDATE_GROUP}" \
      -n -N -l --uts -e \
      -S /opt/google/touch/policies/nvt_ts_update.update.policy \
      "${TS_TOOL}" "${NVT_TOUCHSCREEN_HIDRAW}" "-u" "$1"; then
    log_msg 'Touchscreen fw update pass'
  else
    die 'Touchscreen fw update fail'
  fi
}

main() {
  local with_bridge=true
  local node_path
  local panel
  local device_pid
  local bridge_fw_link_path
  local bridge_fw_path
  local ts_fw_link_path
  local ts_fw_path
  local bridge_dev_fw_ver
  local bridge_bin_fw_ver
  local ts_dev_fw_ver
  local ts_bin_fw_ver

  # Get PID
  for node_path in "${PANEL_NODE_TABLE[@]}"; do
    panel=$(cat "${node_path}")
    case ${panel} in
      'boe,tv110c9m-ll3')
        device_pid='604A'
        log_msg "Panel boe,tv110c9m-ll3 detected, PID=${device_pid}"
        ;;
      'innolux,hj110iz-01a')
        device_pid='604C'
        log_msg "Panel innolux,hj110iz-01a detected, PID=${device_pid}"
        ;;
      *)
        device_pid=${FLAGS_dev_pid}
        with_bridge=false
        log_msg "No special panel detected, PID=${device_pid}"
        ;;
    esac
  done

  # Create custom /dev/nvt_ts_hidraw
  create_nvt_ts_hidraw

  # If bridge exist, check bridge version and update if needed
  if ${with_bridge}; then
    bridge_fw_link_path=${NVT_BRIDGE_FW_PATH_BASE}'_'${NVT_BRIDGE_PID}'.bin'
    bridge_fw_path=$(readlink -f "${bridge_fw_link_path}")
    log_msg "bridge_fw_link_path=${bridge_fw_link_path}"
    log_msg "bridge_fw_path=${bridge_fw_path}"
    if [ ! -e "${bridge_fw_link_path}" ] || [ ! -e "${bridge_fw_path}" ]; then
      die "No valid bridge firmware for ${FLAGS_dev_i2c_path}"
    fi
    bridge_bin_fw_ver=$(echo "${bridge_fw_path#*"${NVT_BRIDGE_PID}_"}" \
      | cut -d '.' -f 1)
    bridge_dev_fw_ver=$(get_bridge_fw_ver)
    if ! bridge_interrupt_handle 0; then
      die "Can not disable bridge interrupt handling"
    fi
    log_msg "bridge_bin_fw_ver=${bridge_bin_fw_ver}"
    log_msg "Before update bridge_dev_fw_ver=${bridge_dev_fw_ver}"
    log_msg "Before update bridge PID=${FLAGS_dev_pid}"
    if [ "${bridge_dev_fw_ver}" != "${bridge_bin_fw_ver}" ] || \
        ! [ "${device_pid}" == "${FLAGS_dev_pid}" ]; then
      # Update bin and PID for bridge, it will also try to keep lock INT
      if ! update_bridge_fw "${bridge_fw_path}" "${device_pid}"; then
        die "Update failed or failed to lock bridge INT"
      fi
      sleep 0.5
      bridge_dev_fw_ver=$(get_bridge_fw_ver)
      if [ "${bridge_dev_fw_ver}" != "${bridge_bin_fw_ver}" ]; then
        log_msg "After update bridge_dev_fw_ver=${bridge_dev_fw_ver}"
        report_update_result "${FLAGS_dev_i2c_path}" \
          "${REPORT_RESULT_FAILURE}" "${bridge_bin_fw_ver}"
        die "Bridge fw update failed for ${FLAGS_dev_i2c_path}"
      else
        log_msg "Bridge fw update to ${bridge_dev_fw_ver}, " \
          "PID update to ${device_pid}"
      fi
      rebind_driver "${FLAGS_dev_i2c_path}"
    else
      log_msg "No need to update bridge fw."
    fi
  fi

  # Check touchscreen version and update if needed
  ts_fw_link_path=${NVT_TS_FW_PATH_BASE}'_'${device_pid}'.bin'
  ts_fw_path=$(readlink -f "${ts_fw_link_path}")
  log_msg "ts_fw_link_path=${ts_fw_link_path}"
  log_msg "ts_fw_path=${ts_fw_path}"
  if [ ! -e "${ts_fw_link_path}" ] || [ ! -e "${ts_fw_path}" ]; then
    die "No valid touchscreen firmware for ${FLAGS_dev_i2c_path}."
  fi
  ts_bin_fw_ver=$(echo "${ts_fw_path#*"${device_pid}_"}" | cut -d '.' -f 1)
  ts_dev_fw_ver=$(get_ts_fw_ver)
  log_msg "ts_bin_fw_ver=${ts_bin_fw_ver}"
  log_msg "Before update ts_dev_fw_ver=${ts_dev_fw_ver}"
  report_initial_version "${FLAGS_dev_i2c_path}" "nvt_ts" "${ts_dev_fw_ver}"
  if [ "${ts_dev_fw_ver}" != "${ts_bin_fw_ver}" ]; then
    update_ts_fw "${ts_fw_path}"
    sleep 0.5
    ts_dev_fw_ver=$(get_ts_fw_ver)
    log_msg "After update ts_dev_fw_ver=${ts_dev_fw_ver}"
    if [ "${ts_dev_fw_ver}" != "${ts_bin_fw_ver}" ]; then
      report_update_result "${FLAGS_dev_i2c_path}" \
        "${REPORT_RESULT_FAILURE}" "${ts_bin_fw_ver}"
      die "Touchscreen fw update failed "\
        "for ${FLAGS_dev_i2c_path}"
    else
      report_update_result "${FLAGS_dev_i2c_path}" \
        "${REPORT_RESULT_SUCCESS}" "${ts_bin_fw_ver}"
      log_msg "Touchscreen fw update to ${ts_dev_fw_ver}"
      rebind_driver "${FLAGS_dev_i2c_path}"
    fi
  else
    log_msg "No need to update touchscreen fw."
  fi

  if ${with_bridge}; then
    if ! bridge_interrupt_handle 1; then
      die "Can not enable bridge interrupt handling"
    fi
  fi
  exit 0
}

main "$@"
