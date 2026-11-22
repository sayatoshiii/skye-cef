#!/usr/bin/env bash
set -euxo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)

platform=${CEF_PLATFORM:?CEF_PLATFORM is required (linux)}
cef_branch=${CEF_BRANCH:?CEF_BRANCH is required}
cef_checkout=${CEF_CHECKOUT:?CEF_CHECKOUT is required}
compile_minutes=${COMPILE_MINUTES:-285}
checkpoint_in=${CHECKPOINT_IN:-}
checkpoint_out=${CHECKPOINT_OUT:?CHECKPOINT_OUT is required}
dist_out=${DIST_OUT:?DIST_OUT is required}

export CEF_ARCHIVE_FORMAT=tar.bz2
ninja_extra_args=()

case "$platform" in
  linux)
    build_dir=/cef-build
    arch_flag=--x64-build
    out_subdir=Release_GN_x64
    dist_glob="cef_binary_*_linux64_minimal.tar.bz2"
    ninja_targets=(cefsimple chrome_sandbox)
    tar_cmd=tar
    export DEBIAN_FRONTEND=noninteractive
    export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome use_thin_lto=false is_cfi=false chrome_pgo_phase=false symbol_level=0 blink_symbol_level=0"

    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      file \
      git \
      lsb-release \
      patch \
      pkg-config \
      python-is-python3 \
      python3 \
      unzip \
      wget \
      xz-utils \
      zstd

    sudo rm -rf \
      /usr/share/dotnet \
      /usr/local/lib/android \
      /usr/local/share/boost \
      /usr/local/share/chromium \
      /usr/local/share/powershell \
      /usr/share/swift \
      /opt/ghc \
      /opt/hostedtoolcache
    sudo docker image prune --all --force || true
    sudo mkdir -p "$build_dir"
    sudo chown "$USER" "$build_dir"
    df -h /
    ;;


  *)
    echo "Unsupported CEF_PLATFORM: $platform" >&2
    exit 1
    ;;
esac

curl -fsSL -o "$build_dir/automate-git.py" \
  "https://raw.githubusercontent.com/chromiumembedded/cef/${cef_checkout}/tools/automate/automate-git.py"

export PATH="$build_dir/depot_tools:${PATH}"
python3 "$build_dir/automate-git.py" \
  --download-dir="$build_dir" \
  --depot-tools-dir="$build_dir/depot_tools" \
  --branch="$cef_branch" \
  --checkout="$cef_checkout" \
  --no-chromium-history \
  --no-debug-build \
  --no-build \
  --no-distrib \
  "$arch_flag" \
  --build-target=cefsimple
df -h "$build_dir"

export DEPOT_TOOLS_UPDATE=0
hash -r

find "$build_dir/chromium/src/third_party/node" -type f -path '*/bin/node' \
  -exec chmod a+x {} + 2>/dev/null || true

if [[ "$platform" == "linux" ]]; then
  (
    cd "$build_dir/chromium/src"
    sudo ./build/install-build-deps.sh --no-chromeos-fonts --no-nacl --no-prompt
    sudo apt-get install -y --no-install-recommends \
      libpipewire-0.3-dev \
      libx11-xcb-dev
  )
fi

python3 "$build_dir/chromium/src/cef/tools/version_manager.py" -c --force-update

# Generate CEF wrapper sources, apply CEF patches to Chromium, and generate GN files.
(
  cd "$build_dir/chromium/src/cef"
  python3 tools/gclient_hook.py
)
rm -rf "$build_dir/chromium/src/out/Debug_GN_"*

# Normalize mtimes across the checkout before restoring any build checkpoint so Siso's
# hashfs (.siso_fs_state) and depfiles (.siso_deps) see identical input metadata across VMs.
python3 - "$build_dir" << 'PY'
import os
import sys

FIXED_TS = 1735689600  # 2025-01-01T00:00:00Z
root = sys.argv[1]
stack = [root]
dirs = [root]

while stack:
    d = stack.pop()
    try:
        with os.scandir(d) as it:
            for entry in it:
                if entry.name == ".git":
                    continue
                if entry.is_dir(follow_symlinks=False):
                    stack.append(entry.path)
                    dirs.append(entry.path)
                else:
                    try:
                        os.utime(entry.path, (FIXED_TS, FIXED_TS), follow_symlinks=False)
                    except OSError:
                        pass
    except OSError:
        pass

