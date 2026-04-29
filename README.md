# Cloud Images Screen Saver (macOS)

A macOS screen saver that lists images under a folder in your Dropbox account, downloads them to a local cache while the saver runs, and shows a random crossfade slideshow.

**This project is not affiliated with Dropbox, Inc.** It uses the [Dropbox HTTP API](https://www.dropbox.com/developers/documentation/http/documentation) with **OAuth 2.0 (PKCE)**, **short-lived access tokens**, and a **refresh token** stored in `ScreenSaverDefaults`.

**License:** [MIT](LICENSE). **Contributing:** see [CONTRIBUTING.md](CONTRIBUTING.md). **Security:** see [SECURITY.md](SECURITY.md).

On GitHub, pushes and pull requests to `main` run **CI** ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)): SwiftFormat / SwiftLint (auto-fix + commit on push after tests; lint-only on PRs), then `swift test --disable-swift-testing`.

## Features

- Recursive folder listing (`files/list_folder`) and image download (`files/download`)
- **Image files only:** `.jpg`, `.jpeg`, `.png` (case-insensitive extension match)
- On-disk cache under `~/Library/Application Support/CloudImagesScreenSaver/cache/` or `~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/CloudImagesScreenSaver/cache` (use legacy .saver `ScreenSaverEngine.legacyScreenSaver`)
- Configuration sheet: Dropbox **App key**, browser sign-in (authorization code + PKCE), **refresh token** persistence, Dropbox path (e.g. `/Photos`), slide interval (2–120 seconds)
- `Dropbox-API-Arg` JSON is encoded per Dropbox’s [HTTP header JSON rules](https://www.dropbox.com/developers/reference/json-encoding) (non-ASCII paths supported)
- Downloads use a dedicated `URLSession` (timeouts + `waitsForConnectivity`), `download(for:)` to stream to disk, and a few retries on common `URLError`s (e.g. `-1005` connection lost) instead of `URLSession.shared.data(for:)`

## Requirements

- macOS 13+
- Xcode 15+ (to build the `.saver` bundle)
- Swift 5.9+ (for the SwiftPM tools / tests)

## Dropbox app setup

1. Create an app in the [Dropbox App Console](https://www.dropbox.com/developers/apps).
2. Grant at least **`files.metadata.read`** and **`files.content.read`** (for listing and downloading).
3. In **Options…**, enter the app **key** (client id), click **Open Dropbox…**, approve the app, copy the **authorization code** Dropbox shows (no redirect URI is used—copy-paste flow), paste it, then **Complete sign-in**. The saver stores a **refresh token** and refreshes **short-lived access tokens** before API calls.

**Security note:** Refresh and cached access tokens live in `ScreenSaverDefaults` for this module. Treat them like passwords; do not share your screen saver plist or backups carelessly.

## Install (release build)

```bash
xcodebuild -project CloudImagesScreenSaver.xcodeproj -target CloudImagesScreenSaver -configuration Release build
cp -R build/Release/CloudImagesScreenSaver.saver ~/Library/Screen\ Savers/
```

Then choose **Cloud Images Screen Saver** (or **CloudImagesScreenSaver**) in **System Settings → Screen Saver** and use **Options…** to sign in to Dropbox and set folder.

**Code signing:** The Xcode project uses automatic signing for local builds. For distribution beyond your own Mac, use your Apple Developer Program identity and follow Apple’s current guidance for notarized screen savers.

## Development

### Screen saver target

```bash
xcodebuild -project CloudImagesScreenSaver.xcodeproj -target CloudImagesScreenSaver -configuration Debug build
```

### SwiftPM: Dropbox API smoke test CLI

```bash
export DROPBOX_APP_KEY='your_app_key'
export DROPBOX_REFRESH_TOKEN='your_refresh_token'
# optional: folder on Dropbox (default is root "")
export DROPBOX_TEST_FOLDER='/Photos'
swift run dropbox-api-test
```

### SwiftPM: tests

```bash
export DROPBOX_APP_KEY='…'               # optional live API tests
export DROPBOX_REFRESH_TOKEN='…'         # together with app key
swift test --disable-swift-testing
```

`swift test` alone also launches Swift’s **Swift Testing** runner; this package has no `@Test` cases, so you may see a confusing **“0 tests in 0 suites”** line after the XCTest summary. `--disable-swift-testing` skips that empty pass.

Environment variables:

| Variable | Purpose |
|----------|---------|
| `DROPBOX_APP_KEY` | Dropbox app key (client id) for refresh-based live tests / CLI |
| `DROPBOX_REFRESH_TOKEN` | Refresh token (use with `DROPBOX_APP_KEY`) |
| `DROPBOX_TEST_FOLDER` | Folder path for `list_folder` (default `""` = root) |
| `DROPBOX_TEST_SKIP_DOWNLOAD=1` | Skip download test |

## Project layout

| Path | Description |
|------|-------------|
| `CloudImagesScreenSaver/` | Screen saver bundle sources |
| `CloudImagesScreenSaver/DropboxClient.swift` | Minimal Dropbox API + `DropboxClientError` (also built as SwiftPM library `DropboxAPI`) |
| `CloudImagesScreenSaver/DropboxOAuth.swift` | PKCE + `/oauth2/token` (SwiftPM `DropboxAPI`) |
| `CloudImagesScreenSaver/DropboxScreenSaverOAuth.swift` | Screen saver defaults + token refresh (Xcode target only) |
| `CloudImagesScreenSaver/ScreenSaverSettings.swift` | Defaults keys and clamps (Xcode target only) |
| `CloudImagesScreenSaver/CloudImagesFolderImageLoader.swift` | Background list + download orchestration |
| `Tools/DropboxAPITest/` | Command-line smoke test |
| `Tests/DropboxAPITests/` | XCTest (optional network) |

## License

MIT — see [LICENSE](LICENSE).

Third-party marks (e.g. Dropbox) belong to their respective owners.

---

## 日本語

**Cloud Images Screen Saver** は、macOS 用のスクリーンセイバーです。Dropbox 上の指定フォルダ以下の画像（**`.jpg` / `.jpeg` / `.png` のみ**）を列挙・キャッシュしながらスライド表示します。

- **リポジトリ名（GitHub）:** `CloudImagesScreenSaver`
- **ビルド:** 上記 `xcodebuild` のあと `CloudImagesScreenSaver.saver` を `~/Library/Screen Savers/` へコピー
- **設定:** システム設定のスクリーンセイバー「オプション」で Dropbox の OAuth（App key → ブラウザで認可コード → Complete sign-in）とフォルダパスを指定（バンドル ID 変更後は再設定が必要です）
- **API テスト:** `DROPBOX_APP_KEY` と `DROPBOX_REFRESH_TOKEN` を設定して `swift run dropbox-api-test` / `swift test --disable-swift-testing`（`swift test` だけだと XCTest の後に空の Swift Testing の行が付くことがある）
- **貢献:** [CONTRIBUTING.md](CONTRIBUTING.md) ／ **セキュリティ:** [SECURITY.md](SECURITY.md) ／ **CI:** `main` 向け [GitHub Actions](.github/workflows/ci.yml)（push で整形の自動コミット、PR は lint のみのあとテスト）

ライセンスは **MIT** です（[LICENSE](LICENSE)。Dropbox 社公式製品ではありません）。
