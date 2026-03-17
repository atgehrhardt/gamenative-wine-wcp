from __future__ import annotations

import json
import re
import time
import urllib.request
from dataclasses import asdict, dataclass
from typing import Any
from urllib.error import URLError

WINE_TAGS_API = "https://gitlab.winehq.org/api/v4/projects/wine%2Fwine/repository/tags?per_page=100"


@dataclass(frozen=True)
class ReleaseInfo:
    product: str
    version: str
    url: str
    tag: str

    def to_json_dict(self) -> dict[str, Any]:
        return asdict(self)


def _fetch_json(url: str) -> Any:
    last_error: Exception | None = None
    for attempt in range(5):
        request = urllib.request.Request(
            url,
            headers={
                "Accept": "application/json",
                "User-Agent": "wcp-builder/0.1.0",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except URLError as exc:
            last_error = exc
            if attempt == 4:
                break
            time.sleep(2 * (attempt + 1))

    raise RuntimeError(f"Failed to fetch {url}: {last_error}") from last_error


def _version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def discover_latest_wine_stable() -> ReleaseInfo:
    tags = _fetch_json(WINE_TAGS_API)
    stable_tags: list[str] = []

    for entry in tags:
        tag = entry["name"]
        if not re.fullmatch(r"wine-\d+\.\d+", tag):
            continue

        major, minor = _version_key(tag)
        if minor != 0:
            continue

        stable_tags.append(tag)

    if not stable_tags:
        raise RuntimeError("Could not find a stable Wine tag.")

    tag = max(stable_tags, key=_version_key)
    version = tag.removeprefix("wine-")
    major_series = version.split(".", 1)[0] + ".0"
    url = f"https://dl.winehq.org/wine/source/{major_series}/wine-{version}.tar.xz"
    return ReleaseInfo(product="wine", version=version, url=url, tag=tag)


def discover_latest_releases() -> dict[str, ReleaseInfo]:
    wine = discover_latest_wine_stable()
    return {"wine": wine}
