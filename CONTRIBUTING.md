# Contributing

Contributions that improve the barman-cloud sidecar builds, supported distributions,
documentation, or release automation are welcome.

## Before making a change

Open an issue for changes that alter the supported plugin versions, image
variants, or release behavior. Bug fixes and focused documentation
improvements can go directly to a pull request.

Keep changes scoped to this repository's purpose: building barman-cloud sidecar images
for CloudNativePG from upstream source. The standard variants are intended to
provide the core sidecar runtime and should stay aligned with the
repository's supported image contract.

## Repository layout

- `images.json` is the source of truth for plugin releases, source
  checksums, distribution base images, build variants, and release channels.
- `tumbleweed.dockerfile` defines the build. Other distribution families can
  be added as `<distro>.dockerfile` plus a `variants` entry.
- `scripts/update_image_pins.py` refreshes base-image and Python-image digests.
- `.github/workflows/release.yml` builds and publishes the complete matrix.

When adding or updating downloaded source, pin both its immutable revision and
its SHA-256 checksum. Base images should remain digest-pinned.

## Local validation

Build the affected variant with Podman. The source pins have no defaults, so
pass them from `images.json` (the README has the full command):

```sh
/opt/homebrew/bin/podman build \
  --platform linux/amd64 \
  -f tumbleweed.dockerfile \
  --build-arg PLUGIN_COMMIT=... --build-arg PLUGIN_SOURCE_SHA256=... \
  -t localhost/plugin-barman-cloud-sidecar:dev .
```

Every Dockerfile builds the plugin binary and the barman venv, then runs an image-level smoke
test before producing the final image. A successful complete build is
therefore the primary validation for Dockerfile or dependency changes.

Also check configuration syntax and whitespace before submitting:

```sh
/opt/homebrew/bin/python3.14 -m json.tool images.json >/dev/null
/opt/homebrew/bin/git diff --check
```

Run the pin-updater tests when changing `scripts/`:

```sh
python3 -m unittest discover -s scripts -p 'test_update_image_pins.py'
```

## Pull requests

In the pull request description:

- explain the problem and the intended behavior;
- identify the plugin versions and OS variants affected;
- list the validation commands run and their results; and
- call out anything that could not be tested locally.

Keep unrelated changes in separate pull requests. A pull request that changes
the common image contract should update every affected distribution rather
than leaving variants with different sidecar features unintentionally.

By contributing, you agree that your contribution is licensed under the terms
of this repository's [LICENSE](LICENSE).
