# OCCT (Nix)

A Nix flake for [OCCT (OverClock Checking Tool)](https://www.ocbase.com/) on
NixOS, for stability testing, benchmarking and hardware monitoring. It wraps
the upstream Linux binary into a package that runs from the Nix store.

It is built for x86_64 Linux only, because upstream ships no aarch64 binary.
Both of upstream's channels, Stable and Testing, are packaged.

The checks build each package and confirm that it carries the unmodified
upstream binary. They do not start OCCT, and the repository keeps no list of
hardware it has been tried on.

## Install

Add the flake:

```nix
{
  inputs.occt-nix = {
    url = "github:Daaboulex/OCCT-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Then add the overlay, install the package and switch on nix-ld, which provides
the dynamic loader the wrapper needs. OCCT is unfree.

```nix
{
  nixpkgs.overlays = [ inputs.occt-nix.overlays.default ];
  nixpkgs.config.allowUnfree = true;
  programs.nix-ld.enable = true;

  environment.systemPackages = [ pkgs.occt ];
}
```

`pkgs.occt` is the Stable channel. `pkgs.occt-testing` is the Testing channel,
upstream's beta releases.

Without the overlay, the two packages are at
`inputs.occt-nix.packages.${pkgs.stdenv.hostPlatform.system}.occt` and
`.occt-testing`. Taken that way they need no `allowUnfree`.

## Run it

Start it with `occt`, or from the OCCT entry in the desktop menu. To run it
without installing, Stable first and Testing second:

```bash
nix run 'github:Daaboulex/OCCT-nix'
nix run 'github:Daaboulex/OCCT-nix#occt-testing'
```

OCCT keeps all its application data in `$XDG_DATA_HOME/occt/`, which is
`~/.local/share/occt/` by default.

OCCT has no network access. The wrapper starts it in its own network namespace
with only the loopback interface.

## Sensors

OCCT's sensors need three kernel facilities that the host has to provide.

```nix
{
  hardware.cpu.x86.msr.enable = true;
  hardware.i2c.enable = true;
  boot.kernelModules = [ "jc42" ];
}
```

The first loads `msr`, where CPU frequency and voltage come from. The second
loads `i2c-dev` and grants the `i2c` group the bus. The third is for DIMM
temperatures, which members of the `i2c` group can read. Reading MSRs still
needs CAP_SYS_RAWIO, and System Tuning needs root.

## GPU tests

OCCT uses OpenCL for its GPU stability tests. The VRAM test uses Vulkan and
works without OpenCL. The package brings the OpenCL loader, but the driver for
your GPU must be registered in the system configuration.

On AMD and Intel the driver is RustiCL, Mesa's OpenCL implementation. It does
not switch on its gallium drivers by itself yet, so name yours:

```nix
{
  hardware.graphics.extraPackages = [ pkgs.mesa.opencl ];
  environment.sessionVariables.RUSTICL_ENABLE = "radeonsi";
}
```

Use `radeonsi` for AMD, `iris` for Intel, or `radeonsi,iris` for both. It is a
session variable, so log out and back in after the rebuild.

NVIDIA provides its own proprietary OpenCL implementation. It is typically
registered automatically when you use the NVIDIA driver module.

## Known limits

- System Tuning only supports Intel Granite Rapids CPUs. AMD Zen 5 (Granite
  Ridge) shows "NO SUPPORTED HARDWARE". This is upstream, not the packaging.
- On very new hardware a GPU can show as a raw PCI ID such as "0x1002", when
  `hwdata` cannot resolve the device name.

## When something does not work

- The wrapper exits with "no /lib64 dynamic loader" when
  `/lib64/ld-linux-x86-64.so.2` is missing. Enable nix-ld, as under Install.
- "The ZFS modules cannot be auto-loaded" is harmless if you do not use ZFS.
  OCCT checks for ZFS storage pools as part of hardware discovery.
- "radv is not a conformant Vulkan implementation" is a standard Mesa warning
  for non-certified drivers. It does not affect functionality.
- `nix-shell -p clinfo --run "clinfo --list"` lists the registered OpenCL
  drivers. Run it after the rebuild and a new login.

## More

- [docs/DESIGN.md](docs/DESIGN.md): the OpenSSL and ICU shims, what the
  wrapper sets up, the libraries and tools it brings along
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): building, the checks, how the
  updater follows upstream
- [SECURITY.md](SECURITY.md): how to report a vulnerability

## License

The Nix packaging and the compat shim in this repository are [MIT](LICENSE) licensed.

The OCCT software is proprietary and unfree. This repository does not
distribute the OCCT binary. It only provides the fetch and wrap pipeline. Your
use of OCCT is subject to the [EULA and license terms](https://www.ocbase.com/)
of OCCT-Base.

The flake's own outputs (`nix run`, `nix build`, `inputs.occt-nix.packages`)
need no setting, because the flake allows unfree for them. `pkgs.occt` and
`pkgs.occt-testing` from the overlay require
`nixpkgs.config.allowUnfree = true` in your Nix configuration.
