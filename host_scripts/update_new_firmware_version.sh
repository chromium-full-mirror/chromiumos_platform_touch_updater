#!/bin/bash
# Copyright 2017 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Detect whether we're inside a chroot or not.
if [ ! -e "/etc/cros_chroot_version" ]; then
  echo "This script must be run inside the chroot.  Run this first:"
  echo "    cros_sdk"
  exit 1
fi

GCLIENT_ROOT="/mnt/host/source"

# Load script libraries.
. "/usr/share/misc/shflags" || exit 1
. "${GCLIENT_ROOT}/src/scripts/remote_access.sh" || exit 1

DEFAULT_BOARD="$(cat "${GCLIENT_ROOT}/src/scripts/.default_board" 2>/dev/null)"

# Here defines flags we need.
DEFINE_string action "" "What action you want to take - cl / "\
"manifest / verification.
                cl - to generate CLs for updating your new firmware version
                manifest - to update Manifest according to new tarball in BCS
                verification - verify from a remote DUT" a
DEFINE_string board "${DEFAULT_BOARD}" "Which board the firmware is for" b
DEFINE_string product_id "" "Product id (or HW id) of the touch controller" i
DEFINE_string firmware_version "" "Firmware version of the new firmware" v
DEFINE_string firmware_path "" "File path of the new firmware binary" p
DEFINE_string touch_type "" "Touch type - TP (Touchpad) / TS (Touchscreen) /"\
" STYLUS" t
DEFINE_string var_name_prefix "" "The prefix to be appended to variables in"\
"ebuild file" n
DEFINE_string touch_vendor "" "The vendor name of this firmware - elan / atmel"\
" / melfas / wacom / raydium / google" r
# TODO(marcochen@chromium.org): CPU can be detected by checking into
# toolchain.conf
DEFINE_string cpu "" "What CPU family used in this board - x86 / arm" c
DEFINE_string chassis_id "" "The chassis_id of this board." s
DEFINE_boolean test_mode $FLAGS_FALSE "Enable test mode." d

FLAGS_HELP="Update the chromeos-touch-firmware-\${board} ebuild file and"\
"the tarball in BCS for the new firmware.

USAGE: $0 [flags]
The link - https://goo.gl/0aedKu is a reference of how to use this script.
"

# Parse command line to each values of flags we defined.
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"
set -e

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Initialize global variables.
prepare_global_info() {
  NEW_EBUILD_CREATED=false
  SUMMARY_MSG="\n"
  PRIVATE_OVERLAY_NAME="$(ls "${GCLIENT_ROOT}"/src/private-overlays/ | "\
"grep overlay-*"${FLAGS_board}"*)"
  EBUILD_DIR="${GCLIENT_ROOT}/src/private-overlays/${PRIVATE_OVERLAY_NAME}/"\
"chromeos-base/chromeos-touch-firmware-${FLAGS_board}"

  for file in "${EBUILD_DIR}/chromeos-touch-firmware-${FLAGS_board}"*.ebuild; do
    if [ ! -L "${file}" ]; then
      EBUILD_FILE="$(basename "${file}")"
    else
      SYMBOLIC_EBUILD_FILE="$(basename "${file}")"
    fi
  done

  TMP="$(mktemp -d /tmp/touch_firmware.XXXXXX)"
}

cleanup() {
  cleanup_remote_access
  rm -rf "${TMP}"
}

check_git_clean() {
  [ -n "$(git status | grep "working tree clean")" ]
}

read_wacom_config() {
  if [ "${FLAGS_touch_vendor}" == "wacom" ]; then
    echo "Please select wacom firmware update method:"
    echo "0 means update wacom firmware according to chassis_id"
    echo "1 means update wacom firmware according to product id"
    read -p ">>" USE_WACOM_PID

    if [ "${USE_WACOM_PID}" != "0" ] &&
      [ "${USE_WACOM_PID}" != "1" ]; then
      die "Invaild input. Wacom update version can only be 0 or 1."
    fi
  fi

}

