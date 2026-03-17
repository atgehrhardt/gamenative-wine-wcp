from __future__ import annotations

import json
import os
import subprocess
import shutil
import tarfile
import tempfile
from pathlib import Path

RUNTIME_BINARIES = {
    "msidb",
    "msiexec",
    "notepad",
    "regedit",
    "regsvr32",
    "wine",
    "wine-preloader",
    "wineboot",
    "winecfg",
    "wineconsole",
    "winedbg",
    "winefile",
    "winemine",
    "winepath",
    "wineserver",
}

def _copytree_contents(source: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for item in source.iterdir():
        target = destination / item.name
        if item.is_dir() and not item.is_symlink():
            shutil.copytree(item, target, symlinks=True, ignore_dangling_symlinks=True, dirs_exist_ok=True)
        else:
            shutil.copy2(item, target, follow_symlinks=False)


def _copytree_contents_filtered(source: Path, destination: Path, skip_relative_paths: set[str]) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for item in source.iterdir():
        relative_name = item.name
        if relative_name in skip_relative_paths:
            continue

        target = destination / item.name
        if item.is_dir() and not item.is_symlink():
            shutil.copytree(
                item,
                target,
                symlinks=True,
                ignore_dangling_symlinks=True,
            )
        else:
            shutil.copy2(item, target, follow_symlinks=False)


def _copy_selected_entries(source: Path, destination: Path, names: set[str]) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for item in sorted(source.iterdir()):
        if item.name not in names:
            continue
        target = destination / item.name
        if item.is_dir() and not item.is_symlink():
            shutil.copytree(item, target, symlinks=True, ignore_dangling_symlinks=True)
        else:
            shutil.copy2(item, target, follow_symlinks=False)


def _copy_selected_bin_entries(sources: list[Path], destination: Path, names: set[str] | None) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for source in sources:
        if not source.exists():
            continue
        for item in sorted(source.iterdir()):
            if names is not None and item.name not in names:
                continue
            target = destination / item.name
            if item.is_dir() and not item.is_symlink():
                if target.exists():
                    shutil.rmtree(target)
                shutil.copytree(item, target, symlinks=True, ignore_dangling_symlinks=True)
            else:
                if target.exists() or target.is_symlink():
                    target.unlink()
                shutil.copy2(item, target, follow_symlinks=False)


def _normalize_lib_layout(root: Path) -> None:
    lib64 = root / "lib64"
    lib = root / "lib"
    if lib64.exists() and not lib.exists():
        lib64.rename(lib)
        return

    if lib64.exists() and lib.exists():
        _copytree_contents(lib64, lib)
        shutil.rmtree(lib64)


def _copy_if_exists(source: Path, destination: Path) -> bool:
    if not source.exists():
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination, follow_symlinks=False)
    return True


def _ensure_loader_binaries(root: Path, required_names: set[str] | None) -> None:
    if required_names is not None and "wine" not in required_names and "wine-preloader" not in required_names:
        return

    wine_root = root / "lib" / "wine"
    if not wine_root.exists():
        return

    preferred_arches = ("aarch64-unix", "x86_64-unix")
    candidate_dirs = [wine_root / arch for arch in preferred_arches]
    candidate_dirs.extend(sorted(path for path in wine_root.iterdir() if path.is_dir() and path.name.endswith("-unix")))

    for name in ("wine", "wine-preloader"):
        if required_names is not None and name not in required_names:
            continue

        target = root / "bin" / name
        if target.exists():
            continue

        for candidate_dir in candidate_dirs:
            if _copy_if_exists(candidate_dir / name, target):
                break


def _write_bionic_wine_wrapper(root: Path, arch: str, binary_name: str) -> None:
    runtime_binary = root / "lib" / "wine" / arch / binary_name
    if not runtime_binary.exists():
        return

    target = root / "bin" / binary_name
    dll_path_entries = [f'$DIR/../lib/wine/{arch}']
    for candidate in ("aarch64-windows", "x86_64-windows", "i386-windows", "arm64ec-windows"):
        if (root / "lib" / "wine" / candidate).exists():
            dll_path_entries.append(f'$DIR/../lib/wine/{candidate}')
    dll_path = ":".join(dll_path_entries)
    script = f"""#!/system/bin/sh
case "$0" in
  */*) DIR="${{0%/*}}" ;;
  *) DIR="." ;;
esac
export WINEDLLPATH="{dll_path}${{WINEDLLPATH:+:$WINEDLLPATH}}"
export WINEDATADIR="$DIR/../share/wine"
exec "$DIR/../lib/wine/{arch}/{binary_name}" "$@"
"""
    target.write_text(script, encoding="utf-8")
    target.chmod(0o755)


def _wrap_bionic_wine_launchers(root: Path, arch: str) -> None:
    for binary_name in ("wine", "wine-preloader"):
        _write_bionic_wine_wrapper(root, arch, binary_name)


