// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// The wire between the app and the credential provider, and what the app will
/// and won't answer down it.
final class AutoFillWireTests: XCTestCase {
    func testEveryMessageSurvivesTheRoundTrip() throws {
        let requests: [AutoFillWire.Request.Body] = [
            .status,
            .matches(services: [], kind: .password),
            .matches(services: ["example.com", "https://login.example.com/in"], kind: .oneTimeCode),
            .password(recordIdentifier: "share/item"),
            .oneTimeCode(recordIdentifier: "share/item"),
        ]
        for body in requests {
            let decoded = try roundTrip(AutoFillWire.Request(body, authenticated: true), as: AutoFillWire.Request.self)
            XCTAssertEqual(decoded.version, AutoFillWire.version)
            XCTAssertTrue(decoded.authenticated)
            XCTAssertEqual(String(describing: decoded.body), String(describing: body))
        }
    }

    func testAResponseCarryingASecretSurvivesAwkwardCharacters() throws {
        // Length-prefixed rather than newline-delimited precisely so a password
        // containing a newline, a quote or a NUL is not a framing bug.
        let awkward = "line\nbreak\u{0}\"quoted\" ünïcödé \u{1F510}"
        let decoded = try roundTrip(AutoFillWire.Response(.secret(awkward)), as: AutoFillWire.Response.self)
        guard case let .secret(value) = decoded.body else { return XCTFail("expected a secret") }
        XCTAssertEqual(value, awkward)
    }

    func testAnOversizedFrameIsRefusedRatherThanRead() throws {
        let (a, b) = try socketPair()
        defer { close(a); close(b) }
        var header = Data()
        let tooBig = UInt32(AutoFillWire.maxRequestLength + 1)
        header.append(UInt8((tooBig >> 24) & 0xff))
        header.append(UInt8((tooBig >> 16) & 0xff))
        header.append(UInt8((tooBig >> 8) & 0xff))
        header.append(UInt8(tooBig & 0xff))
        XCTAssertTrue(UnixSocket.writeAll(header, to: a))

        XCTAssertThrowsError(
            try AutoFillWire.read(AutoFillWire.Request.self, from: b, limit: AutoFillWire.maxRequestLength)
        ) { error in
            XCTAssertEqual(error as? AutoFillWire.Failure, .tooLarge)
        }
    }

    func testATruncatedFrameThrowsRatherThanReturningHalfAMessage() throws {
        let (a, b) = try socketPair()
        defer { close(b) }
        let frame = try AutoFillWire.frame(AutoFillWire.Request(.status))
        XCTAssertTrue(UnixSocket.writeAll(frame.prefix(frame.count - 2), to: a))
        close(a)

        XCTAssertThrowsError(
            try AutoFillWire.read(AutoFillWire.Request.self, from: b, limit: AutoFillWire.maxRequestLength)
        ) { error in
            XCTAssertEqual(error as? AutoFillWire.Failure, .unexpectedEOF)
        }
    }

    func testAPeerThatClosesWithoutSpeakingIsNotAnError() throws {
        let (a, b) = try socketPair()
        defer { close(b) }
        close(a)

        let message = try AutoFillWire.read(
            AutoFillWire.Request.self, from: b, limit: AutoFillWire.maxRequestLength
        )
        XCTAssertNil(message, "a closed connection is an ordinary end, not a failure")
    }

    private func roundTrip<T: Codable>(_ message: T, as type: T.Type) throws -> T {
        let (a, b) = try socketPair()
        defer { close(a); close(b) }
        XCTAssertTrue(UnixSocket.writeAll(try AutoFillWire.frame(message), to: a))
        let decoded = try AutoFillWire.read(type, from: b, limit: AutoFillWire.maxResponseLength)
        return try XCTUnwrap(decoded)
    }
}

/// How the server routes a request, driven over a socket pair with a fake index
/// and a fake `pass-cli`, so none of it needs a signed build or a real vault.
@MainActor
final class AutoFillServerTests: XCTestCase {
    private let trusted = VerifiedPeer(identity: AutoFillChannel.expectedExtensionIdentity ?? "team:T:x")

    func testAnUnverifiedCallerIsRefusedAndTheIndexIsNeverTouched() async throws {
        let index = FakeIndex()
        let response = try await exchange(.status, index: index, peer: .unverified)

        XCTAssertEqual(failure(of: response), .denied)
        XCTAssertFalse(index.wasRead, "a refused caller must not reach the index at all")
    }

    func testStatusReportsIndexingUntilTheVaultsAreRead() async throws {
        let index = FakeIndex(isReady: false)
        guard case let .status(state) = try await exchange(.status, index: index).body else {
            return XCTFail("expected a status")
        }
        XCTAssertEqual(state, .indexing)
    }

