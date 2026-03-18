#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <output-dir>" >&2
  exit 1
fi

RAW_OUTPUT_DIR="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/work/gamenative-wine"
SOURCE_DIR="${WORK_DIR}/src"
METADATA_DIR="${WORK_DIR}/metadata"
mkdir -p "${RAW_OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${RAW_OUTPUT_DIR}" && pwd)"

WINE_REPO="${WCP_GN_WINE_REPO:-https://github.com/GameNative/wine.git}"
WINE_REF="${WCP_GN_WINE_REF:-wine-11.3}"
TERMUXFS_TAG="${WCP_TERMUXFS_TAG:-build-20260218}"
TERMUXFS_ARCHIVE_URL="${WCP_TERMUXFS_ARCHIVE_URL:-https://github.com/GameNative/termux-on-gha/releases/download/${TERMUXFS_TAG}/termuxfs-aarch64.tar}"
PREFIXPACK_URL="${WCP_PREFIXPACK_URL:-https://github.com/GameNative/bionic-prefix-files/raw/main/prefixPack-arm64ec.txz}"
NDK_VERSION_DIR="${WCP_ANDROID_NDK_VERSION_DIR:-27.3.13750724}"
NDK_DOWNLOAD_URL="${WCP_ANDROID_NDK_URL:-https://dl.google.com/android/repository/android-ndk-r27d-linux.zip}"
LLVM_MINGW_VERSION="${WCP_LLVM_MINGW_VERSION:-20250920}"
LLVM_MINGW_DIRNAME="${WCP_LLVM_MINGW_DIRNAME:-llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64}"
LLVM_MINGW_URL="${WCP_LLVM_MINGW_URL:-https://github.com/bylaws/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${LLVM_MINGW_DIRNAME}.tar.xz}"
ARM64EC_INPUT_DLL_ARCHIVE="${ROOT_DIR}/assets/arm64ec_input_dlls.tzst"
OVERLAY_ARM64EC_INPUT_DLLS="${WCP_OVERLAY_ARM64EC_INPUT_DLLS:-0}"

TERMUXFS_ROOT="${HOME}/termuxfs/aarch64"
TERMUX_PREFIX="${TERMUXFS_ROOT}/data/data/com.termux/files/usr"
NDK_ROOT="${HOME}/Android/Sdk/ndk/${NDK_VERSION_DIR}"
LLVM_MINGW_ROOT="${HOME}/toolchains/${LLVM_MINGW_DIRNAME}"
BUILD_OUTPUT_DIR="${HOME}/compiled-files-aarch64"
PREFIXPACK_PATH="${WORK_DIR}/prefixPack.txz"
PROFILE_PATH="${WORK_DIR}/profile.json"
METADATA_PATH="${OUTPUT_DIR}/build-metadata.json"

mkdir -p "${RAW_OUTPUT_DIR}" "${METADATA_DIR}"

ensure_archive() {
  local url="$1"
  local target="$2"
  if [[ -f "${target}" ]]; then
    return
  fi
  mkdir -p "$(dirname "${target}")"
  curl -L --fail --retry 5 -o "${target}" "${url}"
}

ensure_termuxfs() {
  local marker="${TERMUX_PREFIX}/bin"
  if [[ -d "${marker}" ]]; then
    return
  fi

  local archive="${WORK_DIR}/termuxfs-aarch64.tar"
  ensure_archive "${TERMUXFS_ARCHIVE_URL}" "${archive}"
  mkdir -p "${TERMUXFS_ROOT}"
  tar -xf "${archive}" -C "${TERMUXFS_ROOT}"
}

ensure_android_ndk() {
  if [[ -x "${NDK_ROOT}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" ]]; then
    return
  fi

  local archive="${WORK_DIR}/android-ndk-r27d-linux.zip"
  mkdir -p "${HOME}/Android/Sdk/ndk"
  ensure_archive "${NDK_DOWNLOAD_URL}" "${archive}"
  unzip -q "${archive}" -d "${HOME}/Android/Sdk/ndk"
  rm -rf "${NDK_ROOT}"
  mv "${HOME}/Android/Sdk/ndk/android-ndk-r27d" "${NDK_ROOT}"
}

