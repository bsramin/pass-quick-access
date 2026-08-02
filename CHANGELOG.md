# Changelog

## v2026-08-02.2

### Fixed
- "Refresh Index" no longer reads your vaults while the panel lock is on and you
  haven't unlocked yet. It takes you through the same Touch ID the panel does, so
  nothing is read before you have authenticated, exactly as at launch.

## v2026-08-02.1

### Added
- A "Refresh Index" item in the menu-bar menu, for when you have just added a
  login somewhere else and want it in the panel right now.

### Changed
- The app keeps its Proton Pass session warm while it sits in the menu bar. It
  checks in every fifteen minutes, and again when the Mac wakes, and quietly
  signs back in from your saved access token when the session has lapsed, so the
  first press of the hotkey after a long idle opens on your logins instead of the
  sign-in prompt. The check is a single cheap command: it reads nothing from your
  vaults and never holds up an SSH signature.
- Logins added or changed on your other devices now turn up on their own. The
  index is re-read once it is more than five minutes old, after the panel closes
  and after the Mac wakes, so nothing runs while you are using the panel and the
  list is current the next time you open it.

## v2026-07-31.1

### Fixed
- Suggesting the login for your open browser tab now works in the released app.
  Reading the active tab means sending an Apple event, which the release build
  was never entitled to do, so Safari and Chromium tabs were quietly never
  matched no matter how the setting was left.

### Changed
- The app now opens straight from the download, with no right-click or
  Terminal command to get past macOS. Releases are signed and notarized, and
  they keep the hardened runtime fully intact: the shipped build no longer has
  to make an exception for loading the updater.

## v2026-06-30.1

### Added
- Optionally show the logins you use most at the top of the list. Turn on "Show
  frequently used items first" under Settings → General and the app keeps a
  private count, on this Mac, of how often you pick each item and floats your
  most-used ones up, with your chosen order breaking ties. It's off by default,
  and nothing about your usage is stored unless you turn it on.
- A nine-hour option for how long an unlock lasts, under Settings → Security, for
  anyone who wants Touch ID just once a working day.

### Fixed
- Stop the Proton Pass session dropping on its own and sending you back to the
  sign-in prompt, even with an access token saved. pass-cli keeps one session on
  disk and rotates its token as it's used, so when the panel and the SSH agent
  both reached for it at once they rotated each other's token out and lost the
  session. Every pass-cli call the app makes now takes a shared lock, so they no
  longer overlap. When a session does drop, the panel quietly signs back in from
  the saved token, reusing the unlock you just did, instead of showing the
  signed-out screen. And a passing pass-cli error that only mentioned "session"
  no longer reads as a logout, which was sometimes throwing up the prompt for no
  reason.

## v2026-06-25.1

### Added
- Fill logins into the app you came from. Pick an item and the app types the
  username, a Tab, then the password into whatever field has focus, in any
  browser or app, by sending real keystrokes. There are separate Fill Username,
  Fill Password and Fill One-Time Code actions too, and an option to press Return
  afterwards to submit. Filling uses macOS Accessibility access, which the app
  asks for the first time you use it.
- Choose whether picking an item fills, copies, or both, under Settings →
  Autofill. Copy works exactly as before for anyone who prefers the clipboard.
- Suggest the item for the page you're on. Open the panel over a browser and the
  login matching the current tab is selected for you; when several logins match
  the same site, the list narrows to just those. Safari and Chromium browsers
  are read over Automation, which macOS asks to allow once per browser. Firefox,
  Zen and other web apps are opt-in, since reading them turns on their
  accessibility engine.

### Changed
- Redesigned Settings into a native preference window: a tab per area (General,
  Autofill, Security, Icons, Account, SSH Agent, About), with sub-tabs where a
  tab covers more than one thing, and the window resizing to fit each tab.
- Show a small spinner in the search field while the vaults are still indexing,
  so an item that hasn't loaded yet reads as "still indexing" rather than missing.
- Rank search results by where the match lands, so the most relevant item comes
  first. A hit in the title beats one in the username, which beats one buried in
  a URL or note, and a match at the start of a word beats one in the middle. The
  set of results is unchanged; only their order is more useful.

## v2026-06-24.1

