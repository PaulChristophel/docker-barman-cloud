# CloudNativePG barman-cloud plugin sidecar on openSUSE Tumbleweed.
#
# The sidecar is two things:
#   * /manager  - the plugin's Go binary, run as `instance` (gRPC server the
#                 CNPG instance manager talks to) or `restore` (recovery init
#                 container). It execs the barman-cloud-* CLIs from PATH.
#   * /venv     - barman and its cloud SDKs, every package compiled from sdist
#                 with Tumbleweed's toolchain (gcc, rust) against pcm0/python.
#
# The operator image (ghcr.io/cloudnative-pg/plugin-barman-cloud) is NOT built
# here. This sidecar must come from the same plugin release as that operator.

ARG BASE=docker.io/opensuse/tumbleweed:latest@sha256:a408f50f376d8591cfe376b82fcb9ab1af2e905a8b9cab9b27e5003b7a6c9dee
ARG PYTHON_IMAGE=docker.io/pcm0/python:3.15.2-tumbleweed@sha256:9bd30360afad52d03ad9bda03b8c411d613b13bb794d63a87c1cdd976b324869
ARG IMAGE_TITLE="CloudNativePG barman-cloud plugin sidecar on Tumbleweed"
ARG IMAGE_DESCRIPTION="barman-cloud plugin sidecar built from upstream source on openSUSE Tumbleweed for CloudNativePG."
ARG IMAGE_AUTHORS="Paul Christophel <pmartin@gatech.edu>"
ARG IMAGE_VENDOR="Paul Christophel"
ARG IMAGE_OWNER="Paul Christophel <pmartin@gatech.edu>"
ARG IMAGE_SOURCE="https://github.com/PaulChristophel/docker-barman-cloud"
ARG IMAGE_REPOSITORY="docker.io/pcm0/plugin-barman-cloud-sidecar"
ARG IMAGE_URL="https://hub.docker.com/r/pcm0/plugin-barman-cloud-sidecar"
ARG IMAGE_DOCUMENTATION="https://github.com/PaulChristophel/docker-barman-cloud#readme"
ARG IMAGE_REVISION="unknown"
ARG IMAGE_CREATED="1970-01-01T00:00:00Z"
ARG IMAGE_LICENSES="AGPL-3.0-or-later"


FROM --platform=${BUILDPLATFORM} ${BASE} AS source
# Supply these from images.json; deliberately no independent defaults.
ARG PLUGIN_COMMIT
ARG PLUGIN_SOURCE_SHA256
RUN test -n "${PLUGIN_COMMIT}" && test -n "${PLUGIN_SOURCE_SHA256}" \
 && zypper --non-interactive --gpg-auto-import-keys install --no-recommends \
      ca-certificates wget tar gzip \
 && wget -O /tmp/plugin.tar.gz \
      "https://github.com/cloudnative-pg/plugin-barman-cloud/archive/${PLUGIN_COMMIT}.tar.gz" \
 && echo "${PLUGIN_SOURCE_SHA256}  /tmp/plugin.tar.gz" | sha256sum -c - \
 && mkdir -p /src \
 && tar -xzf /tmp/plugin.tar.gz -C /src --strip-components=1


# Cross-compiles on the build host: the binary is static (CGO_ENABLED=0), so
# there is no reason to run the Go toolchain under emulation.
FROM --platform=${BUILDPLATFORM} ${BASE} AS go-builder
ARG GO_PACKAGE=go1.26
ARG TARGETOS
ARG TARGETARCH
RUN zypper --non-interactive --gpg-auto-import-keys install --no-recommends \
      "${GO_PACKAGE}" git-core ca-certificates shadow \
 && groupadd -r go-build \
 && useradd -r -g go-build -d /tmp/go-build go-build \
 && mkdir -p /tmp/go-build /out \
 && chown go-build:go-build /tmp/go-build /out
COPY --from=source --chown=go-build:go-build /src /tmp/go-build/src
USER go-build
WORKDIR /tmp/go-build/src
# GOTOOLCHAIN=local: build with Tumbleweed's Go, never a downloaded toolchain.
ENV GOTOOLCHAIN=local \
    GOPATH=/tmp/go-build/go \
    GOCACHE=/tmp/go-build/cache \
    CGO_ENABLED=0
RUN go version \
 && go mod download \
 && GOOS="${TARGETOS:-linux}" GOARCH="${TARGETARCH}" \
    go build -trimpath -buildvcs=false -ldflags='-s -w' \
      -o /out/manager ./cmd/manager


