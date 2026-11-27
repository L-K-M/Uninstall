# Uninstall: future work

Actionable follow-up work from a source, test and macOS build review. Preserve the existing Trash-first flow, explicit confirmation, and identity checks. Verify open pull requests and current behavior before starting an item.

## Correctness and safety

- **Make the scope of duplicate detection explicit.** Even a complete scan covers only three directories; another copy outside those locations can share data. Add custom scan roots with safeguards against nested roots and symlinks; consider an explicit additional confirmation for related data. Other copies outside scanned locations may share data.
- **Reassess identity verification at the point of moving.** The normal Trash path checks identity before a separate filesystem operation, leaving a time-of-check/time-of-use window. The privileged path also verifies before rename. Investigate descriptor-relative, no-follow operations and macOS Trash semantics before changing this security-sensitive code; test path substitution races and volume boundaries.
- **Surface skipped related paths and discovery errors accurately.** `isDirectPath` silently skips symlinks and inaccessible parents; unexpected `lstat` errors besides permission errors are silently treated as absent. A complete inventory should require either a verified absence or a visible reason for omission. Exercise EIO, symlinked Library paths, and permissions.
- **Clarify sizes and shared storage.** Allocated blocks are estimates, not guaranteed reclaimable bytes: APFS clones, snapshots, compression and hard links outside the measured tree can change reclaimable space. Avoid promising exact savings. Hard-link deduplication shared across separate categories also makes each category depend on enumeration order; measure independently for category estimates and deduplicate only for an aggregate, with tests.
- **Distinguish deferred container scanning from a failed measurement.** Offer a per-app container scan rather than scanning containers for every app; explain permission implications and retain the distinction between skipped, inaccessible and partial results.
- **Protect user data against incomplete selection context.** A related-file match by bundle ID is only a heuristic, and caches can contain valuable offline data. Explain the matching rule and consequences near the confirmation; consider defaulting all related items off. Test duplicate installations, unknown bundle IDs and applications with nonstandard data locations.
- **Improve running-app handling.** Explain which app or copy must quit, offer a non-forced quit action and recheck before removal. Running helper processes and launch agents may remain even when the main bundle is absent; investigate safe detection without killing unrelated processes.

## Performance and interaction

- **Prioritize the selected app during scanning.** All apps are measured in discovery order, three at a time; a selected app may wait behind large bundles. Schedule selected work first, cancel stale scans, and test rapid selection and refresh without stale results.
- **Reduce list churn while measuring.** Each completed scan mutates observable rows and the default size sort reorders the table, potentially moving a row under the pointer and repeatedly sorting and fetching icons. Profile with hundreds of apps; batch results, cache icons, and keep selection stable. Keep progress honest and ensure keyboard navigation remains responsive.
- **Avoid repeated full rescans after removal.** Update the removed row immediately and refresh affected data in the background, with a manual rescan for external changes. Ensure partial failures and shared data remain accurately reflected.
- **Improve search and keyboard flow.** Add a standard search shortcut, clear affordance, search by path as well as name and bundle ID, and preserve selection when a temporary filter hides it. Verify focus, VoiceOver, and keyboard-only review and cancellation.

## Visual design and product ideas

- **Give the detail pane a stronger hierarchy.** Present app icon, name, path and status as a compact identity header, followed by a storage breakdown and a clearly separated review action. Test long names, long paths, narrow windows, dark mode, increased contrast and accessibility text sizes.
- **Explain and visualize storage.** Add a restrained segmented bar for app versus identified related files, with accessible text and uncertainty states. Show selected removable bytes separately from the estimated total; never imply Trash has freed space.
- **Replace the generic initial state with a useful overview.** Show scan progress and aggregate counts or largest apps only when their meaning is defensible; avoid adding estimates across apps with shared data. Include a concise reminder that files go to Trash.
- **Make per-file choices easier to understand.** Group items by risk, expose full paths and notes, offer select/deselect controls, and show exactly what will be moved in the confirmation. Keep destructive actions disabled for protected or unverifiable items.
- **Add a delightful but factual cleanup receipt.** After a move, show app icon, moved item count and an “Open Trash” action, with partial failures prominently visible. Avoid a celebratory space-saved number before Trash is emptied.
- **Provide a finished app identity.** The project references an AppIcon but has no asset catalog. Design and add a distinctive, legible macOS icon and check appearance at Dock, Finder and small sizes.
- **Support audit and recovery.** Consider an optional local history with original and Trash URLs, a Finder reveal action, and clear retention/privacy controls. Do not promise one-click restoration without handling collisions, missing files and permissions.

## Validation gaps

- Add tests for enumeration failures, duplicate installations, cancellation and refresh races, partial measurements, unexpected filesystem errors, running-app changes during confirmation, and authorization failures. Add UI checks for keyboard access, resizing and long text. Test real APFS, external volumes, permissions and a disposable app rather than moving real user data.
- Verify signed distribution, notarization, app icon, privacy prompts, and the administrator path on a clean supported macOS installation before release.
