#!/usr/bin/env bash
# Builds the C interface for Apple platforms and packs it as one XCFramework:
#
#   capi/build-apple.sh [--keyring]   ->  build/apple/LicenseWorker.xcframework
#
#   ios-arm64                      iPhone and iPad
#   ios-arm64_x86_64-simulator     the iOS Simulator on Apple silicon and Intel Macs
#   macos-arm64_x86_64             macOS, universal (apps, AU/VST3/AAX/CLAP plugins)
#
# Static libraries, with license_worker.h and a module map (C, C++, Objective-C,
# and Swift's `import LicenseWorker`). Needs Xcode and the five Rust targets:
#   rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin
# Deployment targets: IPHONEOS_DEPLOYMENT_TARGET (default 13.0), MACOSX_DEPLOYMENT_TARGET (default 11.0).
set -euo pipefail
cd "$(dirname "$0")/.."

features=()
[[ "${1:-}" == "--keyring" ]] && features=(--features keyring)
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-13.0}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
out=build/apple
lib=liblicense_worker.a

for t in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin; do
  echo "== $t"
  cargo rustc -q --release -p license-worker-client-capi --target "$t" --crate-type staticlib ${features[@]+"${features[@]}"}
done

rm -rf "$out"
mkdir -p "$out/ios" "$out/ios-sim" "$out/macos" "$out/headers"
cp target/aarch64-apple-ios/release/$lib "$out/ios/$lib"
lipo -create target/aarch64-apple-ios-sim/release/$lib target/x86_64-apple-ios/release/$lib -output "$out/ios-sim/$lib"
lipo -create target/aarch64-apple-darwin/release/$lib target/x86_64-apple-darwin/release/$lib -output "$out/macos/$lib"

cp capi/include/license_worker.h "$out/headers/"
cat > "$out/headers/module.modulemap" <<'MAP'
module LicenseWorker {
    header "license_worker.h"
    link "license_worker"
    export *
}
MAP

xcodebuild -create-xcframework \
  -library "$out/ios/$lib" -headers "$out/headers" \
  -library "$out/ios-sim/$lib" -headers "$out/headers" \
  -library "$out/macos/$lib" -headers "$out/headers" \
  -output "$out/LicenseWorker.xcframework" >/dev/null

echo "built $out/LicenseWorker.xcframework"
find "$out/LicenseWorker.xcframework" -name "$lib" -exec lipo -info {} \;