# Explicit TARGETPLATFORM: buildah otherwise carries BUILDPLATFORM over from
# the cross-compiling stages above.
FROM --platform=${TARGETPLATFORM} ${PYTHON_IMAGE} AS python-builder
ARG PYTHON_CFLAGS="-O2 -pipe -fstack-protector-strong -D_FORTIFY_SOURCE=3"
ARG PYTHON_LDFLAGS="-Wl,-z,relro,-z,now -Wl,--as-needed"
USER root
RUN zypper --non-interactive --gpg-auto-import-keys install --no-recommends \
      gcc gcc-c++ make cmake pkg-config binutils \
      coreutils findutils grep sed \
      rust cargo \
      postgresql-devel postgresql-server-devel libopenssl-devel libffi-devel \
      libcrc32c-devel \
      shadow \
 && gcc --version | head -n1 \
 && rustc --version \
 && /usr/sbin/groupadd -r py-build \
 && /usr/sbin/useradd -r -g py-build -d /tmp/py-build py-build \
 && mkdir -p /tmp/py-build /venv \
 && chown py-build:py-build /tmp/py-build /venv
COPY --from=source --chown=py-build:py-build \
      /src/containers/sidecar-requirements.txt /tmp/py-build/requirements.txt
# pcm0/python ships libpython and lib-dynload unstripped; strip the copy that
# runtime-builder takes from this stage.
RUN find /usr/local/lib -name '*.so*' -type f -exec strip --strip-unneeded {} + \
 && /usr/local/bin/python3 -c 'import ssl, sqlite3, ctypes, zlib'
USER py-build
WORKDIR /tmp/py-build
# Every package in the hash-locked requirements is built from its sdist.
# Build backends (setuptools, maturin, ...) may come from wheels: they run
# only inside pip's isolated build environments and never reach the image.
# The venv gets no pip, so pip's vendored libraries never ship.
# pg_config comes from postgresqlNN-server-devel and may sit behind
# update-alternatives; find it wherever it landed.
RUN no_binary="$(sed -nE 's/^([A-Za-z0-9._-]+)==.*/\1/p' requirements.txt | paste -sd, -)" \
 && test -n "${no_binary}" \
 && pg_bin="$(dirname "$(ls /usr/bin/pg_config /usr/lib/postgresql*/bin/pg_config 2>/dev/null | sort -V | tail -n1)")" \
 && export PATH="${pg_bin}:${PATH}" \
 && pg_config --version \
 && python3 -m venv --without-pip /venv \
 && CFLAGS="${PYTHON_CFLAGS}" CXXFLAGS="${PYTHON_CFLAGS}" LDFLAGS="${PYTHON_LDFLAGS}" \
    CARGO_HOME=/tmp/py-build/cargo \
    CRC32C_INSTALL_PREFIX=/usr \
    python3 -m pip --python /venv/bin/python install \
      --no-cache-dir \
      --require-hashes \
      --no-binary "${no_binary}" \
      -r requirements.txt \
 && find /venv -name '*.so' -exec strip --strip-unneeded {} + \
 && python3 -c 'import gzip, pathlib, shutil, sys; root = pathlib.Path(sys.argv[1]); files = list(root.rglob("*.json")); assert files, root; [(shutil.copyfileobj(p.open("rb"), gzip.open(p.with_name(p.name + ".gz"), "wb", compresslevel=9)), p.unlink()) for p in files]; print("gzipped", len(files), "botocore data files")' \
      /venv/lib/python3*/site-packages/botocore/data \
 && if grep -rlE '^Tag: .*(manylinux|musllinux)' /venv/lib/python*/site-packages/*.dist-info/WHEEL; then \
      echo "prebuilt binary wheel found in /venv" >&2; exit 1; \
    fi


FROM --platform=${TARGETPLATFORM} ${BASE} AS runtime-builder
ARG PYTHON_IMAGE
RUN mkdir -p /mnt/rootfs \
 && zypper --installroot /mnt/rootfs --non-interactive --gpg-auto-import-keys \
      install --no-recommends \
      filesystem system-user-root ca-certificates ca-certificates-mozilla \
      openSUSE-release timezone \
      libopenssl3 libffi8 libz1 libbz2-1 liblzma5 libreadline8 \
      libsqlite3-0 libgdbm6 libgdbm_compat4 libncurses6 libuuid1 libzstd1 \
      libexpat1 libmpdec4 libgcc_s1 libstdc++6 \
      libpq5 libcrc32c1 tar \
 && zypper --installroot /mnt/rootfs --non-interactive clean --all \
 && rm -rf /mnt/rootfs/var/cache/zypp /mnt/rootfs/var/log/* \
 && grep -q '^postgres:' /mnt/rootfs/etc/group \
      || echo 'postgres:x:26:' >> /mnt/rootfs/etc/group \
 && grep -q '^postgres:' /mnt/rootfs/etc/passwd \
      || echo 'postgres:x:26:26:PostgreSQL:/var/lib/postgresql:/usr/sbin/nologin' >> /mnt/rootfs/etc/passwd
# CPython from pcm0/python, minus pip, ensurepip, the test suite and GUI bits.
COPY --from=python-builder /usr/local/ /mnt/rootfs/usr/local/
RUN cd /mnt/rootfs/usr/local \
 && rm -rf bin/pip* bin/idle* bin/pydoc* \
      lib/python3*/site-packages/pip lib/python3*/site-packages/pip-*.dist-info \
      lib/python3*/ensurepip lib/python3*/test lib/python3*/idlelib \
      lib/python3*/tkinter lib/python3*/turtledemo lib/python3*/turtle.py


