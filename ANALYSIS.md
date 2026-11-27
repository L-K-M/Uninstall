# Uninstall: future work

Actionable follow-up work from source, test, runtime, accessibility and filesystem review. Preserve the existing Trash-first flow, explicit confirmation, and identity checks. Fetch current main and inspect open pull requests before starting an item.

Baseline measurements from 2026-11-27 on one Mac: 92 apps were discovered in about 0.15 s; warm-cache serial measurement of all apps took about 4 s, with Xcode alone contributing about 3 s; the first cold application scan consumed roughly 25 s of CPU. Treat those as directional data, not universal targets.

## In flight

These bounded fixes have open pull requests and should not be duplicated. Remove this section and any completed entries after the PRs are merged or closed:

- PR #4: allow verified related files to be removed even when recursive measurement is incomplete.
- PR #10: update the removed row locally after successful removal instead of immediately rescanning everything.
- PR #12: show per-item and total selected sizes in the removal confirmation.
- PR #13: batch scan-measurement updates to reduce table churn.
- PR #16: add Command-F search focus, path search, clear search, and preserve selection while filtering.
- PR #17: prevent the XCTest host application from scanning the real host system during unit tests.
- PR #20 (core hardening and performance): parallel per-app metadata resolution in discovery, adaptive footprint-measurement concurrency (4-8 by cores), scan-token guard so a cancelled scan cannot leave `isScanning` stuck, status cleared on refresh, persisted `observedLaunches` pruned to known apps, running helpers inside the app bundle count as in-use, vendor uninstallers bundled in `Contents/` detected. CI green; GLM review completed with no findings.
- PR #27 (UI overhaul, batch removal, undo): NavigationSplitView shell, segmented persisted sort control, search with clear button and path matching, row badges (running/protected/duplicate/vendor/stale), detail identity header with version and bundle ID, storage breakdown bar with legend, related files grouped by category with per-category toggles and select all/none/defaults, multi-select batch removal sheet with total size, quit-and-remove for running apps, Trash-location capture with status-bar Undo and bounded removal history, row context menu (Reveal in Finder, Copy Name/Path, Open Vendor Uninstaller, Remove Selected), CSV export, menu commands, app icon asset catalog, About panel, background icon cache. CI green; GLM review completed with no findings.

## Landed via PR (do not re-propose)

