#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh コマンドが見つかりません。GitHub CLI をインストールしてください。" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "error: gh の認証が未設定のようです。`gh auth login` を先に実行してください。" >&2
  exit 1
fi

repo_full="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

plist_path="$repo_root/CloudImagesScreenSaver/Info.plist"
if [[ ! -f "$plist_path" ]]; then
  echo "error: Info.plist が見つかりません: $plist_path" >&2
  exit 1
fi

bundle_version="$(
  /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path" 2>/dev/null \
  || true
)"
if [[ -z "${bundle_version}" ]]; then
  echo "error: CFBundleShortVersionString を読み取れませんでした: $plist_path" >&2
  exit 1
fi

tag="v${bundle_version}"

if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
  echo "error: タグが既に存在します: ${tag}" >&2
  exit 1
fi

if gh release view "${tag}" --repo "${repo_full}" >/dev/null 2>&1; then
  echo "error: GitHub Release が既に存在します: ${tag}" >&2
  exit 1
fi

echo "Release作成対象: repo=${repo_full}, tag=${tag}"

echo "Releaseビルド中..."
xcodebuild -project CloudImagesScreenSaver.xcodeproj -target CloudImagesScreenSaver -configuration Release

saver_bundle_path="$repo_root/build/Release/CloudImagesScreenSaver.saver"
if [[ ! -d "$saver_bundle_path" ]]; then
  echo "error: .saver バンドルが見つかりません: ${saver_bundle_path}" >&2
  exit 1
fi

zip_path="$repo_root/build/Release/CloudImagesScreenSaver-${tag}.zip"
rm -f "$zip_path"

echo ".saver を ZIP 化中..."
(
  cd "$repo_root/build/Release"
  zip -r -y "$zip_path" "CloudImagesScreenSaver.saver"
)

notes_file="$(mktemp)"
{
  echo "Release: ${tag}"
  echo
  echo "Commit: $(git rev-parse --short HEAD)"
  echo "Build (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo
  echo "Changes in this release:"
  git log -1 --pretty=format:'%s%n%n%b'
} > "$notes_file"

echo "Git タグ作成..."
git tag -a "$tag" -m "Release ${tag}"
echo "Git タグ push..."
git push origin "$tag"

echo "GitHub Release 作成..."
gh release create "$tag" "$zip_path" \
  --title "$tag" \
  --notes-file "$notes_file" \
  --repo "$repo_full"

rm -f "$notes_file"

release_url="$(gh release view "$tag" --repo "$repo_full" --json url -q .url)"
echo "完了: ${release_url}"

