# docker-barman-cloud

Source-built sidecar image for the
[CloudNativePG barman-cloud plugin](https://github.com/cloudnative-pg/plugin-barman-cloud),
published as `docker.io/pcm0/plugin-barman-cloud-sidecar`.

Only the **sidecar** is built here. The plugin operator keeps running upstream's
`ghcr.io/cloudnative-pg/plugin-barman-cloud` image and is pointed at this
sidecar through its `SIDECAR_IMAGE` setting.

## What is in the image

| Path | What | Built from |
| --- | --- | --- |
| `/manager` | Plugin Go binary (`instance` sidecar, `restore` init container) | Upstream source at the pinned commit, Tumbleweed's Go, `CGO_ENABLED=0`, cross-compiled |
| `/venv` | barman + cloud SDKs (`barman-cloud-*` CLIs) | Every package in upstream's hash-locked `containers/sidecar-requirements.txt`, compiled from sdist with Tumbleweed's gcc and rust |
| `/usr/local` | CPython | `pcm0/python:<version>-tumbleweed`, with pip, ensurepip, the test suite and tkinter/idle removed |
| `/` | Runtime libraries (`libpq5`, OpenSSL, `tar`, ...) | `zypper --installroot` into an empty rootfs |

Two post-install steps keep the size at or below upstream's (271 MB vs 276 MB
for 0.16.0):

- botocore's sdist ships its service models as raw JSON (~120 MB). They are
  gzipped after install, matching what botocore's own wheels ship.
- `libpython` and `lib-dynload` from `pcm0/python` are stripped.

Building from source also drops the static libraries the manylinux wheels
bundle: zstandard, lz4 and cryptography link against Tumbleweed's libzstd,
liblz4 and OpenSSL. `google-crc32c` links `libcrc32c`, so it uses its C
implementation rather than the slow pure-Python fallback.

There is no package manager or pip in the final image, and the plugin never
uses a shell. A `bash` still arrives as a dependency of Tumbleweed's
`ca-certificates`/`p11-kit`. It runs as
UID/GID `26:26` (`postgres`), the same as `pcm0/postgresql`, so it can share
PGDATA and the WAL directory with the Postgres container.

The build fails if:

- the source tarball's SHA-256 doesn't match `images.json`
- any requirement hash doesn't match upstream's lock file
- a prebuilt `manylinux`/`musllinux` wheel ends up in `/venv`
- `psycopg2` is linked against libpq older than 18
- `google-crc32c` falls back to pure Python, or botocore can't load its gzipped S3 model
- the import, compression round-trip or `--version` checks fail

## Version coupling

The sidecar and the operator speak a gRPC protocol tied to the plugin release.
**Always run a sidecar built from the same plugin version as the operator.**
When you bump the operator image, bump `plugin[].version/commit/sha256` here
first and wait for the image to publish.

## Tags

| Tag | Meaning |
| --- | --- |
| `0.16.0-python3.15-tumbleweed` | Exact plugin version, Python series and OS |
| `0.16-python3.15-tumbleweed` | Latest build of the plugin series |
| `0.16.0-tumbleweed`, `0.16-tumbleweed` | Same, for the default Python entry |
| `0.16.0`, `0.16`, `latest` | Default Python on the `latest` variant |

## Updating

- **Base images:** `update-images.yml` runs daily, refreshes the Tumbleweed and
  `pcm0/python` digests, and auto-merges a PR.
- **Plugin release:** edit `images.json`:

  ```bash
  commit=$(git ls-remote https://github.com/cloudnative-pg/plugin-barman-cloud refs/tags/vX.Y.Z | cut -f1)
  curl -sL "https://github.com/cloudnative-pg/plugin-barman-cloud/archive/${commit}.tar.gz" | sha256sum
  ```

  Also check `go.mod` in that release and bump `go_package` if it needs a newer
  Go series than Tumbleweed's `go1.NN` package provides.

## Building locally

```bash
podman build --platform linux/amd64 -f tumbleweed.dockerfile \
  --build-arg PLUGIN_VERSION=0.16.0 \
  --build-arg PLUGIN_COMMIT=cd3b9faeb18466bc1195688589dc20db2b247f15 \
  --build-arg PLUGIN_SOURCE_SHA256=d568f77606c408bc1b5836a23e12218adb5e38ccd6f0c4994c155bae98aad4e4 \
  --build-arg PYTHON_VERSION=3.15.2 \
  -t localhost/plugin-barman-cloud-sidecar:dev .
```

`pcm0/python` is published for `linux/amd64` only, so on Apple Silicon the
Python stage runs under qemu emulation. A clean build takes well over an hour
there. Enabling Rosetta for the podman machine (`[machine] rosetta = true` in
`containers.conf`) helps a lot, and CI's native amd64 runners are much faster.

## Using it with CNPG

Set the operator Deployment's `SIDECAR_IMAGE` to a digest-pinned reference:

```yaml
- name: SIDECAR_IMAGE
  value: docker.io/pcm0/plugin-barman-cloud-sidecar:0.16.0-python3.15-tumbleweed@sha256:...
```

## License

The build files in this repository are AGPL-3.0-or-later. The software inside
the image keeps its own licenses (the plugin is Apache-2.0, barman is GPL-3.0).
