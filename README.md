# build-config

Build scripts for WitAqua WayDroid, forked from WitAqua-infra/build-config.

- `targets`: what the pipeline builds, one `<device> <variant> <version>` per line.
- `android/generator.py`: turns `targets` into Buildkite steps.
- `android/build.sh`: syncs WitAqua with the
  [WitAqua-WayDroid local manifest](https://github.com/WitAqua-WayDroid/local_manifests),
  builds the waydroid system and vendor images, signs them with the WitAqua-WayDroid keys,
  uploads the zips and publishes them on the
  [OTA channels](https://github.com/WitAqua-WayDroid/ota).
- `android/ota.py`: adds a build to a waydroid OTA channel JSON.

The build host needs rustup (with rustfmt and the Android targets), bindgen-cli and
cbindgen in `~/.cargo/bin` for mesa.
