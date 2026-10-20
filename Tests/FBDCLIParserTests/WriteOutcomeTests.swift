import XCTest
@testable import FBDCLIParser

/// The lost-reply taxonomy (issue #31): a write whose confirmation was lost
/// is an *unknown* write, and the CLI says so instead of inviting a retry.
final class WriteOutcomeTests: XCTestCase {
    private func failure(_ outcome: WriteOutcome) -> WriteFailure {
        WriteFailure(
            outcome: outcome,
            command: "brightness 1",
            readBack: "fbdcli brightness 1"
        )
    }

    func testALostReplySaysTheCommandMayHaveApplied() {
        let message = failure(.replyLost(reason: "the app did not answer in time")).message
        XCTAssertTrue(message.contains("the command may have applied"))
    }

    func testALostReplyNamesTheVerifyingCommand() {
        let message = failure(.replyLost(reason: "the app did not answer in time")).message
        XCTAssertTrue(message.contains("fbdcli brightness 1"))
        XCTAssertTrue(message.contains("Verify the state with:"))
    }

    func testALostReplyExitsWithTheTemporaryFailureCode() {
        // 75 (EX_TEMPFAIL): the write may have been committed, so the caller
        // has to read the state back — a plain failure code invites a retry.
        XCTAssertEqual(failure(.replyLost(reason: "the app did not answer in time")).exitCode, 75)
    }

    func testARefusedWriteIsNotAMayHaveApplied() {
        let message = failure(.refused(status: 400)).message
        XCTAssertFalse(message.contains("may have applied"))
        XCTAssertTrue(message.contains("HTTP 400"))
        XCTAssertEqual(failure(.refused(status: 400)).exitCode, 2)
    }

    func testAFailedWriteIsNotAMayHaveApplied() {
        let message = failure(.failed(reason: "the write was not sent (DDC unavailable?)")).message
        XCTAssertFalse(message.contains("may have applied"))
        XCTAssertTrue(message.contains("the write was not sent (DDC unavailable?)"))
        XCTAssertEqual(failure(.failed(reason: "x")).exitCode, 2)
    }

    /// No failure message may invite a blind retry of a write.
    func testNoFailureMessageInvitesARetry() {
        let outcomes: [WriteOutcome] = [
            .applied,
            .refused(status: 500),
            .failed(reason: "the write was not sent"),
            .replyLost(reason: "the app did not answer in time"),
        ]
        for outcome in outcomes {
            let message = failure(outcome).message.lowercased()
            XCTAssertFalse(message.contains("try again"), message)
            XCTAssertFalse(message.contains("retry"), message)
            XCTAssertFalse(message.contains("please try"), message)
        }
    }

    func testTheMessageNamesTheCommandThatWasRun() {
        let message = failure(.replyLost(reason: "the app did not answer in time")).message
        XCTAssertTrue(message.hasPrefix("fbdcli: brightness 1: "))
    }

    /// A command with no read-back says so, rather than pointing at a
    /// command that cannot show the state.
    func testACommandWithoutAReadBackSaysSo() {
        let failure = WriteFailure(
            outcome: .failed(reason: "the write was not sent"),
            command: "underscan 1",
            readBack: nil
        )
        XCTAssertTrue(failure.message.contains("The CLI cannot read that state back."))
        XCTAssertFalse(failure.message.contains("Verify the state with:"))
    }
}
