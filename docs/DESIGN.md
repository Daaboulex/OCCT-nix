# Design

How the package gets OCCT, a proprietary binary with a bundled .NET runtime,
to run from the Nix store. Everything described here is in
[package.nix](../package.nix). Installing and using the package is covered in
the [README](../README.md).

## What the package is

A Nix flake that wraps the upstream OCCT Linux binary into a package for
NixOS. The upstream binary is installed as it was downloaded, at
`opt/occt/occt-bin`, and started through a wrapper script, `bin/occt`.

The wrapper checks for the dynamic loader at `/lib64/ld-linux-x86-64.so.2` and
exits with an error when it is missing. On NixOS
`programs.nix-ld.enable = true;` provides it. The wrapper sets `NIX_LD` to
glibc's loader unless it is already set.

## Stable and Testing

The package supports both OCCT upstream release channels. The default is
Stable. Passing `branch = "Testing"` to `package.nix` tracks the beta/testing
releases. Each channel has its own block in `sources`, with a version, a URL
and a hash. Any other value for `branch` fails the evaluation.

[flake.nix](../flake.nix) exposes the two as `occt` and `occt-testing`, each as
a package, an app and an overlay attribute.

## OpenSSL compatibility layer

OCCT bundles a .NET runtime whose native code links against legacy OpenSSL 1.1
symbols (`ERR_put_error`, `SSL_state`, `SSLeay`, etc.) that were removed in
OpenSSL 3.x. The packaging strategy has three parts.

1. `openssl-compat-shim` is a small C library compiled at build time into
   `libocct_compat.so`. It provides the missing symbols by wrapping the
   OpenSSL 3.x API. It covers `ERR_put_error`, `SSL_state`, `SSLeay`,
   `SSL_library_init`, `EVP_*` legacy functions, `HMAC_CTX_*`, `CRYPTO_*`
   threading, and `RAND_pseudo_bytes`.
2. The wrapped OpenSSL is a copy of `libssl.so.3` and `libcrypto.so.3` in
   `$out/lib/openssl-wrapped/`. `patchelf` injects the shim into both as a
   dependency (`--add-needed libocct_compat.so`).
3. The load order is set by the wrapper. `LD_LIBRARY_PATH` prioritizes the
   wrapped OpenSSL directory, and `LD_PRELOAD` loads the shim before anything
   else, ensuring the compatibility symbols are resolved first.

## ICU version shim

The same library provides an unversioned `u_strlen` symbol, since the .NET
runtime may look for the unversioned symbol. It forwards to whichever
versioned symbol, `u_strlen_76` to `u_strlen_90`, the loaded ICU exports. When
none of them is found it aborts with a message asking for the shim to be
updated.

## Nix store portability

OCCT expects to write config and logs next to its binary. The wrapper
redirects all application data to `$XDG_DATA_HOME/occt/` (default
`~/.local/share/occt/`) and creates the `app_folder_in_home` and
`disable_update` trigger files there.

OCCT extracts native monitoring libraries at run time and loads them. The
wrapper points `TMPDIR` at `tmp/` in the same directory, so that they do not
land on a `/tmp` that forbids running code. The .NET bundle is extracted under
`runtime/` there, and the wrapper removes extractions older than seven days at
each start.

## No network

The wrapper starts OCCT in its own network namespace with only the loopback
interface, so OCCT has no network access. The reason given in the wrapper is
that OCCT's telemetry has no opt-out switch and local stress testing needs no
network, so any upload attempt fails. Device access, sensors and the Wayland
and X11 sockets go through the filesystem and are unaffected.

## Runtime library path

The wrapper sets `LD_LIBRARY_PATH` to the wrapped OpenSSL directory followed by
the libraries in the `runtimeLibs` list in [package.nix](../package.nix). What
the hardware-facing ones are for:

| Purpose | What the package brings |
|---|---|
| GPU detection | `libdrm` (including `libdrm_amdgpu.so.1`), `libpciaccess`, `libdisplay-info`, and `hwdata` (PCI ID database via `HWDATA_PATH`) for proper GPU name resolution, VRAM reporting, and display info |
| CPU topology | `hwloc` (`libhwloc.so`) for core counts, instruction sets, and hyperthreading detection |
| Storage detection | `systemdLibs` (`libudev.so`) for block device enumeration (size, rotational flag), and `smartmontools` for SMART data |
| OpenCL | `ocl-icd` (the OpenCL ICD loader) with `OCL_ICD_VENDORS` pointing to `/run/opengl-driver/etc/OpenCL/vendors/` for NixOS ICD discovery. It requires a registered OpenCL implementation at the system level |
| Memory temperature monitoring | `i2c-tools`, included in both `LD_LIBRARY_PATH` and `PATH` |
| Wayland and X11 | `GDK_BACKEND=wayland,x11`, with the `wayland` client libraries included |

## Runtime PATH

The wrapper puts these hardware discovery tools on `PATH`: `pciutils`,
`dmidecode`, `smartmontools`, `usbutils`, `zfs`, `lm_sensors`, `nvme-cli`,
`iproute2`, `libva-utils`, `vulkan-tools`, `util-linux`, `kmod`, `i2c-tools`.

## Kernel modules stay with the host

DIMM temperature sensors are read over I2C/SMBus through the `i2c-dev` and
`jc42` kernel modules. CPU frequency and voltage come from the `msr` kernel
module. A user process cannot load modules, so the wrapper does not try, and
the host loads all three. The settings are in the [README](../README.md).

## Desktop integration

The package installs a `.desktop` file, and icons extracted from the upstream
favicon.