FROM scratch
ARG BASE
ARG PYTHON_IMAGE
ARG PLUGIN_VERSION
ARG PLUGIN_COMMIT
ARG PYTHON_VERSION
ARG IMAGE_TITLE
ARG IMAGE_DESCRIPTION
ARG IMAGE_AUTHORS
ARG IMAGE_VENDOR
ARG IMAGE_OWNER
ARG IMAGE_SOURCE
ARG IMAGE_REPOSITORY
ARG IMAGE_URL
ARG IMAGE_DOCUMENTATION
ARG IMAGE_REVISION
ARG IMAGE_CREATED
ARG IMAGE_LICENSES
ARG IMAGE_DISTRIBUTION=tumbleweed
ARG IMAGE_DISTRIBUTION_VERSION=unknown

LABEL org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.base.name="${BASE}" \
      org.opencontainers.image.authors="${IMAGE_AUTHORS}" \
      org.opencontainers.image.title="${IMAGE_TITLE}" \
      org.opencontainers.image.description="${IMAGE_DESCRIPTION}" \
      org.opencontainers.image.vendor="${IMAGE_VENDOR}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.url="${IMAGE_URL}" \
      org.opencontainers.image.documentation="${IMAGE_DOCUMENTATION}" \
      org.opencontainers.image.version="${PLUGIN_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.licenses="${IMAGE_LICENSES}" \
      org.opencontainers.image.ref.name="${IMAGE_REPOSITORY}" \
      org.opencontainers.image.component.plugin-barman-cloud.version="${PLUGIN_VERSION}" \
      org.opencontainers.image.component.plugin-barman-cloud.revision="${PLUGIN_COMMIT}" \
      org.opencontainers.image.component.python.version="${PYTHON_VERSION}" \
      org.opencontainers.image.component.python.image="${PYTHON_IMAGE}" \
      edu.gatech.image.owner="${IMAGE_OWNER}" \
      edu.gatech.image.repository="${IMAGE_REPOSITORY}" \
      edu.gatech.image.os.distribution="${IMAGE_DISTRIBUTION}" \
      edu.gatech.image.os.version="${IMAGE_DISTRIBUTION_VERSION}"

COPY --from=runtime-builder /mnt/rootfs/ /
COPY --from=python-builder /venv /venv
COPY --from=go-builder /out/manager /manager

ENV PATH=/venv/bin:/usr/local/bin:/usr/bin:/bin \
    LANG=C.UTF-8

# No shell in this image: every check below uses exec form.
# Bytecode is compiled at build time because the sidecar runs with a
# read-only root filesystem.
RUN ["/venv/bin/python", "-c", "import compileall, sys, sysconfig; ok = compileall.compile_dir(sysconfig.get_path('stdlib'), quiet=1, invalidation_mode=compileall.py_compile.PycInvalidationMode.UNCHECKED_HASH); ok &= compileall.compile_dir('/venv', quiet=1, invalidation_mode=compileall.py_compile.PycInvalidationMode.UNCHECKED_HASH); sys.exit(0 if ok else 1)"]
RUN ["/venv/bin/python", "-c", "import importlib.util, sys; import barman, psycopg2, cryptography.hazmat.bindings._rust, cramjam, lz4.frame, zstandard, snappy, google_crc32c, boto3, azure.storage.blob, azure.identity, google.cloud.storage; assert psycopg2.__libpq_version__ >= 180000, psycopg2.__libpq_version__; assert importlib.util.find_spec('pip') is None; assert google_crc32c.implementation == 'c', google_crc32c.implementation; import botocore.session; assert botocore.session.get_session().get_service_model('s3').service_name == 's3';assert zstandard.decompress(zstandard.compress(b'x')) == b'x'; assert lz4.frame.decompress(lz4.frame.compress(b'x')) == b'x'; assert snappy.decompress(snappy.compress(b'x')) == b'x'; print(sys.version.split()[0], 'barman', barman.__version__, 'libpq', psycopg2.__libpq_version__)"]
RUN ["/venv/bin/barman-cloud-backup", "--version"]
RUN ["/venv/bin/barman-cloud-wal-archive", "--version"]
RUN ["/usr/bin/tar", "--version"]
RUN ["/manager", "--help"]

USER 26:26
ENTRYPOINT ["/manager"]
