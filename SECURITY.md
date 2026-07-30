# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately
through GitHub's [security advisories](https://github.com/bsramin/pass-quick-access/security/advisories/new),
or by email to a@ramin.it. You will get a response as soon as possible, and
credit if you would like it.

## Security model

The app stores no secrets and holds no Proton credentials. It drives the
official `pass-cli`, keeps only non-secret metadata in memory for searching, and
reads passwords and one-time codes from the CLI just-in-time when you copy them.
Nothing is written to disk by the app.

The trust boundary is the `pass-cli` session: anyone able to run code as your
user can read your vault through the CLI directly, so the app's goal is to never
be a weaker link than the CLI already is. The optional Touch ID lock guards
casual access to an unlocked Mac, not local code execution.

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
