# Merge Request Monitor

Menu-bar macOS app that shows your authored open merge requests, pipeline stages, and approvals.

## Using the app

### Install

Download on the app store: https://apps.apple.com/gb/app/id6820492677?mt=12

Run, and look for the app in the status bar.

### Direct download

1. Go to https://github.com/georgegillams/merge-request-monitor/releases/
1. Download and extract the latest zip
1. Copy the app to `/Applications` and run it
1. Look for the app in the status bar.

## Features

- Menu-bar icon with a popover listing your open MRs
- Pipeline stage status icons (passed, paused, failed, cancelled, unknown)
- Approval counts and approver names
- Multiple GitLab instances (URL + bearer token; tokens in Keychain)
- Launch at login
- Manual refresh and last-updated timestamp
- Greys out data older than 5 minutes

## Requirements

- macOS 13.3+
- Xcode 15+
- GitLab personal access token with `read_api` (or `api`) scope

## Run

1. Open `MergeRequestMonitor.xcodeproj` in Xcode.
2. Select the **Merge Request Monitor** scheme and Run.
3. Click the menu-bar icon → Settings → add your GitLab URL and token.

## Token storage

Personal access tokens are stored in the macOS data protection Keychain. They are not written to UserDefaults or the login keychain.

- Readable only while this Mac is unlocked.
- Not synced through iCloud Keychain, and excluded from backups.
- On a Mac with a login password, stored so that removing that password deletes them. A Mac with no password uses the strongest class macOS allows instead: this device only, while unlocked.

Instance URLs and labels stay in app settings. Only the tokens go in the Keychain.

## Design tokens

UI colors come from [components-swiftUI](https://github.com/georgegillams/components-swiftUI) (`Semantic.Colors`, `Primitive.Layout`).

## Release

### App Store (App Store Connect)

- Update version (marketing version) and build (needs incrementing). In Xcode: select **Merge Request Monitor** target → **General** → **Identity** → **Version** / **Build**
- Take screenshots at 1280×800
- Clean
- Create build online at https://appstoreconnect.apple.com/
- Select non-debug scheme
- Archive
- Upload

Release archives use `MergeRequestMonitor-Release.entitlements` (App Sandbox enabled, with network client). No manual entitlements changes are needed before upload.

### Manual distribution (GitHub Releases)

1. In Xcode, select the **Merge Request Monitor** scheme and **Any Mac (Mac Catalyst)** / **My Mac** as appropriate.
1. Update **Version** / **Build** (see App Store steps above).
1. Product → **Archive**.
1. In the Organizer, select the archive → **Distribute App** → **Direct Distribution**
1. After notarization completes, in the table row, select **Export** to export `Merge Request Monitor.app`.
1. Zip the app for distribution (Finder: right click `Merge Request Monitor.app` → **Compress**) and name it like `Merge-Request-Monitor-<version>.zip`.
1. Revert XCode build target to **Merge Request Monitor** → **My Mac**.
1. In GitHub: go to the [releases page](https://github.com/georgegillams/merge-request-monitor/releases/) and click **Draft a new release**.
1. Choose a tag (create one if needed) like `<version>`, set the release title, and write release notes.
1. Under **Assets**, upload `Merge-Request-Monitor-<version>.zip`.
1. Click **Publish release**.
