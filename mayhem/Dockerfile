# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base). The base provides debian + clang/llvm + libFuzzer + the
# identities + the build-contract ENV. spdm-rs is a RUST workspace (an SPDM security-protocol
# implementation; the fuzz targets parse SPDM request/response messages), and the base ships NO
# Rust toolchain, so this image installs rustup (nightly) + cargo-fuzz as root into a SHARED
# location (/opt/rust) usable by the non-root `mayhem` user, then runs build.sh + test.sh.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t spdm-rs-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty value
# breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default,
# but cargo-fuzz drives Rust instrumentation via RUSTFLAGS (-Zsanitizer=address), NOT $SANITIZER_FLAGS.
# Declared here for parity; build.sh wires ASan into RUSTFLAGS the cargo-fuzz way.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the nightly toolchain (cargo-fuzz needs nightly for `-Z` flags / -Zsanitizer=address).
# Mirrors OSS-Fuzz's base-builder-rust, which pins this exact dated nightly for spdm-rs.
ARG RUST_TOOLCHAIN=nightly-2025-09-05
ARG CARGO_FUZZ_VERSION=0.12.0

# Shared Rust install: CARGO_HOME/RUSTUP_HOME under /opt/toolchains/rust (§6.2 item 8 — must
# be under /opt/toolchains, not $HOME, so the path survives PATCH re-runs). World-readable so
# the non-root `mayhem` user can invoke cargo/rustc/cargo-fuzz without owning the toolchain.
#
# RUSTUP_TOOLCHAIN forces rustup to IGNORE the repo's `rust-toolchain` file (which pins stable
# 1.93.0 — stable rejects the `-Z` flags cargo-fuzz needs). This is exactly what OSS-Fuzz's
# base-builder-rust does (`ENV RUSTUP_TOOLCHAIN nightly-2025-09-05`).
ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:$PATH \
    RUSTUP_TOOLCHAIN=nightly-2025-09-05

USER root
# spdm-rs's pre-build patches the bundled `ring` (git apply) and sets up aws-lc-rs; it needs git
# + a C toolchain (base provides clang). No extra apt deps are required for the ring-backed fuzz
# build, but cmake/perl are pulled by some crypto build scripts — install defensively.
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      cmake perl pkg-config; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"; \
    rustup component add rust-src --toolchain "$RUST_TOOLCHAIN"; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    # The non-root `mayhem` user runs `cargo fuzz build`, which WRITES into CARGO_HOME (registry
    # cache, git checkouts). Toolchain dirs stay read-only; the cargo home must be group/other
    # writable so the build can populate the registry. (Build image, not a hardened runtime.)
    chmod -R a+rX /opt/toolchains/rust; \
    mkdir -p "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    rustc --version; cargo --version; cargo fuzz --version

# DWARF < 4 anchor trick for Rust/cargo-fuzz (§6.2 item 10):
# cargo-fuzz links the precompiled ASan runtime (DWARF5) first; -Zdwarf-version=3 only
# affects rustc's own output. Fix: compile a cosmetic empty C stub as DWARF3, and use a
# cc-wrapper that prepends anchor.o to every linker invocation so the FIRST .debug_info CU
# in each fuzz binary is DWARF3 — satisfying verify-repo's `readelf --debug-dump=info -m1` check.
RUN set -eux; \
    mkdir -p /opt/toolchains/anchor-dwarf3; \
    printf '/* cosmetic DWARF3 anchor: first CU in every fuzz binary */\nvoid __mayhem_dwarf3_anchor(void) {}\n' \
        > /opt/toolchains/anchor-dwarf3/anchor.c; \
    clang -g -gdwarf-3 -fno-sanitize=all -c /opt/toolchains/anchor-dwarf3/anchor.c \
        -o /opt/toolchains/anchor-dwarf3/anchor.o; \
    printf '#!/bin/sh\nexec cc /opt/toolchains/anchor-dwarf3/anchor.o "$@"\n' \
        > /opt/toolchains/anchor-dwarf3/cc-wrapper.sh; \
    chmod +x /opt/toolchains/anchor-dwarf3/cc-wrapper.sh; \
    chmod -R a+rX /opt/toolchains/anchor-dwarf3

USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history +
# submodules) is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run spdm-rs's own unit tests (a self-contained subset) at build time; a failing suite fails the
# image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