ensure_llvm_mingw() {
  if [[ -x "${LLVM_MINGW_ROOT}/bin/llvm-dlltool" ]]; then
    return
  fi

  local archive="${WORK_DIR}/${LLVM_MINGW_DIRNAME}.tar.xz"
  mkdir -p "${HOME}/toolchains"
  ensure_archive "${LLVM_MINGW_URL}" "${archive}"
  tar -xf "${archive}" -C "${HOME}/toolchains"
}

clone_source() {
  rm -rf "${SOURCE_DIR}"
  git clone --depth 1 --branch "${WINE_REF}" "${WINE_REPO}" "${SOURCE_DIR}"
}

prepare_source_tree() {
  python3 - <<'PY' "${SOURCE_DIR}"
from pathlib import Path
import sys

source_dir = Path(sys.argv[1])

build_script = source_dir / "build-scripts" / "build-step-arm64ec.sh"
text = build_script.read_text()

if "set -euo pipefail" not in text:
    text = text.replace("#!/bin/bash\n", "#!/bin/bash\nset -euo pipefail\n", 1)

text = text.replace("--with-fontconfig \\\n", "--without-fontconfig \\\n")

old = """    for patch in \"${PATCHES[@]}\"; do
#      if git apply --check ./android/patches/$patch 2>/dev/null; then
        git apply ./android/patches/$patch
#      fi
    done
"""
new = """    for patch in \"${PATCHES[@]}\"; do
      if git apply --check ./android/patches/$patch >/dev/null 2>&1; then
        git apply ./android/patches/$patch
      else
        echo \"Skipping patch that no longer applies cleanly: $patch\"
      fi
    done
"""
if old in text:
    text = text.replace(old, new, 1)

build_script.write_text(text)

pulse_path = source_dir / "dlls" / "winepulse.drv" / "pulse.c"
pulse = pulse_path.read_text()

old_attach = """    pthread_mutexattr_init(&attr);\n    pthread_mutexattr_setprotocol(&attr, PTHREAD_PRIO_INHERIT);\n    pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST);\n"""
new_attach = """    pthread_mutexattr_init(&attr);\n#ifndef __ANDROID__\n    pthread_mutexattr_setprotocol(&attr, PTHREAD_PRIO_INHERIT);\n    pthread_mutexattr_setrobust(&attr, PTHREAD_MUTEX_ROBUST);\n#endif\n"""
if old_attach in pulse and "#ifndef __ANDROID__" not in pulse:
    pulse = pulse.replace(old_attach, new_attach, 1)

old_mainloop = """    NtSetEvent(params->event, NULL);\n    pthread_cleanup_push(pulse_main_loop_thread_cleanup, NULL);\n    pa_mainloop_run(pulse_ml, &ret);\n    pthread_cleanup_pop(0);\n"""
new_mainloop = """    NtSetEvent(params->event, NULL);\n#ifdef __ANDROID__\n    pa_mainloop_run(pulse_ml, &ret);\n#else\n    pthread_cleanup_push(pulse_main_loop_thread_cleanup, NULL);\n    pa_mainloop_run(pulse_ml, &ret);\n    pthread_cleanup_pop(0);\n#endif\n"""
if old_mainloop in pulse and "#ifdef __ANDROID__" not in pulse:
    pulse = pulse.replace(old_mainloop, new_mainloop, 1)

pulse_path.write_text(pulse)

advapi32_spec_path = source_dir / "dlls" / "advapi32" / "advapi32.spec"
advapi32_spec = advapi32_spec_path.read_text()
advapi32_spec = advapi32_spec.replace(
    "@ stdcall SystemFunction036(ptr long) cryptbase.SystemFunction036\n",
    "@ stdcall SystemFunction036(ptr long) # RtlGenRandom\n",
)
advapi32_spec_path.write_text(advapi32_spec)

advapi32_crypt_path = source_dir / "dlls" / "advapi32" / "crypt.c"
advapi32_crypt = advapi32_crypt_path.read_text()
system_function_036_block = """
static CRITICAL_SECTION random_cs;
static CRITICAL_SECTION_DEBUG random_debug =
{
    0, 0, &random_cs,
    { &random_debug.ProcessLocksList, &random_debug.ProcessLocksList },
      0, 0, { (DWORD_PTR)(__FILE__ ": random_cs") }
};
static CRITICAL_SECTION random_cs = { &random_debug, -1, 0, 0, 0, 0 };

#define MAX_CPUS 256
static char random_buf[sizeof(SYSTEM_INTERRUPT_INFORMATION) * MAX_CPUS];
static ULONG random_len;
static ULONG random_pos;

/* FIXME: assumes interrupt information provides sufficient randomness */
static BOOL fill_random_buffer(void)
{
    ULONG len = sizeof(SYSTEM_INTERRUPT_INFORMATION) * min( NtCurrentTeb()->Peb->NumberOfProcessors, MAX_CPUS );
    NTSTATUS status;

    if ((status = NtQuerySystemInformation( SystemInterruptInformation, random_buf, len, NULL )))
    {
        WARN( "failed to get random bytes %08lx\\n", status );
        return FALSE;
    }
    random_len = len;
    random_pos = 0;
    return TRUE;
}

/******************************************************************************
 * SystemFunction036   (ADVAPI32.@)
 *
 * MSDN documents this function as RtlGenRandom and declares it in ntsecapi.h
 *
 * PARAMS
 *  pbBuffer [O] Pointer to memory to receive random bytes.
 *  dwLen   [I] Number of random bytes to fetch.
 *
 * RETURNS
 *  Success: TRUE
 *  Failure: FALSE
 */

BOOLEAN WINAPI SystemFunction036( void *buffer, ULONG len )
{
    char *ptr = buffer;

    EnterCriticalSection( &random_cs );
    while (len)
    {
        ULONG size;
        if (random_pos >= random_len && !fill_random_buffer())
        {
            SetLastError( NTE_FAIL );
            LeaveCriticalSection( &random_cs );
            return FALSE;
        }
        size = min( len, random_len - random_pos );
        memcpy( ptr, random_buf + random_pos, size );
        random_pos += size;
        ptr += size;
        len -= size;
    }
    LeaveCriticalSection( &random_cs );
    return TRUE;
}
"""

if "BOOLEAN WINAPI SystemFunction036(" not in advapi32_crypt:
    advapi32_crypt = advapi32_crypt.rstrip() + "\n\n" + system_function_036_block + "\n"

advapi32_crypt_path.write_text(advapi32_crypt)

loader_main_path = source_dir / "loader" / "main.c"
loader_main = loader_main_path.read_text()

old_try_dlopen = """static void *try_dlopen( const char *argv0 )
{
    char *dir, *path, *p;
    void *handle;

    if (!argv0) return NULL;
    if (!(dir = realpath_dirname( argv0 ))) return NULL;

    if ((p = remove_tail( dir, "/loader" )))
        path = build_path( p, "dlls/ntdll/ntdll.so" );
    else
        path = build_path( dir, "ntdll.so" );

    handle = dlopen( path, RTLD_NOW );
    free( p );
    free( dir );
    free( path );
    return handle;
}
"""

new_try_dlopen = """static void *try_dlopen( const char *argv0 )
{
    char *dir, *path, *p;
    char *dllpath;
    void *handle = NULL;

    if (!argv0) return NULL;
    if (!(dir = realpath_dirname( argv0 ))) return NULL;

    if ((p = remove_tail( dir, "/loader" )))
    {
        path = build_path( p, "dlls/ntdll/ntdll.so" );
        handle = dlopen( path, RTLD_NOW );
        free( p );
    }
    else
    {
        path = build_path( dir, "../lib/wine/aarch64-unix/ntdll.so" );
        handle = dlopen( path, RTLD_NOW );
        if (!handle)
        {
            free( path );
            path = build_path( dir, "ntdll.so" );
            handle = dlopen( path, RTLD_NOW );
        }
    }

    if (!handle && (dllpath = getenv( "WINEDLLPATH" )))
    {
        char *dllpath_copy = strdup( dllpath );
        char *entry;

        for (entry = strtok( dllpath_copy, ":" ); entry; entry = strtok( NULL, ":" ))
        {
            path = build_path( entry, "aarch64-unix/ntdll.so" );
            handle = dlopen( path, RTLD_NOW );
            free( path );
            if (!handle)
            {
                path = build_path( entry, "ntdll.so" );
                handle = dlopen( path, RTLD_NOW );
                free( path );
            }
            if (handle) break;
        }
        free( dllpath_copy );
        free( dir );
        return handle;
    }

    free( dir );
    free( path );
    return handle;
}
"""

if old_try_dlopen in loader_main and "../lib/wine/aarch64-unix/ntdll.so" not in loader_main:
    loader_main = loader_main.replace(old_try_dlopen, new_try_dlopen, 1)

loader_main_path.write_text(loader_main)

win32u_opengl_path = source_dir / "dlls" / "win32u" / "opengl.c"
win32u_opengl = win32u_opengl_path.read_text()

old_egl_dlopen = """    if (!(funcs->egl_handle = dlopen( SONAME_LIBEGL, RTLD_NOW | RTLD_GLOBAL )))\n    {\n        ERR( \"Failed to load %s: %s\\n\", SONAME_LIBEGL, dlerror() );\n        return FALSE;\n    }\n"""

new_egl_dlopen = """    if (!(funcs->egl_handle = dlopen( SONAME_LIBEGL, RTLD_NOW | RTLD_GLOBAL )))\n    {\n#ifdef __ANDROID__\n        funcs->egl_handle = dlopen( \"libEGL.so\", RTLD_NOW | RTLD_GLOBAL );\n#endif\n        if (!funcs->egl_handle)\n        {\n            ERR( \"Failed to load %s: %s\\n\", SONAME_LIBEGL, dlerror() );\n            return FALSE;\n        }\n    }\n"""

if old_egl_dlopen in win32u_opengl and 'dlopen( "libEGL.so", RTLD_NOW | RTLD_GLOBAL )' not in win32u_opengl:
    win32u_opengl = win32u_opengl.replace(old_egl_dlopen, new_egl_dlopen, 1)

old_egl_client_extensions = """#define CHECK_EXTENSION( ext )                                  \\\n    if (!has_extension( extensions, #ext ))                     \\\n    {                                                           \\\n        ERR( \"Failed to find required extension %s\\n\", #ext );  \\\n        goto failed;                                            \\\n    }\n    CHECK_EXTENSION( EGL_KHR_client_get_all_proc_addresses );\n    CHECK_EXTENSION( EGL_EXT_platform_base );\n#undef CHECK_EXTENSION\n"""

new_egl_client_extensions = """#ifdef __ANDROID__\n    if (!has_extension( extensions, \"EGL_KHR_client_get_all_proc_addresses\" ))\n        WARN( \"Missing EGL client extension %s, continuing with Android fallback\\n\",\n              \"EGL_KHR_client_get_all_proc_addresses\" );\n    if (!has_extension( extensions, \"EGL_EXT_platform_base\" ))\n        WARN( \"Missing EGL client extension %s, continuing with Android fallback\\n\",\n              \"EGL_EXT_platform_base\" );\n#else\n    if (!has_extension( extensions, \"EGL_KHR_client_get_all_proc_addresses\" ))\n    {\n        ERR( \"Failed to find required extension %s\\n\", \"EGL_KHR_client_get_all_proc_addresses\" );\n        goto failed;\n    }\n    if (!has_extension( extensions, \"EGL_EXT_platform_base\" ))\n    {\n        ERR( \"Failed to find required extension %s\\n\", \"EGL_EXT_platform_base\" );\n        goto failed;\n    }\n#endif\n"""

if old_egl_client_extensions in win32u_opengl and "continuing with Android fallback" not in win32u_opengl:
    win32u_opengl = win32u_opengl.replace(old_egl_client_extensions, new_egl_client_extensions, 1)

old_display_funcs_init = """static void display_funcs_init(void)\n{\n    struct egl_platform *egl, *next;\n    UINT status;\n\n    if (egl_init( &driver_funcs )) TRACE( \"Initialized EGL library\\n\" );\n\n    if ((status = user_driver->pOpenGLInit( WINE_OPENGL_DRIVER_VERSION, &display_funcs, &driver_funcs )))\n        WARN( \"Failed to initialize the driver OpenGL functions, status %#x\\n\", status );\n    init_egl_platforms( &display_funcs, driver_funcs );\n"""

old_forced_glx_display_funcs_init = """static void display_funcs_init(void)\n{\n    struct egl_platform *egl, *next;\n    UINT status;\n#ifdef __ANDROID__\n    const char *wine_x11forceglx = getenv( \"WINE_X11FORCEGLX\" );\n    BOOL force_glx = wine_x11forceglx && atoi( wine_x11forceglx );\n#else\n    BOOL force_glx = FALSE;\n#endif\n\n    if (!force_glx && egl_init( &driver_funcs )) TRACE( \"Initialized EGL library\\n\" );\n    else if (force_glx) TRACE( \"Skipping EGL initialization because WINE_X11FORCEGLX is enabled\\n\" );\n\n    if ((status = user_driver->pOpenGLInit( WINE_OPENGL_DRIVER_VERSION, &display_funcs, &driver_funcs )))\n        WARN( \"Failed to initialize the driver OpenGL functions, status %#x\\n\", status );\n    if (!force_glx) init_egl_platforms( &display_funcs, driver_funcs );\n"""

if old_forced_glx_display_funcs_init in win32u_opengl:
    win32u_opengl = win32u_opengl.replace(old_forced_glx_display_funcs_init, old_display_funcs_init, 1)

old_egl_config_filter = """    for (i = 0, j = 0; i < count; i++)\n    {\n        funcs->p_eglGetConfigAttrib( egl->display, configs[i], EGL_RENDERABLE_TYPE, &render );\n        if (render & EGL_OPENGL_BIT) configs[j++] = configs[i];\n    }\n    count = j;\n"""

new_egl_config_filter = """    for (i = 0, j = 0; i < count; i++)\n    {\n        funcs->p_eglGetConfigAttrib( egl->display, configs[i], EGL_RENDERABLE_TYPE, &render );\n#ifdef __ANDROID__\n        if (render & (EGL_OPENGL_BIT | EGL_OPENGL_ES2_BIT)) configs[j++] = configs[i];\n#else\n        if (render & EGL_OPENGL_BIT) configs[j++] = configs[i];\n#endif\n    }\n    count = j;\n"""

if old_egl_config_filter in win32u_opengl and "EGL_OPENGL_ES2_BIT" not in win32u_opengl:
    win32u_opengl = win32u_opengl.replace(old_egl_config_filter, new_egl_config_filter, 1)

win32u_opengl_path.write_text(win32u_opengl)

winex11_opengl_path = source_dir / "dlls" / "winex11.drv" / "opengl.c"
winex11_opengl = winex11_opengl_path.read_text()

old_x11drv_init_egl_platform = """static void x11drv_init_egl_platform( struct egl_platform *platform )\n{\n    platform->type = EGL_PLATFORM_X11_KHR;\n    platform->native_display = gdi_display;\n    egl = platform;\n}\n"""

new_x11drv_init_egl_platform = """static void x11drv_init_egl_platform( struct egl_platform *platform )\n{\n#ifdef __ANDROID__\n    platform->type = 0;\n    platform->native_display = 0;\n#else\n    platform->type = EGL_PLATFORM_X11_KHR;\n    platform->native_display = gdi_display;\n#endif\n    egl = platform;\n}\n"""

if old_x11drv_init_egl_platform in winex11_opengl and "platform->type = 0;" not in winex11_opengl:
    winex11_opengl = winex11_opengl.replace(old_x11drv_init_egl_platform, new_x11drv_init_egl_platform, 1)

winex11_opengl_path.write_text(winex11_opengl)
PY
}

