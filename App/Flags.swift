import DocumentCore
import Foundation

/// Feature flags (PLAN.md §11).
///
/// The definitions moved into `DocumentCore` in Wave 2 and this is now a re-export. There were
/// briefly two `Flags` enums reading the same `UserDefaults` keys with **different defaults** —
/// one in the app target, one in the package — which is a bug that shows up as a feature being on
/// in the window and off in the same process's document model. One definition, in the layer that
/// both the window and the document model can see.
///
/// `defaults write com.quino.opensheets OSFlagEditing -bool YES` still takes effect at the next
/// check rather than the next launch, which is what makes a flag useful while developing.
typealias Flags = DocumentCore.Flags

extension DocumentCore.Flags {
    /// Every flag and its current value, for bug reports.
    static var summary: String {
        let states = [
            ("editing", editingEnabled),
            ("mcp", mcpEnabled),
            ("formulaEngine", formulaEngineEnabled),
            ("snapshots", snapshotsEnabled),
            ("changeTracking", changeTrackingEnabled),
            ("sheetStructure", sheetStructureEditing),
            ("explorer", explorerEnabled),
            ("handshake", handshakeEnabled),
            ("chat", chatEnabled),
        ]
        return states.map { "\($0.0)=\($0.1 ? "on" : "off")" }.joined(separator: " ")
    }
}
