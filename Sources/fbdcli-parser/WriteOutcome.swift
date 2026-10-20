/// How a state-changing write ended, from the CLI's point of view.
///
/// The distinction the CLI has to make is between a write that *did not
/// happen* (the app refused it, the request never arrived, there was no
/// control path) and a write whose *confirmation was lost* (the request went
/// out, but nothing came back — the app may have committed it). Only the
/// second one can leave the system in a changed state, so only the second one
/// is reported as "may have applied".
public enum WriteOutcome: Equatable {
    /// The app answered and accepted the write.
    case applied
    /// The app answered with an error status: the write was refused.
    case refused(status: Int)
    /// The write did not happen (no control path, the request never reached
    /// the app, …). The reason says which.
    case failed(reason: String)
    /// The request was sent, but no confirmation came back. The app may have
    /// committed the write before the confirmation went missing.
    case replyLost(reason: String)
}

/// The CLI's wording for a state-changing write it could not confirm.
///
/// The contract: a lost confirmation is **not** a failed write, it is an
/// unknown one. The message says so, and it names the command that reads the
/// state back — because a blind retry of a write that already landed applies
/// the change twice.
public struct WriteFailure: Equatable {
    /// The phrase used when the confirmation was lost. FBD's honest
    /// vocabulary: the write is not known to have failed, it is known not to
    /// have been confirmed.
    public static let mayHaveApplied = "the command may have applied"

    /// What the CLI knows about the write.
    public let outcome: WriteOutcome
    /// The command that was run, e.g. `brightness 1`.
    public let command: String
    /// The command that reads the state back, e.g. `fbdcli brightness 1`.
    /// nil when no command prints that state.
    public let readBack: String?

    public init(outcome: WriteOutcome, command: String, readBack: String?) {
        self.outcome = outcome
        self.command = command
        self.readBack = readBack
    }

    /// What happened to the write, in one clause.
    public var reason: String {
        switch outcome {
        case .applied:
            return "the write was confirmed"
        case .refused(let status):
            return "the app refused the write (HTTP \(status))"
        case .failed(let reason):
            return reason
        case .replyLost(let reason):
            return "\(reason) — \(Self.mayHaveApplied)"
        }
    }

    /// The line the CLI prints.
    public var message: String {
        if let readBack {
            return "fbdcli: \(command): \(reason). Verify the state with: \(readBack)"
        }
        return "fbdcli: \(command): \(reason). The CLI cannot read that state back."
    }

    /// The exit code for a failed write.
    ///
    /// 75 (`EX_TEMPFAIL`) when the confirmation was lost: the write may have
    /// been committed, so the caller has to read the state back before doing
    /// anything else — a plain failure code would invite a blind retry. 2 for
    /// a write that failed outright.
    public var exitCode: Int32 {
        switch outcome {
        case .replyLost: return 75
        case .applied, .refused, .failed: return 2
        }
    }
}
