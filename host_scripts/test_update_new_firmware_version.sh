#!/bin/bash
# Copyright 2017 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Detect whether we're inside a chroot or not
if [ ! -e "/etc/cros_chroot_version" ]; then
  echo "This script must be run inside the chroot.  Run this first:"
  echo "    cros_sdk"
  exit 1
fi

# Loads script libraries.
. "/usr/share/misc/shflags" || exit 1

# Flags
DEFINE_string board "" "Which board the test simulates in" b
DEFINE_boolean revert $FLAGS_FALSE "revert all changes by this test" r
DEFINE_string branch "" "revert to which branch" n

FLAGS_HELP="This test will perform some fake firmware updates request in your \
repos, then you need to verify the result manually.

USAGE: $0 -b xxx
"

# Parse command line
FLAGS "$@" || exit 1
eval set -- "${FLAGS_ARGV}"

if [ "$#" != 0 ]; then
  flags_help
  exit 1
fi

die() {
  echo "ERROR: $*" >&2
  exit 1
}

GCLIENT_ROOT="/mnt/host/source"
PUBLIC_DIR="${GCLIENT_ROOT}/src/overlays/overlay-${FLAGS_board}"
PRIVATE_DIR="${GCLIENT_ROOT}/src/private-overlays/overlay-"\
"${FLAGS_board}-private"

# Revert all changes by this test
if [ "${FLAGS_revert}" = "${FLAGS_TRUE}" ]; then
  cd "${PRIVATE_DIR}"
  git checkout "${FLAGS_branch}"
  git branch -D test_update_new_fw
  cd "${PUBLIC_DIR}"
  git checkout .
  exit 0
fi

# Check the flag value
if [ -z "${FLAGS_board}" ]; then
    die "Please specify a board using -b"
fi

if [ ! -d "${PRIVATE_DIR}" ]; then
  die "There is no corresponding private overlay in your tree ${PRIVATE_DIR}."
fi

TOUCH_FW_DIR="${PRIVATE_DIR}/chromeos-base/chromeos-touch-firmware-"\
"${FLAGS_board}"

setup_test_environment() {
  cd "${PRIVATE_DIR}"
  git checkout -b test_update_new_fw

  if [ -d "${TOUCH_FW_DIR}" ]; then
    rm -rf "${TOUCH_FW_DIR}"
  fi

  git add . && git commit -m "test touch firmware update"
}

check_test_result() {
  if [ $? != 0 ]; then
    die "${1} is failed."
    exit 1
  fi

  echo "${1} is passed."
}

#======== test start #========

setup_test_environment

# set -x

cd "${SCRIPT_LOCATION}"
# test case 1 - to create initial touch firmware folder
./update_new_firmware_version.sh -a cl \
                                 -b "${FLAGS_board}" \
                                 -i 154.0 -v 3.0 \
                                 -p testdata/154.0_3.0.bin \
                                 -t TS -r elan \
                                 -c arm \
                                 -d
check_test_result "Test case 1 - Create_Initial_Touch_Firmware_Folder"

# test case 2 - to uprev existed configuration
./update_new_firmware_version.sh -a cl \
                                 -b "${FLAGS_board}" \
                                 -i 154.0 \
                                 -v 4.0 \
                                 -p testdata/154.0_4.0.bin \
                                 -t TS \
                                 -r elan \
                                 -c arm \
                                 -d
check_test_result "Test case 2 - Uprev_Existed_Configuration"

# test case 3 - to add a new configuration
./update_new_firmware_version.sh -a cl \
                                 -b "${FLAGS_board}" \
                                 -i 200.0 \
                                 -v 5.0 \
                                 -p testdata/200.0_1.0.bin \
                                 -t TP \
                                 -r elan \
                                 -c arm \
                                 -d
check_test_result "Test case 3 - Add_New_Configuration"

# test case 4 - to add a new configuration of wacom
echo 0 | ./update_new_firmware_version.sh -a cl \
                                          -b "${FLAGS_board}" \
                                          -s "${FLAGS_board}" \
                                          -v 100 \
                                          -p testdata/wacom_100.hex \
                                          -t STYLUS \
                                          -r wacom \
                                          -c arm \
                                          -d
check_test_result "Test case 4 - Add_New_Configuration_for_Wacom"

# test case 5 - to uprev existed configuration of wacom
echo 0 | ./update_new_firmware_version.sh -a cl \
                                          -b "${FLAGS_board}" \
                                          -s "${FLAGS_board}" \
                                          -v 200 \
                                          -p testdata/wacom_200.hex \
                                          -t STYLUS \
                                          -r wacom \
                                          -c arm \
                                          -d
check_test_result "Test case 5 - Uprev_Existed_Configuration_for_Wacom"

# test case 5 - to add a new configuration of melfas
./update_new_firmware_version.sh -a cl \
                                 -b "${FLAGS_board}" \
                                 -i 100.4 \
                                 -v 1.0 \
                                 -p testdata/100.4_1.0.fw \
                                 -t TS \
                                 -r melfas \
                                 -c arm \
                                 -d
check_test_result "Test case 6 - Add_New_Configuration_For_Another_Vendor"

# test case 6 - to add a new configuration of atmel
./update_new_firmware_version.sh -a cl \
                                 -b "${FLAGS_board}" \
                                 -i 33.3 \
                                 -v 1.0 \
                                 -p testdata/33.3_1.0.bin \
                                 -t TP \
                                 -r atmel \
                                 -c arm \
                                 -d
check_test_result "Test case 7 - Add_New_Configuration_For_Another_Vendor"

echo "After verifying all modified codes, remember to
  ${0} -b ${FLAGS_board} -r -n your_original_branch"
