# Linux VRAM Management & 4GB VRAM Stutter Fix

A collection of installation commands, configuration files, and troubleshooting information for Linux VRAM management using the DMEM cgroup system.

This repository is mainly aimed at Linux gaming systems with limited VRAM, especially AMD GPUs where heavy VRAM pressure can cause severe stuttering, FPS drops, or freezes.

## What's included

* Installation commands for `dmemcg-booster`
* KDE Plasma foreground VRAM management
* Commands for checking whether DMEM is active
* A custom `dmem.max` safety-limit workaround
* Automatic VRAM-capacity detection
* A configurable VRAM safety margin (for example, 50 MiB)
* Verification and troubleshooting commands

## Important

The `dmemcg-booster` and Plasma foreground-booster packages are third-party projects and are **not my software**. They are included here only as installation references.

Upstream projects:

* dmemcg-booster: https://gitlab.steamos.cloud/holo/dmemcg-booster
* KCGroups / Plasma integration: https://github.com/pixelcluster/kcgroups
* KDE KCGroups: https://github.com/KDE/kcgroups

The custom `dmem.max` limiter in this repository is a separate experimental workaround. It is intended to leave a small amount of VRAM unused instead of allowing `app.slice` to consume the entire available VRAM capacity.

The custom scripts were developed with AI assistance and then tested on my own system. **Use them at your own risk and inspect the commands before running them**, especially commands that use `sudo` or modify `/sys/fs/cgroup`.

This repository is not affiliated with or endorsed by CachyOS, Valve, KDE, or the developers of the upstream projects.

## Example

On a 4 GiB GPU, a 50 MiB safety margin results in approximately:

`4 GiB - 50 MiB = 4225761280 bytes`

The safety margin can be changed in the script.

## Why this exists

The goal is to provide an easy-to-follow reference for experimenting with Linux DMEM/VRAM management, particularly on systems where running completely out of VRAM causes severe performance problems.

Always test the configuration on your own hardware and revert it if it causes instability.
