# Changelog

## v2026-06-19.3

### Fixed
- Fix a crash on launch. The previous release quit right away with a
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