derive_version() {
  python3 - <<'PY' "${SOURCE_DIR}/VERSION"
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
match = re.search(r"(\d+(?:\.\d+)+(?:-[A-Za-z0-9.]+)?)", text)
if match:
    print(match.group(1))
else:
    print(text.replace(" ", "-"))
PY
}

normalize_build_output() {
  local bin_dir="${BUILD_OUTPUT_DIR}/bin"
  local unix_dir="${BUILD_OUTPUT_DIR}/lib/wine/aarch64-unix"

  mkdir -p "${bin_dir}"

  local wine_source=""
  local preloader_source=""
  local wineserver_source=""

  for wine_source in \
    "${bin_dir}/wine" \
    "${bin_dir}/wine64" \
    "${bin_dir}/wine-wow64" \
    "${bin_dir}/wine32" \
    "${unix_dir}/wine"; do
    if [[ -f "${wine_source}" ]]; then
      break
    fi
  done

  if [[ ! -f "${wine_source}" ]]; then
    echo "Could not find a Wine launcher binary to normalize under ${BUILD_OUTPUT_DIR}" >&2
    exit 1
  fi

  if [[ ! -e "${bin_dir}/wine" ]]; then
    cp -f "${wine_source}" "${bin_dir}/wine"
    chmod 0755 "${bin_dir}/wine"
  fi

  if [[ ! -e "${bin_dir}/wine64" ]]; then
    ln -sf wine "${bin_dir}/wine64"
  fi

  for preloader_source in \
    "${bin_dir}/wine-preloader" \
    "${bin_dir}/wine64-preloader" \
    "${bin_dir}/wine-preloader-wow64" \
    "${bin_dir}/wine32-preloader" \
    "${unix_dir}/wine-preloader"; do
    if [[ -f "${preloader_source}" ]]; then
      break
    fi
  done

  if [[ -f "${preloader_source}" && ! -e "${bin_dir}/wine-preloader" ]]; then
    cp -f "${preloader_source}" "${bin_dir}/wine-preloader"
    chmod 0755 "${bin_dir}/wine-preloader"
  fi

  for wineserver_source in \
    "${bin_dir}/wineserver" \
    "${unix_dir}/wineserver"; do
    if [[ -f "${wineserver_source}" ]]; then
      break
    fi
  done

  if [[ -f "${wineserver_source}" && ! -e "${bin_dir}/wineserver" ]]; then
    cp -f "${wineserver_source}" "${bin_dir}/wineserver"
    chmod 0755 "${bin_dir}/wineserver"
  fi

  local helper
  for helper in \
    msidb \
    msiexec \
    notepad \
    regedit \
    regsvr32 \
    wineboot \
    winecfg \
    wineconsole \
    winedbg \
    winefile \
    winemine \
    winepath; do
    if [[ ! -e "${bin_dir}/${helper}" ]]; then
      ln -sf wine "${bin_dir}/${helper}"
    fi
  done
}

