// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import LocalAuthentication
import SwiftUI

/// Shows the SSH approval card with Touch ID embedded directly in it (via
/// `LAAuthenticationView`), so there's a single native surface and no separate
/// system dialog. The card's lifetime is tied to the biometric result: it appears
/// with the request and is torn down the moment the user approves, denies, or the
/// request times out. Requests are serialised so only one prompt is up at a time.
@MainActor
final class SignInfoCoordinator {
    /// An unanswered request fails closed after this long, so a forgotten prompt
    /// doesn't hang the ssh client.
    private static let timeout: Duration = .seconds(60)

    private struct Pending {
        let request: SignRequest
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var queue: [Pending] = []
    private var panel: NSPanel?
    private var authContext: BiometricContext?
    private var timeoutTask: Task<Void, Never>?
    private var evaluating = false
    private var isBusy = false

    /// Called with the authenticated context right after an approval, before the
    /// signature is forwarded, so a dropped session can be restored within the same
    /// Touch ID. It must not restart the agent (the upstream connection is in use).
    var onAuthenticated: ((LAContext) async -> Void)?

    func present(_ request: SignRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.append(Pending(request: request, continuation: continuation))
            pumpIfIdle()
        }
    }

    private func pumpIfIdle() {
        guard !isBusy, let pending = queue.first else { return }
        isBusy = true
        start(pending.request)
    }

    private func start(_ request: SignRequest) {
        let auth = BiometricContext()
        // Embedding the prompt needs biometric hardware. On a Mac without Touch ID
        // fall back to the ordinary system prompt (which offers the password).
        guard auth.canEvaluate(.deviceOwnerAuthenticationWithBiometrics) else {
            Task {
                let ok = await BiometricAuth.authenticate(reason: Self.reason(for: request), timeout: Self.timeout)
                finish(ok)
            }
            return
        }
        self.authContext = auth
        evaluating = false
        showCard(for: request, context: auth.context)
    }

