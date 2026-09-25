// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Foundation
import LocalAuthentication

/// Drives the list the extension shows, and every way that list can fail to
/// appear.
///
/// Every call to the app blocks, so all of them run off the main thread: the
/// app may be reading a vault, waiting on Proton, or not running at all, and
/// none of those is a reason to freeze a sheet the user is looking at.
@MainActor
final class AutoFillListModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case list
        /// Something the user can act on: unlock, or open the app.
        case locked
        /// Something they cannot, with the reason in plain words.
        case message(String)
    }

    @Published var query = ""
    @Published private(set) var phase: Phase = .loading
    /// Shown under the spinner. The wait that needs explaining is the first
    /// index after an unlock, which reads every vault and is nobody's idea of
    /// instant.
    @Published private(set) var note: String?
    @Published private(set) var candidates: [AutoFillWire.Response.Candidate] = []

    struct Section {
        let heading: String?
        let candidates: [AutoFillWire.Response.Candidate]
    }

    /// The logins for this site first, then everything else under a heading.
    /// Searching flattens the two, because once someone is typing a name they
    /// are past caring which of them the site matched.
    var sections: [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.isEmpty else {
            return [Section(heading: nil, candidates: candidates.filter { matches($0, trimmed) })]
        }
        let forSite = candidates.filter(\.matchesSite)
        let rest = candidates.filter { !$0.matchesSite }
        return [
            forSite.isEmpty ? nil : Section(heading: nil, candidates: forSite),
            rest.isEmpty ? nil : Section(heading: forSite.isEmpty ? nil : "All logins", candidates: rest),
        ].compactMap { $0 }
    }

    private func matches(_ candidate: AutoFillWire.Response.Candidate, _ query: String) -> Bool {
        candidate.title.lowercased().contains(query)
            || (candidate.account ?? "").lowercased().contains(query)
    }

    private let services: [String]
    private let kind: AutoFillWire.Request.Kind
    /// Carried across requests once the user has unlocked, so picking a second
    /// item in the same sheet doesn't ask again.
    private var authenticated = false

    init(services: [String], kind: AutoFillWire.Request.Kind) {
        self.services = services
        self.kind = kind
    }

    func load() {
        phase = .loading
        note = nil
        Task { await loadWaitingForTheIndex() }
    }

    /// Asks for the matches, and keeps asking while the app says it is still
    /// reading vaults. The app answers that immediately rather than holding the
    /// connection, because one pass-cli run per vault outlasts any deadline
    /// worth putting on a socket.
    private func loadWaitingForTheIndex() async {
        let deadline = Date().addingTimeInterval(Self.indexWait)
        var wakeAttempts = 0
        while true {
            let result = await Self.send(.matches(services: services, kind: kind), authenticated: authenticated)

            // Nobody listening. Open the app's URL once and keep asking for a
            // few seconds: with the app closed there is nothing behind a
            // password prompt at all, and telling someone mid-login to go and
            // launch something is a poor substitute for launching it. The app
            // reads that URL as a cue to rebind too, so this also covers a
            // socket that went missing under a running app.
            if case let .failure(error) = result,
               case .unavailable = error as? AutoFillClient.Failure ?? .transport,
               wakeAttempts < Self.wakeAttempts {
                if wakeAttempts == 0 { Self.wakeTheApp() }
                wakeAttempts += 1
                note = "Starting Pass Quick Access…"
                try? await Task.sleep(for: .milliseconds(600))
                continue
            }

            guard case let .success(response) = result,
                  case .failure(.indexNotReady) = response.body else {
                apply(result)
                return
            }
            guard Date() < deadline else {
                phase = .message("Pass Quick Access is still reading your vaults. Try again in a moment.")
                return
            }
            note = "Reading your vaults…"
            try? await Task.sleep(for: .milliseconds(700))
        }
    }

    /// How long to keep waiting on a first index. Long, because the wait is
    /// real work and the alternative is telling the user something is wrong
    /// when nothing is.
    private static let indexWait: TimeInterval = 60

    /// How many times to ask again after opening the app's URL, 600ms apart.
    /// A cold launch needs more than the single retry this used to allow.
    private static let wakeAttempts = 5

    /// Runs the system's own authentication, then asks again. The prompt belongs
    /// here rather than in the app: raised from the extension it appears over
    /// the AutoFill sheet, where the user is looking, instead of behind it.
    func unlock() {
        phase = .loading
        Task {
            guard await Self.authenticate() else {
                phase = .locked
                return
            }
            authenticated = true
            load()
        }
    }

    /// Reads one secret for the chosen row. Returns nil having already put the
    /// reason on screen.
    func secret(for candidate: AutoFillWire.Response.Candidate) async -> String? {
        phase = .loading
        note = nil
        let body: AutoFillWire.Request.Body = kind == .oneTimeCode
            ? .oneTimeCode(recordIdentifier: candidate.recordIdentifier)
            : .password(recordIdentifier: candidate.recordIdentifier)
        let result = await Self.send(body, authenticated: authenticated)
        if case let .success(response) = result, case let .secret(value) = response.body { return value }
        apply(result)
        return nil
    }

    private func apply(_ result: Result<AutoFillWire.Response, Error>) {
        note = nil
        let response: AutoFillWire.Response
        switch result {
        case let .success(value):
            response = value
        case let .failure(error):
            phase = .message(Self.describe(error))
            return
        }
        switch response.body {
        case let .matches(candidates):
            self.candidates = candidates
            phase = candidates.isEmpty ? .message("No logins for this site.") : .list
        case let .failure(reason):
            phase = Self.describe(reason)
        case .status, .secret:
            phase = .message("Pass Quick Access answered something unexpected.")
        }
    }

    private static func describe(_ failure: AutoFillWire.Response.Failure) -> Phase {
        switch failure {
        case .locked:
            return .locked
        case .signedOut:
            return .message("Signed out of Proton Pass. Open Pass Quick Access to sign back in.")
        case .indexNotReady:
            return .message("Pass Quick Access is still reading your vaults. Try again in a moment.")
        case .timedOut:
            return .message("Proton Pass isn't responding, try again.")
        case .notFound:
            return .message("That login is no longer in your vault.")
        case .denied, .unsupportedVersion:
            // Both mean app and extension disagree about who the other is, which
            // after an interrupted update is the likeliest explanation.
            return .message("This extension and Pass Quick Access don't match. Reopen the app.")
        case .unavailable:
            return .message(notRunningMessage)
        }
    }

    private static let notRunningMessage =
        "Pass Quick Access isn't running, or AutoFill is off in its settings."

    /// Telling these apart matters. An app that is there but busy is not an app
    /// that isn't running, and saying so sends the user off to fix the wrong
    /// thing.
    private static func describe(_ error: Error) -> String {
        switch error as? AutoFillClient.Failure {
        case let .unavailable(reason):
            // No team on the signature, no reachable container, and a socket
            // nobody is bound to all read the same on screen and are nothing
            // alike underneath, so the reason goes to the log.
            NSLog("AutoFill couldn't reach Pass Quick Access: \(reason)")
            return notRunningMessage
        case .transport:
            return "Pass Quick Access stopped answering. Try again."
        case .untrustedServer, .unsupportedVersion:
            return "This extension and Pass Quick Access don't match. Reopen the app."
        case nil:
            return "AutoFill couldn't reach Pass Quick Access."
        }
    }

    private static func send(
        _ body: AutoFillWire.Request.Body,
        authenticated: Bool
    ) async -> Result<AutoFillWire.Response, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result {
                    try AutoFillClient.send(.init(body, authenticated: authenticated))
                })
            }
        }
    }

    /// Opens the app's URL scheme, which launches it. A sandboxed extension may
    /// not reach into another bundle, but it may ask LaunchServices to open a
    /// URL, and the app's handler reads nothing from it.
    private static func wakeTheApp() {
        guard let url = AutoFillChannel.wakeURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // The user is looking at a form, not at us.
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    }

    /// Touch ID with the device password as the fallback, the same forgiving
    /// policy the panel uses, so a biometric lockout doesn't strand someone.
    private static func authenticate() async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "unlock Pass Quick Access"
            ) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
