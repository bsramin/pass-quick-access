// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import PassQuickAccess

/// What the panel does when Proton Pass is slow or down. The failure these guard
/// against is silence: a fill or copy that reads a field goes out to the server,
/// and while that hangs the panel used to look like it had ignored the key.
@MainActor
final class OutageFeedbackTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")

    func testAStalledReadSaysItIsWaiting() async throws {
        let runner = StallingRunner()
        let viewModel = try await loadedViewModel(runner: runner)
        // Drop the prefetch, so the read under test is the one the action makes.
        viewModel.clearTransientSecrets()

        let action = Task { await viewModel.perform(.fillPassword) }
        defer { action.cancel() }
        await waitUntil { viewModel.busyMessage != nil }

        XCTAssertEqual(viewModel.busyMessage, QuickAccessViewModel.waitingMessage)
    }

    func testASecondPressDoesNotStackAnotherRead() async throws {
        let runner = StallingRunner()
        let viewModel = try await loadedViewModel(runner: runner)
        viewModel.clearTransientSecrets()

        let action = Task { await viewModel.perform(.fillPassword) }
        defer { action.cancel() }
        await waitUntil { viewModel.busyMessage != nil }
        await viewModel.perform(.fillPassword)

        XCTAssertEqual(runner.fieldReads, 1, "the second press must not queue behind the stalled read")
    }

    func testAReadThatTimesOutBlamesTheServiceNotTheItem() async throws {
        let viewModel = try await loadedViewModel(runner: FailingReadRunner(error: .timedOut))

        await viewModel.perform(.fillPassword)

        XCTAssertEqual(viewModel.toast, QuickAccessViewModel.unreachableMessage)
        XCTAssertNil(viewModel.busyMessage, "the notice goes when the read ends")
    }

    func testANetworkErrorReadsAsTheServiceBeingDown() async throws {
        let error = PassCLIError.commandFailed(status: 1, stderr: "error sending request: connection refused")
        let viewModel = try await loadedViewModel(runner: FailingReadRunner(error: error))

        await viewModel.perform(.fillPassword)

        XCTAssertEqual(viewModel.toast, QuickAccessViewModel.unreachableMessage)
    }

    func testAnItemLevelFailureKeepsItsOwnMessage() async throws {
        let error = PassCLIError.commandFailed(status: 1, stderr: "item has no totp")
        let viewModel = try await loadedViewModel(runner: FailingReadRunner(error: error))

        await viewModel.perform(.fillPassword)

        XCTAssertEqual(viewModel.toast, "Couldn't read the password")
    }

    // MARK: - Helpers

    /// A view model with one login item indexed and selected, ready to act on.
    private func loadedViewModel(runner: ProcessRunning) async throws -> QuickAccessViewModel {
        let client = PassCLIClient(executable: executable, runner: runner)
        let viewModel = QuickAccessViewModel(client: client, busyNoticeDelay: .milliseconds(10))
        await viewModel.reload()
        XCTAssertFalse(viewModel.results.isEmpty, "the fixture vault should have indexed")
        return viewModel
    }

    /// Polls the main actor until the condition holds, so a test can catch a
    /// state the view model reaches on its own timer.
    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for the expected state", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Test doubles

/// Answers the index instantly and then hangs on the field read, the way a
/// pass-cli waiting on an unreachable server does.
private final class StallingRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var fieldReads: Int {
        lock.withLock { reads }
    }

    private func recordRead() {
        lock.withLock { reads += 1 }
    }

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        guard arguments.contains("view") else { return indexResponse(for: arguments) }
        recordRead()
        try await Task.sleep(for: .seconds(30))
        return ProcessResult(status: 0, stdout: Data(), stderr: Data())
    }
}

/// Indexes fine, then fails every field read with one given error.
private struct FailingReadRunner: ProcessRunning {
    let error: PassCLIError

    func run(executable: URL, arguments: [String], environment: [String: String]?, timeout: Duration) async throws -> ProcessResult {
        guard arguments.contains("view") else { return indexResponse(for: arguments) }
        throw error
    }
}

/// One vault holding one login item, enough for an action to have a target.
private func indexResponse(for arguments: [String]) -> ProcessResult {
    let json = arguments.contains("vault")
        ? """
        {"vaults": [{"name": "Personal", "vault_id": "v1", "share_id": "s1"}]}
        """
        : """
        {"items": [
          {"id": "i1", "share_id": "s1", "vault_id": "v1", "modify_time": "2026-01-01T00:00:00",
           "content": {"title": "GitHub", "note": "", "item_uuid": "u1", "extra_fields": [],
             "content": {"Login": {"email": "", "username": "octocat",
               "password": "do-not-decode", "urls": ["https://github.com"], "totp_uri": "", "passkeys": []}}}}
        ]}
        """
    return ProcessResult(status: 0, stdout: Data(json.utf8), stderr: Data())
}
