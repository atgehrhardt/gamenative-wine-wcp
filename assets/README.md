`proton-9.0-arm64ec_container_pattern.tzst` is copied from the GameNative repository:

- Source: [GameNative](https://github.com/utkarshdalal/GameNative)
- Original path: `app/src/main/assets/proton-9.0-arm64ec_container_pattern.tzst`

The builder uses this tracked asset as the baseline Wine prefix/container pattern for custom Bionic Wine packages in CI, then overlays any real Wine-generated prefix content on top.

`arm64ec_input_dlls.tzst` is also copied from the GameNative repository:

- Source: [GameNative](https://github.com/utkarshdalal/GameNative)
- Original path: `app/src/main/assets/arm64ec_input_dlls.tzst`

GameNative only auto-extracts this asset for its built-in `proton-9.0-arm64ec` package. The builder applies the same overlay to custom arm64ec Wine builds so their staged `lib/wine/` tree matches what GameNative expects at runtime.