    func testALockedAppOffersNothingUntilTheExtensionHasAuthenticated() async throws {
        let defaults = lockedDefaults()
        let window = UnlockWindow(defaults: defaults)

        let locked = try await exchange(.password(recordIdentifier: "s1/i1"), unlockWindow: window)
        XCTAssertEqual(failure(of: locked), .locked)

        // The extension has just taken the user through Touch ID. The setting
        // under test is "authenticate every time", where the shared window never
        // opens, so this has to be honoured on its own merits or AutoFill would
        // be permanently locked for anyone who picks that option.
        let unlocked = try await exchange(
            .password(recordIdentifier: "s1/i1"), unlockWindow: window, authenticated: true
        )
        XCTAssertEqual(secret(of: unlocked), "hunter2")
    }

    func testMatchesAreFilteredToWhatTheRequestCanActuallyUse() async throws {
        let index = FakeIndex(items: [
            summary(id: "s1/i1", title: "With code", hasTOTP: true),
            summary(id: "s1/i2", title: "Password only", hasTOTP: false),
        ])

        guard case let .matches(all) = try await exchange(
            .matches(services: [], kind: .password), index: index
        ).body else { return XCTFail("expected matches") }
        XCTAssertEqual(all.map(\.title), ["With code", "Password only"])

        guard case let .matches(codes) = try await exchange(
            .matches(services: [], kind: .oneTimeCode), index: index
        ).body else { return XCTFail("expected matches") }
        XCTAssertEqual(codes.map(\.title), ["With code"])
        XCTAssertTrue(codes.allSatisfy(\.hasOneTimeCode))
    }

    func testALapsedSessionIsRepairedRatherThanReported() async throws {
        let index = FakeIndex(
            items: [summary(id: "s1/i1", title: "GitHub", hasTOTP: false)],
            isSignedOut: true,
            canRestore: true
        )
        let response = try await exchange(.password(recordIdentifier: "s1/i1"), index: index)

        XCTAssertEqual(secret(of: response), "hunter2")
        XCTAssertEqual(index.restoreAttempts, 1, "the token should be tried before giving up")
    }

    func testASessionThatCannotBeRepairedIsReportedOnce() async throws {
        let index = FakeIndex(isSignedOut: true, canRestore: false)
        let response = try await exchange(.status, index: index)

        guard case let .status(state) = response.body else { return XCTFail("expected a status") }
        XCTAssertEqual(state, .signedOut)
        XCTAssertEqual(index.restoreAttempts, 1)
    }

    func testAnUnknownRecordIdentifierIsNotFoundAndNeverReachesTheCLI() async throws {
        let runner = ArgumentRecordingRunner()
        let response = try await exchange(.password(recordIdentifier: "made/up"), runner: runner)

        XCTAssertEqual(failure(of: response), .notFound)
        XCTAssertTrue(runner.invocations.isEmpty, "an unknown item must not spawn pass-cli")
    }

    func testTheCLISeesTheIndexedReferenceNotTheOneOnTheWire() async throws {
        let runner = ArgumentRecordingRunner()
        _ = try await exchange(.password(recordIdentifier: "s1/i1"), runner: runner)

        let arguments = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(arguments, ["item", "view", "--share-id", "s1", "--item-id", "i1", "--field", "password"])
    }

    func testAnUnreachableServiceIsReportedAsATimeoutRatherThanAMissingItem() async throws {
        let runner = ArgumentRecordingRunner(failure: .timedOut)
        let response = try await exchange(.password(recordIdentifier: "s1/i1"), runner: runner)

        XCTAssertEqual(failure(of: response), .timedOut)
    }

    func testAFrameFromAFutureVersionIsRefusedRatherThanGuessedAt() async throws {
        let (client, server) = try socketPair()
        defer { close(client) }
        let fake = FakeIndex()
        let subject = makeServer(index: fake)

        // Hand-rolled because the encoder always writes the current version.
        let payload = try JSONSerialization.data(withJSONObject: [
            "version": AutoFillWire.version + 1,
            "authenticated": false,
            "body": ["status": [:]],
        ])
        var frame = Data()
        let length = UInt32(payload.count)
        frame.append(UInt8((length >> 24) & 0xff))
        frame.append(UInt8((length >> 16) & 0xff))
        frame.append(UInt8((length >> 8) & 0xff))
        frame.append(UInt8(length & 0xff))
        frame.append(payload)
        XCTAssertTrue(UnixSocket.writeAll(frame, to: client))

        let response = try await serve(subject, on: server, readingFrom: client)
        XCTAssertEqual(failure(of: response), .unsupportedVersion)
    }

    // MARK: - Harness

