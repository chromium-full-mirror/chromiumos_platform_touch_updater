# Touch firmware report

Every time the touch update scripts are run, they produce a report file at
`/run/touch-updater/firmware-versions`, containing a summary of the run. This
is useful for including in feedback reports, but is also machine-readable for
use by diagnostics and other code.

[TOC]

## File format

The file has one or more lines for each touch device handled by the scripts.
Each line will contain the sysfs path to the device followed by a JSON object.
To get all the information related to a particular device, readers of the file
should combine the JSON objects on its lines, with values included later in the
file taking precedence. For example, take this report file:

```
/sys/devices/platform/AMD0010:00/i2c-0/i2c-ELAN0000:00 {"updater": "Elan", "initial_version": "123.0"}
/sys/devices/platform/AMD0010:00/i2c-1/i2c-ATML0001:01 {"updater": "Atmel firmware", "initial_version": "1.0.AA"}
/sys/devices/platform/AMD0010:00/i2c-0/i2c-ELAN0000:00 {"update_status": "SUCCESS", "flashed_version": "124.0"}
/sys/devices/platform/AMD0010:00/i2c-1/i2c-ATML0001:01 {"update_status": "SUCCESS", "flashed_version": "1.1.BB"}
/sys/devices/platform/AMD0010:00/i2c-1/i2c-ATML0001:01 {"initial_config": "7c2fb6"}
/sys/devices/platform/AMD0010:00/i2c-1/i2c-ATML0001:01 {"update_status": "FAILURE", "flashed_config": "12abf4"}
/sys/devices/pci0000:00/0000:00:15.0/i2c_designware.0/i2c-0/i2c-FTCS0038:00 {"tool": "ftphid_ezupg_ap", "tool_version": "2.4_2025-02-25"}
```

For the Elan device (`/sys/devices/platform/AMD0010:00/i2c-0/i2c-ELAN0000:0`),
following JSON object would be formed:

```json
{
  "updater": "Elan",
  "initial_version": "123.0",
  "update_status": "SUCCESS",
  "flashed_version": "124.0"
}
```

While for the Atmel device
(`/sys/devices/platform/AMD0010:00/i2c-1/i2c-ATML0001:01`), this JSON would be
formed:

```json
{
  "updater": "Atmel firmware",
  "initial_version": "1.0.AA",
  "update_status": "FAILURE",
  "flashed_version": "1.1.BB",
  "initial_config": "7c2fb6",
  "flashed_config": "12abf4"
}
```

(Note that although the firmware update was successful here, the overall status
is still `FAILURE` due to the config change.)

### JSON fields

The JSON objects may contain any of these fields:

*   `updater`: a name for the updater making the report
*   `update_status`: either `"NOT_NEEDED"`, `"SUCCESS"`, or `"FAILURE"`
    (defaults to "NOT_NEEDED" if unspecified)
*   `initial_version`: the version found on the device at boot (or `(recovery)`
    if it was in a recovery mode)
*   `flashed_version`: if an update or downgrade was *attempted* (whether
    successful or not), the new firmware version
*   `initial_config`: the config found on the device at boot, typically
    represented by its checksum
*   `flashed_config`: if an update or downgrade was *attempted* (whether
    successful or not), the new config, typically represented by its checksum
*   `name`: a name for the device as reported by the kernel driver
*   `vendor_id`: the 16-bit HID vendor id for the device in hexadecimal format
*   `product_id`: the 16-bit HID product id for the device in hexadecimal format
*   `tool`: a name for the tool used by the updater
*   `tool_version`: the version of the tool used by the updater

Version numbers are strings, but readers of the file can assume that versions
are lexically ordered (e.g. version "1.2.3" is later than "1.2.0", and version
"4D" is earlier than "5A"). `initial_config` and `flashed_config`, on the other
hand, are not lexically comparable.

Individual updaters may include extra fields for other notable information. For
example, the Elan updater includes `elan_product_id`, which specifies the exact
touch device found in more detail than the evdev product ID does.

## Creating the report from an update script

`chromeos-touch-common.sh` provides five utility functions for writing to the
report:

*   `report_initial_version` should be called by every firmware updater on every
    run.
*   `report_update_result` should only be called after a firmware update is
    attempted, giving the status and the version of the new firmware.
*   `report_initial_config` and `report_config_result` are the equivalents for
    config updaters.
*   `report_updater_run` should be called by every firmware updater on every
    run. Will usually be called before updater specific script is invoked.
*   `report_tool_version` should be called by every firmware updater on every
    run.

(Note that `report_tool_version` is not fully used in every firmware updater yet.)

See the comments in [the source file](../common/scripts/chromeos-touch-common.sh)
for the details of each call.