overlay_arm64ec_input_dlls() {
  if [[ "${OVERLAY_ARM64EC_INPUT_DLLS}" != "1" ]]; then
    return
  fi

  if [[ ! -f "${ARM64EC_INPUT_DLL_ARCHIVE}" ]]; then
    echo "Missing arm64ec input DLL archive: ${ARM64EC_INPUT_DLL_ARCHIVE}" >&2
    exit 1
  fi

  mkdir -p "${BUILD_OUTPUT_DIR}/lib/wine"
  tar --zstd -xf "${ARM64EC_INPUT_DLL_ARCHIVE}" -C "${BUILD_OUTPUT_DIR}/lib/wine"
}

build_wine() {
  pushd "${SOURCE_DIR}" >/dev/null
  bash autogen.sh
  bash build-scripts/build-step0.sh
  bash build-scripts/build-step-arm64ec.sh --build-sysvshm --configure --build --install
  popd >/dev/null
}

write_profile() {
  local version="$1"
  cat > "${PROFILE_PATH}" <<EOF
{
  "type": "Wine",
  "versionName": "wine-${version}-arm64ec",
  "versionCode": 1,
  "description": "Wine ${version} arm64ec built from GameNative's Android patch stack",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
EOF
}

package_artifact() {
  local version="$1"
  local artifact="wine-${version}-arm64ec.wcp"
  local release_tag="wine-${version}-arm64ec"

  ensure_archive "${PREFIXPACK_URL}" "${PREFIXPACK_PATH}"
  write_profile "${version}"

  if [[ ! -d "${BUILD_OUTPUT_DIR}/bin" || ! -d "${BUILD_OUTPUT_DIR}/lib" || ! -d "${BUILD_OUTPUT_DIR}/share" ]]; then
    echo "Expected GameNative Wine build output under ${BUILD_OUTPUT_DIR}" >&2
    exit 1
  fi

  rm -f "${OUTPUT_DIR:?}/${artifact}"
  tar -C "${BUILD_OUTPUT_DIR}" -cJf "${OUTPUT_DIR}/${artifact}" bin lib share \
    -C "${WORK_DIR}" prefixPack.txz profile.json

  python3 - <<PY "${METADATA_PATH}" "${version}" "${artifact}" "${release_tag}" "${WINE_REF}" "${WINE_REPO}"
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
metadata = {
    "version": sys.argv[2],
    "artifact": sys.argv[3],
    "release_tag": sys.argv[4],
    "source_ref": sys.argv[5],
    "source_repo": sys.argv[6],
}
path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
PY
}

ensure_termuxfs
ensure_android_ndk
ensure_llvm_mingw
clone_source
prepare_source_tree
build_wine
VERSION="$(derive_version)"
normalize_build_output
overlay_arm64ec_input_dlls
package_artifact "${VERSION}"

echo "Built ${OUTPUT_DIR}/wine-${VERSION}-arm64ec.wcp"
echo "Metadata written to ${METADATA_PATH}"