    private func exchange(
        _ body: AutoFillWire.Request.Body,
        index: FakeIndex? = nil,
        runner: ArgumentRecordingRunner? = nil,
        unlockWindow: UnlockWindow? = nil,
        peer: VerifiedPeer? = nil,
        authenticated: Bool = false
    ) async throws -> AutoFillWire.Response {
        let (client, server) = try socketPair()
        defer { close(client) }
        let subject = makeServer(
            index: index ?? FakeIndex(items: [summary(id: "s1/i1", title: "GitHub", hasTOTP: true)]),
            runner: runner ?? ArgumentRecordingRunner(),
            unlockWindow: unlockWindow ?? UnlockWindow(defaults: unlockedDefaults()),
            peer: peer ?? trusted
        )
        let frame = try AutoFillWire.frame(AutoFillWire.Request(body, authenticated: authenticated))
        XCTAssertTrue(UnixSocket.writeAll(frame, to: client))
        return try await serve(subject, on: server, readingFrom: client)
    }

    /// Runs one connection on a background thread, the way the listener would,
    /// and reads the answer back off the main one.
    ///
    /// The read has to be awaited rather than blocking here: the server answers
    /// from the main actor, and a test that blocks the main thread on the reply
    /// deadlocks against the very hop it is waiting for.
    private func serve(
        _ server: AutoFillServer,
        on serverFD: Int32,
        readingFrom clientFD: Int32
    ) async throws -> AutoFillWire.Response {
        let thread = Thread { server.serve(serverFD) }
        thread.start()
        UnixSocket.setReadTimeout(5, on: clientFD)
        let response: AutoFillWire.Response? = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try AutoFillWire.read(
                        AutoFillWire.Response.self, from: clientFD, limit: AutoFillWire.maxResponseLength
                    )
                })
            }
        }
        return try XCTUnwrap(response)
    }

    private func makeServer(
        index: FakeIndex,
        runner: ArgumentRecordingRunner = ArgumentRecordingRunner(),
        unlockWindow: UnlockWindow? = nil,
        peer: VerifiedPeer? = nil
    ) -> AutoFillServer {
        let verified = peer ?? trusted
        return AutoFillServer(
            client: PassCLIClient(executable: URL(fileURLWithPath: "/usr/bin/true"), runner: runner),
            index: index,
            unlockWindow: unlockWindow ?? UnlockWindow(defaults: unlockedDefaults()),
            socketPath: "/dev/null",
            verifyPeer: { _ in verified }
        )
    }

    private func failure(of response: AutoFillWire.Response) -> AutoFillWire.Response.Failure? {
        guard case let .failure(reason) = response.body else { return nil }
        return reason
    }

    private func secret(of response: AutoFillWire.Response) -> String? {
        guard case let .secret(value) = response.body else { return nil }
        return value
    }

    private func summary(id: String, title: String, hasTOTP: Bool) -> ItemSummary {
        let parts = id.split(separator: "/")
        return ItemSummary(
            itemID: String(parts[1]),
            shareID: String(parts[0]),
            vaultName: "Personal",
            title: title,
            username: "octocat",
            urls: ["https://github.com"],
            hasPassword: true,
            hasTOTP: hasTOTP
        )
    }

    private func unlockedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "autofill-tests-\(UUID().uuidString)")!
        defaults.set(false, forKey: SettingKey.requireAuth)
        return defaults
    }

    private func lockedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "autofill-tests-\(UUID().uuidString)")!
        defaults.set(true, forKey: SettingKey.requireAuth)
        defaults.set(0, forKey: SettingKey.authTimeout)
        return defaults
    }
}

// MARK: - Test doubles

@MainActor
private final class FakeIndex: AutoFillIndexSource {
    private let items: [ItemSummary]
    private let ready: Bool
    private var signedOut: Bool
    private let canRestore: Bool
    private(set) var wasRead = false
    private(set) var restoreAttempts = 0

    init(
        items: [ItemSummary] = [],
        isReady: Bool = true,
        isSignedOut: Bool = false,
        canRestore: Bool = false
    ) {
        self.items = items
        self.ready = isReady
        self.signedOut = isSignedOut
        self.canRestore = canRestore
    }

    var autofillIsIndexReady: Bool { ready }
    var autofillIsSignedOut: Bool { signedOut }
    func autofillLoadIndexIfNeeded() async {}

    func autofillRestoreSession() async -> Bool {
        restoreAttempts += 1
        if canRestore { signedOut = false }
        return canRestore
    }

    func autofillItems(matchingHosts hosts: [String]) -> [ItemSummary] {
        wasRead = true
        return items
    }

    func autofillItem(recordIdentifier: String) -> ItemSummary? {
        wasRead = true
        return items.first { $0.id == recordIdentifier }
    }
}

/// Records what pass-cli would have been asked, and answers a fixed secret.
private final class ArgumentRecordingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let failure: PassCLIError?

    init(failure: PassCLIError? = nil) {
        self.failure = failure
    }

    var invocations: [[String]] { lock.withLock { recorded } }

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        lock.withLock { recorded.append(arguments) }
        if let failure { throw failure }
        return ProcessResult(status: 0, stdout: Data("hunter2".utf8), stderr: Data())
    }
}

/// A connected pair of Unix sockets, standing in for the listener and a caller.
private func socketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return (fds[0], fds[1])
}
