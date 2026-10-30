import XCTest
@testable import CompanionCore

@MainActor
final class OperationGateTests: XCTestCase {
    func testUserActionReceivesTheBackgroundSlotBeforeAnotherOperationCanAcquireIt() async throws {
        let scratch = try ScratchDirectory(); defer { scratch.cleanup() }
        let gate = OperationGate(log: CompanionLog(paths: scratch.paths))
        let acquired = await gate.acquireBackground(), background = try XCTUnwrap(acquired)
        let user = Task { await gate.acquireForUserAction() }
        let waiting = await eventually { await gate.hasPendingUserAction }
        XCTAssertTrue(waiting)
        await gate.release(background)
        let next = await user.value, token = try XCTUnwrap(next)
        let unrelated = await gate.acquire(), anotherPoll = await gate.acquireBackground()
        XCTAssertNil(unrelated); XCTAssertNil(anotherPoll)
        await gate.release(background) // A stale release must not unlock the foreground slot.
        let stillBusy = await gate.isBusy
        XCTAssertTrue(stillBusy)
        await gate.release(token)
        let free = await gate.isBusy
        XCTAssertFalse(free)
    }

    func testCancellationOfAQueuedActionDoesNotRunItOrLeakTheGate() async throws {
        let scratch = try ScratchDirectory(); defer { scratch.cleanup() }
        let gate = OperationGate(log: CompanionLog(paths: scratch.paths))
        let acquired = await gate.acquireBackground(), background = try XCTUnwrap(acquired)
        let user = Task { await gate.acquireForUserAction() }
        let waiting = await eventually { await gate.hasPendingUserAction }
        XCTAssertTrue(waiting)
        user.cancel()
        let cancelled = await user.value
        XCTAssertNil(cancelled)
        await gate.release(background)
        let acquiredAgain = await gate.acquire(), next = try XCTUnwrap(acquiredAgain)
        await gate.release(next)
    }

    func testABackgroundLookIsNotAForegroundOperation() async throws {
        let scratch = try ScratchDirectory(); defer { scratch.cleanup() }
        let gate = OperationGate(log: CompanionLog(paths: scratch.paths))
        let acquired = await gate.acquireBackground(), background = try XCTUnwrap(acquired)
        let busy = await gate.isBusy, foreground = await gate.isBusyInForeground
        XCTAssertTrue(busy); XCTAssertFalse(foreground)
        await gate.release(background)
        let operation = await gate.acquire(), token = try XCTUnwrap(operation)
        let held = await gate.isBusyInForeground
        XCTAssertTrue(held)
        await gate.release(token)
    }

    func testForegroundOperationsStillRejectDuplicateActions() async throws {
        let scratch = try ScratchDirectory(); defer { scratch.cleanup() }
        let gate = OperationGate(log: CompanionLog(paths: scratch.paths))
        let acquired = await gate.acquire(), first = try XCTUnwrap(acquired)
        let duplicate = await gate.acquireForUserAction(), poll = await gate.acquireBackground()
        XCTAssertNil(duplicate); XCTAssertNil(poll)
        await gate.release(first)
    }
}
