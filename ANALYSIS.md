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

## Correctness and safety

- **Make duplicate-detection scope explicit and expandable.** Even a complete scan covers only `/Applications`, `~/Applications` and `/System/Applications`; copies in Downloads, other volumes or custom locations can share data. Add custom scan roots with safeguards against nested roots and symlinks, and explain remaining uncertainty before removing related data.
- **Reassess identity verification at the point of moving.** The normal Trash path checks identity before a separate filesystem operation, leaving a time-of-check/time-of-use window. The privileged path is stronger but still security-sensitive. Investigate descriptor-relative or no-follow operations and macOS Trash semantics before changing it; test path substitution races and volume boundaries.
- **Surface skipped paths and discovery errors accurately.** Partly addressed by open PRs #7 and #22 (unexpected `lstat` errno now marks the inventory incomplete and wider bundle IDs are scanned), but `isDirectPath` still silently skips symlinked candidates and inaccessible parents, and unreadable application roots still leave duplicate detection authoritative over a partial inventory. A complete inventory should require either verified absence or a visible reason for omission. Exercise EIO, symlinked Library paths, permissions and unreadable application roots.
- **Handle symlinked applications deliberately.** The scanner ignores `.app` symlinks. On current macOS this can omit cryptex-linked system apps such as Safari, and it can omit user-installed aliases. Either support verified symlinked bundles or show them as skipped rather than pretending they do not exist.
- **Clarify sizes and shared storage.** Allocated blocks are estimates, not guaranteed reclaimable bytes: APFS clones, snapshots, compression and hard links outside the measured tree can change what is actually freed. Hard-link deduplication shared across categories also makes category sizes depend on enumeration order; measure independently for category estimates and deduplicate only for an aggregate, with tests.
- **Distinguish deferred container scanning from failure.** A container that was intentionally not scanned should not use the same copy or state as an inaccessible or partially measured item. Offer per-app container scanning rather than scanning containers for every app, explain privacy implications, and preserve deferred/inaccessible/partial states in the model.
- **Protect user data against heuristic matching.** Branch work adds opt-in launch-agent, preference-pane, plug-in and diagnostic categories, but bundle-ID paths still miss vendor suites, app-name folders, group containers, UUID-keyed containers, installer receipts, system-wide `/Library` files and nonstandard locations; shared IDs can also overassociate data. Explain the matching rule and consequences near confirmation, consider defaulting all related items off, and test duplicate installations, unknown IDs and custom locations.
- **Improve running-process handling.** `NSWorkspace.runningApplications` misses helpers, command-line tools, XPC services and launch agents. Explain which exact app or copy must quit, offer a non-forced quit action, recheck before removal, and investigate safe helper detection without killing unrelated processes.
- **Re-check running state inside the move loop.** The in-use check happens before the asynchronous move, so an app or sibling copy can launch into the window between the check and the rename/trash operation. Re-verify immediately before each item moves and abort cleanly if the app became active.
- **Verify vendor uninstallers.** A matching `.app` beside the application is opened without checking developer identity or vendor relationship. Show its path and signing information and preferably require a same-team or clearly verified match before opening.
- **Disclose multi-user scope.** Cleanup reads only the current user's Library. Removing a shared app can leave other users' caches, preferences and containers behind; say so in review copy before adding any multi-user cleanup.
- **Tighten stale-file semantics.** Device/inode/birthtime catches replacement but not edits that preserve the inode. Decide whether modification time or content version belongs in identity checks, or adjust the “changed after scan” copy so it does not overstate the guarantee.
- **Harden the administrator process lifecycle.** Success currently depends on the combined stdout/stderr exactly equaling `moved`, so any diagnostic can turn a successful move into a reported failure. Use a machine-readable final status or sentinel. Add timeout/cancellation for ignored authentication prompts and make process shutdown respond to task cancellation.
- **Name the app in the authorization prompt.** The generic “needs administrator permission” prompt does not say which app is being moved or why. Include the app name/path, and surface authentication failures with enough context to act on them.
- **Bound local launch history.** `observedLaunches` in UserDefaults grows forever and validates recreated apps only at whole-second birthtime precision. Prune stale paths and compare nanosecond birthtime where available.
- **Make partial-failure semantics explicit.** The app bundle moves first, then related items one at a time; a mid-list failure leaves earlier items in the Trash while later ones still move. Say so in the confirmation, report per-item outcomes, and consider staging all moves through one authorized helper so a failure does not strand a half-removed app.
- **Queue notices and status instead of overwriting them.** A single optional notice and a single status string mean a second message replaces the first, including during multi-item removals. Keep the most severe message until dismissed, or use a small toast stack.
- **Explain protection instead of showing a bare lock.** Protected is currently `readOnly || path.hasPrefix("/System/") || isSelf`; the UI says only “This app is protected.” State which rule applied and what would make removal possible.