def _prune_wine_arches(root: Path, allowed_arches: set[str]) -> None:
    wine_root = root / "lib" / "wine"
    if not wine_root.exists():
        return

    for item in wine_root.iterdir():
        if item.is_dir() and item.name.endswith(("-windows", "-unix")) and item.name not in allowed_arches:
            shutil.rmtree(item)


def ensure_minimal_prefix(prefix: Path) -> None:
    (prefix / "drive_c").mkdir(parents=True, exist_ok=True)
    (prefix / "dosdevices").mkdir(parents=True, exist_ok=True)

    c_drive = prefix / "dosdevices" / "c:"
    if not c_drive.exists():
        c_drive.symlink_to("../drive_c")

    for registry_name in ("system.reg", "user.reg", "userdef.reg"):
        registry_path = prefix / registry_name
        if not registry_path.exists():
            registry_path.write_text("WINE REGISTRY Version 2\n\n", encoding="utf-8")


def _set_registry_string_value(registry_path: Path, section: str, key: str, value: str) -> None:
    if not registry_path.exists():
        registry_path.write_text("WINE REGISTRY Version 2\n\n", encoding="utf-8")

    lines = registry_path.read_text(encoding="utf-8").splitlines()
    section_header = f"[{section}]"
    key_prefix = f'"{key}"='

    section_start = None
    for index, line in enumerate(lines):
        if line.startswith(section_header):
            section_start = index
            break

    if section_start is None:
        if lines and lines[-1] != "":
            lines.append("")
        lines.extend(
            [
                f"{section_header} 1",
                "#time=1",
                f'{key_prefix}"{value}"',
                "",
            ]
        )
    else:
        section_end = len(lines)
        for index in range(section_start + 1, len(lines)):
            if lines[index].startswith("["):
                section_end = index
                break

        replaced = False
        for index in range(section_start + 1, section_end):
            if lines[index].startswith(key_prefix):
                lines[index] = f'{key_prefix}"{value}"'
                replaced = True
                break

        if not replaced:
            insert_at = section_start + 1
            while insert_at < section_end and lines[insert_at].startswith("#"):
                insert_at += 1
            lines.insert(insert_at, f'{key_prefix}"{value}"')

    registry_path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def has_real_prefix_content(prefix: Path) -> bool:
    expected_paths = (
        prefix / "drive_c" / "windows",
        prefix / "drive_c" / "Program Files",
        prefix / "drive_c" / "users",
    )
    return any(path.exists() for path in expected_paths)


def has_bionic_x11_runtime(root: Path) -> bool:
    required_paths = (
        root / "lib" / "wine" / "aarch64-unix" / "winex11.so",
        root / "lib" / "wine" / "aarch64-windows" / "winex11.drv",
        root / "lib" / "wine" / "i386-windows" / "winex11.drv",
    )
    return all(path.exists() for path in required_paths)


def _extract_container_pattern(template_archive: Path, destination: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="wcp-prefix-template-") as temporary_directory:
        temporary_path = Path(temporary_directory)
        raw_tar_path = temporary_path / "pattern.tar"
        extracted_root = temporary_path / "extracted"

        subprocess.run(
            ["zstd", "-d", "-q", "-o", os.fspath(raw_tar_path), os.fspath(template_archive)],
            check=True,
        )

        with tarfile.open(raw_tar_path, "r:") as archive:
            safe_members = []
            for member in archive.getmembers():
                member_path = Path(member.name)
                if any(part.startswith("._") or part == "__MACOSX" for part in member_path.parts):
                    continue
                safe_members.append(member)
            archive.extractall(extracted_root, members=safe_members, filter="fully_trusted")

        extracted_prefix = extracted_root / ".wine"
        if not extracted_prefix.exists():
            raise FileNotFoundError(f"Expected .wine/ inside container pattern archive {template_archive}")

        _copytree_contents(extracted_prefix, destination)


def _apply_lib_wine_overlay(archive_path: Path, destination: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="wcp-lib-wine-overlay-") as temporary_directory:
        temporary_path = Path(temporary_directory)
        raw_tar_path = temporary_path / "overlay.tar"
        extracted_root = temporary_path / "extracted"

        subprocess.run(
            ["zstd", "-d", "-q", "-o", os.fspath(raw_tar_path), os.fspath(archive_path)],
            check=True,
        )

        with tarfile.open(raw_tar_path, "r:") as archive:
            safe_members = []
            for member in archive.getmembers():
                member_path = Path(member.name)
                if any(part.startswith("._") or part == "__MACOSX" for part in member_path.parts):
                    continue
                safe_members.append(member)
            archive.extractall(extracted_root, members=safe_members, filter="fully_trusted")

        _copytree_contents(extracted_root, destination)


def materialize_prefix(
    generated_prefix: Path,
    destination: Path,
    template_archive: Path | None = None,
) -> Path:
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True, exist_ok=True)

    if template_archive is not None:
        if not template_archive.exists():
            raise FileNotFoundError(f"Expected prefix template archive at {template_archive}")
        _extract_container_pattern(template_archive, destination)

    if generated_prefix.exists() and has_real_prefix_content(generated_prefix):
        _copytree_contents(generated_prefix, destination)

    ensure_minimal_prefix(destination)
    _set_registry_string_value(destination / "user.reg", "Software\\Wine\\Drivers", "Graphics", "x11")
    return destination


