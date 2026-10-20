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
   - For CI, store the same private key as the `SPARKLE_ED_PRIVATE_KEY` secret.
   - The Sparkle tools live in `.sparkle/` (generate_appcast, generate_keys,
     sign_update — from the official Sparkle 2.9.5 release).
3. **Appcast host** — the appcast is committed to the repo root and the feed
   URL in `Sources/FBD/Resources/Info.plist` points at
   `https://raw.githubusercontent.com/FisiFla/FBD/main/appcast.xml`.
   **Note**: the feed URL points at the repository root, so the repository has
   to be public for the appcast to be reachable. It is. The committed feed
   still advertises 1.4.0 — the unsigned releases (2.0.0, 2.1.0) cannot
   regenerate it, because `generate_appcast` refuses an ad-hoc-signed app. It
   catches up with the next signed release.

## Release checklist

### 1. Version bump

```sh
make bump-version VERSION=1.1.0        # Info.plist: version + build+1
# Update CHANGELOG.md: move [Unreleased] -> [1.1.0] - YYYY-MM-DD
# Commit: "Release 1.1.0"
git tag v1.1.0 && git push origin v1.1.0   # triggers .github/workflows/release.yml
```

### 2. Build + sign + notarize (CI or local)

Pushing the tag runs `.github/workflows/release.yml`, which:

1. runs `swift test`;
2. builds the universal app (`make app STRICT_UNIVERSAL=1` — a failed
   arm64+x86_64 build fails the release);
3. **if the five Apple secrets are set** (APPLE_CERT_BASE64, APPLE_CERT_PASSWORD,
   APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID): signs inside-out
   (Sparkle XPC services, Autoupdate, Updater.app, the framework, then the app,
   all with `--options runtime --timestamp`, no `--deep`), verifies with
   `codesign --verify --strict`, notarizes, staples, then checks
   `stapler validate` and `spctl -a -vv`;
4. **if `SPARKLE_ED_PRIVATE_KEY` is also set**: regenerates `appcast.xml` from the
   signed zip with Sparkle's `generate_appcast`, attaches it to the release and
   commits it to `main` (a rejected push is only a warning; use the release
   asset). Without the key this step is skipped with a notice — do step 4 below
   by hand;
5. publishes the GitHub Release from the CHANGELOG section.

Without the Apple secrets the release is still created, but as a **prerelease**
whose only asset is `FBD-unsigned.zip`. Gatekeeper blocks it; do not ship it as
a real release.

Manual equivalent (same order, from the repo root):

```sh
make app STRICT_UNIVERSAL=1               # universal build/FBD.app (ad-hoc)
ID="Developer ID Application: <Your Name> (<TEAMID>)"
SP=build/FBD.app/Contents/Frameworks/Sparkle.framework
for x in "$SP"/Versions/*/XPCServices/*.xpc; do
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$ID" "$x"
done
codesign --force --options runtime --timestamp --sign "$ID" "$SP"/Versions/*/Autoupdate "$SP"/Versions/*/Updater.app
codesign --force --options runtime --timestamp --sign "$ID" "$SP"
codesign --force --options runtime --timestamp --sign "$ID" build/FBD.app
codesign --verify --strict build/FBD.app
```

Notarization (Apple ID with app-specific password in `~/.netrc` or env):

```sh
ditto -c -k --keepParent build/FBD.app build/FBD.zip   # name MUST be FBD.zip (release.yml asset)
xcrun notarytool submit build/FBD.zip \
  --keychain-profile "notarytool" --wait
xcrun stapler staple build/FBD.app
xcrun stapler validate build/FBD.app
spctl -a -vv build/FBD.app                              # "accepted, source=Notarized Developer ID"
ditto -c -k --keepParent build/FBD.app build/FBD.zip   # re-zip the stapled app
```

### 3. Create the GitHub Release

`release.yml` creates it from the CHANGELOG section (tag = `v1.0.0` →
`## [1.0.0]`). It uploads `build/FBD.zip` (stapled). Add a `.dmg` too if you
make one.

### 4. Publish the Sparkle appcast

CI does this when `SPARKLE_ED_PRIVATE_KEY` is configured (see above). By hand:

```sh
# After the release exists (asset URL must be live), regenerate the feed:
./.sparkle/generate_appcast \
  --ed-key-file .sparkle/sparkle_private_key \
  --download-url-prefix https://github.com/FisiFla/FBD/releases/download/<TAG>/ \
  <dir-with-FBD.zip>
cp <dir>/appcast.xml .   # feed URL points at the repo-root appcast.xml
git add appcast.xml && git commit -m "appcast: add <VERSION>" && git push
```
The `sparkle:edSignature` is computed over the exact archive, so the feed must
be generated from the final signed, stapled `FBD.zip`; a feed signed from a
different zip fails Sparkle's verification. (`generate_appcast` refuses
ad-hoc-signed apps by design.)

## CI note

`.github/workflows/ci.yml` builds (debug + release), tests and packages a
universal app bundle on every push and PR (`macos-15`, an Apple Silicon
runner). The universal build is strict in CI (`STRICT_UNIVERSAL=1`): there is
no silent fallback to a native-only binary, and the build log is uploaded when
it fails. `.github/workflows/release.yml` runs on `v*` tags as described in
step 2. **The release workflow can only be exercised by pushing a tag**, so
expect the first signed run to need small fixes.

## First-release sanity list

- [ ] `fbdcli auth-token` + curl round trip on a clean machine
- [ ] Virtual display create/destroy (macOS 26+; CG path needs 13–15 test)
- [ ] DDC brightness on a real external monitor (Apple Silicon)
- [ ] Shortcuts shows the FBD intents (`shortcuts list` or the Shortcuts app)
- [ ] `spctl --assess` passes on a fresh download (Gatekeeper)
- [ ] Sparkle update check finds the appcast (`fbdcli http status`-adjacent:
      app menu → Check for Updates)
