# Releasing FBD

End-to-end release flow. Everything except the notarization credentials can
be done locally; the signing certificate and Sparkle keys are the only
external secrets needed.

## Prerequisites (one-time)

1. **Apple Developer ID Application certificate** in your keychain
   (`security find-identity -p codesigning` should list it).
2. **Sparkle signing keys** (EdDSA) — generate once, keep private key safe:
   ```sh
   # From the Sparkle tools directory (or the Sparkle.xcframework's bin):
   #   https://github.com/sparkle-project/Sparkle/tree/master/bin
   ./generate_keys  # prints Ed25519 private key + public key
   ```
   - Public key → `SUPublicEDKey` in Info.plist.
   - Private key → used by `sign_update` when publishing an appcast.
3. **Appcast host** — any static host (GitHub Pages, S3, your NAS).
   `SUFeedURL` in `Sources/FBD/Resources/Info.plist` currently empty = updates
   off. Set it to the appcast URL when the first release is out.

## Release checklist

### 1. Version bump

```sh
# Info.plist: CFBundleShortVersionString (e.g. 0.2.0), CFBundleVersion (build)
# Update CHANGELOG.md: move [Unreleased] -> [0.2.0] - YYYY-MM-DD
# Commit: "Release 0.2.0"
git tag 0.2.0 && git push origin 0.2.0
```

### 2. Build + sign + notarize (local or CI)

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
ditto -c -k --keepParent build/FBD.app FBD-0.2.0.zip
xcrun notarytool submit FBD-0.2.0.zip \
  --keychain-profile "notarytool" --wait
xcrun stapler staple build/FBD.app
```

### 3. Create the GitHub Release

- Upload `FBD-0.2.0.zip` (stapled) + `FBD.dmg` if you make one.
- Paste the CHANGELOG entry.

### 4. Publish the Sparkle appcast

```sh
# From Sparkle bin/: generate_appcast <dir-with-zips>
./generate_appcast --account "Your Name" \
  --ed-key-file sparkle_private_key.pem ~/path/to/releases/
# Point SUFeedURL at the generated appcast.xml; commit + push.
```

## CI note

`.github/workflows/ci.yml` builds/tests/packages on every push (Intel
`macos-15` runner). A release workflow that signs + notarizes would need the
certificate + notary credentials as GitHub secrets — add it once the cert
exists (see Pending in `.ai_infinite_backlog.md`).

## First-release sanity list

- [ ] `fbdcli auth-token` + curl round trip on a clean machine
- [ ] Virtual display create/destroy (macOS 26+; CG path needs 13–15 test)
- [ ] DDC brightness on a real external monitor (Apple Silicon)
- [ ] Shortcuts shows the FBD intents (`shortcuts list` or the Shortcuts app)
- [ ] `spctl --assess` passes on a fresh download (Gatekeeper)
- [ ] Sparkle update check finds the appcast (`fbdcli http status`-adjacent:
      app menu → Check for Updates)
