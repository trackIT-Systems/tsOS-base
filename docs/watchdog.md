# Safe Booting and System Recovery

## Overview

Reliable operation of embedded systems requires protection against various failure modes, including kernel panics, boot process hangs, and application crashes. The Raspberry Pi provides several mechanisms to ensure the system can automatically recover (reboot) when these issues occur.

## Hardware Watchdog

The Raspberry Pi includes a hardware watchdog timer. If this timer is not reset ("pet") periodically by the software, it triggers a hardware reset of the system.

### Hardware Limitations

**Important**: The Raspberry Pi hardware watchdog has a maximum timeout limit of approximately **15 seconds**.

- This is a hard limit of the Broadcom SoC implementation.
- Attempts to configure a longer timeout will be capped at 15 seconds by the hardware.
- Both the bootloader and the kernel driver respect this limit.

## Bootloader Configuration (`config.txt`)

There are two primary ways to configure the watchdog in `/boot/firmware/config.txt`. It is important to understand the difference between them:

### 1. `dtparam=watchdog=on`
- **Function**: Enables the watchdog hardware device tree node.
- **Behavior**: The hardware is made *available* to the Linux kernel. The watchdog is **not** active during the boot process. It only becomes active once the OS (systemd or watchdog daemon) opens the device and starts feeding it.
- **Use Case**: General system monitoring where boot hangs are not a primary concern.
- **Note**: This is enabled by default on Raspberry Pi 3 and newer models running recent Raspberry Pi OS versions. Explicit configuration is primarily needed for older hardware or custom device trees.

### 2. `kernel_watchdog_timeout=10`
- **Function**: Enables the watchdog *in the bootloader* and passes the active timer to the kernel.
- **Behavior**: The bootloader starts the watchdog timer with the specified timeout (e.g., 10 seconds) before loading the kernel. It then updates the kernel command line to tell the kernel that the watchdog is already running.
- **Default**: 0 (Disabled). The watchdog is not started by the bootloader unless this is set to a non-zero value.
- **Use Case**: **High-Reliability**. This protects against hangs *during* the boot process. If the kernel crashes or freezes before userspace starts, the system will reboot.

**Recommendation**: For unattended systems, use `kernel_watchdog_timeout` to ensure coverage during the entire boot sequence.

## Kernel Command Line Parameters

To further harden the system, add the following parameters to `/boot/firmware/cmdline.txt`. These configure how the kernel handles failures and interacts with the watchdog.

### `panic=10`
- **Description**: Panic timeout.
- **Effect**: If a kernel panic occurs (unrecoverable system error), wait 10 seconds and then reboot.
- **Default**: 0 (wait forever), which requires a manual power cycle.

### `bcm2835_wdt.nowayout=1`
- **Description**: Watchdog "No Way Out" mode.
- **Effect**: Once the watchdog is started, it cannot be stopped by the application or by closing the device file. If the watchdog daemon crashes or is killed, the watchdog timer will expire and reboot the system.
- **Benefit**: prevents accidental disabling of the watchdog.

### `watchdog_core.open_timeout=30`
- **Description**: Watchdog open grace period.
- **Effect**: If the watchdog was started by the bootloader (via `kernel_watchdog_timeout`), this parameter defines how long the kernel waits for userspace (systemd) to open and take over the watchdog device.
- **Default**: 0 (Disabled/Infinite). If 0, the kernel will keep petting the watchdog indefinitely (if the driver supports it) until userspace opens it, or it will stop the watchdog if the driver doesn't support "keep running".
- **Benefit**: Prevents a reboot loop if userspace takes slightly longer to start than the initial hardware timeout allows.

## Systemd Configuration

Once the system is booted, systemd takes over "feeding" the watchdog. Configure this in `/etc/systemd/system.conf`:

```ini
[Manager]
RuntimeWatchdogSec=10
```

- **RuntimeWatchdogSec**: How often systemd pets the watchdog. Must be less than the hardware limit (15s).

## Summary of a High-Reliability Configuration

1. **`config.txt`**:
   ```
   # Enable watchdog early to protect boot process
   kernel_watchdog_timeout=10
   ```

2. **`cmdline.txt`**:
   ```
   ... panic=10 bcm2835_wdt.nowayout=1 watchdog_core.open_timeout=30
   ```

3. **`system.conf`**:
   ```
   RuntimeWatchdogSec=10
   ```

## References

- [Raspberry Pi Documentation - kernel_watchdog_timeout](https://www.raspberrypi.com/documentation/computers/config_txt.html#kernel_watchdog_timeout)
- [Raspberry Pi Forums - Watchdog Timer 15 Second Limit](https://forums.raspberrypi.com/viewtopic.php?t=9526)
