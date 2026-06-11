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
be a weaker link than the CLI already is. Signed release builds use the hardened
runtime without `get-task-allow`. The optional Touch ID lock guards casual
access to an unlocked Mac, not local code execution.

See the security model section of the [README](README.md) for more detail.

## Scope

This policy covers the Pass Quick Access app in this repository. Issues in
`pass-cli` or Proton Pass itself should be reported to Proton.
