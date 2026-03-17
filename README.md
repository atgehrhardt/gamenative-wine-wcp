# WCP

Builds GameNative-compatible `arm64ec` Wine `.wcp` packages.

This repo is focused on one thing: producing custom Wine packages that GameNative can import and run inside its Bionic container model on Android. The current build path uses GameNative's patched Wine fork and GameNative-style Android/Bionic toolchain setup rather than trying to package a stock WineHQ build directly.

## Current Status

This project is still experimental. The remaining work is mostly runtime compatibility and graphics debugging for specific games.

## Supported Build Path

The supported build path is GitHub Actions.

The main workflow is:

- [`.github/workflows/build-wcp.yml`](/Users/atgehrhardt/Dev/wcp/.github/workflows/build-wcp.yml)

That workflow runs:

- [`scripts/build-gamenative-wine.sh`](/Users/atgehrhardt/Dev/wcp/scripts/build-gamenative-wine.sh)

It:

1. Clones `GameNative/wine`
2. Uses the `wine-11.3` branch by default
3. Downloads the Android NDK, `llvm-mingw`, and `termuxfs`
4. Runs GameNative's arm64ec Android build flow
5. Normalizes the install tree into a `.wcp`
6. Uploads the artifact and publishes a GitHub release

## Triggering A Build

You can start a build from GitHub Actions with either:

- `workflow_dispatch`
- the scheduled run in [`.github/workflows/build-wcp.yml`](/Users/atgehrhardt/Dev/wcp/.github/workflows/build-wcp.yml)

The default source ref is controlled by:

```yaml
env:
  WCP_GN_WINE_REF: wine-11.3
```

## Local Build

GitHub Actions is the primary path, but you can still run the same builder locally:

```bash
bash ./scripts/build-gamenative-wine.sh out
```
