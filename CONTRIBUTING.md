# Contributing

Thanks for your interest in Pass Quick Access.

## Getting set up

You need macOS 14 or later, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and [`pass-cli`](https://github.com/protonpass/pass-cli)
installed and logged in to run the app against a real account.

```sh
xcodegen generate # writes PassQuickAccess.xcodeproj
xcodebuild -scheme PassQuickAccess -destination 'platform=macOS' test
```

The Xcode project is generated from `project.yml` and is not committed, so run
`xcodegen generate` after pulling changes that touch the project structure.

## Signing

The project builds ad-hoc signed by default, which is all the tests and a local
run need. To sign with your own Apple Developer identity, copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your team and
identity there. That file is git-ignored.

## Working on the code

- The app is Swift with SwiftUI content hosted in AppKit, built under strict
  concurrency with warnings treated as errors. Keep the build clean.
- Add or update tests for behaviour changes. The data layer and search are
  covered by unit tests; follow the existing style.
- Comments explain *why*, not *what*. Match the surrounding code.
- Keep commits focused and their messages in the imperative ("Add", "Fix"),
  describing the change and the reason.

## Pull requests

Open an issue first for anything substantial so we can agree on the approach.
Make sure `xcodebuild test` passes before you open the PR, and describe what you
changed and how you verified it.