### Fixed
- Stop the SSH agent from giving `Permission denied (publickey)` after the Mac
  has been idle or asleep, where the only fix was toggling the agent off and on
  in Settings. Two things were behind it. The upstream `pass-cli` agent does not
  survive a long idle or a sleep/wake, and recovery only restarted it in the
  background after the request had already failed, so the first `ssh` still
  failed; now, when a connection finds the agent gone, it is restarted and
  retried in place so that first `ssh` just works. And under heavy use the proxy
  served every connection from a shared thread pool with a hard ceiling, which
  long-lived forwarded sessions could exhaust, leaving new connections accepted
  but never answered; each connection now gets its own thread, so a new `ssh` is
  always served. A stalled agent reply also no longer pins a connection open
  indefinitely.

## v2026-06-19.4

- The first release with a working in-app updater, so new versions arrive as an
Update pill instead of a manual download.

- Show the real release version (the dated one, like 2026-06-19.4) in the update
  window and the "up to date" message, instead of the marketing version that
  never changes.

## v2026-06-19.3

### Fixed
- Fix a crash on launch. The 2026-06-19.2 release quit right away with a
  missing-library error, because the signed build would not load the bundled
  updater framework. It starts normally again.

## v2026-06-19.2

### Added
- Update itself when a new version is out, without getting in the way. A small
  "Update" pill shows up next to the menu-bar icon and at the edge of the search
  bar when a release is available, and the menu gains an "Update Now" item next
  to a "Check for Updates" one that's always there. Clicking a pill opens the
  release notes and lets you update on the spot. The check runs quietly at launch
  and every couple of hours, sends no account data, never installs on its own,
  and verifies each update's signature before applying it. Block the update host
  to turn it off (see SECURITY.md).

## v2026-06-19.1

### Changed
- Show vault items as they load instead of waiting for the whole index. Vaults
  are read one at a time (running `pass-cli` in parallel races the session token
  and signs you out), so with many vaults the panel used to sit on a spinner for
  several seconds. It now fills in vault by vault, with a count of
  how far along it is, so you can start searching straight away. While the index
  is still coming in, a search with no match yet keeps showing that it's
  indexing rather than saying "No matches", so an item in a vault that hasn't
  loaded doesn't look missing.

## v2026-06-18.1

### Fixed
- Stop the Proton Pass session from dropping on its own. Opening the panel
  indexed every vault with several `pass-cli` processes at once, and because
  they share one session they raced Proton's token refresh: the first to
  refresh invalidated the token the others still held, signing you out. The
  reconnect then re-indexed and raced again, which is why you'd get two or three
  Touch ID prompts back to back. The app now runs `pass-cli` one process at a
  time, so the session stays put.
- Keep the SSH agent working after a session refresh. The upstream `pass-cli`
  agent would keep signing with a stale session (`Permission denied
  (publickey)`), and since its socket was still reachable the recovery never
  restarted it, so the only workaround was toggling the agent off and on in
  Settings. Recovery now restarts the agent unconditionally, and it heals itself
  when a signature is rejected or the agent goes unreachable, so `git` and `ssh`
  keep working without a visit to Settings.

## v2026-06-14.1

### Added
- Stay signed in across a session expiry. When your Proton Pass session expires,
  the panel no longer dead-ends: it offers a one-click sign-in that opens
  Proton's web login in your browser, then reloads the index and the SSH agent
  once you're back, with no relaunch.
- Optional Personal Access Token, stored in the Keychain behind Touch ID, to
  reconnect without the browser. The app re-logs in with it, reusing the next
  Touch ID you do for the panel or an SSH signature. Manage it under
  Settings → Account.

## v2026-06-12.1

### Added
- Optional SSH agent: serves your Proton Pass SSH keys to `git` and `ssh` and
  asks for Touch ID before every signature, showing which app is requesting it.
  It proxies the official `pass-cli` agent, so private keys stay inside the CLI
  and never reach this app. Off by default; enable it under Settings → SSH.

## v2026-06-11.1

### Added
- Floating quick-access panel summoned by a global hotkey (default ⌥⇧Space).
- Search matching Proton Pass: substring, diacritic-insensitive, multi-word,
  over titles, usernames, emails, URLs, notes and custom fields.
- Item detail view with Copy Username, Copy Password, Copy One-Time Code, and
  Open in Browser, each shown only when the item has that field.
- Sort by most recently modified or alphabetically.
- Optional Touch ID lock with a configurable timeout.
- Opt-in website icons with a clear privacy notice; a local monogram otherwise.
- Resume the previous item when reopening within 30 seconds of an action.