def _pack_prefix(prefix_dir: Path, output_path: Path) -> None:
    if output_path.exists():
        output_path.unlink()

    with tarfile.open(output_path, "w:xz") as archive:
        archive.add(prefix_dir, arcname=".wine", recursive=True)


def _write_profile(stage_dir: Path, version_name: str, description: str) -> None:
    profile = {
        "type": "Wine",
        "versionName": version_name,
        "versionCode": 1,
        "description": description,
        "files": [],
        "wine": {
            "binPath": "bin",
            "libPath": "lib",
            "prefixPack": "prefixPack.txz",
        },
    }
    (stage_dir / "profile.json").write_text(json.dumps(profile, indent=2) + "\n", encoding="utf-8")


def create_wcp_archive(stage_dir: Path, output_path: Path) -> Path:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        output_path.unlink()

    with tarfile.open(output_path, "w:xz") as archive:
        for item in sorted(stage_dir.iterdir()):
            archive.add(item, arcname=item.name, recursive=True)

    return output_path


def package_wine_tree(
    source_root: Path,
    output_path: Path,
    version_name: str,
    description: str,
) -> Path:
    with tempfile.TemporaryDirectory(prefix="wcp-stage-") as temporary_directory:
        stage_dir = Path(temporary_directory)
        source_root = source_root.resolve()

        required_dir = source_root / "bin"
        if not required_dir.exists():
            raise FileNotFoundError(f"Expected a staged tree with bin/ at {source_root}")

        share_root = source_root / "share"
        default_prefix_dir = share_root / "default_pfx"
        if not default_prefix_dir.exists():
            raise FileNotFoundError(f"Expected share/default_pfx in staged tree at {source_root}")

        _copytree_contents_filtered(source_root, stage_dir, skip_relative_paths={"share"})

        if share_root.exists():
            copied_share_root = stage_dir / "share"
            copied_share_root.mkdir(parents=True, exist_ok=True)
            _copytree_contents_filtered(share_root, copied_share_root, skip_relative_paths={"default_pfx"})

        _normalize_lib_layout(stage_dir)

        _pack_prefix(default_prefix_dir, stage_dir / "prefixPack.txz")

        share_dir = stage_dir / "share"
        if share_dir.exists() and not any(share_dir.iterdir()):
            share_dir.rmdir()

        _write_profile(stage_dir, version_name=version_name, description=description)
        return create_wcp_archive(stage_dir, output_path)


def stage_installed_wine_tree(
    install_root: Path,
    prefix: str,
    exec_prefix: str,
    stage_dir: Path,
    allowed_runtime_bins: set[str] | None = None,
    allowed_wine_arches: set[str] | None = None,
    share_subdirs: set[str] | None = None,
    arm64ec_input_dll_archive: Path | None = None,
) -> Path:
    prefix_root = install_root / prefix.lstrip("/")
    exec_root = install_root / exec_prefix.lstrip("/")
    if not prefix_root.exists():
        raise FileNotFoundError(f"Expected install prefix at {prefix_root}")
    if not exec_root.exists():
        raise FileNotFoundError(f"Expected install exec prefix at {exec_root}")

    stage_dir.mkdir(parents=True, exist_ok=True)

    _copy_selected_bin_entries(
        [prefix_root / "bin", exec_root / "bin"],
        stage_dir / "bin",
        allowed_runtime_bins,
    )

    for directory_name in ("lib", "lib64"):
        candidate = exec_root / directory_name
        if candidate.exists():
            _copytree_contents(candidate, stage_dir / directory_name)

    share_root = prefix_root / "share"
    if share_root.exists():
        if share_subdirs is None:
            _copytree_contents(share_root, stage_dir / "share")
        else:
            _copy_selected_entries(share_root, stage_dir / "share", share_subdirs)

    _normalize_lib_layout(stage_dir)
    if allowed_wine_arches is not None:
        _prune_wine_arches(stage_dir, allowed_wine_arches)
    if arm64ec_input_dll_archive is not None:
        if not arm64ec_input_dll_archive.exists():
            raise FileNotFoundError(f"Expected arm64ec input DLL archive at {arm64ec_input_dll_archive}")
        _apply_lib_wine_overlay(arm64ec_input_dll_archive, stage_dir / "lib" / "wine")
    _ensure_loader_binaries(stage_dir, allowed_runtime_bins)
    if allowed_wine_arches is not None and "aarch64-unix" in allowed_wine_arches:
        _wrap_bionic_wine_launchers(stage_dir, "aarch64-unix")
    return stage_dir


def stage_android_wine_tree(install_root: Path, prefix: str, exec_prefix: str, stage_dir: Path) -> Path:
    return stage_installed_wine_tree(install_root, prefix, exec_prefix, stage_dir)