## Performance and interaction

- **Prioritize visible or selected apps during measurement.** Branch work measures the selected app first, but apps are otherwise measured in discovery order and the queue does not reprioritize when selection changes. Reprioritize on change, cancel stale work, and test rapid selection and refresh without stale results.
- **Reduce remaining list churn.** Largely addressed on a branch: rows keep their pre-scan order while measurements land, and an explicit sort applies immediately; PR #13 batches the observable updates themselves. Profile with hundreds of apps, keep keyboard navigation responsive, and preserve honest progress.
- **Cache and prepare icons off the critical path.** Branch work caches `NSWorkspace` icons by path on the main actor. Remaining: prepare icons before rendering where possible and test icon changes after app updates.
- **Attack large-bundle measurement cost.** Measuring one huge app dominates wall time because each bundle is walked serially. Investigate `getattrlistbulk` or careful parallel subtree measurement while preserving hard-link and cross-device correctness. Benchmark cold and warm caches.
- **Cache bundle measurements cautiously.** Large app bundles rarely change, while related files change often. A version/identity-aware in-memory or persistent cache could avoid repeated bundle walks, but it needs explicit invalidation and must not present stale cache data as fresh.
- **Deprioritize protected system apps.** They inflate row and measurement counts but cannot be removed. Hide or collapse them by default, lazily measure them, or provide a clear visibility filter.
- **Add scan cancellation and lifecycle ownership.** Scans now run as cancellable tasks off the main actor, but the scan menu still cannot cancel them, and scan lifetime is not tied clearly to the window. Provide cancellation, ensure partial state is coherent, and cancel or finish work deliberately when the window closes.
- **Do not silently drop scan requests.** `refresh()` refuses to run while a removal sheet is open and gives no feedback, so a user-initiated rescan appears to do nothing. Defer it until the sheet closes, explain why it was ignored, or disable the control with a reason.
- **Support incremental refresh.** Branch work removes moved rows locally instead of rescanning everything. Still needed: re-measure one selected app or container on demand without paying for a full scan.

## Visual design and product ideas

