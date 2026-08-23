import Foundation
import SheetModel

/// How a failure is written for whoever reads it — an agent over MCP, or a person at a shell.
///
/// One place, because the two front ends must not describe the same failure differently, and
/// because one of `SheetError`'s recovery suggestions is actively misleading in this context and
/// has to be replaced rather than repeated.
public enum ErrorText {
    /// `[code] message`, plus a line saying what to do about it when there is one.
    public static func render(_ error: SheetError) -> String {
        var text = "[\(error.code)] \(error.message)"
        if let advice = advice(for: error) { text += "\n\(advice)" }
        return text
    }

    /// What to do next.
    ///
    /// Mostly ``SheetModel/SheetError/recoverySuggestion``, with one deliberate override:
    /// `SheetError.pathDenyListed` carries the same *"grant the folder in OpenSheets"* line the
    /// outside-the-workspace case does, and here that is wrong — a deny-list rule overrides
    /// grants, so granting the folder changes nothing. Telling a user to do something that
    /// cannot work is worse than telling them nothing, and telling an *agent* to do it costs a
    /// round trip and ends in the same refusal.
    static func advice(for error: SheetError) -> String? {
        if case let .pathDenyListed(_, rule) = error {
            return "This is not a grant problem: '\(rule)' is refused inside granted folders too. "
                + "Nothing you can do in the app will allow it."
        }
        return error.recoverySuggestion
    }
}