verify_args() {
  if [ "${FLAGS_action}" != "cl" ] &&
    [ "${FLAGS_action}" != "manifest" ] &&
    [ "${FLAGS_action}" != "verification" ]; then
    die "Action should be one of cl / manifest / verification using -a"
  fi

  if [ -z "${FLAGS_board}" ]; then
    die "Please specify a board using -b"
  fi

  local private_dir="${GCLIENT_ROOT}/src/private-overlays/"\
"${PRIVATE_OVERLAY_NAME}"
  if [ ! -d "${private_dir}" ]; then
    die "There is no corresponding private overlay in your tree ${private_dir}."
  fi

  if [ "${FLAGS_action}" = "manifest" ]; then
    # Board is the only information which is needed by action - manifest.
    return
  fi

  if [ -z "${FLAGS_firmware_version}" ]; then
    die "Please specify a firmware version using -v"
  fi

  if [ "${FLAGS_touch_vendor}" != "elan" ] &&
    [ "${FLAGS_touch_vendor}" != "atmel" ] &&
    [ "${FLAGS_touch_vendor}" != "melfas" ] &&
    [ "${FLAGS_touch_vendor}" != "wacom" ] &&
    [ "${FLAGS_touch_vendor}" != "raydium" ] &&
    [ "${FLAGS_touch_vendor}" != "google" ]; then
    die "Touch vendor should be one of elan / atmel / melfas / wacom / raydium"\
" / google using -r"
  fi

  if [ "${FLAGS_action}" = "verification" ]; then
    return
  fi

  read_wacom_config

  if [ "${FLAGS_touch_vendor}" != "wacom" ] || [ "${USE_WACOM_PID}" != "0" ] &&
    [ -z "${FLAGS_product_id}" ]; then
    die "Product ID is required for the all non-Wacom vendors using -i"\
" to specify one."
  fi

  if [ -z "${FLAGS_firmware_path}" ]; then
    die "Please specify a firmware path using -p"
  fi

  if [ ! -f "${FLAGS_firmware_path}" ]; then
    die "Firmware file does not exist at ${FLAGS_firmware_path}."
  fi
  FLAGS_firmware_path="$(readlink -f "${FLAGS_firmware_path}")"

  if [ "${FLAGS_touch_type}" != "TP" ] &&
    [ "${FLAGS_touch_type}" != "TS" ] &&
    [ "${FLAGS_touch_type}" != "STYLUS" ]; then
    die "Touch type should be one of TP / TS / STYLUS using -t"
  fi

  # Checks below are for special ones according to each vendors.
  if [ "${FLAGS_touch_vendor}" = "melfas" ] &&
    [ "${FLAGS_touch_type}" != "TS" ]; then
    die "Melfas only supports TS now."
  fi

  if [ "${FLAGS_touch_vendor}" = "wacom" ] &&
    [  "${USE_WACOM_PID}" = "0" ] &&
    [ "${FLAGS_chassis_id}" = "" ]; then
    die "Wacom needs chassis_id info using -s"
  fi

  if [ "${FLAGS_touch_vendor}" = "google" ] &&
    [ "${FLAGS_touch_type}" != "TP" ]; then
    die "Google only supports TP now."
  fi

  # Check whether EBUILD_DIR exists or if we need to create an initial one.
  if [ ! -d "${EBUILD_DIR}" ]; then
    if [ "${FLAGS_cpu}" != "x86" ] && [ "${FLAGS_cpu}" != "arm" ]; then
      die "In order to create initial ebuild, CPU should be specified as arm" \
"or x86 using -c"
    fi
  fi

  if [ -n "${FLAGS_var_name_prefix}" ]; then
    FLAGS_var_name_prefix="${FLAGS_var_name_prefix}_"
  fi
}

# Generate a variable name for use in an ebuild.
# This function uses the global flags passed in by the user as well as a single
# argument indicating the contents of that variable to generate the correct
# variable name.
#
# Example:
# generate_ebuild_variable_name "FW_VERSION"
#   Might result in the variable name:
#     "TEST_TP_FW_VERSION_154_0"
#   If touch vendor is wacom then variable name would be as below because wacom
#   doesn't have product id:
#     "TEST_TP_FW_VERSION_WACOM"
generate_ebuild_variable_name() {
  local main_name="${1}"
  local escaped_product_id="${FLAGS_product_id/./_}"
  local suffix="${escaped_product_id}"

  if [ "${FLAGS_touch_vendor}" = "wacom" ] &&
    [ "${USE_WACOM_PID}" = "0" ]; then
    suffix="WACOM"
  fi

  echo "${FLAGS_var_name_prefix}${FLAGS_touch_type}_${main_name}_${suffix}"
}

