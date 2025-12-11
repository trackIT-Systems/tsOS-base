# Updatability

## Overview

tsOS-base supports safe system updates through a dual-boot mechanism using Raspberry Pi's tryboot feature. This allows testing new system images before committing to them, with automatic rollback on boot failure.

## Dual-Boot Mechanism

The system uses Raspberry Pi's tryboot feature to enable dual-boot between the current production system and a new update candidate.

### Partition Layout

The system uses multiple root partitions:
- **Partition 2 (rootfs)**: Current production root filesystem (6 GiB, ext4)
- **Partition 3 (clonefs)**: Update candidate root filesystem (6 GiB, ext4)

Both partitions are identical in size and structure, allowing one to serve as a backup or update target.

### Tryboot Process

1. **Triggering Tryboot Mode**
   - Reboot with tryboot parameter: `reboot "0 tryboot"`
   - This signals the Raspberry Pi bootloader to enter tryboot mode

2. **Bootloader Behavior**
   - In tryboot mode, the bootloader loads `tryboot.txt` instead of the standard `config.txt`
   - `tryboot.txt` can specify a different commandline file using `cmdline=cmdline.try`
   - `cmdline.try` can point to a different root partition (e.g., `root=/dev/mmcblk0p3` instead of `root=/dev/mmcblk0p2`)

3. **Boot Failure Detection**
   - If the boot fails, the bootloader detects this (exact detection mechanism depends on bootloader implementation)
   - On the next boot attempt, the bootloader automatically falls back to loading `config.txt` (normal boot mode)
   - This ensures the system always returns to a known-good state

4. **Successful Boot**
   - If the tryboot system boots successfully, it can be committed as the new production system
   - The boot configuration can be updated to make the new partition the default

## Update Workflow

### Preparing an Update

1. **Clone Current System**
   - Copy the current rootfs (partition 2) to clonefs (partition 3)
   - Or install a new system image to clonefs partition

2. **Configure Tryboot**
   - Create `tryboot.txt` in `/boot/firmware/` (or `/media/boot/`)
   - Create `cmdline.try` with kernel parameters pointing to partition 3:
     ```
     root=/dev/mmcblk0p3 rootfstype=ext4 ...
     ```

3. **Test the Update**
   - Reboot with: `reboot "0 tryboot"`
   - System will boot from partition 3
   - Test functionality and stability

4. **Commit or Rollback**
   - **If successful**: Update `cmdline.txt` to point to partition 3, or swap partition roles
   - **If failed**: Simply reboot normally - system will automatically use partition 2

## Boot Configuration Files

### Standard Boot (`config.txt` + `cmdline.txt`)
- `config.txt`: Standard Raspberry Pi configuration
- `cmdline.txt`: Kernel command line with `root=/dev/mmcblk0p2` (or current production root)

### Tryboot Mode (`tryboot.txt` + `cmdline.try`)
- `tryboot.txt`: Tryboot-specific configuration, typically includes:
  ```
  cmdline=cmdline.try
  ```
- `cmdline.try`: Kernel command line with `root=/dev/mmcblk0p3` (or update candidate root)

## Safety Features

- **Automatic Rollback**: Failed tryboot attempts automatically return to normal boot mode
- **Read-Only Base**: Production rootfs remains read-only (protected by overlayroot)
- **Partition Isolation**: Update candidate runs independently without affecting production system
- **No Manual Intervention**: Rollback happens automatically on boot failure

## Use Cases

- **System Updates**: Test new OS versions or major updates before committing
- **Configuration Testing**: Test kernel parameters or system configurations
- **Safe Experimentation**: Try new features without risking production system
- **Field Updates**: Update remote systems with confidence that rollback is automatic

## Implementation Notes

- The tryboot mechanism is built into the Raspberry Pi bootloader (start.elf)
- No special software is required on the system side - it's handled at the bootloader level
- The bootloader tracks tryboot state and automatically manages fallback
- Both root partitions should be identical in structure and size for seamless switching
