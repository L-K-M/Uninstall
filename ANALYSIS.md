# Uninstall: future work

Actionable follow-up work from source, test, runtime, accessibility and filesystem review. Preserve the existing Trash-first flow, explicit confirmation, and identity checks. Fetch current main and inspect open pull requests before starting an item. Notes such as “branch work” or a PR number mark partially implemented items; keep them so the reasoning survives.

Baseline measurements from 2026-11-27 on one Mac: 92 apps were discovered in about 0.15 s; warm-cache serial measurement of all apps took about 4 s, with Xcode alone contributing about 3 s; the first cold application scan consumed roughly 25 s of CPU. Treat those as directional data, not universal targets.

## In flight

These bounded fixes have open pull requests and should not be duplicated. Remove this section and any completed entries after the PRs are merged or closed:

- PR #4: allow verified related files to be removed even when recursive measurement is incomplete.
- PR #10: update the removed row locally after successful removal instead of immediately rescanning everything.
- PR #12: show per-item and total selected sizes in the removal confirmation.
- PR #13: batch scan-measurement updates to reduce table churn.
- PR #16: add Command-F search focus, path search, clear search, and preserve selection while filtering.
- PR #17: prevent the XCTest host application from scanning the real host system during unit tests.
- PR #20 (core hardening and performance, this pass): parallel per-app metadata resolution in discovery (Spotlight last-used lookup was serial), adaptive footprint-measurement concurrency (4-8 by cores instead of fixed 3), scan-token guard so a cancelled scan cannot leave `isScanning` stuck, status message cleared on refresh, persisted `observedLaunches` pruned to known apps, running helpers whose bundle URL is inside the app bundle count as in-use, vendor uninstallers bundled in `Contents/` detected (validated via `Info.plist`, avoiding a Launch Services race with concurrent `Bundle(url:)`). CI green; GLM review completed with no findings. Overlaps PR #5/#8 (concurrency, off-main work) — reconcile on merge.
- PR #27 (UI overhaul, batch removal, undo, this pass): NavigationSplitView shell, segmented persisted sort picker with direction toggle, search field with clear button and path matching, row badges (running/protected/duplicate/vendor-uninstaller/not-opened-in-a-year), detail identity header with version and bundle ID, colored storage breakdown bar with legend, related files grouped by category with per-category master toggles and Select All/None/Defaults, multi-select batch removal sheet with total reclaimable size, quit-and-remove for running apps, Trash-location capture per moved item with status-bar Undo and a bounded persisted removal history plus lifetime total in About, row context menu (Reveal in Finder, Copy Name, Copy Path, Open Vendor Uninstaller, Remove Selected), CSV export via save panel, menu commands (Cmd+R, Cmd+Shift+R, Cmd+F, Cmd+E, Delete, About), generated `AppIcon` asset catalog, About panel, background actor icon cache (`AppIconCache`) instead of synchronous `NSWorkspace.icon(forFile:)` in row bodies. CI green; GLM review completed with no findings. Overlaps PRs #8, #11, #14, #18, #19, #23, #25 — reconcile on merge.

Overlapping work from another pass at this review (open PRs, reconcile on merge rather than duplicating):

- PR #8: discovery/measurement off the main actor, stable row order while measuring, icon cache, selected app first, local row removal after a move.
- PR #19: storage breakdown bar with accessible summary, relative last-opened dates, running/duplicate/protected badges, related-file select all/none and sizes, confirmation item count/total bytes, Reveal in Finder.
- PR #22: opt-in launch agents, preference panes, plug-ins and diagnostics categories; non-allowlist bundle-identifier path check; unexpected `lstat` errno marks the inventory incomplete.

Additional open pull requests from this review pass (also reconcile on merge):

