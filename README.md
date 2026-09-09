# hadron-firmware

Prebuilt [linux-firmware](https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git)
packaged so it can be added to a [Kairos Hadron](https://github.com/kairos-io/hadron)
image.

Hadron ships with a deliberately small firmware set to keep the base image lean.
Most hardware works out of the box, but some devices (GPUs, Wi-Fi/Bluetooth chips,
NICs, etc.) need extra firmware blobs. This repository builds the full upstream
`linux-firmware` tree, split into per-vendor/per-device pieces, and publishes them
as two kinds of artifacts so you only ship the firmware you actually need:

1. **Firmware container images** (OCI images) — one image per firmware folder,
   meant to be copied on top of your Hadron image with a small `Dockerfile`.
2. **System extensions (sysexts)** — `*.sysext.raw` files that are loaded at boot
   by `systemd-sysext` and can be added/removed on a running system, without
   rebuilding the OS image.

Both artifacts contain exactly the same firmware files; pick whichever way of
consuming them fits your workflow.

> A browsable list of every release and the images/sysexts it published is
> available at the project's GitHub Pages site:
> <https://kairos-io.github.io/hadron-firmware/>. You can also look at the
> [Releases](https://github.com/kairos-io/hadron-firmware/releases) page directly.

> **Found a bug, or want to request a feature?** Open it on
> [kairos-io/kairos](https://github.com/kairos-io/kairos/issues), including
> issues about this repository. Every Kairos issue lives in one place, so you
> never have to work out which repository to file against.

## What gets published

Each release corresponds to an upstream `linux-firmware` version (for example
`20260622`) and is tagged with that version. The `linux-firmware` tree is split
into targets, one per top-level folder (very large folders such as `intel` and
`qcom` are split further into per-subfolder pieces plus a `*-generic` remainder,
and loose files at the root are grouped into an `uncategorized` target).

For every target you get:

- An OCI image: `ghcr.io/kairos-io/hadron-firmware/linux-firmware-<target>:<version>`
  Inside the image the files live under `/usr/lib/firmware/...`, the firmware
  directory the kernel searches by default.
- A sysext file attached to the release:
  `linux-firmware-<target>_<version>.sysext.raw`

For example, the `amdgpu` firmware for release `20260622` is published as:

- Image: `ghcr.io/kairos-io/hadron-firmware/linux-firmware-amdgpu:20260622`
- Sysext: `linux-firmware-amdgpu_20260622.sysext.raw`

The sysext files published on the releases are **unsigned**. If you run Trusted
Boot you must build and sign them yourself — see
[Signed sysexts for Trusted Boot](#signed-sysexts-for-trusted-boot).

## Option 1: Add firmware to your Hadron image (OCI images)

This is the same pattern used by the Hadron
[`add-packages` examples](https://github.com/kairos-io/hadron/tree/main/examples/add-packages):
build a derived image `FROM` your Hadron base and `COPY` the firmware layer in.

Because the firmware images are `FROM scratch` images that already place files at
`/usr/lib/firmware/...`, you just copy their whole root (`/`) into your
image root (`/`):

```dockerfile
# Start from the Hadron image you already use.
FROM ghcr.io/kairos-io/hadron:main

# Copy in the firmware you need. Add as many COPY lines as you want.
COPY --from=ghcr.io/kairos-io/hadron-firmware/linux-firmware-amdgpu:20260622 / /
COPY --from=ghcr.io/kairos-io/hadron-firmware/linux-firmware-rtw88:20260622 / /
```

Build it:

```bash
docker build -t my-registry.example.com/my-hadron:latest .
```

> Important: the image produced above is **not** a bootable/upgradeable Kairos
> image yet — it is just a Hadron rootfs with extra firmware. A raw Hadron image
> cannot be used to upgrade a running Kairos node directly. You first have to
> "kairosify" it (add the Kairos framework, init system integration, etc.) with
> [`kairos-init`](https://github.com/kairos-io/kairos-init), and then either push
> the resulting image to upgrade to, or turn it into installable media (ISO, raw
> disk, etc.) with [AuroraBoot](https://github.com/kairos-io/AuroraBoot).

For example, run `kairos-init` as a build stage on top of the image above so the
final image is a proper Kairos image you can deploy or upgrade to:

```dockerfile
FROM quay.io/kairos/kairos-init:latest AS kairos-init

# Turn the Hadron image with firmware into a bootable Kairos image.
FROM my-registry.example.com/my-hadron:latest
ARG VERSION=1.0.0
RUN --mount=type=bind,from=kairos-init,src=/kairos-init,dst=/kairos-init /kairos-init --version "${VERSION}"
```

```bash
docker build -t my-registry.example.com/my-kairos:latest .
docker push my-registry.example.com/my-kairos:latest
```

Only the resulting `my-registry.example.com/my-kairos:latest` image (or the media
produced from it with AuroraBoot) can be used to install or upgrade a node. Refer
to the [Kairos factory documentation](https://kairos.io/docs/reference/kairos-factory/)
for the full set of `kairos-init` flags and AuroraBoot invocations.

Tips:

- Pin to a specific firmware version tag (for example `:20260622`) rather than a
  moving tag so your builds are reproducible.
- Only copy the targets your hardware needs; the whole tree is large and there is
  no benefit to shipping firmware you will never load.
- Not sure which target holds your firmware? Check the release listing on the
  [GitHub Pages site](https://kairos-io.github.io/hadron-firmware/) or browse the
  image list on a [release](https://github.com/kairos-io/hadron-firmware/releases).

## Option 2: Add firmware as a sysext

System extensions let you add firmware to an **already installed** system without
rebuilding the OS image. At boot `systemd-sysext` merges the extension's
`/usr/...` contents into the running system (read-only), and `kairos-agent`
manages installing/enabling them. See the Kairos
[system extensions documentation](https://kairos.io/docs/advanced/sys-extensions/)
for the full picture.

> Requirement: the base OS needs systemd 252 or newer (Hadron already satisfies
> this).

### Install and enable with kairos-agent

`kairos-agent sysext install` accepts `https:`, `http:`, `file:` and `oci:` URIs.
The simplest option is to point it at the `*.sysext.raw` file attached to a
release:

```bash
# Download and install the firmware sysext from a release asset.
kairos-agent sysext install https://github.com/kairos-io/hadron-firmware/releases/download/20260622/linux-firmware-amdgpu_20260622.sysext.raw

# Enable it for the active boot profile and load it right now.
kairos-agent sysext enable --active --now linux-firmware-amdgpu

# Confirm it is enabled.
kairos-agent sysext list --active
```

Notes:

- The `enable`/`disable`/`remove` commands accept a regex, so you can use a short
  name like `amdgpu` instead of the full filename.
- Use `--common` instead of `--active` if you want the extension loaded in every
  boot profile (active, passive and recovery).
- Drop `--now` if you only want the change to take effect on the next reboot.
- To remove it again: `kairos-agent sysext disable --active --now linux-firmware-amdgpu`
  (or `kairos-agent sysext remove --now linux-firmware-amdgpu` to delete it).

### Signed sysexts for Trusted Boot

Under **Trusted Boot** the sysext signature is verified at boot against the keys
enrolled in the EFI firmware (PK/KEK/DB). The `*.sysext.raw` files attached to the
releases here are **unsigned examples** and will be *ignored* on a Trusted Boot
system.

To use firmware sysexts under Trusted Boot you must build and sign them yourself
with the **same private key/certificate** you used to sign your EFI files, so they
verify correctly on your machines. The [`firmware.sh`](firmware.sh) script in this
repository supports this: it builds the firmware images locally and then produces
signed sysexts via [AuroraBoot](https://github.com/kairos-io/AuroraBoot).

```bash
# Build the firmware images and produce signed sysexts using your own keys.
# This requires docker and access to the docker socket.
./firmware.sh --build
./firmware.sh --sysext \
  --private-key /path/to/your/db.key \
  --certificate /path/to/your/db.pem
```

The signed `*.sysext.raw` files are written to the `build/` directory. Install
them on your nodes the same way as above (for example with a local path):

```bash
kairos-agent sysext install file:///path/to/linux-firmware-amdgpu_20260622.sysext.raw
kairos-agent sysext enable --active --now linux-firmware-amdgpu
```

> The keys under `.github/keys/` in this repository are **test keys only** and are
> considered compromised. Never use them in production — always sign with your own
> Trusted Boot keys.

## Overriding a single blob on a running node

`/usr/lib/firmware` is part of the read-only OS image, so it is not the place to
patch a single blob on a node that is already installed. The Hadron base image
symlinks `/usr/lib/firmware/updates` to `/usr/local/lib/firmware`, which lives on
the persistent partition, and the kernel searches `/lib/firmware/updates` before
`/lib/firmware`. Dropping a file there overrides the one shipped in the image,
and removing it restores the shipped one:

```bash
mkdir -p /usr/local/lib/firmware/amdgpu
cp my-fixed-blob.bin /usr/local/lib/firmware/amdgpu/
```

Nothing has to be set on the kernel cmdline. Note that this directory is *not*
where the firmware images and sysexts install to; it is reserved for local
overrides, so a folder named `updates` never appears in a published target.

**Match or beat the compression of the blob you are replacing.** The kernel
retries the whole search path per suffix rather than per directory: it tries
every directory uncompressed, then every directory with `.zst`, then every
directory with `.xz` (`_request_firmware` in
`drivers/base/firmware_loader/main.c`). The images here are built with upstream
`copy-firmware.sh --zstd`, so the shipped blobs are `.zst`. An uncompressed
override, as above, wins. A `.zst` override wins. An `.xz` override loses to the
shipped `.zst` and does so silently, because the `.zst` stage runs first and
never reaches `.xz`.

## Building it yourself

Everything is driven by the [`firmware.sh`](firmware.sh) script, which discovers
the firmware layout from the built `linux-firmware` tree and generates the
Dockerfiles automatically. It needs `docker` (with `buildx`).

```bash
# Show all options.
./firmware.sh --help

# Only generate the Dockerfile.firmware (no build), to inspect the targets.
./firmware.sh --dockerfile-only

# Build every firmware image locally.
./firmware.sh --build

# Build a single target.
./firmware.sh --build --target amdgpu

# Build for a specific linux-firmware version and push to a registry.
./firmware.sh --build --push \
  --repository ghcr.io/kairos-io/hadron-firmware \
  --firmware-version 20260622

# Turn the built images into (optionally signed) sysexts.
./firmware.sh --sysext [--private-key KEY --certificate CERT]
```

Common flags:

| Flag | Description |
|------|-------------|
| `--dockerfile-only` | Generate `Dockerfile.firmware` only, without building. |
| `--build` | Build the firmware images. |
| `--sysext` | Create sysexts from the built firmware images. |
| `--push` | Push built images to the repository (requires `--build`). |
| `--target <name>` | Build only the named target. |
| `--firmware-version <ver>` | linux-firmware version to build. |
| `--repository <repo>` | Destination image repository (default `ttl.sh`). |
| `--private-key <path>` | Private key used to sign sysexts (Trusted Boot). |
| `--certificate <path>` | Certificate used to sign sysexts (Trusted Boot). |

Releases (images, unsigned sysexts and the release listing on GitHub Pages) are
produced automatically by the CI workflows in
[`.github/workflows`](.github/workflows) when a version tag is pushed.