- App icon asset catalog, About panel, copyright in Info.plist (PR #27).
- Icon loading off the main thread via `AppIconCache` (PR #27).
- Parallel discovery metadata pass and adaptive measurement concurrency (PR #20).
- `isScanning` stuck-true fix, status message cleared on refresh, `observedLaunches` pruning by path, helper-process-in-bundle in-use check, bundled `Contents/` uninstaller detection (PR #20).
- `checkedByApp` pruned to current rows, single sort path (PR #27).
- Basic batch uninstall (multi-select + one sheet), basic put-back Undo with persisted history, quit-and-remove, CSV export (PR #27).

## Correctness and safety

- **Make duplicate-detection scope explicit and expandable.** Even a complete scan covers only `/Applications`, `~/Applications` and `/System/Applications`; copies in Downloads, other volumes or custom locations can share data. Add custom scan roots with safeguards against nested roots and symlinks, and explain remaining uncertainty before removing related data.
- **Reassess identity verification at the point of moving.** The normal Trash path checks identity before a separate filesystem operation, leaving a time-of-check/time-of-use window. The privileged path is stronger but still security-sensitive. Investigate descriptor-relative or no-follow operations and macOS Trash semantics before changing it; test path substitution races and volume boundaries.
- **Surface skipped paths and discovery errors accurately.** `isDirectPath` silently skips symlinked candidates and inaccessible parents; unexpected `lstat` errors besides permission errors are treated as absence. A complete inventory should require either verified absence or a visible reason for omission. Exercise EIO, symlinked Library paths, permissions and unreadable application roots.
- **Handle symlinked applications deliberately.** The scanner ignores `.app` symlinks. On current macOS this can omit cryptex-linked system apps such as Safari, and it can omit user-installed aliases. Either support verified symlinked bundles or show them as skipped rather than pretending they do not exist.
- **Clarify sizes and shared storage.** Allocated blocks are estimates, not guaranteed reclaimable bytes: APFS clones, snapshots, compression and hard links outside the measured tree can change what is actually freed. Hard-link deduplication shared across categories also makes category sizes depend on enumeration order; measure independently for category estimates and deduplicate only for an aggregate, with tests. Directory blocks themselves are currently not counted, so totals slightly undercount.
- **Distinguish deferred container scanning from failure.** A container that was intentionally not scanned should not use the same copy or state as an inaccessible or partially measured item. Offer per-app container scanning rather than scanning containers for every app, explain privacy implications, and preserve deferred/inaccessible/partial states in the model.
- **Protect user data against heuristic matching.** Bundle-ID paths miss vendor suites, app-name folders, group containers, launch agents, receipts, system-wide `/Library` files and nonstandard locations; shared IDs can also overassociate data. Explain the matching rule and consequences near confirmation, consider defaulting all related items off, and test duplicate installations, unknown IDs and custom locations.
- **Surface silently dropped selections.** When a checked related file is not removable (container not scanned, inaccessible), the removal plan currently drops it without explanation. Show a hint naming the skipped items and why.
- **Improve running-process handling.** `NSWorkspace.runningApplications` misses helpers, command-line tools, XPC services and launch agents. PR #20 added detection of processes whose bundle URL is inside the app bundle; PR #27 added a quit-and-remove action. Still open: explain which exact app or copy must quit, offer a non-forced quit with force fallback, recheck before removal, and investigate safe helper detection without killing unrelated processes.
- **Verify vendor uninstallers.** A matching `.app` beside the application or inside `Contents/` (added in PR #20) is opened without checking developer identity or vendor relationship. Show its path and signing information and preferably require a same-team or clearly verified match before opening.
- **Disclose multi-user scope.** Cleanup reads only the current user's Library. Removing a shared app can leave other users' caches, preferences and containers behind; say so in review copy before adding any multi-user cleanup.
- **Tighten stale-file semantics.** Device/inode/birthtime catches replacement but not edits that preserve the inode. Decide whether modification time or content version belongs in identity checks, or adjust the “changed after scan” copy so it does not overstate the guarantee.
- **Harden the administrator process lifecycle.** Success currently depends on the combined stdout/stderr exactly equaling `moved`, so any diagnostic can turn a successful move into a reported failure. Use a machine-readable final status or sentinel. Add timeout/cancellation for ignored authentication prompts and make process shutdown respond to task cancellation.
- **Bound local launch history.** PR #20 prunes `observedLaunches` to known app paths; comparing nanosecond birthtime (not whole-second) for recreated apps is still open.

## Performance and interaction

- **Prioritize visible or selected apps during measurement.** Apps are measured in discovery order, so the selected app may wait behind a huge bundle. Reprioritize when selection changes, cancel stale work, and test rapid selection and refresh without stale results.
- **Reduce remaining list churn.** Scan updates are batched in PR #13, but rows can still reorder as sizes arrive. Consider deferring size reordering until the first pass completes or stabilizing rows while the pointer/keyboard is active. Profile with hundreds of apps and preserve honest progress. A per-row “measuring” spinner is still missing (rows show “—”).
- **Attack large-bundle measurement cost.** Measuring one huge app dominates wall time because each bundle is walked serially. Investigate `getattrlistbulk` or careful parallel subtree measurement while preserving hard-link and cross-device correctness. Benchmark cold and warm caches. (Discovery metadata and measurement concurrency were parallelized in PR #20; per-bundle walks are still serial.)
- **Cache bundle measurements cautiously.** Large app bundles rarely change, while related files change often. A version/identity-aware in-memory or persistent cache could avoid repeated bundle walks, but it needs explicit invalidation and must not present stale cache data as fresh.
- **Deprioritize protected system apps.** They inflate row and measurement counts but cannot be removed. Hide or collapse them by default, lazily measure them, or provide a clear visibility filter.
- **Add scan cancellation and lifecycle ownership.** The scan menu can restart work but cannot cancel it, and scan lifetime is not tied clearly to the window. Provide cancellation, ensure partial state is coherent, and cancel or finish work deliberately when the window closes.
- **Support incremental refresh.** Users need a way to re-measure one selected app or container without paying the cost of a full scan.

## Visual design and product ideas

- **Test the new detail pane and rows across environments.** PR #27 added the identity header, badges, storage bar and grouped related files. Still open: test long names, long paths, narrow windows, dark mode, increased contrast and accessibility text sizes.
- **Explain and visualize storage.** PR #27 added a restrained segmented bar for app versus identified related files with a legend. Still open: show selected removable bytes separately from estimated totals inside the bar area, accessible values and uncertainty states; never imply Trash has already freed space.
- **Replace the generic empty detail state with a useful overview.** PR #27 added a multi-selection summary. Still open: show scan progress, concise Trash-first safety copy, or defensible largest-candidate shortcuts. Avoid aggregating sizes across apps when shared data makes the total misleading.
- **Make per-file choices easier to understand.** PR #27 added category grouping, per-category master toggles and select all/none/defaults. Still open: group items by risk or data value, expose default choices more clearly, align sizes. Keep destructive actions disabled for protected or unverifiable items.
- **Add state information to rows.** PR #27 added running/protected/duplicate/vendor-uninstaller/stale badges. Still open: same-name duplicates need a location subtitle or other disambiguation.
- **Audit the denser table.** PR #27 restyled rows with icons and badges. Still open: numeric right alignment, date formatting (relative dates landed), vertical density, tooltip coverage, keyboard navigation and VoiceOver row structure.
- **Add macOS conveniences.** PR #27 added row context menu (Reveal in Finder, Copy Name, Copy Path, Open Vendor Uninstaller, Remove Selected) and menu commands (Cmd+R, Cmd+Shift+R, Cmd+F, Cmd+E, Delete, About). Still open: measure-this-app/container action, consistent tooltips, visible sort/scan state in menus.
- **Provide a factual cleanup receipt.** PR #27 added status-bar Undo and a removal history. Still open: after a move, show the app icon, moved item count and an “Open Trash” action, with partial failures prominent. Avoid celebratory space-saved numbers before Trash is emptied.
- **Support audit and recovery.** PR #27 stores bounded removal records (original + Trash URLs) and can put items back. Still open: a reviewable history UI, retention controls, and designing put-back collision/permission behavior (Undo currently refuses when the original path is taken). Do not promise one-click Put Back until collisions, missing files and permissions are designed.
- **Localize deliberately.** Strings are hardcoded. Introduce localization infrastructure and audit fixed sheet/detail layouts for longer translations and larger text.

## High-value feature backlog

- **Leftover and orphan scanning.** Find files left by apps that are already gone. Use evidence-based confidence labels such as exact bundle ID, vendor prefix, app-name match or user-confirmed evidence; never present heuristic matches as certain.
- **Advanced batch uninstall.** PR #27 landed basic multi-select removal. Still open: a review queue, per-item failures with safe continuation without losing the queue.
- **Smart cleanup recommendations.** Rank large, unused, duplicate or never-opened apps with factual explanations, not scare copy. (A stale-app badge landed in PR #27; a banner when sorting by size is still open.)
- **Launch-item and system-leftover awareness.** Detect matching LaunchAgents, LaunchDaemons, login items, PrivilegedHelperTools and system-wide `/Library` files; explain them and offer separately reviewable choices (admin auth needed to remove).
- **Duplicate-app comparison.** Show version, location, size and last-opened date side by side and help the user keep the right copy.
- **Drag-and-drop uninstall.** Accept an app dropped on the window or Dock icon, scan it, and open the standard review flow.
- **Optional system-app filter.** Hide protected Apple apps by default while keeping them searchable and auditable.
- **Version and provenance metadata.** PR #27 shows version and bundle ID in the detail header. Still open: developer/signing status, architecture, installation source hints.
- **Cleanup cockpit.** A concise overview of large unused apps, orphan leftovers and duplicates, each as a review queue rather than automatic deletion.
- **Menu-bar quick glance.** Show scan status or cleanup candidates without opening the main window; never bypass the normal review for destructive actions.
- **First-run explanation.** Three concise panels: everything goes to Trash, related matches are reviewable, and containers require explicit permission.

## Validation gaps

- Add tests for enumeration failures, duplicate installations, cancellation and refresh races, partial measurements, unexpected filesystem errors, running-app changes during confirmation, authorization failures and administrator-process timeouts. (PR #20 added concurrent-discovery and uninstaller-detection tests; PR #27 added batch-move, put-back and history tests — 14/14 passing locally.)
- Add UI tests or previews for keyboard access, VoiceOver, resizing, long text, large dynamic type, light/dark mode and increased contrast.
- Test real APFS volumes, external volumes, permissions, symlinked installation roots and a disposable app rather than moving real user data.
- Verify signed distribution, notarization, app icon rendering at all sizes (Dock, Finder, small sizes), privacy prompts and the administrator path on a clean supported macOS installation before release.
