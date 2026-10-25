# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately
through GitHub's [security advisories](https://github.com/bsramin/pass-quick-access/security/advisories/new),
or by email to a@ramin.it. You will get a response as soon as possible, and
credit if you would like it.

## Security model

The app stores no secrets and holds no Proton credentials. It drives the
official `pass-cli`, keeps only non-secret metadata for searching, and reads
passwords and one-time codes from the CLI just-in-time when you copy them.

No secret is ever written to disk. Two pieces of non-secret metadata are: the
sealed index described below, and the optional suggestion list described under
*System AutoFill*.

The trust boundary is the `pass-cli` session: anyone able to run code as your
user can read your vault through the CLI directly, so the app's goal is to never
be a weaker link than the CLI already is. The optional Touch ID lock guards
casual access to an unlocked Mac, not local code execution.

### The sealed index

The index is rebuilt by reading every vault through `pass-cli`, which is one CLI
run per vault and the reason a cold launch used to show a spinner before it
could show a row. The rows from the last complete read are kept in
`~/Library/Application Support/PassQuickAccess/index.sealed` so the panel and
System AutoFill can answer at once and refresh behind you.

What the file holds is what a row shows and what a row is matched against:
title, username, email, the item's URLs, vault name, modification time, and
whether the item has a password or a one-time code, plus the item and share ids
needed to ask the CLI for the secret later.

What it does not hold: any password, any one-time code or seed, and neither the
item's note nor its custom fields. Those are searched from memory and are back a
second or two after launch, once the first refresh lands. They are left out
because a note is the field people paste recovery codes into.

It is sealed with AES-256-GCM. The key is 32 random bytes in the Keychain,
`WhenUnlockedThisDeviceOnly` and never synchronised, so the file can be opened
only on this Mac and only while it is unlocked. The file is `0600` inside a
`0700` directory and marked excluded from backups. A file that cannot be opened,
or that was written by an older shape of the row, reads as no cache at all and
the index is read from the CLI as before. Losing the session removes it.

This is weaker than keeping the metadata in memory alone, and it is the trade
the feature makes: a Mac where someone can run code as you can read your whole
vault through `pass-cli` anyway, which is the trust boundary stated above, and
an attacker with the file but not the Keychain gets ciphertext.

### System AutoFill

The bundled credential-provider extension lets macOS, Safari and other apps ask
this app for a password or a one-time code. It is sandboxed, as macOS requires
of a credential provider, and it reads nothing itself: it asks the app over a
Unix socket in the app's App Group container, and both ends verify the other's
code signature, same team and expected bundle identifier, before anything is
exchanged. Only the app ever runs `pass-cli`, so the single-session rule the CLI
depends on is unchanged. Nothing on that socket can steer the CLI: an item
reference is resolved through the in-memory index, never taken from the wire.

"Name your logins in the menu", under Settings → Autofill → System, is the one
thing the app writes into a store it does not own. Off by default. Turning it on saves
each login's **website, username and an opaque item reference** into the
password database macOS manages, so the native menu can name your logins before
you have picked this app. It never saves a password, a one-time code, a note or
anything else from the item. Turning it off removes what was written, as does
losing the session or turning the provider off.

Passkeys are deliberately not offered. Providing one means signing the WebAuthn
challenge with the credential's private key, and `pass-cli` exposes neither the
key nor any signing operation, so claiming the capability would put the app in
the passkey picker only to fail every assertion.

Released builds are signed with a Developer ID certificate and notarized by
Apple. They run under the hardened runtime with `get-task-allow` left out, so
another process cannot attach to the app, and with library validation on, so the
app loads no code signed by anyone else. A build made from source without a
certificate is ad-hoc signed and has to relax library validation, because an
ad-hoc signature carries no team identifier for the embedded Sparkle framework to
match; that is the only difference between the two.

See the security model section of the [README](README.md) for more detail.

## Update checks

The app checks for new versions with [Sparkle](https://sparkle-project.org). At
launch, and then every two hours, it makes one plain HTTPS GET for the appcast at
`https://bsramin.github.io/pass-quick-access/appcast.xml`, a static file on
GitHub Pages. The request carries no account data and no system profile. The only
thing it reveals is the standard Sparkle user agent, which is the app version and
the macOS version, both already known to GitHub. Seeing this request on the
network is expected and not a sign of anything wrong, and blocking that host
turns the check off without breaking the app.

Nothing installs on its own. When a newer version exists the app shows a small
"Update" pill and waits; it downloads and replaces the app only after you pick
"Update Now". Every update is verified against an ed25519 (EdDSA) public key
pinned inside the app before it is allowed to install, so a tampered or
intercepted download is rejected. That check is Sparkle's own and is independent
of Apple's notarization, which the download also carries: a forged update has to
defeat both. The private half of the signing key lives only in the maintainer's
Keychain and a GitHub Actions secret, and the release workflow that uses it runs
only when a maintainer publishes a release, never from a pull request.

## Scope

This policy covers the Pass Quick Access app in this repository. Issues in
`pass-cli` or Proton Pass itself should be reported to Proton.