- PR #5: measurement concurrency 3→4, selected app measured first, name order held while size/last-opened sorts would churn rows, and cached workspace icons.
- PR #7: accept valid bundle-ID characters beyond `[A-Za-z0-9.-]`; treat every `lstat` failure except ENOENT as an unremovable unavailable item instead of silence.
- PR #11: explicit Move to Trash / App Only actions, Select All/None for related files, pre-review selected-size caption, item-count/size summary in the sheet, and a post-removal banner with Open Trash.
- PR #14: allocation bar with App/Selected/Other legend, risk-grouped related files, and checkbox labels using the path's last component.
- PR #18: filter menu (All/Removable/Has Related Files/Running/Protected), running dot, path search, and a detail-pane Reveal in Finder button.
- PR #23: real app icon asset catalog with a continuous-curvature squircle, four-stop gradient, depth effects, and simplified 16/32px bin mark.
- PR #25: Command-R / Command-Shift-R scan shortcuts, Command-F search focus, and a checkmark on the active sort item.

Open pull requests from this consolidation pass, all CI green but unmerged (reconcile on merge):

- PR #9: real app icon asset catalog and Resources build phase (overlaps the icon work in #23 and #27).
- PR #15: per-item and total reclaimable sizes in the detail pane, review sheet and success status, plus honest lower-bound copy (overlaps #11, #12 and #19).
- PR #21: exact-match leftover locations for LaunchAgents, Preferences directories, Application Scripts plists, PreferencePanes, Internet Plug-ins and Quick Look generators, with decoy and hard-link tests (overlaps #7 and #22).
- PR #24: sentinel-based authorized-move result parsing, distinct cancellation token and name-limit-safe fallback name, with tests (addresses the administrator lifecycle bullet below).
- PR #26: Show in Trash action that opens the Trash window and reports failure instead of failing silently (overlaps #11 and #19).
- PR #28: row context actions for Open, Reveal in Finder, Copy Path and graceful Quit, disabled during removal and hidden for protected apps (overlaps #18, #19 and #27).

## Correctness and safety