    /// Started from the card's `onAppear`, so the embedded `LAAuthenticationView`
    /// is in the window before the evaluation begins.
    private func evaluate() {
        guard !evaluating, let auth = authContext, let request = queue.first?.request else { return }
        evaluating = true

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.timeout)
            guard !Task.isCancelled else { return }
            self?.authContext?.invalidate()
        }

        Task {
            finish(await runEvaluation(auth: auth, request: request))
        }
    }

    private func runEvaluation(auth: BiometricContext, request: SignRequest) async -> Bool {
        do {
            let approved = try await auth.evaluate(.deviceOwnerAuthenticationWithBiometrics, reason: Self.reason(for: request))
            // Reuse this Touch ID to restore the session before the signature is
            // forwarded, so a logged-out session doesn't fail the sign.
            if approved { await onAuthenticated?(auth.context) }
            return approved
        } catch let error as LAError where Self.biometricsUnusable(error) {
            // Touch ID is locked out or otherwise unusable. Drop the embedded card
            // and offer the system prompt, which falls back to the Mac password, so
            // the user can still approve (and unlocking re-enables Touch ID).
            timeoutTask?.cancel()
            timeoutTask = nil
            hideCard()
            return await BiometricAuth.authenticate(reason: Self.reason(for: request), timeout: Self.timeout)
        } catch {
            // Cancels (Deny, timeout) and other failures are a denial.
            return false
        }
    }

    /// Whether an evaluation error means Touch ID can't be used right now, so we
    /// should fall back to the password prompt rather than deny.
    private static func biometricsUnusable(_ error: LAError) -> Bool {
        switch error.code {
        case .biometryLockout, .biometryNotAvailable, .biometryNotEnrolled, .authenticationFailed:
            return true
        default:
            return false
        }
    }

    /// Denying (or timing out) cancels the in-flight evaluation, which makes
    /// `evaluatePolicy` throw and resolves the request as not approved.
    private func deny() {
        authContext?.invalidate()
    }

    private func finish(_ approved: Bool) {
        guard isBusy, let pending = queue.first else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        authContext = nil
        evaluating = false
        hideCard()
        queue.removeFirst()
        isBusy = false
        pending.continuation.resume(returning: approved)
        pumpIfIdle()
    }

    private func showCard(for request: SignRequest, context: LAContext) {
        let view = SignInfoView(
            appName: request.client.name,
            keyName: request.keyName ?? "an SSH key",
            fingerprintShort: Self.shortFingerprint(request.fingerprint),
            unverified: !request.peer.isVerified,
            context: context,
            onAppear: { [weak self] in self?.evaluate() },
            onDeny: { [weak self] in self?.deny() }
        )

        // `.titled` (with the bar hidden) lets the panel become key, which the
        // embedded biometric view needs; the traffic lights are hidden for a clean
        // card.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 340),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        center(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    private func hideCard() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func center(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { panel.center(); return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + 60
        ))
    }

    /// The reason passed to `evaluatePolicy` (and to the fallback system prompt).
    /// macOS prepends a localized "<App> is trying to …", so this must be an
    /// infinitive phrase in the user's language to read correctly after it.
    private static func reason(for request: SignRequest) -> String {
        let name = request.keyName
        // The dialog's prefix is in the OS UI language, which an unlocalized app's
        // `Locale.current` doesn't reflect, so read the preferred language directly.
        // Each phrase is an infinitive that completes "<App> is trying to …". The
        // CJK/Arabic/Russian forms are best-effort and worth a native review.
        let locale = Locale.preferredLanguages.first.map { Locale(identifier: $0) }
        let traditionalChinese = locale?.language.script?.identifier == "Hant"
        switch locale?.language.languageCode?.identifier {
        case "it":
            return name.map { "usare la chiave SSH «\($0)»" } ?? "usare una chiave SSH"
        case "es":
            return name.map { "usar la clave SSH «\($0)»" } ?? "usar una clave SSH"
        case "fr":
            return name.map { "utiliser la clé SSH « \($0) »" } ?? "utiliser une clé SSH"
        case "de":
            return name.map { "den SSH-Schlüssel „\($0)“ zu verwenden" } ?? "einen SSH-Schlüssel zu verwenden"
        case "pt":
            return name.map { "usar a chave SSH “\($0)”" } ?? "usar uma chave SSH"
        case "ru":
            return name.map { "использовать SSH-ключ «\($0)»" } ?? "использовать SSH-ключ"
        case "ja":
            return name.map { "SSH鍵「\($0)」を使用" } ?? "SSH鍵を使用"
        case "ko":
            return name.map { "SSH 키 “\($0)” 사용" } ?? "SSH 키 사용"
        case "ar":
            return name.map { "استخدام مفتاح SSH «\($0)»" } ?? "استخدام مفتاح SSH"
        case "zh":
            if traditionalChinese {
                return name.map { "使用 SSH 金鑰「\($0)」" } ?? "使用 SSH 金鑰"
            }
            return name.map { "使用 SSH 密钥“\($0)”" } ?? "使用 SSH 密钥"
        default:
            return name.map { "use the SSH key “\($0)”" } ?? "use an SSH key"
        }
    }

    private static func shortFingerprint(_ hex: String) -> String {
        let prefix = Array(hex.prefix(16))
        var groups: [String] = []
        var index = 0
        while index < prefix.count {
            let end = min(index + 4, prefix.count)
            groups.append(String(prefix[index..<end]))
            index = end
        }
        return "SHA256 " + groups.joined(separator: " ") + "…"
    }
}

/// Adapts the main-actor coordinator to the `Sendable` presenter seam the
/// authorizer calls from its background actor.
struct SignInfoPresenter: SignApprovalPresenting {
    let coordinator: SignInfoCoordinator

    func present(_ request: SignRequest) async -> Bool {
        await coordinator.present(request)
    }
}
