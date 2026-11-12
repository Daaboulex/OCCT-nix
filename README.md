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

A Nix flake that wraps the upstream OCCT Linux binary into a package for NixOS:

- **Daily upstream check** at 06:00 UTC tracking both Stable and Testing channels (commits to `main` on hash change)
- **OpenSSL 1.1 compatibility shim** — bundled .NET runtime targets removed OpenSSL 1.1 symbols; this flake compiles `libocct_compat.so` to wrap them onto OpenSSL 3.x
- **ICU + Nix-store portability shims** — unversioned `u_strlen`, redirected app-data path under `$XDG_DATA_HOME/occt/` (default `~/.local/share/occt/`)
- **Hardware discovery PATH**: the wrapper puts the tools listed under [Runtime PATH](#runtime-path) on `PATH`
- **Update verification**: before a new pin is committed the updater runs `nix flake check` and builds both packages; the checks in [`flake.nix`](./flake.nix) include that each installed binary is byte-identical to the upstream download

## Features

- **OpenSSL 1.1 Compatibility Shim**: OCCT bundles a .NET runtime that links against legacy OpenSSL 1.1 symbols (`ERR_put_error`, `SSL_state`, `SSLeay`, etc.) removed in OpenSSL 3.x. A custom C shim (`libocct_compat.so`) wraps the modern 3.x API and is injected via `LD_PRELOAD` + `patchelf --add-needed` into a wrapped OpenSSL layer.
- **ICU Version Shim**: Provides an unversioned `u_strlen` symbol forwarding to whichever versioned symbol, `u_strlen_76` to `u_strlen_90`, the loaded ICU exports, since the .NET runtime may look for the unversioned symbol.
- **Nix Store Portability**: OCCT expects to write config/logs next to its binary. The wrapper redirects all application data to `$XDG_DATA_HOME/occt/` (default `~/.local/share/occt/`) and creates `app_folder_in_home` + `disable_update` trigger files.
- **Full Hardware Discovery**: Runtime `PATH` includes the hardware discovery tools listed under [Runtime PATH](#runtime-path).
- **Memory Temperature Monitoring**: DIMM temperature sensors are read over I2C/SMBus through the `i2c-dev` and `jc42` kernel modules, which the host loads (see Privileged Mode). `i2c-tools` is included in both `LD_LIBRARY_PATH` and `PATH`.
- **Stable & Testing Branches**: Supports both OCCT upstream release channels. Default is Stable; pass `branch = "Testing"` to track the beta/testing releases.
- **GPU Detection**: `libdrm` (including `libdrm_amdgpu.so.1`), `libpciaccess`, `libdisplay-info`, and `hwdata` (PCI ID database via `HWDATA_PATH`) for proper GPU name resolution, VRAM reporting, and display info.
- **CPU Topology**: `hwloc` (`libhwloc.so`) for core counts, instruction sets, and hyperthreading detection.
- **Storage Detection**: `systemdLibs` (`libudev.so`) for block device enumeration (size, rotational flag). `smartmontools` for SMART data.
- **OpenCL Support**: `ocl-icd` (OpenCL ICD loader) with `OCL_ICD_VENDORS` pointing to `/run/opengl-driver/etc/OpenCL/vendors/` for NixOS ICD discovery. Requires a registered OpenCL implementation at the system level (see below).
- **MSR Access**: CPU frequency and voltage come from the `msr` kernel module, which the host loads (see Privileged Mode).
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

The wrapper needs the dynamic loader at `/lib64/ld-linux-x86-64.so.2` and exits with an error when it is missing; on NixOS, `programs.nix-ld.enable = true;` provides it. The wrapper starts OCCT in its own network namespace with only the loopback interface, so OCCT has no network access.

### Run directly

```bash
# Stable (default)
nix run 'github:Daaboulex/OCCT-nix'

# Testing/Beta
nix run 'github:Daaboulex/OCCT-nix#occt-testing'
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
     inputs.occt-nix.packages.${pkgs.stdenv.hostPlatform.system}.occt
     # inputs.occt-nix.packages.${pkgs.stdenv.hostPlatform.system}.occt-testing  # for beta releases
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

OCCT's sensors need three kernel facilities the host provides; a user process cannot load modules, so the wrapper does not try. On NixOS set `hardware.cpu.x86.msr.enable = true;` (loads `msr`), `hardware.i2c.enable = true;` (loads `i2c-dev` and grants the `i2c` group the bus), and `boot.kernelModules = [ "jc42" ];` (DIMM temperatures). Reading MSRs still needs CAP_SYS_RAWIO, and System Tuning needs root.

**Note**: System Tuning only supports Intel Granite Rapids CPUs. AMD Zen 5 (Granite Ridge) is not yet supported for tuning — this is an upstream OCCT limitation.

## Packaging Details

### OpenSSL Compatibility Layer

OCCT's bundled .NET native code calls OpenSSL 1.1 symbols that were removed in 3.x. The packaging strategy:

1. **`openssl-compat-shim`**: A small C library compiled at build time that provides the missing symbols by wrapping the OpenSSL 3.x API. Covers `ERR_put_error`, `SSL_state`, `SSLeay`, `SSL_library_init`, `EVP_*` legacy functions, `HMAC_CTX_*`, `CRYPTO_*` threading, and `RAND_pseudo_bytes`.
2. **Wrapped OpenSSL**: Copies `libssl.so.3` and `libcrypto.so.3` into `$out/lib/openssl-wrapped/`, then uses `patchelf` to inject the shim as a dependency (`--add-needed libocct_compat.so`).
3. **Load order**: `LD_LIBRARY_PATH` prioritizes the wrapped OpenSSL dir, and `LD_PRELOAD` loads the shim before anything else, ensuring the compatibility symbols are resolved first.

### Runtime Library Path

The wrapper sets `LD_LIBRARY_PATH` to the wrapped OpenSSL directory followed by the libraries in the `runtimeLibs` list in [`package.nix`](./package.nix).

### Runtime PATH

Hardware discovery tools: `pciutils`, `dmidecode`, `smartmontools`, `usbutils`, `zfs`, `lm_sensors`, `nvme-cli`, `iproute2`, `libva-utils`, `vulkan-tools`, `util-linux`, `kmod`, `i2c-tools`.

## Known Limitations

- **System Tuning**: Only supports Intel Granite Rapids. AMD Zen 5 shows "NO SUPPORTED HARDWARE" — this is upstream, not a packaging issue.
- **Memory temperatures need host kernel modules**: DIMM temperature sensors are accessed via I2C/SMBus which requires `i2c-dev` and `jc42` kernel modules. The host loads them (see Privileged Mode); membership of the `i2c` group reads them.
- **OpenCL requires system config**: The package provides the ICD loader but the actual driver (RustiCL, NVIDIA, etc.) must be registered at the NixOS system level via `hardware.graphics.extraPackages`.
- **`RUSTICL_ENABLE` needed for AMD/Intel**: RustiCL doesn't auto-detect gallium drivers yet — the env var must be set at the session level.
- **ZFS warning**: "The ZFS modules cannot be auto-loaded" is harmless if you don't use ZFS. OCCT checks for ZFS storage pools as part of hardware discovery.
- **radv warning**: "radv is not a conformant Vulkan implementation" is a standard Mesa warning for non-certified drivers. It does not affect functionality.
- **GPU name shows PCI ID**: If `hwdata` can't resolve a device name (very new hardware), the raw PCI ID (e.g. "0x1002") is displayed instead.

## Updates

[`update.yml`](./.github/workflows/update.yml) runs daily at 06:00 UTC and on
manual dispatch. OCCT is a proprietary binary with no public API, so
[`scripts/update.sh`](./scripts/update.sh) is a `custom`-type updater: it reads
the Stable and Testing version and SHA-256 checksum from the JSON embedded in
the `ocbase.com` download page, downloads each binary whose pin differs
(requiring HTTP 200 and at least 100 MB), compares its SHA-256 with the
published checksum, rewrites the matching `sources` block in
[`package.nix`](./package.nix), then runs `nix flake check` and builds both
packages. On success it commits to `main`; on failure it opens an
`update-failed` issue.

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

The pre-commit hooks come from the
[Nix Packaging Standard](https://github.com/Daaboulex/nix-packaging-standard).

## License

- **Nix packaging & compat shim**: This repo is [MIT](./LICENSE) licensed.
- **OCCT software**: Proprietary, unfree. This repository does **not** distribute the OCCT binary — it only provides the fetch + wrap pipeline. Your use of OCCT is subject to the [EULA and license terms](https://www.ocbase.com/) of OCCT-Base.
- **Unfree gate**: the flake's own outputs (`nix run`, `nix build`, `inputs.occt-nix.packages`) need no setting, because the flake allows unfree for them. `pkgs.occt` and `pkgs.occt-testing` from the overlay require `nixpkgs.config.allowUnfree = true` in your Nix configuration.

<!-- BEGIN generated:footer -->
<!-- END generated:footer -->
