#!/bin/zsh
set -eu
setopt PIPE_FAIL

project_root="${0:A:h:h}"
cd "$project_root"
version="${VERSION:-0.4.2}"
output_dir="${BUILD_DIR:-$project_root/build}"
output_dir="${output_dir:A}"
dist_dir="${DIST_DIR:-$project_root/dist}"
dist_dir="${dist_dir:A}"
skip_build=false
for argument in "$@"; do
  case "$argument" in
    --skip-build) skip_build=true ;;
    --help|-h)
      print -- "Usage: ./scripts/package-release.sh [--skip-build]"
      print -- "Creates a Universal .dmg, .zip, SHA256SUMS and release-manifest.json in dist/."
      print -- "Optional: SIGNING_IDENTITY and NOTARY_PROFILE for Developer ID signing/notarization."
      exit 0 ;;
    *) print -u2 -- "Unknown argument: $argument"; exit 2 ;;
  esac
done
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  print -u2 -- "VERSION must have the form 0.4.2."; exit 2
fi
if [[ -n "${NOTARY_PROFILE:-}" && -z "${SIGNING_IDENTITY:-}" ]]; then
  print -u2 -- "NOTARY_PROFILE requires a Developer ID SIGNING_IDENTITY."; exit 2
fi
if ! $skip_build; then "$project_root/build.sh"; fi
source_app="$output_dir/准点点击器.app"
[[ -d "$source_app" ]] || { print -u2 -- "Missing app: $source_app"; exit 1; }
[[ -f docs/INSTALL.md ]] || { print -u2 -- "Missing docs/INSTALL.md"; exit 1; }
for required_architecture in arm64 x86_64; do
  xcrun lipo "$source_app/Contents/MacOS/PunctualClicker" -verify_arch "$required_architecture"
done
actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")
[[ "$actual_version" == "$version" ]] || { print -u2 -- "Built version $actual_version does not match VERSION=$version."; exit 1; }

task_package_stage=$(mktemp -d "${TMPDIR:-/tmp}/punctual-clicker-package.XXXXXX")
trap 'rm -rf "$task_package_stage"' EXIT
mkdir -p "$dist_dir" "$task_package_stage/dmg"
app="$task_package_stage/dmg/准点点击器.app"
ditto --norsrc --noextattr "$source_app" "$app"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp \
    --identifier local.lrc.punctual-clicker "$app"
fi
codesign --verify --deep --strict "$app"
notarized=false
submit_for_notarization() {
  local submitted_file="$1"
  local result_file="$2"
  xcrun notarytool submit "$submitted_file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$result_file"
  local result_status
  result_status=$(/usr/bin/plutil -extract status raw -o - "$result_file")
  if [[ "$result_status" != "Accepted" ]]; then
    print -u2 -- "Notarization was not accepted: $result_status"
    cat "$result_file" >&2
    return 1
  fi
}
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  # Staple the app before making both release formats, so the ZIP is usable offline too.
  ditto -c -k --keepParent --norsrc --noextattr "$app" "$task_package_stage/notarization.zip"
  submit_for_notarization "$task_package_stage/notarization.zip" "$task_package_stage/notary-app.json"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  notarized=true
fi
ln -s /Applications "$task_package_stage/dmg/Applications"
ditto --norsrc --noextattr docs/INSTALL.md "$task_package_stage/dmg/安装说明.md"
asset_base="PunctualClicker-$version-macOS-universal"
dmg="$dist_dir/$asset_base.dmg"
zip="$dist_dir/$asset_base.zip"
# Replacing these generated release assets does not alter installed applications.
rm -f "$dmg" "$zip"
hdiutil create -volname "准点点击器 $version" -srcfolder "$task_package_stage/dmg" -ov -format UDZO "$dmg"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$dmg"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  submit_for_notarization "$dmg" "$task_package_stage/notary-dmg.json"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
ditto -c -k --keepParent "$app" "$zip"
hdiutil verify "$dmg"
(
  cd "$dist_dir"
  shasum -a 256 "$asset_base.dmg" "$asset_base.zip" > SHA256SUMS
)
signature_details=$(codesign -dv --verbose=4 "$app" 2>&1)
if [[ "$signature_details" == *"Signature=adhoc"* ]]; then
  signing_type="ad-hoc"
elif [[ "$signature_details" == *"Authority=Developer ID Application:"* ]]; then
  signing_type="Developer ID Application"
else
  signing_type="code signed (not verified as Developer ID Application)"
fi
xcrun swift "$project_root/scripts/release-manifest.swift" "$dist_dir/release-manifest.json" \
  "$version" "$signing_type" "$notarized" "$dmg" "$zip"
print -- "Release assets: $dist_dir"
print -- "- $asset_base.dmg"
print -- "- $asset_base.zip"
print -- "- SHA256SUMS"
print -- "- release-manifest.json"
if ! $notarized; then
  print -- "This release is not notarized. macOS may require manual first-open approval."
fi
