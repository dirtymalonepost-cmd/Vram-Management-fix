# Linux VRAM Manager

A small Bash-based utility for Linux gaming systems using the kernel DMEM cgroup interface. It can install or enable the available VRAM-management stack, apply a persistent `dmem.max` VRAM headroom limit, verify the configuration, and remove the custom setup.

> **Experimental:** The `dmem.max` ceiling is a workaround intended to leave a small amount of VRAM headroom instead of allowing `app.slice` to consume the full reported capacity. Results can vary by GPU, driver, kernel, game, and desktop environment.

## Features

- Install and enable supported DMEM/VRAM-management packages
- Choose or change the VRAM safety margin in MiB
- Automatically detect the current user's UID
- Detect AMD/Intel `vram` and NVIDIA `vidmem` DMEM regions
- Apply the ceiling persistently with a systemd oneshot service
- Verify service state, VRAM capacity, `dmem.max`, and `dmem.current`
- Remove the custom ceiling and its systemd configuration
- Optionally remove the VRAM-management packages

## How it works

The custom workaround lowers `app.slice/dmem.max` below the GPU's reported VRAM capacity, leaving a configurable amount of headroom.

Example for a 4 GiB GPU with 50 MiB of headroom:

```text
VRAM capacity : 4278190080 bytes
Safety margin : 50 MiB
VRAM ceiling  : 4225761280 bytes
```

The custom service is a **oneshot**: it applies the limit and exits. It does not continuously monitor VRAM or keep a monitoring process running. After the service exits, the kernel continues enforcing `dmem.max`.

## Requirements

The target system needs:

- systemd
- cgroup v2
- a kernel with DMEM cgroup support
- a GPU driver that exposes device VRAM through the DMEM controller
- a normal systemd user cgroup hierarchy with `app.slice`

The package installer currently supports:

- **CachyOS / Arch-based systems:** `pacman`, with AUR fallback when `yay` or `paru` is available
- **Fedora / Nobara-style systems:** `dnf`, when the required packages are available in the configured repositories
- **Bazzite:** detects the integrated DMEM stack instead of attempting to remove its image-provided packages

Other distributions may work when the same kernel, systemd, cgroup, and GPU-driver requirements are satisfied, but are not guaranteed by this tool.

## Usage

### From source

```bash
chmod +x vram-manager.sh
./vram-manager.sh
```

### Binary release

On x86_64 Linux systems, download `Linux-VRAM-Manager-x86_64` from the latest GitHub Release, make it executable if necessary, and run it.

The Bash source is kept in the repository so it can be inspected directly.

## Menu

```text
1) Install / enable VRAM management
2) Apply / change VRAM ceiling
3) Verify current / post-reboot state
4) Remove custom VRAM ceiling
5) Remove everything
6) System / package status
7) Exit
```

## What the custom limiter changes

The custom limiter creates:

```text
/usr/local/sbin/set-dmem-appslice-limit
/etc/systemd/system/dmemcg-appslice-limit@.service
/etc/default/dmemcg-appslice-limit
```

It also changes the live kernel-managed cgroup interface at:

```text
/sys/fs/cgroup/.../app.slice/dmem.max
```

It does **not** modify:

- GPU drivers or GPU firmware
- BIOS/UEFI settings
- kernel files
- game files
- personal files or media
- the installed files of the upstream VRAM-management packages

The `/sys/fs/cgroup` entries are kernel-managed cgroup interfaces, not ordinary files stored on disk.

## Upstream credits

This project does not claim ownership of the underlying DMEM/VRAM-management projects. It uses their functionality where available and adds a separate `dmem.max` headroom workaround and management interface.

### dmemcg-booster

Service for enabling and controlling DMEM cgroup limits for foreground games.

https://gitlab.steamos.cloud/holo/dmemcg-booster

### KCGroups / Plasma integration

`pixelcluster/kcgroups` is a fork of KDE's KCGroups library with DMEM cgroup integration for foreground applications.

https://github.com/pixelcluster/kcgroups

CachyOS packages the KDE integration as `plasma-foreground-booster` and identifies `kcgroups` as its base package.

https://packages.cachyos.org/package/cachyos/x86_64/plasma-foreground-booster

### Linux DMEM cgroup functionality

The underlying `dmem.*` interface is provided by the Linux kernel; this project does not implement the kernel controller.

## AI disclosure

This project was developed with AI assistance. The source code is published in the repository so the implementation can be inspected directly. The custom `dmem.max` workaround was personally modified and tested on CachyOS.

## License

The custom code in this repository is released under the MIT License. Third-party projects, packages, and kernel components referenced by this project remain under their respective upstream licenses.
