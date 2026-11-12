# Development

Building the package, the checks, and how the pinned OCCT version is updated.

## Upstream

| | |
|---|---|
| Project | [OCCT](https://www.ocbase.com) |
| License | Proprietary |
| Tracked | Custom update script |

The flake follows the `nixos-unstable` branch of nixpkgs. CI runs from
[ci.yml](../.github/workflows/ci.yml).

## Commands

| Command | What it does |
|---|---|
| `nix develop` | Dev shell with pre-commit hooks |
| `nix flake check` | Evaluates the flake and runs the checks, which build both packages |
| `nix build` | Builds Stable |
| `nix build .#occt-testing` | Builds Testing |
| `nix run` | Runs Stable |
| `nix run .#occt-testing` | Runs Testing |

The pre-commit hooks come from the
[Nix Packaging Standard](https://github.com/Daaboulex/nix-packaging-standard).

To inspect the libraries the binary asks for, and the generated wrapper:

```bash
readelf -d result/opt/occt/occt-bin | grep NEEDED
cat result/bin/occt
```

## Checks

The checks in [flake.nix](../flake.nix) include that each installed binary is
byte-identical to the upstream download. `binary-pristine` covers Stable and
`binary-pristine-testing` covers Testing.

## Updates

[update.yml](../.github/workflows/update.yml) runs daily at 06:00 UTC and on
manual dispatch, tracking both the Stable and the Testing channel. With the
repository variable `UPDATE_CADENCE` set to `weekly`, only the Sunday run goes
ahead.

OCCT is a proprietary binary with no public API, so
[scripts/update.sh](../scripts/update.sh) is a `custom`-type updater. It works
in this order:

1. It reads the Stable and Testing version and SHA-256 checksum from the JSON
   embedded in the `ocbase.com` download page.
2. It downloads each binary whose pin differs, requiring HTTP 200 and at
   least 100 MB.
3. It compares the SHA-256 of the download with the published checksum.
4. It rewrites the matching `sources` block in
   [package.nix](../package.nix). Nothing is written until every channel that
   needs an update has passed step 3.
5. It runs `nix flake check` and builds both packages.

On success the workflow commits to `main`. On failure it opens an
`update-failed` issue.

When upstream has no separate Testing release, its Testing download serves the
Stable binary. The updater then pins Testing to the same version and hash as
Stable.

To trigger the updater by hand:

```bash
gh workflow run update.yml
```