# Set chromeos-bsp-xxx-private to depend on chromeos-touch-firmware-xxx so the
# latter one we created by this script can be built into the image.
set_dep_into_chromeos_bsp() {
  local bsp_dir="${GCLIENT_ROOT}/src/private-overlays/${PRIVATE_OVERLAY_NAME}/"\
"chromeos-base/chromeos-bsp-${FLAGS_board}-private"
  local bsp_ebuild_file=""
  local bsp_symbolic_ebuild_file=""

  for file in "${bsp_dir}"/*.ebuild; do
    if [ ! -L "${file}" ]; then
      bsp_ebuild_file="${file}"
    else
      bsp_symbolic_ebuild_file="${file}"
    fi
  done

  local line1="chromeos-base\/chromeos-touch-firmware-${FLAGS_board}"
  sed -i "/RDEPEND=/a \\\t${line1}" "${bsp_ebuild_file}"

  # Ebuild version should be bumped.
  local file_name="${bsp_symbolic_ebuild_file%.*}"
  local old_rev="${file_name##*r}"
  local new_rev="$((old_rev+1))"
  local new_symbolic_ebuild_file=\
"${bsp_symbolic_ebuild_file/-r${old_rev}/-r${new_rev}}"
  git mv "${bsp_symbolic_ebuild_file}" "${new_symbolic_ebuild_file}"

  SUMMARY_MSG="${SUMMARY_MSG}"\
"* Remember to add changes in chromeos-bsp-${FLAGS_board}-private to a CL\n"
}

# Before modifying source tree, we need to make sure the target repo is clear so
# we don't bring unnecessary changes into the new created branch which will host
# modified content by this script.
prepare_new_git_branch() {
  if ! check_git_clean && [ "${FLAGS_test_mode}" = "${FLAGS_FALSE}" ]; then
    die "CL will be only generated when your git status is clean - $(pwd)."
  fi

  if [ "${FLAGS_test_mode}" = "${FLAGS_FALSE}" ]; then
    echo "Creating new branch..."
    repo start Update-Touch-FW-"${FLAGS_touch_vendor}"-"${FLAGS_product_id}"
  fi
}

# If the touch vendor needs it's own fw updater then make.conf needs to be
# modified to add dependency.
#
# This function works on repo of public overlay in order to do git commands.
setup_stand_alone_fw_updater() {
  if [ "${FLAGS_touch_vendor}" != "wacom" ]; then
    return
  fi

  local overlay_name=\
"$(ls "${GCLIENT_ROOT}"/src/overlays/ | grep overlay-*"${FLAGS_board}")"
  pushd "${GCLIENT_ROOT}/src/overlays/${overlay_name}"

  local conf="make.conf"
  local line1="# Include the ${FLAGS_touch_vendor} firmware updating tool"
  local line2="INPUT_DEVICES=\"${FLAGS_touch_vendor}\""

  if [ -z "$(grep "^${line2}$" "${conf}")" ]; then
    prepare_new_git_branch
    sed -i -e "\$a \\\n${line1}\n${line2}" "${conf}"

    SUMMARY_MSG="${SUMMARY_MSG}* Remember to upload the CL for $(pwd)/${conf}\n"
  fi

  popd
}

# Create initial ebuild based on template.ebuild.txt.
# Add dependency into chromeos-bsp-xxx-private.
# Check whether this touch vendor needs stand along fw updater.
create_initial_ebuild_dir() {
  mkdir "${EBUILD_DIR}"

  EBUILD_FILE="chromeos-touch-firmware-${FLAGS_board}-0.0.1.ebuild"
  cp "${SCRIPT_LOCATION}/template.ebuild.txt" "${EBUILD_DIR}/${EBUILD_FILE}"

  sed -i "s/YEAR/$(date +"%Y")/g" "${EBUILD_DIR}/${EBUILD_FILE}"
  sed -i "s/PROJECT/${FLAGS_board}/g" "${EBUILD_DIR}/${EBUILD_FILE}"
  if [ "${FLAGS_cpu}" = "x86" ]; then
    sed -i "s/CPU_FAMILY/-\* x86 amd64/g" "${EBUILD_DIR}/${EBUILD_FILE}"
  else
    sed -i "s/CPU_FAMILY/-\* arm arm64/g" "${EBUILD_DIR}/${EBUILD_FILE}"
  fi

  SYMBOLIC_EBUILD_FILE="chromeos-touch-firmware-${FLAGS_board}-0.0.1-r1.ebuild"
  ln -rs "${EBUILD_DIR}/${EBUILD_FILE}" "${EBUILD_DIR}/${SYMBOLIC_EBUILD_FILE}"

  set_dep_into_chromeos_bsp

  NEW_EBUILD_CREATED=true
}

# There are two use cases which would leverage this function to generate blob
# name and they are the name in the tarball and the name in the ebuild.
# Name in the tarball:
#   part_1 would be the product id and part_2 will be the firmware version so it
#   might result in the example like 100.0_3.0.bin or wacom_3.0.hex.
# Name in the ebuild:
#   It is similar to the name in the tarball but both product id and firmware
#   version are wrapped as variables first then they are used to be composed as
#   the name. It might result in the example like
#   ${TP_PRODUCT_ID_200_0}_${TP_FW_VERSION_200_0}.bin or
#   wacom_${STYLUS_FW_VERSION_WACOM}.hex
generate_blob_name() {
  local part_1="${1}"
  local part_2="${2}"
  local blob_name="${part_1}_${part_2}"

  if [ "${FLAGS_touch_vendor}" = "wacom" ]; then
    if [ "${USE_WACOM_PID}" = 0 ]; then
      blob_name="wacom_${part_2}.hex"
    else
      blob_name="${blob_name}.hex"
    fi
  elif [ "${FLAGS_touch_vendor}" = "melfas" ]; then
    blob_name="${blob_name}.fw"
  elif [ "${FLAGS_touch_vendor}" = "raydium" ]; then
    blob_name="raydium_${blob_name}.bin"
  else
    blob_name="${blob_name}.bin"
  fi

  echo "${blob_name}"
}

generate_symlink_path() {
  local product_id_var="$(generate_ebuild_variable_name "PRODUCT_ID")"
  local path="/lib/firmware/PLACEHOLDER_\${${product_id_var}}"

  if [ "${FLAGS_touch_vendor}" = "elan" ]; then
    if [ "${FLAGS_touch_type}" = "TP" ]; then
      path="${path/PLACEHOLDER/elan_i2c}.bin"
    else
      path="${path/PLACEHOLDER/elants_i2c}.bin"
    fi
  elif [ "${FLAGS_touch_vendor}" = "melfas" ] ; then
    path="${path/PLACEHOLDER/melfas_mip4}.fw"
  elif [ "${FLAGS_touch_vendor}" = "atmel" ] ; then
    if [ "${FLAGS_touch_type}" = "TP" ]; then
      path="${path/PLACEHOLDER/maxtouch-tp}.fw"
    else
      path="${path/PLACEHOLDER/maxtouch-ts}.fw"
    fi
  elif [ "${FLAGS_touch_vendor}" = "raydium" ] ; then
    path="/lib/firmware/raydium.fw"
  elif [ "${FLAGS_touch_vendor}" = "wacom" ]; then
    # This is for the case of Wacom.
    if [ "${USE_WACOM_PID}" = 0 ]; then
      path="/lib/firmware/wacom_firmware_${FLAGS_chassis_id}.hex"
    else
      local wacom2_prefix="wacom2_firmware"
      path="${path/PLACEHOLDER/${wacom2_prefix}}.fw"
    fi
  elif [ "${FLAGS_touch_vendor}" = "google" ]; then
    if [ "${FLAGS_touch_type}" = "TP" ]; then
      path="/lib/firmware/google_touchpad.bin"
    else
      path="/lib/firmware/google_touchscreen.bin"
    fi
  fi

  echo "${path}"
}

# This function tries to
#   1. download the old tarball contained blobs from BCS. If we are under test
#      mode then just copy it from temp folder - do_not_commit. Or if this is
#      an initial ebuild then we create the first tarball.
#   2. delete the blob of old firmware version and put new one into it.
#   3. repack the tarball and store it in folder - do_not_commit which should be
#      uploaded into BCS by users manually.
update_blob_in_tarball() {
  local old_fw_version="${1}"
  local gs_path="gs://chromeos-binaries/HOME/bcs-${FLAGS_board}-private/"\
"overlay-${FLAGS_board}-private/chromeos-base/"\
"chromeos-touch-firmware-${FLAGS_board}"
  local fw_path="opt/google/touch/firmware"
  local extracted_folder=""
  local new_blob_name=\
"$(generate_blob_name "${FLAGS_product_id}" "${FLAGS_firmware_version}")"
  local full_blob_path=""
  local upload_folder="do_not_commit"
  local upload_folder_path="${SCRIPT_LOCATION}/${upload_folder}"

  if ${NEW_EBUILD_CREATED}; then
    extracted_folder="new_created"
    full_blob_path="${TMP}/${extracted_folder}/${fw_path}"
    mkdir -p "${full_blob_path}"
  else
    local old_tarball_name="$(basename "${EBUILD_FILE/ebuild/tbz2}")"
    local gs_old_tarball_path="${gs_path}/${old_tarball_name}"

    if [ "${FLAGS_test_mode}" = "${FLAGS_TRUE}" ] &&
      [ -f "${upload_folder_path}/${old_tarball_name}" ]; then
      cp "${upload_folder_path}/${old_tarball_name}" "${TMP}"
    else
      gsutil cp "${gs_old_tarball_path}" "${TMP}"
    fi

    tar -jxvf "${TMP}/${old_tarball_name}" -C "${TMP}"

    # Here tries to find out old blob and delete it.
    extracted_folder="${old_tarball_name%.*}"
    full_blob_path="${TMP}/${extracted_folder}/${fw_path}"
    local old_blob_name=\
"$(generate_blob_name "${FLAGS_product_id}" "${old_fw_version}")"

    rm -f "${full_blob_path}/${old_blob_name}"
  fi

  # Now new blob would be added into the extracted folder.
  cp "${FLAGS_firmware_path}" "${full_blob_path}/${new_blob_name}"

  # We are repacking tarball with new blob here.
  local new_folder="${new_ebuild_file%.*}"
  mv "${TMP}/${extracted_folder}" "${TMP}/${new_folder}"
  tar -jcvf "${TMP}/${new_folder}.tbz2" -C "${TMP}" "${new_folder}"

  mkdir -p "${upload_folder_path}"
  cp "${TMP}/${new_folder}.tbz2" "${upload_folder_path}"
  SUMMARY_MSG="${SUMMARY_MSG}"\
"* Remember to copy the console output as a comment to your CL in gerrit.\n"\
"* Remember to upload this new tarball to BCS\n"\
"    1. Go to web page - "\
"https://www.google.com/chromeos/partner/fe/#bcUpload:type=PRIVATE\n"\
"    2. Select Component File: ${upload_folder}/${new_folder}.tbz2\n"\
"    3. Select Partner: your own partner name\n"\
"    4. Select Overlay: ${PRIVATE_OVERLAY_NAME}\n"\
"    5. Relative path to file: "\
"chromeos-base/chromeos-touch-firmware-${FLAGS_board}\n"\
"    6. Press \"Upload\" button\n"\
"* After uploading this new tarball to BCS, \"./update_new_firmware_version.sh"\
" -a manifest\" should be called to update Manifest file."
}

# Add lines into an existing ebuild to include a new FW version.
# Lines added to the ebuild will follow the general pattern of the example
# below, though it will vary slightly based on different vendors.
#
# TEST_TP_PRODUCT_ID_1_0="1.0"
# TEST_TP_FW_VERSION_1_0="3.0"
# TEST_TP_FW_NAME_1_0="${TEST_TP_PRODUCT_ID_1_0}_${TEST_TP_FW_VERSION_1_0}.bin"
# TEST_TP_SYM_LINK_PATH_1_0=\
# "/lib/firmware/elan_i2c_${TEST_TP_PRODUCT_ID_1_0}.bin"
#
# dosym "/opt/google/touch/firmware/${TEST_TP_FW_NAME_1_0}" \
#   "${TEST_TP_SYM_LINK_PATH_1_0}"
add_new_fw_to_ebuild() {
  # Prepare all information which would be formed as lines into the ebuild.
  local product_id_var="$(generate_ebuild_variable_name "PRODUCT_ID")"
  local product_id_line="${product_id_var}=\"${FLAGS_product_id}\""

  local fw_version_var="$(generate_ebuild_variable_name "FW_VERSION")"
  local fw_version_line="${fw_version_var}=\"${FLAGS_firmware_version}\""

  local fw_name_var="$(generate_ebuild_variable_name "FW_NAME")"
  local fw_name_value=\
"$(generate_blob_name "\${${product_id_var}}" "\${${fw_version_var}}")"
  local fw_name_line="${fw_name_var}=\"${fw_name_value}\""

  local sym_link_var="$(generate_ebuild_variable_name "SYM_LINK_PATH")"
  local sym_link_path="$(generate_symlink_path)"
  local sym_link_line="${sym_link_var}=\"${sym_link_path}\""

  # Start to add lines into the ebuild files.
  sed -i "/S=\${WORKDIR}/i \
"${product_id_line}\\n"\
"${fw_version_line}\\n"\
"${fw_name_line}\\n"\
"${sym_link_line}\\n"" "$1"

  local line1="\tdosym \"\/opt\/google\/touch\/firmware\/\${${fw_name_var}}\""\
" \\\\"
  local line2="\t\t\"\${${sym_link_var}}\""
  sed -i "/symlinks/a \
"placeholder1\\n"\
"placeholder2"" "$1"
  sed -i "s/placeholder1/${line1}/g" "$1"
  sed -i "s/placeholder2/${line2}/g" "$1"

  setup_stand_alone_fw_updater
}

# Create a new branch for the CL.
# If chrome-touch-firmware-xxx does not exist yet then create it by template.
# Update firmware information in the ebuild.
# Bump ebuild version.
#
# This function works on repo of private overlay in order to do git commands.
modify_ebuild_file() {
  pushd "${GCLIENT_ROOT}/src/private-overlays/${PRIVATE_OVERLAY_NAME}"

  prepare_new_git_branch

  echo "Starting to modify ebuild file..."
  # Check whether EBUILD_DIR exists or we need to create an initial one.
  if [ ! -d "${EBUILD_DIR}" ]; then
    echo "Creating a whole new chromeos-touch-firmware-${FLAGS_board}..."
    create_initial_ebuild_dir
  fi

  # Extract the corresponding line specifying the old fw version already in the
  # ebuild (if it exists) and prepare the new version.
  local fw_varaible_name="$(generate_ebuild_variable_name "FW_VERSION")"
  local old_fw_version_line=\
"$(grep "${fw_varaible_name}" "${EBUILD_DIR}/${EBUILD_FILE}" | head -n 1)"
  local old_fw_version=""

  if [ -z "${old_fw_version_line}" ]; then
    # There is no existed setting for this product id yet.
    add_new_fw_to_ebuild "${EBUILD_DIR}/${EBUILD_FILE}"
  else
    # There is an old fw version already.
    old_fw_version="${old_fw_version_line#*=}"
    old_fw_version="${old_fw_version//\"/}"
    if [ "${old_fw_version}" = "${FLAGS_firmware_version}" ]; then
      echo "The firmware version is the same so there is nothing to do."
      exit 1
    fi
    local new_fw_version_line=\
"${fw_varaible_name}=\"${FLAGS_firmware_version}\""

    # Change the old firmware version to the new one.
    sed -i "s/^${old_fw_version_line}$/${new_fw_version_line}/" \
"${EBUILD_DIR}/${EBUILD_FILE}"
  fi

  SUMMARY_MSG="${SUMMARY_MSG}"\
"* Remember to add changes in chromeos-touch-firmware-${FLAGS_board} to a CL\n"

  if ${NEW_EBUILD_CREATED} ; then
    new_ebuild_file="${EBUILD_FILE}"
    new_symbolic_ebuild_file="${SYMBOLIC_EBUILD_FILE}"
    update_blob_in_tarball "${old_fw_version}"
    return
  fi

  # Ebuild version should be bumped.
  # EBUILD_FILE should look like "chromeos-touch-firmware-xxx-0.0.1.ebuild".
  file_name="${EBUILD_FILE%.*}"
  # file_name should look like "chromeos-touch-firmware-xxx-0.0.1".
  old_rev="${file_name##*.}"
  new_rev="$((old_rev+1))"
  new_ebuild_file="${EBUILD_FILE/0.0.${old_rev}/0.0.${new_rev}}"
  git mv "${EBUILD_DIR}/${EBUILD_FILE}" "${EBUILD_DIR}/${new_ebuild_file}"
  git rm "${EBUILD_DIR}/${SYMBOLIC_EBUILD_FILE}"
  new_symbolic_ebuild_file=\
"${SYMBOLIC_EBUILD_FILE/0.0.${old_rev}/0.0.${new_rev}}"
  ln -rs "${EBUILD_DIR}/${new_ebuild_file}" \
"${EBUILD_DIR}/${new_symbolic_ebuild_file}"

  update_blob_in_tarball "${old_fw_version}"

  popd
}

# This script can only apply new FW versions when the target repo is clean
# (no pending changes).  In order to perform multiple test from
# test_update_new_firmware_version.sh, this functioin will commit any patches
# immediately after the end of each test to keep the repo clean for the next
# round of tests.
#
# This function works on repo of private overly in order to do git commands.
commit_if_in_test_mode() {
  if [ "${FLAGS_test_mode}" = "${FLAGS_TRUE}" ]; then
    # For test mode, each result of test cases should be committed especially
    # the first one so the following test can operate git commands correctly.
    pushd "${GCLIENT_ROOT}/src/private-overlays/${PRIVATE_OVERLAY_NAME}"
    git add .
    git commit -m "test case"
    popd
  fi
}

# Entry function to modify source code and generate the CL for supporting the
# new firmware update.
action_cl() {
  modify_ebuild_file
  commit_if_in_test_mode
}

# After a new tarball has been generated by action_cl and has been uploaded to
# BCS via CPFE, this function generates an updated Manifest to use when
# downloading that file.
#
# This function works on the folder contained the ebuild file in order to call
# ebuild command to process Manifest.
action_manifest() {
  pushd "${EBUILD_DIR}"

  ebuild-"${FLAGS_board}" "${SYMBOLIC_EBUILD_FILE}" manifest
  SUMMARY_MSG="${SUMMARY_MSG}* manifest is updated\n"\
"  Then \"./update_new_firmware_version.sh -a verification ...\" can be called"\
" to verify changes here."

  popd
}

# To verify whether the generated changes are correct or not.
# 1. build chromeos-touch-firmware-"${FLAGS_board}"
# 2. install this package into the DUT by cros deploy.
# 3. reboot the DUT
# 4. Extract logs from DUT and verify the keyword - "Update FW succeeded"
#
# This function works on the folder contained the ebuild file in order to call
# emerge command to build the package.
#
# TODO(marcochen@chromium.org): Some touch vendors (ex: wacom) would need it's
#   own update tool. So if the CL is made for it in first time then additional
#   packages would need to be deployed.
action_verification() {
  pushd "${EBUILD_DIR}"

  echo "Initializing remote access..."
  remote_access_init

  echo "Rebuilding the package..."
  emerge-"${FLAGS_board}" chromeos-touch-firmware-"${FLAGS_board}"

  echo "Deploying new package to remote DUT..."
  cros deploy "${FLAGS_remote}" chromeos-touch-firmware-"${FLAGS_board}"

  echo "Rebooting remote DUT and waiting for connection again..."
  remote_reboot

  echo "Waiting more 6s for making sure touch updater can finish the job."
  sleep 6
  echo "Checking the firmware update result from logs in the remote DUT..."
  remote_sh "cat /var/log/messages | grep ${FLAGS_touch_vendor}-touch"
  local result="$(echo "${REMOTE_OUT}" | \
grep "Update FW succeded. Current Firmware: ${FLAGS_firmware_version}")"

  if [ -z "${result}" ]; then
    echo "Firmware update is not successful"
  else
    echo "${result}"
  fi

  SUMMARY_MSG="${SUMMARY_MSG}"\
"* Remember to copy the console output as a comment to your CL in gerrit.\n"\
"${REMOTE_OUT}\n"

  popd
}

main() {
  trap cleanup EXIT

  if [ "$#" != 0 ]; then
    flags_help
    exit 1
  fi

  prepare_global_info

  verify_args

  action_"${FLAGS_action}"

  echo "${SUMMARY_MSG}"
}

main "$@"
