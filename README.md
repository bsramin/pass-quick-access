# Pass Quick Access

[![CI](https://github.com/bsramin/pass-quick-access/actions/workflows/ci.yml/badge.svg)](https://github.com/bsramin/pass-quick-access/actions/workflows/ci.yml)


![Search](docs/screenshots/app.png)


A native macOS quick-access window for [Proton Pass](https://proton.me/pass).
Press a keystroke from any app, search your logins, and copy a username,
password or one-time code, or open the item's site in your browser. The same
idea as 1Password's Quick Access, built for Proton Pass, which ships an Electron
desktop app and no native quick-access of its own.

> Not affiliated with or endorsed by Proton AG.

## 💛 Looking for a sponsor

[![Sponsor](https://img.shields.io/badge/Sponsor-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white)](https://github.com/sponsors/bsramin)

This is a free, open-source side project, and it will stay that way. I'm looking
for a **sponsor to cover the Apple Developer Program membership** (99 USD/year).

With it, I can ship the app **notarized and signed**, so it installs without
Gatekeeper warnings, and add **automatic updates** so everyone stays on the
latest version effortlessly. The app would remain **completely free and fully
open source** for everyone, forever. The sponsorship pays only for the Apple
membership that makes safe, frictionless distribution possible.

If you or your company would like to help, you can sponsor through
**[GitHub Sponsors](https://github.com/sponsors/bsramin)**. Your support would be
credited here with thanks.

## Screenshots

| Search | Item detail | Settings |
| --- | --- | --- |
| ![Search](docs/screenshots/search.png) | ![Item detail](docs/screenshots/detail.png) | ![Settings](docs/screenshots/settings.png) |

## How it works

The app does not reimplement Proton's authentication or cryptography. It drives
the official [`pass-cli`](https://github.com/protonpass/pass-cli), the
Proton-maintained command-line client, and wraps it in a native macOS UI.

```
 ┌──────────────────────────────────────────┐
 │ Floating panel (AppKit NSPanel + SwiftUI) │
 │   hotkey ▸ search ▸ pick ▸ copy / open    │
 └───────────────┬──────────────────────────┘
                 │ metadata only (titles, URLs, usernames)
 ┌───────────────▼──────────────────────────┐
 │ PassCLIClient  (actor over pass-cli)      │
 │   vault list · item list · item view      │
 └───────────────┬──────────────────────────┘
                 │ secrets fetched just-in-time, never cached
 ┌───────────────▼──────────────────────────┐
 │ pass-cli  ▸  Proton Pass servers          │
 └──────────────────────────────────────────┘
```

## Features

- **Floating search panel** summoned by a global hotkey (default ⌥⇧Space,
  configurable). It opens over any app without pulling you out of it, and
  dismisses when it loses focus.
- **Search that matches Proton Pass**: the same substring, diacritic-insensitive,
  multi-word matching as the official client, over titles, usernames, emails,
  URLs, notes and custom fields. Results are ordered by most recently modified
  or alphabetically.
- **Item detail view** with copy actions, each shown only when the item has that
  field:
  - Copy Username
  - Copy Password
  - Copy One-Time Code
  - Open in Browser, with a chooser when an item has several URLs
- **Keyboard driven**: arrows to move, Page Up/Down and Home/End to jump, `→`
  to open an item, `←` to step back, `esc` to close.
- **Resume**: reopen within 30 seconds of an action and you land back on the
  same item, to grab another field.
- **Optional Touch ID lock** with a configurable timeout, falling back to your
  Mac password.
- **Stays signed in**: when your Proton Pass session expires, the panel offers a
  one-click sign-in that opens Proton's web login in your browser, then reloads
  itself and the SSH agent once you're back. Optionally save a Personal Access
  Token (in the Keychain, behind Touch ID) to reconnect without the browser,
  reusing your next Touch ID. Set it up under **Settings → Account**.
- **Website icons** are off by default; items show a locally generated monogram.
  You can opt in to fetching favicons, with a clear notice of what that shares.
  Favicons are never fetched for local or private addresses, including hostnames
  that resolve to one, so the feature stays off your local network.

## SSH agent

An optional SSH agent serves your Proton Pass SSH keys to `git` and `ssh`, the
way 1Password's does, and asks for Touch ID before every signature, naming the
app that requested it. It is off by default; turn it on under **Settings → SSH**.

![SSH key signature request with Touch ID](docs/screenshots/ssh-agent.png)

It does not hold keys or sign anything itself. `pass-cli` already ships an SSH
agent that stores the keys and does the signing; this app runs a thin **proxy**
in front of it that adds the native confirmation. Private keys never enter the
app, consistent with the security model below. Repeated signatures within a few
seconds aren't re-prompted, you can mark an app trusted so it stops asking, and
non-interactive `BatchMode` probes are denied without a prompt.

### Setting it up

1. **Store an SSH key in Proton Pass.** SSH keys live under *Custom item* (the
   "Other" type) in the Proton Pass apps. `pass-cli ssh-agent debug --vault-name
   <name>` lists which of your items are usable as SSH keys.
2. **Enable the agent** in *Settings → SSH*. The app starts the upstream
   `pass-cli` agent for you (it fetches your keys from Proton, so the status
   reaches *Running* after a few seconds).
3. **Point SSH at the proxy.** Flip on *Configure ~/.ssh/config automatically* and
   the app writes the entry for you (and removes it when you turn it back off):
   ```
   Host *
       IdentityAgent ~/.ssh/pass-quick-access-agent.sock
   ```
   For most people that's all you need: `ssh` and `git` read `~/.ssh/config`. Some
   tools ignore it and only look at the `SSH_AUTH_SOCK` environment variable
   (`ssh-add`, some GUI clients, certain scripts). If you use those, also enable
   *Set SSH_AUTH_SOCK for new programs*: it publishes the proxy socket to your
   login session via `launchctl`, so they pick it up too. It applies to programs
   launched afterwards, so quit and reopen a terminal (or app) for it to take
   effect.
4. **Use `git` and `ssh` normally.** Each signature pops a Touch ID prompt naming
   the app and key. Check the keys are served with:
   ```sh
   SSH_AUTH_SOCK=~/.ssh/pass-quick-access-agent.sock ssh-add -l
   ```

### Migrating from 1Password

The workflow is the same one you already know:

- Move (or recreate) your SSH keys as Proton Pass items, and register the public
  keys with your servers / GitHub as usual.
- Let the app write its `~/.ssh/config` entry (step 3 above), then **remove
  1Password's own `IdentityAgent` line** and turn off its SSH agent. The app only
  manages its own block, so anything another tool added is yours to clean up.
- **Gotcha shared by every agent:** an explicit on-disk `IdentityFile` for a host
  takes precedence over the agent, so `ssh` uses the file (and prompts for its
  passphrase) instead of asking the agent. Remove the `IdentityFile` lines for
  the hosts you want served from Proton Pass.

## Security model

- **Secrets are never persisted or indexed.** The in-memory index holds only
  titles, URLs, usernames and the presence of a password or one-time code, never
  the secret values. Passwords and codes are read fresh from `pass-cli` at the
  moment you copy them, handed to the pasteboard, and the pasteboard entry is
  marked concealed and cleared after 30 seconds.
- **Authentication lives in `pass-cli`.** The app holds no Proton credentials and
  relies on the CLI's existing session.
- **The trust boundary is that session.** Anyone who can run code as your user
  can already read everything through `pass-cli` directly, so the app is careful
  not to be a weaker link: nothing is written to disk, and signed release builds
  use the hardened runtime without `get-task-allow` so other processes can't
  attach.
- An optional Touch ID lock guards casual access to an unlocked Mac. It is not a
  defense against local code execution.

## Requirements

- macOS 14 or later
- [`pass-cli`](https://github.com/protonpass/pass-cli) installed and logged in
  (`pass-cli login`). The CLI requires a paid Proton Pass plan.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the project

## Build and run

```sh
xcodegen generate
xcodebuild -scheme PassQuickAccess -destination 'platform=macOS' -derivedDataPath build build
open build/Build/Products/Debug/PassQuickAccess.app
```

Run the tests with:

```sh
xcodebuild -scheme PassQuickAccess -destination 'platform=macOS' test
```

`PassQuickAccess.xcodeproj` is generated from `project.yml` and is not checked
in. By default the project builds ad-hoc signed; to sign with your own Apple
Developer identity, copy `Config/Local.xcconfig.example` to
`Config/Local.xcconfig` and fill in your team.

## Limitations

- The CLI is the only supported way in. There is no public Proton Pass API, so
  the app is as capable as `pass-cli` and no more.
- Ordering uses the item's modification time. The official app also factors in
  last-use time, which `pass-cli` does not expose. If you'd like it to, vote for
  [this Proton feature request](https://protonmail.uservoice.com/forums/953584-proton-pass-authenticator/suggestions/51396523-cli-expose-and-update-last-used-time-for-items).
- Distribution is currently build-from-source. A notarized release needs an
  Apple Developer ID certificate (a paid Apple Developer Program membership);
  [sponsoring the project](https://github.com/sponsors/bsramin) would help cover
  it, so builds could open without a Gatekeeper prompt.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Security reports go through
[SECURITY.md](SECURITY.md).

## License

[GNU General Public License v3.0](LICENSE). This is a community project and is
not affiliated with or endorsed by Proton AG.
