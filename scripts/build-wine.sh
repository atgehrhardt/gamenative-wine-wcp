#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <wine-version> <wine-source-url> <output-dir>" >&2
  exit 1
fi

WINE_VERSION="$1"
WINE_URL="$2"
RAW_OUTPUT_DIR="$3"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/work/wine-${WINE_VERSION}"
SOURCE_ARCHIVE="${WORK_DIR}/wine-${WINE_VERSION}.tar.xz"
SOURCE_DIR="${WORK_DIR}/src"
TOOLS_BUILD_DIR="${WORK_DIR}/build-tools"
BUILD_DIR="${WORK_DIR}/build"
INSTALL_ROOT="${WORK_DIR}/install-root"
STAGE_DIR="${WORK_DIR}/stage"
WINE_PREFIX="/opt/wine-${WINE_VERSION}-arm64ec"
WINE_EXEC_PREFIX="${WINE_PREFIX}"
ANDROID_NDK_ROOT="${ANDROID_NDK_ROOT:-/opt/android-ndk}"
ANDROID_API="${ANDROID_API:-28}"
ANDROID_TARGET="${ANDROID_TARGET:-aarch64-linux-android}"
LLVM_MINGW_ROOT="${LLVM_MINGW_ROOT:-/opt/llvm-mingw}"
PREFIX_TEMPLATE_ARCHIVE="${ROOT_DIR}/assets/proton-9.0-arm64ec_container_pattern.tzst"
ARM64EC_INPUT_DLL_ARCHIVE="${ROOT_DIR}/assets/arm64ec_input_dlls.tzst"
TOOLCHAIN="${ANDROID_NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64"
CONFIGURE_ONLY="${WCP_CONFIGURE_ONLY:-0}"
BUILD_TRIPLE="${BUILD_TRIPLE:-$(gcc -dumpmachine)}"
COMMON_CONFIGURE_FLAGS=(
  --disable-tests
  --without-alsa
  --without-cups
  --without-dbus
  --without-fontconfig
  --without-freetype
  --without-gphoto
  --without-gstreamer
  --without-krb5
  --without-netapi
  --without-oss
  --without-pcap
  --without-pcsclite
  --without-pulse
  --without-sane
  --without-sdl
  --without-udev
  --without-unwind
  --without-usb
  --without-v4l2
  --without-wayland
  --without-x
)

mkdir -p "${RAW_OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${RAW_OUTPUT_DIR}" && pwd)"

rm -rf "${WORK_DIR}"
mkdir -p "${SOURCE_DIR}" "${TOOLS_BUILD_DIR}" "${BUILD_DIR}" "${INSTALL_ROOT}" "${STAGE_DIR}" "${OUTPUT_DIR}"

curl -L --fail --retry 5 -o "${SOURCE_ARCHIVE}" "${WINE_URL}"
tar -xJf "${SOURCE_ARCHIVE}" -C "${SOURCE_DIR}" --strip-components=1

python3 - <<'PY' "${SOURCE_DIR}"
from pathlib import Path
import sys

source_dir = Path(sys.argv[1])


def replace_once(path: Path, old: str, new: str) -> bool:
    text = path.read_text()
    if old not in text:
        return False
    path.write_text(text.replace(old, new, 1))
    return True


android_h = source_dir / "dlls/wineandroid.drv/android.h"
replace_once(
    android_h,
    "extern void ANDROID_WindowPosChanged( HWND hwnd, HWND insert_after, HWND owner_hint, UINT swp_flags, BOOL fullscreen,\n"
    "                                      const struct window_rects *new_rects, struct window_surface *surface );\n",
    "extern void ANDROID_WindowPosChanged( HWND hwnd, HWND insert_after, HWND owner_hint, UINT swp_flags,\n"
    "                                      const struct window_rects *new_rects, struct window_surface *surface );\n",
)
replace_once(
    android_h,
    "extern pthread_mutex_t drawable_mutex;\n",
    "struct opengl_drawable;\n\nextern pthread_mutex_t drawable_mutex;\n",
)
android_h_text = android_h.read_text()
set_window_decl = "extern void set_window_opengl_drawable( HWND hwnd, struct opengl_drawable *new_drawable, BOOL current );\n"
if set_window_decl not in android_h_text:
    android_h_text = android_h_text.replace(
        "extern ANativeWindow *get_client_window( HWND hwnd );\n",
        set_window_decl + "extern ANativeWindow *get_client_window( HWND hwnd );\n",
        1,
    )
