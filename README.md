# Uninstall

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

**Latest release:** v<!-- version -->1.0<!-- /version --> · [Download](https://github.com/L-K-M/Uninstall/releases/latest)

Uninstall is a native macOS app for reviewing installed apps and moving them to the Trash. Sort by total size or last opened, select an app, and choose **Remove App Only** or **Remove App and Selected Files**. The confirmation sheet lists the paths that will be moved. When moving the app bundle requires administrator access, macOS handles authentication.

Select multiple apps to remove them in one batch, quit a running app and remove it in one step, and use **Undo** in the status bar to put a fresh removal back from the Trash. Row context menus offer Reveal in Finder and Copy Path, and the scan menu can export the app list as CSV.

## Run locally

Open `Uninstall.xcodeproj` in Xcode and run the **Uninstall** scheme on your Mac, or build it with `scripts/build.sh`. Requires macOS 14 or later. Run the scheme’s tests with **Product → Test**. `scripts/release.sh` cuts a version tag whose CI build publishes the unsigned macOS zip and DMG.

## What it measures

Uninstall scans `/Applications`, `~/Applications`, and `/System/Applications`, including apps in subfolders. It uses Spotlight’s last-used date and locally stores launch dates for installed apps it sees running. Apps with neither date show **Unknown**.

The size column estimates allocated disk space for the app bundle and related files identified by bundle ID in the current user’s Library. For protected apps, Uninstall measures the app bundle. Choose **Scan Including App Containers** in the scan menu to measure those folders for removable apps. macOS may prompt for access. Inaccessible files are marked as unavailable, and incomplete totals are shown as lower bounds.

Preferences, application support, and containers are optional selections in the removal review. Caches and logs are preselected. Group containers are excluded, and cleanup is disabled for files shared by duplicate installations in the scanned locations. Some apps use custom locations that a bundle-ID scan cannot identify. Uninstall shows a vendor uninstaller when it finds a matching one next to the app.

Files moved to Trash can be restored from there. Their disk space becomes available after the Trash is emptied.

## License

Uninstall's own code is released into the public domain under the [Unlicense](LICENSE). The app bundles no third-party code, so its artifacts ship no third-party notices.