for d in reversed(dirs):
    try:
        os.utime(d, (FIXED_TS, FIXED_TS), follow_symlinks=False)
    except OSError:
        pass
PY

if [[ -n "$checkpoint_in" && -f "$checkpoint_in" ]]; then
  rm -rf "$build_dir/chromium/src/out"
  "$tar_cmd" -I "zstd -d" -xf "$checkpoint_in" -C "$build_dir/chromium/src"
  rm -f "$checkpoint_in"
  df -h "$build_dir"
fi

set +e
python3 - "$compile_minutes" "$build_dir/chromium/src" \
  autoninja "${ninja_extra_args[@]}" -C "out/$out_subdir" "${ninja_targets[@]}" << 'PY'
import os
import signal
import subprocess
import sys
import time

budget_sec = int(float(sys.argv[1]) * 60)
cwd = sys.argv[2]
cmd = sys.argv[3:]

t0 = time.monotonic()
proc = subprocess.Popen(cmd, cwd=cwd, start_new_session=True)
try:
    rc = proc.wait(timeout=budget_sec)
except subprocess.TimeoutExpired:
    elapsed_min = (time.monotonic() - t0) / 60.0
    print(
        f"\n==> Reached {elapsed_min:.1f}m stage budget; sending SIGINT so Siso flushes build state...",
        flush=True,
    )
    try:
        os.killpg(proc.pid, signal.SIGINT)
    except ProcessLookupError:
        pass
    try:
        rc_after = proc.wait(timeout=180)
        if rc_after == 0:
            sys.exit(0)
    except subprocess.TimeoutExpired:
        print("==> Build group still running after 180s; sending SIGTERM...", flush=True)
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
    sys.exit(75)

sys.exit(rc)
PY
compile_rc=$?
set -e

df -h "$build_dir"

if [[ "$compile_rc" -eq 0 ]]; then
  if [[ "$platform" == "linux" ]]; then
    lib=$(find "$build_dir/chromium/src/out/$out_subdir" -maxdepth 2 -type f -name libcef.so | head -1)
    test -n "$lib"
    nm "$lib" > "$build_dir/cef_symbols.txt"
    grep -q ' ff_h264_decoder$' "$build_dir/cef_symbols.txt"
    grep -q ' ff_aac_decoder$' "$build_dir/cef_symbols.txt"
    rm -f "$build_dir/cef_symbols.txt"
  fi

  python3 "$build_dir/automate-git.py" \
    --download-dir="$build_dir" \
    --depot-tools-dir="$build_dir/depot_tools" \
    --branch="$cef_branch" \
    --checkout="$cef_checkout" \
    --no-chromium-history \
    --no-update \
    --no-depot-tools-update \
    --no-build \
    --force-distrib \
    --no-debug-build \
    --minimal-distrib-only \
    "$arch_flag" \
    --build-target="${ninja_targets[0]}"


  dist="$build_dir/chromium/src/cef/binary_distrib"
  # shellcheck disable=SC2086
  tarball=$(echo "$dist"/$dist_glob)
  test -f "$tarball"
  (
    cd "$dist"
    sha256sum "$(basename "$tarball")" > "$(basename "$tarball").sha256"
  )

  mkdir -p "$dist_out"
  cp -f "$tarball" "$tarball.sha256" "$dist_out/"
  ls -lh "$dist_out"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "completed=true" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

if [[ "$compile_rc" -eq 75 ]]; then
  rm -f \
    "$build_dir/chromium/src/out/$out_subdir"/siso_* \
    "$build_dir/chromium/src/out/$out_subdir"/siso.INFO*

  mkdir -p "$(dirname "$checkpoint_out")"
  "$tar_cmd" --format=posix -I "zstd -T0 -3" -cf "$checkpoint_out" \
    -C "$build_dir/chromium/src" out
  ls -lh "$checkpoint_out"
  df -h "$build_dir"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "completed=false" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

echo "ERROR: autoninja failed with exit code $compile_rc" >&2
exit "$compile_rc"