android_h_text = android_h_text.replace(set_window_decl + set_window_decl, set_window_decl)
android_h.write_text(android_h_text)

win32u_opengl = source_dir / "dlls/win32u/opengl.c"
replace_once(
    win32u_opengl,
    "static void set_window_opengl_drawable( HWND hwnd, struct opengl_drawable *new_drawable, BOOL current )\n",
    "__attribute__((visibility(\"default\"))) void set_window_opengl_drawable( HWND hwnd, struct opengl_drawable *new_drawable, BOOL current )\n",
)
replace_once(
    win32u_opengl,
    "void set_window_opengl_drawable( HWND hwnd, struct opengl_drawable *new_drawable, BOOL current )\n",
    "__attribute__((visibility(\"default\"))) void set_window_opengl_drawable( HWND hwnd, struct opengl_drawable *new_drawable, BOOL current )\n",
)

wineandroid_makefile = source_dir / "dlls/wineandroid.drv/Makefile.in"
replace_once(
    wineandroid_makefile,
    "EXTRA_TARGETS = wine-debug.apk\n",
    "",
)

dllmain = source_dir / "dlls/wineandroid.drv/dllmain.c"
replace_once(
    dllmain,
    "    params.start_device_callback = android_start_device;\n",
    "    params.start_device_callback = (UINT_PTR)android_start_device;\n",
)

wineandroid_opengl = source_dir / "dlls/wineandroid.drv/opengl.c"
replace_once(
    wineandroid_opengl,
    "static void *opengl_handle;\n",
    "pthread_mutex_t drawable_mutex;\n\nstatic void *opengl_handle;\n",
)
PY

if [[ ! -x "${TOOLCHAIN}/bin/clang" ]]; then
  echo "Android NDK clang toolchain not found at ${TOOLCHAIN}" >&2
  exit 1
fi

if [[ ! -d "${LLVM_MINGW_ROOT}/bin" ]]; then
  echo "llvm-mingw toolchain not found at ${LLVM_MINGW_ROOT}" >&2
  exit 1
fi

pushd "${TOOLS_BUILD_DIR}" >/dev/null
"${SOURCE_DIR}/configure" \
  --build="${BUILD_TRIPLE}" \
  --host="${BUILD_TRIPLE}" \
  --enable-win64 \
  --without-mingw \
  "${COMMON_CONFIGURE_FLAGS[@]}"
make -j"$(nproc)" __tooldeps__
popd >/dev/null

pushd "${BUILD_DIR}" >/dev/null
export PATH="${LLVM_MINGW_ROOT}/bin:${PATH}"
export AR="${TOOLCHAIN}/bin/llvm-ar"
export AS="${TOOLCHAIN}/bin/clang --target=${ANDROID_TARGET}${ANDROID_API}"
export CC="${TOOLCHAIN}/bin/clang --target=${ANDROID_TARGET}${ANDROID_API}"
export CXX="${TOOLCHAIN}/bin/clang++ --target=${ANDROID_TARGET}${ANDROID_API}"
export LD="${TOOLCHAIN}/bin/ld.lld"
export NM="${TOOLCHAIN}/bin/llvm-nm"
export RANLIB="${TOOLCHAIN}/bin/llvm-ranlib"
export STRIP="${TOOLCHAIN}/bin/llvm-strip"
export PKG_CONFIG=/bin/false
export CFLAGS="${CFLAGS:-} -O2 -pipe"
export CXXFLAGS="${CXXFLAGS:-} -O2 -pipe"
export LDFLAGS="${LDFLAGS:-} -fuse-ld=lld"

