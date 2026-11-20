#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=16.0 \
    -dynamiclib -fobjc-arc -Os -framework Foundation -framework UIKit \
    -Wl,-install_name,@executable_path/Frameworks/IPAWorkshopYouTube.dylib \
    YouTubePatch.m -o "$tmp/YouTubePatch.bin"
/usr/bin/lipo "$tmp/YouTubePatch.bin" -verify_arch arm64

if [[ "${1:-}" == --check ]]; then
    cat > "$tmp/Fixture.c" <<'SOURCE'
int main(void) { return 0; }
SOURCE
    cat > "$tmp/Check.swift" <<'SOURCE'
import Foundation

@main
struct VerifyLoadCommand {
    static func main() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        try YouTubePackagePatch.appendLoadCommand(to: executable)
        do {
            try YouTubePackagePatch.appendLoadCommand(to: executable)
            fatalError("A second identical load command was accepted")
        } catch PatchError.alreadyPatched {}
    }
}
SOURCE
    xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=16.0 \
        -Wl,-headerpad,0x1000 "$tmp/Fixture.c" -o "$tmp/Fixture"
    xcrun swiftc YouTubePackagePatch.swift "$tmp/Check.swift" -o "$tmp/Check"
    "$tmp/Check" "$tmp/Fixture"
    xcrun otool -L "$tmp/Fixture" | grep -F '@executable_path/Frameworks/IPAWorkshopYouTube.dylib'
fi

install -m 644 "$tmp/YouTubePatch.bin" YouTubePatch.bin
