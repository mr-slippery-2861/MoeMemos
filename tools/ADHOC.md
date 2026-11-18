# Personal Ad Hoc builds

Install from **https://adhoc.ummon.tech/** in Safari on a registered device. The site has a separate tab for Moe Memos, Jarvis and VVTerm, with each app's three most recent builds. GitHub login requires access to the existing private `neilc6321/jarvis-ios` artifact repository. The previous `jarvis-install.ummon.tech` address redirects here; already issued install tickets remain usable until expiry.

## Package and publish Moe Memos

```sh
tools/publish-adhoc.sh              # next build number, upload and publish
tools/publish-adhoc.sh 2            # explicit build number (1–9999)
tools/publish-adhoc.sh --export-only AdHoc 2
```

The script snapshots the current working tree, including local source edits, into a private temporary directory. It sets personal signing identifiers only in that copy, archives a Release build, exports an IPA, and verifies the main app, share extension and widgets. It checks the certificate, team, shared container, keychain group, provisioning profile, expiry, build number and all requested UDIDs before publishing. The public source repository never receives the signed IPA or device list. GitHub's uploaded SHA-256 must match before the draft release is published. A failed build retains its temporary directory and logs.

Local inputs (ignored by Git):

- `adhoc-devices.txt`: one UDID per line, or Apple's tab-separated device export. Existing personal devices have been copied from the Jarvis configuration.
- Distribution signing files in `~/Library/Application Support/Jarvis-iOS/signing`: `release.keychain-db`, `keychain-password`, `certificate-id`, `distribution.cer`.
- App Store Connect API configuration in `~/Library/Application Support/Jarvis-iOS/app-store-connect.json` (`key_path`, `key_id`, `issuer_id`). Alternatively set all three `MOEMEMOS_ASC_KEY_PATH`, `MOEMEMOS_ASC_KEY_ID`, `MOEMEMOS_ASC_ISSUER_ID` variables.
- GitHub CLI authentication for `neilc6321`, or a supplied `GH_TOKEN` with access to the private artifact repository.

Defaults: team `H53J58LAD7`; main bundle `tech.ummon.moememos`; extensions `.share` and `.widgets`; App Group `group.tech.ummon.moememos`. Initial Apple Developer setup must assign that group to all three App IDs and enable Journaling Suggestions on the main App ID. The helper registers missing devices and App IDs and creates/reuses Ad Hoc profiles. If capabilities change, invalidate/regenerate their profiles in Apple Developer before the next build.

Optional overrides: `MOEMEMOS_IOS_TEAM_ID`, `MOEMEMOS_ADHOC_BUNDLE_ID`, `MOEMEMOS_ADHOC_SIGNING_DIR`, `MOEMEMOS_ADHOC_DEVICE_FILE`. If changing the main bundle, also update `MOEMEMOS_BUNDLE_ID` in the installer configuration.

## Shared installation site

The canonical installer source is `tools/private-install` in the [Jarvis iOS repository](https://github.com/neilc6321/jarvis-ios). Its README covers deployment and GitHub login configuration. Add future apps to that directory's `apps.mjs`, then publish releases to the same private artifact repository using:

```text
Tag:   <app-id>-v<version>-adhoc.<build>
Asset: <assetName>-<version>-build<build>-AdHoc.ipa
```

The IPA asset must have GitHub's SHA-256 digest. Existing Jarvis releases retain their unprefixed `v<version>-adhoc.<build>` tags. Build numbers increase independently for each app. Existing Jarvis and VVTerm publishers can keep using their current release repository; the shared site discovers their releases automatically.