"${SOURCE_DIR}/configure" \
  --build="${BUILD_TRIPLE}" \
  --host="${ANDROID_TARGET}" \
  --prefix="${WINE_PREFIX}" \
  --exec-prefix="${WINE_EXEC_PREFIX}" \
  --with-wine-tools="${TOOLS_BUILD_DIR}" \
  --with-mingw=clang \
  --enable-archs=i386,x86_64,aarch64 \
  "${COMMON_CONFIGURE_FLAGS[@]}"

python3 - <<'PY' "${BUILD_DIR}"
from pathlib import Path
import sys

build_dir = Path(sys.argv[1])

top_level_makefile = build_dir / "Makefile"
if top_level_makefile.exists():
    lines = top_level_makefile.read_text().splitlines(keepends=True)
    rewritten_lines: list[str] = []
    skip = 0
    for line in lines:
        if skip:
            skip -= 1
            continue
        if line.startswith("dlls/wineandroid.drv/wine-debug.apk:"):
            skip = 2
            continue
        rewritten_lines.append(line.replace(" dlls/wineandroid.drv/wine-debug.apk", ""))
    top_level_makefile.write_text("".join(rewritten_lines))

module_makefile = build_dir / "dlls/wineandroid.drv/Makefile"
if module_makefile.exists():
    module_text = module_makefile.read_text()
    module_text = module_text.replace(" wine-debug.apk", "")
    module_makefile.write_text(module_text)
PY

if [[ "${CONFIGURE_ONLY}" == "1" ]]; then
  echo "Configured Wine ${WINE_VERSION} for ${ANDROID_TARGET}${ANDROID_API}; stopping because WCP_CONFIGURE_ONLY=1"
  popd >/dev/null
  exit 0
fi

make -j"$(nproc)"
make install DESTDIR="${INSTALL_ROOT}"
popd >/dev/null

PYTHONPATH="${ROOT_DIR}/src" python3 - <<'PY' "${INSTALL_ROOT}" "${STAGE_DIR}" "${WINE_VERSION}" "${OUTPUT_DIR}" "${WINE_PREFIX}" "${WINE_EXEC_PREFIX}" "${PREFIX_TEMPLATE_ARCHIVE}" "${ARM64EC_INPUT_DLL_ARCHIVE}"
import shutil
import sys
from pathlib import Path

from wcp_builder.packaging import (
    has_bionic_x11_runtime,
    RUNTIME_BINARIES,
    has_real_prefix_content,
    materialize_prefix,
    package_wine_tree,
    stage_installed_wine_tree,
)

install_root = Path(sys.argv[1])
stage_dir = Path(sys.argv[2])
version = sys.argv[3]
output_dir = Path(sys.argv[4])
prefix = sys.argv[5]
exec_prefix = sys.argv[6]
prefix_template_archive = Path(sys.argv[7])
arm64ec_input_dll_archive = Path(sys.argv[8])

if stage_dir.exists():
    shutil.rmtree(stage_dir)

stage_installed_wine_tree(
    install_root,
    prefix,
    exec_prefix,
    stage_dir,
    allowed_runtime_bins=RUNTIME_BINARIES,
    allowed_wine_arches={"aarch64-unix", "aarch64-windows", "x86_64-windows", "i386-windows"},
    share_subdirs={"wine"},
    arm64ec_input_dll_archive=arm64ec_input_dll_archive,
)

if not has_bionic_x11_runtime(stage_dir):
    raise RuntimeError(
        "Staged Wine runtime is missing the X11 driver files GameNative's Bionic path expects "
        "(winex11.so / winex11.drv). Refusing to package a known-bad artifact."
    )

generated_prefix_root = install_root / prefix.lstrip("/") / "share" / "default_pfx"
prefix_root = materialize_prefix(
    generated_prefix=generated_prefix_root,
    destination=stage_dir / "share" / "default_pfx",
    template_archive=prefix_template_archive,
)

if not has_real_prefix_content(prefix_root):
    raise RuntimeError(
        "Wine packaging did not produce a usable default prefix under share/default_pfx. "
        "Refusing to package a broken artifact."
    )

package_wine_tree(
    source_root=stage_dir,
    output_path=output_dir / f"wine-{version}-arm64ec.wcp",
    version_name=f"{version}-arm64ec",
    description=f"Wine {version} arm64ec for GameNative",
)
PY
