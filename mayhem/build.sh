#!/usr/bin/env bash
#
# spdm-rs/mayhem/build.sh — build ccc-spdm-tools/spdm-rs' cargo-fuzz targets as sanitized
# libFuzzer binaries, replicating OSS-Fuzz's Rust path
# (oss-fuzz/projects/spdm-rs/build.sh, which runs `bash sh_script/pre-build.sh` then, from
# `spdmlib/`, `cargo fuzz build --release`, shipping every produced fuzz binary).
#
# spdm-rs is a Rust SPDM (Security Protocol and Data Model) implementation. The fuzz targets each
# feed an attacker-controlled byte buffer into the responder/requester message handler for one
# SPDM request/response code (version_rsp, capability_rsp, certificate_rsp, key_exchange_req, …).
#
# Layout notes that drive this script:
#   - The cargo-fuzz crate lives at `spdmlib/fuzz/` and declares its OWN workspace
#     (`[workspace] members = ["."]`), so it does NOT inherit the top-level workspace. OSS-Fuzz
#     therefore runs `cargo fuzz build` from inside `spdmlib/` and pins the target dir with
#     CARGO_TARGET_DIR=$SRC/spdm-rs/target. We do the same.
#   - `sh_script/pre-build.sh` patches the bundled `ring` submodule (git apply) and initializes
#     aws-lc-rs. It MUST run before the fuzz build (ring is patched in place).
#   - The repo's `rust-toolchain` file pins stable 1.93.0, which rejects the `-Z` flags cargo-fuzz
#     needs; the Dockerfile exports RUSTUP_TOOLCHAIN=nightly-... to force rustup to ignore it
#     (exactly as OSS-Fuzz's base-builder-rust does).
#
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even
# though the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

TRIPLE="x86_64-unknown-linux-gnu"

# OSS-Fuzz pins the fuzz target output under the repo-root target dir.
export CARGO_TARGET_DIR="$SRC/target"

# Apply the upstream pre-build patches (ring) + aws-lc-rs setup, exactly like OSS-Fuzz.
echo "=== sh_script/pre-build.sh (ring patches + aws-lc-rs setup) ==="
bash sh_script/pre-build.sh

# Compile the ASan options override and bake it into every fuzz binary.
# __asan_default_options is a weak symbol in ASan's runtime; a strong C definition here
# disables LSan (detect_leaks=0) so the binary never tries to invoke ptrace for leak
# detection. Mayhem's container sandbox blocks ptrace → LSan fatal-abort → exit 1 → 0
# edges recorded. Compiled without ASan instrumentation to avoid init-order cycles.
echo "=== compiling ASan options override (mayhem/asan_options.c) ==="
clang -fno-sanitize=all -c "$SRC/mayhem/asan_options.c" -o "$SRC/mayhem/asan_options.o"
ASAN_OPTS_OBJ="$SRC/mayhem/asan_options.o"

# RUST_DEBUG_FLAGS: DWARF < 4 compliance (§6.2 item 10).
# cargo-fuzz links the precompiled ASan runtime (DWARF5, compiled by Rust's bundled clang) first;
# -Zdwarf-version=3 alone cannot downgrade the already-compiled runtime CUs. Fix: use a
# cc-wrapper linker that prepends anchor.o (a cosmetic empty DWARF3 CU) as the FIRST object so
# the first .debug_info CU in every fuzz binary reads DWARF3 (satisfying verify-repo's -m1 check).
RUST_DEBUG_FLAGS="-Clinker=/opt/toolchains/anchor-dwarf3/cc-wrapper.sh -Cdebuginfo=2 -Zdwarf-version=3"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces.
# The asan_options.o link-arg bakes __asan_default_options into every fuzz binary (see above).
# RUST_DEBUG_FLAGS wires in the DWARF3 anchor linker (spec-v2 §6.2 item 10).
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS} --cfg fuzzing -Zsanitizer=address -Cforce-frame-pointers -C link-arg=${ASAN_OPTS_OBJ}"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "CARGO_TARGET_DIR=$CARGO_TARGET_DIR"

# The fuzz crate lives in spdmlib/fuzz (cargo-fuzz convention); cargo-fuzz is invoked from the
# containing package directory (spdmlib), matching OSS-Fuzz. A single `cargo fuzz build` (no target
# name) builds every [[bin]] in spdmlib/fuzz/Cargo.toml. `--release` matches OSS-Fuzz.
pushd spdmlib >/dev/null
cargo fuzz build --release
popd >/dev/null

# Enumerate every fuzz target from spdmlib/fuzz/fuzz_targets/*.rs (== the [[bin]] names).
mapfile -t FUZZ_TARGETS < <(for f in spdmlib/fuzz/fuzz_targets/*.rs; do basename "${f%.rs}"; done | sort)
echo "fuzz targets (${#FUZZ_TARGETS[@]}): ${FUZZ_TARGETS[*]}"

# cargo-fuzz emits binaries under CARGO_TARGET_DIR/<triple>/release. Resolve the dir robustly from
# cargo metadata (run inside the fuzz workspace) and fall back to the conventional path.
TARGET_DIR="$(cd spdmlib/fuzz && cargo metadata --no-deps --format-version 1 2>/dev/null \
  | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
[ -n "$TARGET_DIR" ] || TARGET_DIR="$CARGO_TARGET_DIR"
RELEASE_DIR="$TARGET_DIR/$TRIPLE/release"
echo "RELEASE_DIR=$RELEASE_DIR"

n=0
for t in "${FUZZ_TARGETS[@]}"; do
  bin="$RELEASE_DIR/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    echo "--- contents of $RELEASE_DIR ---" >&2
    ls -la "$RELEASE_DIR" 2>&1 >&2 || true
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  n=$((n+1))
done
echo "build.sh complete: copied $n fuzz binaries to /mayhem/"
ls -la /mayhem/ | grep -vE 'mayhem$|\.git|total' | head -50 || true
