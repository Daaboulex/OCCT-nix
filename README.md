# OCCT-nix

<!-- BEGIN generated:badges -->
[![CI](https://github.com/Daaboulex/OCCT-nix/actions/workflows/ci.yml/badge.svg)](https://github.com/Daaboulex/OCCT-nix/actions/workflows/ci.yml)
[![NixOS unstable](https://img.shields.io/badge/NixOS-unstable-78C0E8?logo=nixos&logoColor=white)](https://nixos.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
<!-- END generated:badges -->

A Nix flake for [OCCT (OverClock Checking Tool)](https://www.ocbase.com/) on NixOS — stability testing, benchmarking, and hardware monitoring.

<!-- BEGIN generated:upstream -->
## Upstream

| | |
|---|---|
| **Project** | [Upstream](https://www.ocbase.com) |
| **License** | Proprietary |
| **Tracked** | Custom update script |

<!-- END generated:upstream -->

## What Is This?

A Nix flake that wraps the upstream OCCT Linux binary into a NixOS-portable package with full CI infrastructure:

- **Daily upstream check** at 06:00 UTC tracking both Stable and Testing channels (commits to `main` on hash change)
- **OpenSSL 1.1 compatibility shim** — bundled .NET runtime targets removed OpenSSL 1.1 symbols; this flake compiles `libocct_compat.so` to wrap them onto OpenSSL 3.x
- **ICU + Nix-store portability shims** — unversioned `u_strlen`, redirected app-data path under `~/.local/share/occt/`
- **Hardware discovery PATH** — bundles `dmidecode`, `smartmontools`, `pciutils`, `usbutils`, `lm_sensors`, `nvme-cli`, `kmod`, `util-linux`, `iproute2`, `libva-utils`, `vulkan-tools`, `i2c-tools`
- **Pre-publish verification** — wrapper exists, ELF magic valid, shim libs present, runtime deps wired (`ci.yml`)

## Features

- **OpenSSL 1.1 Compatibility Shim**: OCCT bundles a .NET runtime that links against legacy OpenSSL 1.1 symbols (`ERR_put_error`, `SSL_state`, `SSLeay`, etc.) removed in OpenSSL 3.x. A custom C shim (`libocct_compat.so`) wraps the modern 3.x API and is injected via `LD_PRELOAD` + `patchelf --add-needed` into a wrapped OpenSSL layer.
- **ICU Version Shim**: Provides an unversioned `u_strlen` symbol forwarding to the versioned `u_strlen_76`, since the .NET runtime may look for the unversioned symbol.
- **Nix Store Portability**: OCCT expects to write config/logs next to its binary. The wrapper redirects all application data to `~/.local/share/occt/` and creates `app_folder_in_home` + `disable_update` trigger files.
- **Full Hardware Discovery**: Runtime `PATH` includes `dmidecode`, `smartmontools`, `pciutils`, `usbutils`, `lm_sensors`, `nvme-cli`, `kmod`, `util-linux`, `iproute2`, `libva-utils`, `vulkan-tools`, and `i2c-tools`.
- **Memory Temperature Monitoring**: Wrapper loads `i2c-dev` and `jc42` kernel modules at startup for DIMM temperature sensors via I2C/SMBus. `i2c-tools` is included in both `LD_LIBRARY_PATH` and `PATH`.
- **Stable & Testing Branches**: Supports both OCCT upstream release channels. Default is Stable; pass `branch = "Testing"` to track the beta/testing releases.
- **GPU Detection**: `libdrm` (including `libdrm_amdgpu.so.1`), `libpciaccess`, `libdisplay-info`, and `hwdata` (PCI ID database via `HWDATA_PATH`) for proper GPU name resolution, VRAM reporting, and display info.
- **CPU Topology**: `hwloc` (`libhwloc.so`) for core counts, instruction sets, and hyperthreading detection.
- **Storage Detection**: `systemdLibs` (`libudev.so`) for block device enumeration (size, rotational flag). `smartmontools` for SMART data.
- **OpenCL Support**: `ocl-icd` (OpenCL ICD loader) with `OCL_ICD_VENDORS` pointing to `/run/opengl-driver/etc/OpenCL/vendors/` for NixOS ICD discovery. Requires a registered OpenCL implementation at the system level (see below).
- **MSR Access**: Wrapper attempts `modprobe msr` for CPU frequency/voltage reading, plus `modprobe i2c-dev` and `modprobe jc42` for DIMM temperature sensors (all fail silently without root).
- **Wayland + X11**: `GDK_BACKEND=wayland,x11` with `wayland` client libraries included.
- **Desktop Integration**: `.desktop` file and icons extracted from the upstream favicon.

<!-- BEGIN generated:installation -->
## Installation

Add as a flake input:

```nix
{
  inputs.OCCT = {
    url = "github:Daaboulex/OCCT-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Then add the overlay:

```nix
nixpkgs.overlays = [ inputs.OCCT.overlays.default ];
```

<!-- END generated:installation -->

## Usage

### Run directly

```bash
# Stable (default)
NIXPKGS_ALLOW_UNFREE=1 nix run 'github:Daaboulex/OCCT-nix' --impure

# Testing/Beta
NIXPKGS_ALLOW_UNFREE=1 nix run 'github:Daaboulex/OCCT-nix#occt-testing' --impure
```

### Add to a NixOS flake

1. Add the input:

   ```nix
   inputs.occt-nix.url = "github:Daaboulex/OCCT-nix";
   ```

2. Use the overlay or add the package directly:

   ```nix
   # Via overlay (recommended — makes pkgs.occt and pkgs.occt-testing available)
   nixpkgs.overlays = [ inputs.occt-nix.overlays.default ];
   environment.systemPackages = [ pkgs.occt ];
   # environment.systemPackages = [ pkgs.occt-testing ];  # for beta releases

   # Or directly
   environment.systemPackages = [
     inputs.occt-nix.packages.${pkgs.system}.occt
     # inputs.occt-nix.packages.${pkgs.system}.occt-testing  # for beta releases
   ];
   ```

## OpenCL Setup

OCCT uses OpenCL for GPU stability tests (VRAM test uses Vulkan and works without OpenCL). The package includes the `ocl-icd` loader library but the actual GPU driver must be registered at the **system level**.

### AMD GPUs (RustiCL)

RustiCL (Mesa's OpenCL implementation) doesn't auto-enable its gallium drivers yet. You need:

1. Register the OpenCL ICD in `hardware.graphics.extraPackages`:

   ```nix
   hardware.graphics.extraPackages = [ pkgs.mesa.opencl ];
   ```

2. Set the `RUSTICL_ENABLE` environment variable to your gallium driver:

   ```nix
   environment.sessionVariables.RUSTICL_ENABLE = "radeonsi";  # AMD GPUs
   # environment.sessionVariables.RUSTICL_ENABLE = "iris";     # Intel GPUs
   # environment.sessionVariables.RUSTICL_ENABLE = "radeonsi,iris";  # Both
   ```

3. Verify after rebuild + re-login:

   ```bash
   nix-shell -p clinfo --run "clinfo --list"
   ```

**Note**: `RUSTICL_ENABLE` is a session variable — changes require logout/login to take effect.

### NVIDIA GPUs

NVIDIA provides its own proprietary OpenCL implementation. It is typically registered automatically when using the NVIDIA driver module.

### Intel GPUs

Same as AMD but with `iris` as the gallium driver name.

## Privileged Mode

OCCT's System Tuning feature and full sensor access require elevated privileges. The wrapper attempts `modprobe msr`, `modprobe i2c-dev`, and `modprobe jc42` automatically but full functionality (including memory DIMM temperatures) requires running as root:

```bash
sudo occt
```

**Note**: System Tuning only supports Intel Granite Rapids CPUs. AMD Zen 5 (Granite Ridge) is not yet supported for tuning — this is an upstream OCCT limitation.

## Packaging Details

### OpenSSL Compatibility Layer

OCCT's bundled .NET native code calls OpenSSL 1.1 symbols that were removed in 3.x. The packaging strategy:

1. **`openssl-compat-shim`**: A small C library compiled at build time that provides the missing symbols by wrapping the OpenSSL 3.x API. Covers `ERR_put_error`, `SSL_state`, `SSLeay`, `SSL_library_init`, `EVP_*` legacy functions, `HMAC_CTX_*`, `CRYPTO_*` threading, and `RAND_pseudo_bytes`.
2. **Wrapped OpenSSL**: Copies `libssl.so.3` and `libcrypto.so.3` into `$out/lib/openssl-wrapped/`, then uses `patchelf` to inject the shim as a dependency (`--add-needed libocct_compat.so`).
3. **Load order**: `LD_LIBRARY_PATH` prioritizes the wrapped OpenSSL dir, and `LD_PRELOAD` loads the shim before anything else, ensuring the compatibility symbols are resolved first.

### Runtime Library Path

The wrapper sets `LD_LIBRARY_PATH` with ~30 libraries covering:

| Category | Libraries |
|---|---|
| GUI / Display | gtk3, gdk-pixbuf, glib, libX11, libXcursor, libXext, libXi, libXrandr, libXrender, libXfixes, libICE, libSM, wayland |
| Graphics | libGL, mesa, vulkan-loader, ocl-icd, libdrm, libpciaccess, libdisplay-info |
| .NET Runtime | openssl (wrapped), zlib, krb5, icu, lttng-ust, libunwind |
| Hardware | hwloc, systemdLibs (libudev), pciutils, lm_sensors, curl, i2c-tools |

### Runtime PATH

Hardware discovery tools: `pciutils`, `dmidecode`, `smartmontools`, `usbutils`, `zfs`, `lm_sensors`, `nvme-cli`, `iproute2`, `libva-utils`, `vulkan-tools`, `util-linux`, `kmod`, `i2c-tools`.

## Known Limitations

- **System Tuning**: Only supports Intel Granite Rapids. AMD Zen 5 shows "NO SUPPORTED HARDWARE" — this is upstream, not a packaging issue.
- **Memory temperatures require root**: DIMM temperature sensors are accessed via I2C/SMBus which requires `i2c-dev` and `jc42` kernel modules. The wrapper loads these automatically but they need root privileges. Run `sudo occt` for full sensor access.
- **OpenCL requires system config**: The package provides the ICD loader but the actual driver (RustiCL, NVIDIA, etc.) must be registered at the NixOS system level via `hardware.graphics.extraPackages`.
- **`RUSTICL_ENABLE` needed for AMD/Intel**: RustiCL doesn't auto-detect gallium drivers yet — the env var must be set at the session level.
- **ZFS warning**: "The ZFS modules cannot be auto-loaded" is harmless if you don't use ZFS. OCCT checks for ZFS storage pools as part of hardware discovery.
- **radv warning**: "radv is not a conformant Vulkan implementation" is a standard Mesa warning for non-certified drivers. It does not affect functionality.
- **GPU name shows PCI ID**: If `hwdata` can't resolve a device name (very new hardware), the raw PCI ID (e.g. "0x1002") is displayed instead.

## Automation & CI

Three GitHub Actions workflows, from the
[Nix Packaging Standard](https://github.com/Daaboulex/nix-packaging-standard):

### CI (`ci.yml`)

Runs on every push and PR: an AI-artifact guard, then builds every output the
flake declares (`occt` and `occt-testing`, plus the standard's conformance and
schema checks) via `nix-fast-build`.

### Update (`update.yml`)

Runs **daily at 06:00 UTC** (and on manual dispatch). OCCT is a proprietary
binary with no public API, so it ships a **bespoke `scripts/update.sh`** (a
`custom`-type updater): it downloads the latest Stable + Testing binaries from
`ocbase.com`, validates each (HTTP 200, size >100 MB, ELF magic), extracts the
version from .NET assembly metadata, recomputes the SRI hash, rewrites the
matching `sources` block, then evaluates and builds. On success it commits to
`main`; on failure it opens an `update-failed` issue.

### Maintenance (`maintenance.yml`)

Runs **weekly**: refreshes `flake.lock` (pushing only if the result still
builds) and deletes stale `update/*` branches older than 30 days.

### Supply chain

- All GitHub Actions are pinned to commit SHAs (not mutable tags).
- Downloads are validated (HTTP status, minimum file size, ELF magic) before any
  hash comparison.

## Development

```bash
nix develop                  # dev shell with pre-commit hooks
nix flake check              # eval + build all outputs (incl. both packages)
nix build                    # build stable
nix build .#occt-testing     # build testing
nix run                      # run stable
nix run .#occt-testing       # run testing

# Inspect the binary's libraries / the generated wrapper
readelf -d result/opt/occt/occt-bin | grep NEEDED
cat result/bin/occt

# Manually trigger the updater
gh workflow run update.yml
```

Pre-commit hooks (from the standard): `nixfmt-rfc-style`, `typos`, `rumdl`,
`check-readme-sections`.

## License

- **Nix packaging & compat shim**: This repo is [MIT](./LICENSE) licensed.
- **OCCT software**: Proprietary, unfree. This repository does **not** distribute the OCCT binary — it only provides the fetch + wrap pipeline. Your use of OCCT is subject to the [EULA and license terms](https://www.ocbase.com/) of OCCT-Base.
- **Unfree gate**: requires `nixpkgs.config.allowUnfree = true` in your Nix configuration.

<!-- BEGIN generated:footer -->
<!-- END generated:footer -->
