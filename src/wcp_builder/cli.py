from __future__ import annotations

import argparse
import json

from .releases import discover_latest_releases


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wcp-builder")
    subparsers = parser.add_subparsers(dest="command", required=True)

    discover_parser = subparsers.add_parser("discover", help="Print the latest official stable Wine release metadata.")
    discover_parser.add_argument("--format", choices=("json", "github-output"), default="json")

    return parser


def _command_discover(output_format: str) -> int:
    releases = {name: info.to_json_dict() for name, info in discover_latest_releases().items()}
    if output_format == "json":
        print(json.dumps(releases, indent=2, sort_keys=True))
        return 0

    print(f"wine_version={releases['wine']['version']}")
    print(f"wine_tag={releases['wine']['tag']}")
    print(f"wine_url={releases['wine']['url']}")
    return 0


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    if args.command == "discover":
        return _command_discover(args.format)

    parser.error(f"Unhandled command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
