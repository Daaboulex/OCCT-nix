# OCCT-nix

A standalone Nix flake for the [OCCT (OverClock Checking Tool)](https://www.ocbase.com/), providing stability and benchmark testing on NixOS.

## Features

- **OpenSSL Compatibility**: Includes a custom C shim to support the internal .NET runtime's dependency on legacy OpenSSL 1.1 symbols.
- **Portability**: Redirects all application data and logs to `~/.local/share/occt/` to comply with the read-only Nix store.
- **Full Hardware Discovery**: Integrated dependencies like `zfs`, `smartmontools`, `dmidecode`, and `usbutils` for accurate hardware probing.
- **Wayland Support**: Ready for modern NixOS desktops with native Wayland preference.

## Usage

### Run directly (ad-hoc)

```bash
NIXPKGS_ALLOW_UNFREE=1 nix run 'github:Daaboulex/occt-nix' --impure
```

### Add to your NixOS Flake

1. Add to `flake.nix` inputs:

   ```nix
   occt-nix.url = "github:Daaboulex/occt-nix";
   ```

2. Add to your system packages:

   ```nix
   environment.systemPackages = [
     inputs.occt-nix.packages.${pkgs.system}.occt
   ];
   ```

## Legal & Licensing

- **Nix Packaging & Shim**: The build instructions and compatibility code in this repository are licensed under the [MIT License](LICENSE).
- **OCCT Software**: OCCT itself is **proprietary software**. This repository does **not** distribute the OCCT binary; it only provides instructions to fetch and package it. Your use of OCCT is subject to the [EULA and license terms](https://www.ocbase.com/) of OCCT-Base.
- **Unfree Software**: You must explicitly allow unfree software in your Nix configuration (`nixpkgs.config.allowUnfree = true;`) to use this package.

## Development

Build locally:

```bash
nix build --impure
```

The build uses a complex patching strategy (`patchelf`) to inject the compatibility shim into a wrapped OpenSSL library layer.
