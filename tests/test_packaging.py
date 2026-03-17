from __future__ import annotations

import shutil
import subprocess
import tarfile
from pathlib import Path

import pytest

from wcp_builder.packaging import materialize_prefix, stage_installed_wine_tree


def _write_zstd_tar(path: Path, entries: dict[str, str]) -> None:
    raw_tar_path = path.with_suffix("")
    with tarfile.open(raw_tar_path, "w:") as archive:
        for archive_name, contents in entries.items():
            temp_path = raw_tar_path.parent / archive_name.replace("/", "_")
            temp_path.parent.mkdir(parents=True, exist_ok=True)
            temp_path.write_text(contents, encoding="utf-8")
            archive.add(temp_path, arcname=archive_name)
            temp_path.unlink()

    subprocess.run(["zstd", "-q", "-o", str(path), str(raw_tar_path)], check=True)
    raw_tar_path.unlink()


@pytest.mark.skipif(shutil.which("zstd") is None, reason="zstd is required for container pattern tests")
def test_materialize_prefix_uses_template_when_generated_prefix_is_empty(tmp_path: Path) -> None:
    template_archive = tmp_path / "pattern.tzst"
    _write_zstd_tar(
        template_archive,
        {
            ".wine/system.reg": "WINE REGISTRY Version 2\n\n[System]\n",
            ".wine/drive_c/windows/win.ini": "[windows]\n",
            ".wine/drive_c/users/Public/Desktop/readme.txt": "hello\n",
        },
    )

    generated_prefix = tmp_path / "generated"
    generated_prefix.mkdir()

    destination = tmp_path / "result"
    materialize_prefix(generated_prefix, destination, template_archive)

    assert (destination / "drive_c" / "windows" / "win.ini").exists()
    assert (destination / "drive_c" / "users" / "Public" / "Desktop" / "readme.txt").exists()


@pytest.mark.skipif(shutil.which("zstd") is None, reason="zstd is required for container pattern tests")
def test_materialize_prefix_overlays_real_generated_prefix(tmp_path: Path) -> None:
    template_archive = tmp_path / "pattern.tzst"
    _write_zstd_tar(
        template_archive,
        {
            ".wine/system.reg": "template\n",
            ".wine/drive_c/windows/win.ini": "template\n",
        },
    )

    generated_prefix = tmp_path / "generated"
    (generated_prefix / "drive_c" / "windows").mkdir(parents=True)
    (generated_prefix / "drive_c" / "users" / "tester").mkdir(parents=True)
    (generated_prefix / "system.reg").write_text("generated\n", encoding="utf-8")

    destination = tmp_path / "result"
    materialize_prefix(generated_prefix, destination, template_archive)

    assert (destination / "drive_c" / "windows").exists()
    assert (destination / "drive_c" / "users" / "tester").exists()
    assert (destination / "system.reg").read_text(encoding="utf-8") == "generated\n"
    assert '"Graphics"="x11"' in (destination / "user.reg").read_text(encoding="utf-8")


@pytest.mark.skipif(shutil.which("zstd") is None, reason="zstd is required for container pattern tests")
def test_stage_installed_wine_tree_applies_arm64ec_input_dll_overlay(tmp_path: Path) -> None:
    install_root = tmp_path / "install"
    prefix_root = install_root / "opt" / "wine-test"
    stage_root = tmp_path / "stage"
    runtime_dir = prefix_root / "lib" / "wine"

    (prefix_root / "bin").mkdir(parents=True)
    (runtime_dir / "aarch64-unix").mkdir(parents=True)
    (runtime_dir / "aarch64-windows").mkdir(parents=True)
    (runtime_dir / "i386-windows").mkdir(parents=True)

    (prefix_root / "bin" / "wine").write_text("launcher\n", encoding="utf-8")
    (runtime_dir / "aarch64-unix" / "wine").write_text("runtime\n", encoding="utf-8")
    (runtime_dir / "aarch64-unix" / "wine-preloader").write_text("preloader\n", encoding="utf-8")
    (runtime_dir / "aarch64-windows" / "dinput.dll").write_text("original-arm\n", encoding="utf-8")
    (runtime_dir / "i386-windows" / "dinput.dll").write_text("original-x86\n", encoding="utf-8")

    overlay_archive = tmp_path / "arm64ec_input_dlls.tzst"
    _write_zstd_tar(
        overlay_archive,
        {
            "aarch64-windows/dinput.dll": "patched-arm\n",
            "i386-windows/dinput.dll": "patched-x86\n",
        },
    )

    stage_installed_wine_tree(
        install_root,
        "/opt/wine-test",
        "/opt/wine-test",
        stage_root,
        allowed_runtime_bins={"wine", "wine-preloader"},
        allowed_wine_arches={"aarch64-unix", "aarch64-windows", "i386-windows"},
        arm64ec_input_dll_archive=overlay_archive,
    )

    assert (stage_root / "lib" / "wine" / "aarch64-windows" / "dinput.dll").read_text(encoding="utf-8") == "patched-arm\n"
    assert (stage_root / "lib" / "wine" / "i386-windows" / "dinput.dll").read_text(encoding="utf-8") == "patched-x86\n"
