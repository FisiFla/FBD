# Releasing FBD

End-to-end release flow. Everything except the notarization credentials can
be done locally; the signing certificate and Sparkle keys are the only
external secrets needed.

## Prerequisites (one-time)

1. **Apple Developer ID Application certificate** in your keychain
   (`security find-identity -p codesigning` should list it).
2. **Sparkle signing keys** (EdDSA) — already generated for this project
   (1.0.0):
   - Public key → `SUPublicEDKey` in `Sources/FBD/Resources/Info.plist`.
   - Private key → `.sparkle/sparkle_private_key` (gitignored, chmod 600).
     **Keep it safe** — every future appcast must be signed with it. Back it
     up off-machine. If you ever need to regenerate: Sparkle's
     `generate_keys` (Keychain-based) or `openssl genpkey -algorithm ED25519`
     → base64 of the raw 32-byte seed (see `.sparkle/` for the format).
   - The Sparkle tools live in `.sparkle/` (generate_appcast, generate_keys,
     sign_update — from the official Sparkle 2.9.5 release).
3. **Appcast host** — the appcast is committed to the repo root and the feed
   URL in `Sources/FBD/Resources/Info.plist` points at
   `https://raw.githubusercontent.com/FisiFla/FBD/main/appcast.xml`.
   **Note**: raw.githubusercontent 404s while the repo is private — decide
   before the first release whether to make the repo public at release time
   or host the appcast elsewhere.

## Release checklist

### 1. Version bump

```sh
make bump-version VERSION=1.1.0        # Info.plist: version + build+1
# Update CHANGELOG.md: move [Unreleased] -> [1.1.0] - YYYY-MM-DD
# Commit: "Release 1.1.0"
git tag v1.1.0 && git push origin v1.1.0   # triggers .github/workflows/release.yml
```

### 2. Build + sign + notarize (local or CI)

The release workflow does this automatically **if the five secrets are set**
(APPLE_CERT_BASE64, APPLE_CERT_PASSWORD, APPLE_ID,
APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID). Without them it uploads an
unsigned artifact instead — Gatekeeper will block that download, so add the
secrets before tagging a real release. Manual equivalent:

```sh
make app                                  # universal build/FBD.app (ad-hoc)
# Sign with the Developer ID cert:
codesign --force --options runtime \
  --sign "Developer ID Application: <Your Name> (<TEAMID>)" \
  build/FBD.app/Contents/Frameworks/Sparkle.framework
codesign --force --options runtime \
  --sign "Developer ID Application: <Your Name> (<TEAMID)>" \
  --deep build/FBD.app
# Verify:
codesign --verify --deep --strict build/FBD.app
spctl --assess --type execute build/FBD.app   # "accepted" after notarization
```

Notarization (Apple ID with app-specific password in `~/.netrc` or env):

```sh
ditto -c -k --keepParent build/FBD.app build/FBD.zip   # name MUST be FBD.zip (release.yml asset)
xcrun notarytool submit build/FBD.zip \
  --keychain-profile "notarytool" --wait
xcrun stapler staple build/FBD.app
```

### 3. Create the GitHub Release

`release.yml` creates it from the CHANGELOG section (tag = `v1.0.0` →
`## [1.0.0]`). It uploads `build/FBD.zip` (stapled). Add a `.dmg` too if you
make one.

### 4. Publish the Sparkle appcast

```sh
# After the release exists (asset URL must be live), regenerate the feed:
./.sparkle/generate_appcast \
  --ed-key-file .sparkle/sparkle_private_key \
  --download-url-prefix https://github.com/FisiFla/FBD/releases/download/<TAG>/ \
  <dir-with-FBD.zip>
cp <dir>/appcast.xml .   # feed URL points at the repo-root appcast.xml
git add appcast.xml && git commit -m "appcast: add <VERSION>" && git push
```
The initial 1.0.0 appcast is already generated and committed (from an
unsigned archive — generate_appcast refuses ad-hoc-signed apps by design).
**It must be regenerated from the final signed FBD.zip after the release
publishes** — the `sparkle:edSignature` is computed over the exact archive,
so a feed signed from a different zip will fail Sparkle's verification.

## CI note

`.github/workflows/ci.yml` builds/tests/packages on every push (Intel
`macos-15` runner). `.github/workflows/release.yml` runs on `v*` tags:
without the signing secrets it uploads an unsigned artifact and warns; with
them (APPLE_CERT_BASE64, APPLE_CERT_PASSWORD, APPLE_ID,
APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID — see the workflow header) it
codesigns, notarizes, staples and publishes a GitHub Release from the
CHANGELOG section.

## First-release sanity list

- [ ] `fbdcli auth-token` + curl round trip on a clean machine
- [ ] Virtual display create/destroy (macOS 26+; CG path needs 13–15 test)
- [ ] DDC brightness on a real external monitor (Apple Silicon)
- [ ] Shortcuts shows the FBD intents (`shortcuts list` or the Shortcuts app)
- [ ] `spctl --assess` passes on a fresh download (Gatekeeper)
- [ ] Sparkle update check finds the appcast (`fbdcli http status`-adjacent:
      app menu → Check for Updates)
