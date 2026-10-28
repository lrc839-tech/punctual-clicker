#!/bin/zsh
set -eu
setopt PIPE_FAIL

project_root="${0:A:h}"
cd "$project_root"
version="${VERSION:-0.4.2}"
build_number="${BUILD_NUMBER:-8}"
output_dir="${BUILD_DIR:-$project_root/build}"
output_dir="${output_dir:A}"
install_requested=false
for argument in "$@"; do
  case "$argument" in
    --install) install_requested=true ;;
    --help|-h)
      print -- "Usage: ./build.sh [--install]"
      print -- "Builds a self-contained Universal macOS app in build/."
      print -- "--install also copies it to ~/Applications/准点点击器/."
      print -- "Optional environment: VERSION, BUILD_NUMBER, BUILD_DIR, SIGNING_IDENTITY."
      exit 0 ;;
    *) print -u2 -- "Unknown argument: $argument"; exit 2 ;;
  esac
done
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 -- "VERSION must have the form 0.4.2."; exit 2
fi
for command_name in xcrun ditto codesign lipo; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    print -u2 -- "Missing build tool: $command_name (install Apple Command Line Tools)."; exit 1
  fi
done
if [[ ! -f Sources/CalibrationServer.swift ]]; then
  print -u2 -- "Missing Sources/CalibrationServer.swift; the standalone app requires the native calibration server."; exit 1
fi
if [[ ! -f Calibration/index.html ]]; then
  print -u2 -- "Missing Calibration/index.html."; exit 1
fi

# Sign outside the Documents file-provider tree. FinderInfo can otherwise be
# reattached while compiling, invalidating the distributable app bundle.
task_build_stage=$(mktemp -d "${TMPDIR:-/tmp}/punctual-clicker-build.XXXXXX")
trap 'rm -rf "$task_build_stage"' EXIT
app="$task_build_stage/准点点击器.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Calibration" "$output_dir"
sources=(Sources/*.swift)
for architecture in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "${architecture}-apple-macosx13.0" \
    -parse-as-library "${sources[@]}" -o "$task_build_stage/PunctualClicker-$architecture" \
    -framework AppKit -framework ApplicationServices -framework Network
done
xcrun lipo -create "$task_build_stage/PunctualClicker-arm64" "$task_build_stage/PunctualClicker-x86_64" \
  -output "$app/Contents/MacOS/PunctualClicker"
for required_architecture in arm64 x86_64; do
  xcrun lipo "$app/Contents/MacOS/PunctualClicker" -verify_arch "$required_architecture"
done
ditto --norsrc --noextattr Calibration/index.html "$app/Contents/Resources/Calibration/index.html"
if [[ -f docs/INSTALL.md ]]; then
  ditto --norsrc --noextattr docs/INSTALL.md "$app/Contents/Resources/安装说明.md"
fi
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PunctualClicker</string>
<key>CFBundleIdentifier</key><string>local.lrc.punctual-clicker</string>
<key>CFBundleName</key><string>准点点击器</string>
<key>CFBundleDisplayName</key><string>准点点击器</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>在同一局域网内与 iPhone Safari 校准页通信，测量手机镜像点击的接收延迟。</string>
</dict></plist>
PLIST
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
    --identifier local.lrc.punctual-clicker "$app"
else
  codesign --force --sign - --timestamp=none --identifier local.lrc.punctual-clicker "$app"
fi
codesign --verify --deep --strict "$app"

output_app="$output_dir/准点点击器.app"
if /bin/ps -axo comm= | /usr/bin/grep -F -x "$output_app/Contents/MacOS/PunctualClicker" >/dev/null; then
  print -u2 -- "The output app is running; quit it before rebuilding: $output_app"; exit 1
fi
# Only replace the named generated app; no user reports or other files are touched.
rm -rf "$output_app"
ditto --norsrc --noextattr "$app" "$output_app"
codesign --verify --deep --strict "$output_app"
print -- "Built: $output_app"
print -- "Architectures: $(xcrun lipo -archs "$output_app/Contents/MacOS/PunctualClicker")"
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
  print -- "Signing: ad-hoc; not Developer ID signed and not notarized."
fi

if $install_requested; then
  install_dir="$HOME/Applications/准点点击器"
  install_app="$install_dir/准点点击器.app"
  if /bin/ps -axo comm= | /usr/bin/grep -F -x "$install_app/Contents/MacOS/PunctualClicker" >/dev/null; then
    print -u2 -- "The installed app is running. Quit it, then run ./build.sh --install again."; exit 1
  fi
  mkdir -p "$install_dir"
  rm -rf "$install_app"
  ditto --norsrc --noextattr "$app" "$install_app"
  codesign --verify --deep --strict "$install_app"
  print -- "Installed: $install_app"
fi
