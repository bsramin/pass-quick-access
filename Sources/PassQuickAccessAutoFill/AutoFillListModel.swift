// SPDX-License-Identifier: GPL-3.0-only

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
    @Published private(set) var candidates: [AutoFillWire.Response.Candidate] = []

    /// What the user typed, matched against what a row shows. The app already
    /// narrowed the list to the site in question; this is for the case where it
    /// matched nothing and the whole vault is on screen.
    var visible: [AutoFillWire.Response.Candidate] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter {
            $0.title.lowercased().contains(trimmed)
                || ($0.account ?? "").lowercased().contains(trimmed)
        }
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
        Task {
            let response = await Self.send(.matches(services: services, kind: kind), authenticated: authenticated)
            apply(response)
        }
    }

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
        let body: AutoFillWire.Request.Body = kind == .oneTimeCode
            ? .oneTimeCode(recordIdentifier: candidate.recordIdentifier)
            : .password(recordIdentifier: candidate.recordIdentifier)
        let response = await Self.send(body, authenticated: authenticated)
        if case let .secret(value) = response?.body { return value }
        apply(response)
        return nil
    }

    private func apply(_ response: AutoFillWire.Response?) {
        guard let response else {
            phase = .message(Self.notRunningMessage)
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

    private static func send(
        _ body: AutoFillWire.Request.Body,
        authenticated: Bool
    ) async -> AutoFillWire.Response? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let response = try? AutoFillClient.send(.init(body, authenticated: authenticated))
                continuation.resume(returning: response)
            }
        }
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
