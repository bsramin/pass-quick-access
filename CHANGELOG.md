# Changelog

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
