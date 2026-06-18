// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Sparkle

/// Bridges Sparkle to the app's own update surface. Sparkle never shows a window
/// on its own here: scheduled and launch checks use `checkForUpdateInformation`,
/// a silent probe that only reports through the delegate, and the result lights
/// up the pills via `UpdateController`. An actual download starts only when the
/// user picks "Update Now", which runs a full check whose user driver installs
/// straight away (the user already agreed in the notes window).
@MainActor
final class SparkleUpdater: NSObject {
    private let controller: UpdateController
    private var updater: SPUUpdater!
    private let checkInterval: TimeInterval = 2 * 60 * 60
    private var timer: Timer?
    /// Whether the in-flight check came from the user (the menu), so a "no update"
    /// result is worth a word back; background checks stay silent.
    private var checkWasUserInitiated = false

    init(controller: UpdateController) {
        self.controller = controller
        super.init()

        // The delegate is fixed at init time in Sparkle 2, so the updater is built
        // here, once `self` exists.
        let driver = InstallingUserDriver(hostBundle: .main, delegate: nil)
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        // We run our own schedule (launch + every two hours), so Sparkle's own
        // scheduler stays off and never surfaces a prompt of its own.
        updater.automaticallyChecksForUpdates = false
        try? updater.start()

        controller.onInstall = { [weak self] in self?.updater.checkForUpdates() }
        controller.onCheck = { [weak self] in self?.check(userInitiated: true) }
    }

    /// Checks once now (at launch) and then every two hours.
    func start() {
        check(userInitiated: false)
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check(userInitiated: Bool) {
        checkWasUserInitiated = userInitiated
        updater.checkForUpdateInformation()
    }

    private func reportUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "Pass Quick Access \(Bundle.main.shortVersion) is the latest version."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension SparkleUpdater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let update = AvailableUpdate(version: item.displayVersionString, releaseNotes: item.itemDescription ?? "")
        DispatchQueue.main.async { [weak self] in self?.controller.present(update) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.controller.present(nil)
            if self.checkWasUserInitiated { self.reportUpToDate() }
        }
    }
}

/// The user driver used only by the explicit "Update Now" check: it skips
/// Sparkle's "an update is available" window (the user already saw ours and
/// agreed) and goes straight to downloading, installing, and relaunching, while
/// still showing Sparkle's standard download/install progress.
private final class InstallingUserDriver: SPUStandardUserDriver {
    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        reply(.install)
    }
}

private extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}
