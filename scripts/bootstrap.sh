#!/usr/bin/env bash
# Fetches the Azahar emulator source at a pinned tag, applies the iOS patches and links the
# AzaharCore frontend layer into the tree. Safe to run repeatedly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AZAHAR_TAG="${AZAHAR_TAG:-2126.2}"
SRC="${AZAHAR_SRC:-$ROOT/external/azahar}"

echo "==> Azahar $AZAHAR_TAG → $SRC"
if [ ! -d "$SRC/.git" ]; then
  mkdir -p "$(dirname "$SRC")"
  git clone --branch "$AZAHAR_TAG" --depth 1 https://github.com/azahar-emu/azahar "$SRC"
fi
echo "==> Submodules (this downloads ~1.5 GB the first time)"
git -C "$SRC" submodule update --init --recursive --depth 1 -j 8

# Applied patches are recorded in a stamp file per tree, because once later patches touch the
# same lines an earlier one can no longer be reverse-checked on its own.
apply_patch() {
  local dir="$1" patch="$2" stamp="$1/.holofold-patches"
  local id="$(basename "$patch") $(git hash-object "$patch")"
  if [ -f "$stamp" ] && grep -qxF "$id" "$stamp"; then
    echo "    present   $(basename "$patch")"
  elif git -C "$dir" apply --check "$patch" 2>/dev/null; then
    git -C "$dir" apply "$patch"
    echo "$id" >> "$stamp"
    echo "    applied   $(basename "$patch")"
  elif git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
    echo "$id" >> "$stamp"
    echo "    present   $(basename "$patch")"
  else
    echo "error: $(basename "$patch") does not apply to $dir (different Azahar version?)." >&2
    echo "       If this tree already has it, add the line '$id' to $stamp." >&2
    exit 1
  fi
}

echo "==> Patches"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0001-ios-frontend-support.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0002-visionos.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0003-visionos-offscreen-presentation.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0004-vulkan-moltenvk-async-pipelines.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0005-interpreter-fast-page-cache.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0006-vulkan-skip-pipeline-wait-on-apple.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0007-vulkan-persist-driver-pipeline-cache.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0008-gsp-signal-missed-pdc.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0009-moltenvk-async-queue-submits.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0010-apple-renderer-stability-toggles.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0011-gsp-resignal-stalled-queue.patch"
apply_patch "$SRC"                                   "$ROOT/patches/azahar/0013-dsp-recorder-audio-tap.patch"
apply_patch "$SRC/externals/openal-soft"             "$ROOT/patches/openal-soft/0001-visionos.patch"
apply_patch "$SRC/externals/dynarmic"                "$ROOT/patches/dynarmic/0001-ios-dual-mapped-jit.patch"
# Azahar builds its own externals/oaknut (dynarmic then skips its bundled copy); patch both so
# whichever copy CMake picks has the iOS JIT changes.
apply_patch "$SRC/externals/oaknut"                  "$ROOT/patches/oaknut/0001-ios26-jit-arena.patch"
apply_patch "$SRC/externals/dynarmic/externals/oaknut" "$ROOT/patches/oaknut/0001-ios26-jit-arena.patch"

echo "==> Linking Core/ as src/azios"
ln -sfn "$ROOT/Core" "$SRC/src/azios"

echo "Done. Next: ./scripts/build-core-ios.sh"