- **Make duplicate-detection scope explicit and expandable.** Even a complete scan covers only `/Applications`, `~/Applications` and `/System/Applications`; copies in Downloads, other volumes or custom locations can share data. Add custom scan roots with safeguards against nested roots and symlinks, and explain remaining uncertainty before removing related data.
- **Reassess identity verification at the point of moving.** The normal Trash path checks identity before a separate filesystem operation, leaving a time-of-check/time-of-use window. The privileged path is stronger but still security-sensitive. Investigate descriptor-relative or no-follow operations and macOS Trash semantics before changing it; test path substitution races and volume boundaries.
- **Surface skipped paths and discovery errors accurately.** Partly addressed by open PRs #7 and #22 (unexpected `lstat` errno now marks the inventory incomplete and wider bundle IDs are scanned), but `isDirectPath` still silently skips symlinked candidates and inaccessible parents, and unreadable application roots still leave duplicate detection authoritative over a partial inventory. A complete inventory should require either verified absence or a visible reason for omission. Exercise EIO, symlinked Library paths, permissions and unreadable application roots.
- **Handle symlinked applications deliberately.** The scanner ignores `.app` symlinks. On current macOS this can omit cryptex-linked system apps such as Safari, and it can omit user-installed aliases. Either support verified symlinked bundles or show them as skipped rather than pretending they do not exist.
- **Clarify sizes and shared storage.** Allocated blocks are estimates, not guaranteed reclaimable bytes: APFS clones, snapshots, compression and hard links outside the measured tree can change what is actually freed. Hard-link deduplication shared across categories also makes category sizes depend on enumeration order; measure independently for category estimates and deduplicate only for an aggregate, with tests. Directory blocks themselves are not counted, so totals slightly undercount (tests assert file-only sums).
- **Distinguish deferred container scanning from failure.** A container that was intentionally not scanned should not use the same copy or state as an inaccessible or partially measured item. Offer per-app container scanning rather than scanning containers for every app, explain privacy implications, and preserve deferred/inaccessible/partial states in the model.
- **Protect user data against heuristic matching.** Branch work adds opt-in launch-agent, preference-pane, plug-in and diagnostic categories, but bundle-ID paths still miss vendor suites, app-name folders, group containers, UUID-keyed containers, installer receipts, system-wide `/Library` files and nonstandard locations; shared IDs can also overassociate data. Explain the matching rule and consequences near confirmation, consider defaulting all related items off, and test duplicate installations, unknown IDs and custom locations.
- **Surface silently dropped selections.** When a checked related file is not removable (container not scanned, inaccessible), `prepareRemoval` currently drops it from the plan without explanation. Show a hint naming the skipped items and why.
- **Improve running-process handling.** `NSWorkspace.runningApplications` misses helpers, command-line tools, XPC services and launch agents. PR #20 added detection of processes whose bundle URL is inside the app bundle; PR #27 added a quit-and-remove action. Still open: explain which exact app or copy must quit, offer a non-forced quit with force fallback, recheck before removal, and investigate safe helper detection without killing unrelated processes.
- **Re-check running state inside the move loop.** The in-use check happens before the asynchronous move, so an app or sibling copy can launch into the window between the check and the rename/trash operation. Re-verify immediately before each item moves and abort cleanly if the app became active.
- **Verify vendor uninstallers.** A matching `.app` beside the application or inside `Contents/` (the latter added by PR #20) is opened without checking developer identity or vendor relationship. Show its path and signing information and preferably require a same-team or clearly verified match before opening. Also detect `.pkg` and script uninstallers rather than only sibling or bundled `.app` bundles.
- **Disclose multi-user scope.** Cleanup reads only the current user's Library. Removing a shared app can leave other users' caches, preferences and containers behind; say so in review copy before adding any multi-user cleanup.
- **Tighten stale-file semantics.** Device/inode/birthtime catches replacement but not edits that preserve the inode. Decide whether modification time or content version belongs in identity checks, or adjust the “changed after scan” copy so it does not overstate the guarantee.
- **Harden the administrator process lifecycle.** PR #24 replaced exact-output matching with an `UNINSTALL_MOVE_OK` sentinel, added a distinct `UNINSTALL_MOVE_CANCELLED` token, preserved diagnostics and fixed the long-name fallback budget. Still open: timeout/cancellation for ignored authentication prompts, task-cancel-aware process shutdown, naming the app being moved in the authorization prompt, surfacing authentication failures with enough context, and end-to-end tests of the privileged path.
- **Bound local launch history.** PR #20 prunes `observedLaunches` to known app paths; validating recreated apps at nanosecond birthtime precision (instead of whole-second) is still open.
- **Make partial-failure semantics explicit.** The app bundle moves first, then related items one at a time; a mid-list failure leaves earlier items in the Trash while later ones still move. Say so in the confirmation, report per-item outcomes, and consider staging all moves through one authorized helper so a failure does not strand a half-removed app.
- **Queue notices and status instead of overwriting them.** A single optional notice and a single status string mean a second message replaces the first, including during multi-item removals. Keep the most severe message until dismissed, or use a small toast stack.
- **Prune per-app selection state.** `checkedByApp` lives for the whole view and is only cleared by the scan menu, so reinstalled apps inherit old checkbox choices and the dictionary grows. Prune ids absent from `model.rows`, or store selections relative to item identities.
- **Explain protection instead of showing a bare lock.** Protected is currently `readOnly || path.hasPrefix("/System/") || isSelf`; the UI says only “This app is protected.” State which rule applied and what would make removal possible.
- **Keep destructive removal off the main actor.** `AppModel.confirmRemoval` calls synchronous `AppRemoval.perform` inside a plain `Task`, which inherits the main actor, so trashing and `Process.waitUntilExit()` can freeze the UI. Run removal detached and publish results back to the main actor. Measurement already runs off-main through task-group children; preserve that property.
- **Report multi-problem removals in a real list.** Newline-joined problems go into a plain `Alert` that can truncate. Use a small scrollable sheet with monospace paths and a Copy action.

## Performance and interaction

- **Prioritize visible or selected apps during measurement.** Branch work measures the selected app first, but apps are otherwise measured in discovery order and the queue does not reprioritize when selection changes. Reprioritize on change, cancel stale work, and test rapid selection and refresh without stale results.
- **Reduce remaining list churn.** Largely addressed on a branch: rows keep their pre-scan order while measurements land, and an explicit sort applies immediately; PR #13 batches the observable updates themselves. Profile with hundreds of apps, keep keyboard navigation responsive, and preserve honest progress. A per-row “measuring” spinner is still missing (unmeasured rows show “—”).
- **Cache and prepare icons off the critical path.** PR #27 loads icons through a background actor cache (`AppIconCache`) instead of synchronous `NSWorkspace.icon(forFile:)` in row bodies; PR #8 also has branch work caching on the main actor — reconcile on merge. Remaining: prepare icons before rendering where possible and test icon changes after app updates.
- **Speed up discovery and measurement orchestration.** PR #20 resolves per-app metadata (Spotlight last-used, bundle info) concurrently in `discover()` with deterministic order, and raises footprint-measurement concurrency adaptively (4-8 by cores). Per-bundle walks are still serial — see next item.
- **Attack large-bundle measurement cost.** Measuring one huge app dominates wall time because each bundle is walked serially. Investigate `getattrlistbulk` or careful parallel subtree measurement while preserving hard-link and cross-device correctness. Benchmark cold and warm caches.
- **Cache bundle measurements cautiously.** Large app bundles rarely change, while related files change often. A version/identity-aware in-memory or persistent cache could avoid repeated bundle walks, but it needs explicit invalidation and must not present stale cache data as fresh.
- **Deprioritize protected system apps.** They inflate row and measurement counts but cannot be removed. Hide or collapse them by default, lazily measure them, or provide a clear visibility filter.
- **Add scan cancellation and lifecycle ownership.** Scans now run as cancellable tasks off the main actor, and PR #20 made the `isScanning` flag cancellation-safe, but the scan menu still cannot cancel them, and scan lifetime is not tied clearly to the window. Provide cancellation, ensure partial state is coherent, and cancel or finish work deliberately when the window closes.
- **Do not silently drop scan requests.** `refresh()` refuses to run while a removal sheet is open and gives no feedback, so a user-initiated rescan appears to do nothing. Defer it until the sheet closes, explain why it was ignored, or disable the control with a reason.
- **Fix footer accounting.** The status bar reports the filtered row count, so it jumps while typing in search. Show total rows and the filter match count separately.
- **Fix unknown-date sort direction.** The comparator always places unknown last-opening rows at the end, even for “Least Recently Opened”.
- **Support incremental refresh.** Branch work removes moved rows locally instead of rescanning everything. Still needed: re-measure one selected app or container on demand without paying for a full scan.

## Visual design and product ideas

- **Give the detail pane a stronger hierarchy.** PR #27 adds the identity header with version and bundle ID plus Running/Duplicate/Protected/Vendor-uninstaller/stale badges; PR #19 has similar branch work — reconcile on merge. Still missing: source/provenance and the empty-state overview. Test long names, long paths, narrow windows, dark mode, increased contrast and accessibility text sizes.
- **Explain and visualize storage.** PR #27 adds a segmented app-vs-related allocation bar with a colored legend; PRs #14 and #19 have similar bars with accessible labels and a selected-bytes line — reconcile on merge. Remaining: distinct styling/copy for deferred container scans, inaccessible items and partial measurements instead of one generic “couldn’t be measured” state, and showing selected removable bytes separately from estimated totals; never imply Trash has already freed space.
- **Replace the generic empty detail state with a useful overview.** PR #27 adds a multi-selection summary pane. Still open: show scan progress, concise Trash-first safety copy, or defensible largest-candidate shortcuts. Avoid aggregating sizes across apps when shared data makes the total misleading.
- **Make per-file choices easier to understand.** PR #27 adds category grouping, per-category master toggles, Select All/None/Defaults and full paths; PRs #14 and #19 add risk/value grouping, sizes in toggle labels and a removable count/size summary — reconcile on merge. Remaining: expose default choices explicitly and keep destructive actions disabled for protected or unverifiable items.
- **Add state information to rows.** PR #27 adds running/protected/duplicate/vendor-uninstaller/stale badges; PR #18/#19 have similar branch work — reconcile on merge. Still open: incomplete-measurement and container-scan-needed indicators, and a location subtitle for same-name duplicates.
- **Use a denser, more polished table.** PR #27 restyles rows (icon, name, badges) with relative last-opened dates and a segmented persisted sort control. Still open: audit numeric right alignment, vertical density, tooltip coverage, keyboard navigation and VoiceOver row structure.
- **Add macOS conveniences.** PR #27 adds a row context menu (Reveal in Finder, Copy Name, Copy Path, Open Vendor Uninstaller, Remove Selected), CSV export and menu commands (Cmd+R/Cmd+Shift+R/Cmd+F/Cmd+E/Delete/About); PRs #18 and #25 have filter/search/shortcut branch work — reconcile on merge. Still wanted: measure-this-app/container, consistent tooltips, and visible sort/scan state in menus.
- **Provide a factual cleanup receipt.** PR #27 adds a status-bar Undo (put back from the Trash) plus persisted removal records and a lifetime total in About; PR #11 adds a post-removal banner with Open Trash; PR #19 adds the app icon and moved-item count — reconcile on merge. Keep partial failures prominent and avoid celebratory space-saved numbers before the Trash is emptied.
- **Provide a finished app identity.** PR #27 ships a generated `AppIcon` asset catalog (gradient squircle with a trash glyph, all sizes); PR #23 has a more elaborate icon design — reconcile on merge. Still verify the rendered Dock tile, Finder Get Info, dark/light appearances and 16px Finder-sidebar legibility.
- **Support audit and recovery.** PR #27 stores bounded removal records (original + Trash URLs, capped at 100) and can put items back when the original path is free. Still open: a reviewable history UI, retention controls, and designing put-back collision/permission behavior. Do not promise one-click Put Back until collisions, missing files and permissions are designed.
- **Localize deliberately.** Strings are hardcoded. Introduce localization infrastructure and audit fixed sheet/detail layouts for longer translations and larger text.
- **Audit long-text truncation.** Detail header, related-file paths and review-sheet paths need explicit line limits and middle or tail truncation so deep Library paths cannot break layouts at the minimum window width.
- **Add a disable-able delight layer.** Space-reclaimed counter, factual date-based quips only where the data supports them, a subtle celebration above 1 GB, and keyboard power shortcuts. Keep it opt-out for users who dislike whimsy.

## High-value feature backlog

- **Leftover and orphan scanning.** Find files left by apps that are already gone. Use evidence-based confidence labels such as exact bundle ID, vendor prefix, app-name match or user-confirmed evidence; never present heuristic matches as certain.
- **Batch uninstall.** PR #27 lands basic multi-select removal with one confirmation sheet and a total size. Still open: a review queue, per-item failures and safe continuation without losing the queue.
- **Smart cleanup recommendations.** Rank large, unused, duplicate or never-opened apps with factual explanations, not scare copy. (PR #27 adds a not-opened-in-a-year badge; a banner when sorting by size is still open.)
- **Launch-item awareness.** Branch work detects `~/Library/LaunchAgents` (opt-in) but not LaunchDaemons, login items or helper tools; keep expanding evidence and always offer separately reviewable choices with an explanation. Also consider listing system-level leftovers (PrivilegedHelperTools, system-wide `/Library`) read-only with admin-authorized removal.
- **Empty-Trash hand-off.** After a move, offer to open or empty the Trash, and show the moved item count/size. Never describe space as freed before the Trash is emptied. (PRs #11 and #26 add Open Trash affordances; #27 adds Undo.)
- **Settings and audit export.** A settings scene for scan roots, container-scan default and confirm-before-remove, plus CSV/JSON export of the inventory (name, bundle ID, path, size, last opened, related items) for cleanup planning. (PR #27 lands CSV export of the current list.)
- **Persistence for preferences.** Sort order, search text, include-containers choice, filters and last selection reset on launch. Persist them in `UserDefaults` or `@SceneStorage` and restore context on relaunch.
- **Smart selection presets.** One-click “select all removable caches and logs” or “everything over N MB”, built on the existing per-category toggles.
- **Duplicate-app comparison.** Show version, location, size and last-opened date side by side and help the user keep the right copy.
- **Drag-and-drop uninstall.** Accept an app dropped on the window or Dock icon, scan it, and open the standard review flow.
- **Optional system-app filter.** Hide protected Apple apps by default while keeping them searchable and auditable.
- **Version and provenance metadata.** PR #27 shows version and bundle ID in the detail header. Still open: developer/signing status, architecture, installation source hints.
- **Cleanup cockpit.** A concise overview of large unused apps, orphan leftovers and duplicates, each as a review queue rather than automatic deletion.
- **Menu-bar quick glance.** Show scan status or cleanup candidates without opening the main window; never bypass the normal review for destructive actions.
- **First-run explanation.** Three concise panels: everything goes to Trash, related matches are reviewable, and containers require explicit permission.
- **Set-and-forget watchlist.** Let users park apps they intend to remove and notify them when those apps become removable (protected→normal), receive updates, or have been idle; no pestering, and no automatic removal.
- **Approximate storage before/after.** Read `volumeAvailableCapacityKey` before a move and after the Trash is emptied, framed explicitly as approximate and only after emptying.
- **App-health hints.** Factual observations such as unusually large caches, no launch in over a year, duplicate copies with different versions, or missing vendor uninstaller, presented as neutral insights rather than scare copy.
- **Command-line companion.** A small `uninstall list|measure|trash <bundle-id>` tool sharing the same engine for scripting and support workflows, still routing destructive actions through the review model.
- **Migration helper.** Before trashing, optionally export an app's preferences/support files to a chosen folder; clearly opt-in, never folded into the default path.
- **State-aware empty and error views.** Distinguish “no apps found”, “search found nothing”, “a scan root could not be read”, and “permission needed”, each with a retry/reveal action instead of one generic placeholder.

## Validation gaps

- Add tests for enumeration failures, duplicate installations, cancellation and refresh races, partial measurements, unexpected filesystem errors, running-app changes during confirmation, authorization failures and administrator-process timeouts. (PR #20 added concurrent-discovery and bundled/sibling/symlinked-uninstaller tests; PR #27 added batch-move with Trash-location capture, put-back round-trip and refusal cases, and history accounting — 14/14 passing locally.)
- Add UI tests or previews for keyboard access, VoiceOver, resizing, long text, large dynamic type, light/dark mode and increased contrast.
- Test real APFS volumes, external volumes, permissions, symlinked installation roots and a disposable app rather than moving real user data.
- Verify signed distribution, notarization, app icon rendering at all sizes (Dock, Finder, small sizes), privacy prompts and the administrator path on a clean supported macOS installation before release.
- Add performance regression coverage around full-scan duration, cold versus warm cache, and large-bundle measurement.

## Considered and deliberately deferred

- Permanent or secure deletion with typed confirmation: powerful but raises the cost of mistakes for little gain while Trash exists.
- Automatic background scanning, scheduled cleanups and a menu-bar daemon: scope creep for a focused utility unless the menu-bar feature stays read-only.
- Cross-volume and File Provider/iCloud-aware sizing: easy to get wrong; current “incomplete” labelling is honest.
- Group-container cleanup: intentionally excluded because containers are shared; revisit only with per-app ownership data.
- Kernel extensions, system extensions and script leftovers outside exact matches: too risky for this threat model.
