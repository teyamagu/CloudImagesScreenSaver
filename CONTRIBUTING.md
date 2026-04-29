# Contributing

Thank you for helping improve Cloud Images Screen Saver.

## Environment

- macOS 13+ and Xcode 15+ (for the `.saver` target).
- Swift 5.9+ for SwiftPM (`DropboxAPI` library, tests, `dropbox-api-test`).

## Before you open a pull request

1. **Build the screen saver**

   ```bash
   xcodebuild -project CloudImagesScreenSaver.xcodeproj -scheme CloudImagesScreenSaver -configuration Debug build
   ```

2. **Run tests** (no Dropbox token required for most tests)

   ```bash
   swift test --disable-swift-testing
   ```

   Use `export DROPBOX_APP_KEY=…` and `export DROPBOX_REFRESH_TOKEN=…` only if you are exercising live API tests.

3. **Do not commit secrets** — never add real Dropbox app keys, refresh tokens, `.env` files with secrets, or personal signing assets.

4. **Optional formatting** — if you use SwiftFormat / SwiftLint locally, align with `.swiftformat` and `.swiftlint.yml`.

## CI on GitHub

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs on pushes and pull requests to `main`:

- **Push:** applies SwiftFormat and SwiftLint fixes, runs `swift test --disable-swift-testing`, then commits and pushes any formatting-only changes (only if tests passed).
- **Pull request:** runs `swiftformat --lint` and `swiftlint lint` (no repo writes), then the same tests — fix formatting locally if the check fails.

If the bot cannot push (branch protection), adjust repository settings or apply formatting locally before merging.

## Code of conduct

Keep discussions and reviews respectful and focused on the project.

## License

By contributing, you agree your contributions are licensed under the same **MIT License** as this repository (see [LICENSE](LICENSE)).
