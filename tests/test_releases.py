import unittest
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from wcp_builder import packaging
from wcp_builder import releases
from wcp_builder.releases import _version_key


class VersionKeyTests(unittest.TestCase):
    def test_version_key_orders_wine_tags(self) -> None:
        self.assertGreater(_version_key("wine-11.0"), _version_key("wine-10.0"))

    def test_version_key_handles_release_components(self) -> None:
        self.assertGreater(_version_key("wine-11.2"), _version_key("wine-11.0"))


class DiscoverLatestWineStableTests(unittest.TestCase):
    def test_discovers_latest_stable_wine_tag(self) -> None:
        payload = [
            {
                "name": "wine-11.2",
            },
            {
                "name": "wine-11.0",
            },
            {
                "name": "wine-10.0",
            },
        ]

        original = releases._fetch_json
        releases._fetch_json = lambda url: payload
        try:
            latest = releases.discover_latest_wine_stable()
        finally:
            releases._fetch_json = original

        self.assertEqual(latest.version, "11.0")
        self.assertEqual(latest.tag, "wine-11.0")
        self.assertEqual(latest.url, "https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz")


class StageAndroidWineTreeTests(unittest.TestCase):
    def test_stages_android_install_layout(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            install_root = temp_root / "install-root"
            prefix_root = install_root / "opt" / "wine"
            exec_root = prefix_root / "arm64-v8a"
            (exec_root / "bin").mkdir(parents=True)
            (exec_root / "lib" / "wine").mkdir(parents=True)
            (prefix_root / "share" / "wine").mkdir(parents=True)
            (exec_root / "bin" / "wine").write_text("binary", encoding="utf-8")
            (exec_root / "lib" / "wine" / "wineandroid.drv.so").write_text("driver", encoding="utf-8")
            (prefix_root / "share" / "wine" / "wine.inf").write_text("inf", encoding="utf-8")

            stage_dir = temp_root / "stage"
            packaging.stage_android_wine_tree(install_root, "/opt/wine", "/opt/wine/arm64-v8a", stage_dir)

            self.assertTrue((stage_dir / "bin" / "wine").exists())
            self.assertTrue((stage_dir / "lib" / "wine" / "wineandroid.drv.so").exists())
            self.assertTrue((stage_dir / "share" / "wine" / "wine.inf").exists())


if __name__ == "__main__":
    unittest.main()