- **Give the detail pane a stronger hierarchy.** Branch work adds version and Running/Duplicate/Protected badges plus relative dates; still missing are bundle ID, source/provenance and the empty-state overview. Test long names, long paths, narrow windows, dark mode, increased contrast and accessibility text sizes.
- **Explain and visualize storage.** Largely addressed by open PRs #14 and #19: segmented allocation bars with accessible breakdown labels, selected-bytes line, and copy stating figures are allocated-space estimates and the Trash must be emptied. Remaining: distinct styling/copy for deferred container scans, inaccessible items and partial measurements instead of one generic “couldn’t be measured” state.
- **Replace the generic empty detail state with a useful overview.** Show scan progress, concise Trash-first safety copy, or defensible largest-candidate shortcuts. Avoid aggregating sizes across apps when shared data makes the total misleading.
- **Make per-file choices easier to understand.** PRs #14 and #19 add risk/value grouping, sizes in toggle labels, a removable count/size summary and Select All / Select None. Remaining: expose default choices explicitly and keep destructive actions disabled for protected or unverifiable items.
- **Add state information to rows.** Protected, running, duplicate, incomplete measurement, container scan needed and vendor uninstaller availability should be visible without opening details. Same-name duplicates need a location subtitle or other disambiguation.
- **Use a denser, more polished table.** Current rows are attractive but sparse. Audit numeric right alignment, date formatting, vertical density, tooltip coverage, keyboard navigation and VoiceOver row structure.
- **Add macOS conveniences.** Reveal in Finder now exists on the detail pane, plus filter/search/reveal work in PR #18 and scan shortcuts with visible active-sort state in PR #25. Still wanted: row context menus, Copy Path, Open Vendor Uninstaller from the row, and measure-this-app/container.
- **Provide a factual cleanup receipt.** PR #11 adds a post-removal banner with an Open Trash action; PR #19 adds the app icon and moved-item count. Keep partial failures prominent and avoid celebratory space-saved numbers before the Trash is emptied.
- **Provide a finished app identity.** PR #23 adds a real asset catalog (`AppIcon.icns`, 16–512px) with a continuous-curvature squircle, gradient depth and simplified small-size bin marks. Still verify the rendered Dock tile, Finder Get Info, dark/light appearances and 16px Finder-sidebar legibility.
- **Support audit and recovery.** Consider a privacy-preserving local history of original and Trash URLs, with retention controls and clear recovery guidance. Do not promise one-click Put Back until collisions, missing files and permissions are designed.
- **Localize deliberately.** Strings are hardcoded. Introduce localization infrastructure and audit fixed sheet/detail layouts for longer translations and larger text.

## High-value feature backlog

- **Leftover and orphan scanning.** Find files left by apps that are already gone. Use evidence-based confidence labels such as exact bundle ID, vendor prefix, app-name match or user-confirmed evidence; never present heuristic matches as certain.
- **Batch uninstall.** Support multi-select, a review queue, total selected size, per-item failures and safe continuation without losing the queue.
- **Smart cleanup recommendations.** Rank large, unused, duplicate or never-opened apps with factual explanations, not scare copy.
- **Launch-item awareness.** Branch work detects `~/Library/LaunchAgents` (opt-in) but not LaunchDaemons, login items or helper tools; keep expanding evidence and always offer separately reviewable choices with an explanation.
- **Empty-Trash hand-off.** After a move, offer to open or empty the Trash, and show the moved item count/size. Never describe space as freed before the Trash is emptied.
- **Settings and audit export.** A settings scene for scan roots, container-scan default and confirm-before-remove, plus CSV/JSON export of the inventory (name, bundle ID, path, size, last opened, related items) for cleanup planning.
- **Smart selection presets.** One-click “select all removable caches and logs” or “everything over N MB”, built on the existing per-category toggles.
- **Duplicate-app comparison.** Show version, location, size and last-opened date side by side and help the user keep the right copy.
- **Drag-and-drop uninstall.** Accept an app dropped on the window or Dock icon, scan it, and open the standard review flow.
- **Optional system-app filter.** Hide protected Apple apps by default while keeping them searchable and auditable.
- **Version and provenance metadata.** Show version, developer/signing status, architecture, installation source hints and location.
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

- Add tests for enumeration failures, duplicate installations, cancellation and refresh races, partial measurements, unexpected filesystem errors, running-app changes during confirmation, authorization failures and administrator-process timeouts.
- Add UI tests or previews for keyboard access, VoiceOver, resizing, long text, large dynamic type, light/dark mode and increased contrast.
- Test real APFS volumes, external volumes, permissions, symlinked installation roots and a disposable app rather than moving real user data.
- Verify signed distribution, notarization, app icon, privacy prompts and the administrator path on a clean supported macOS installation before release.
