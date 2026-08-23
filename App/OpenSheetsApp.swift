import SwiftUI

/// The app entry point, deliberately almost empty.
///
/// PLAN.md §2.1: the Xcode target is thin on purpose. Eleven agents editing one
/// `project.pbxproj` produces unmergeable garbage, so ~95% of the code lives in
/// `Packages/OpenSheetsCore` where adding a file requires editing no manifest. A8 replaces
/// this file with the real document scene; everything it needs from the window is already
/// configured here so that swap does not also become a window-chrome debugging session.
///
/// The two modifiers below are not cosmetic. `.hiddenTitleBar` plus a full-size content view
/// is what lets the grid bleed under the toolbar with `.backgroundExtensionEffect()`
/// (PLAN.md §3.1) — a standard titled window would stop the content at a hard edge and the
/// glass would sit on a seam.
@main
struct OpenSheetsApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchPlaceholder()
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1280, height: 800)
    }
}

/// What Wave 0 shows: proof the window opens and the package is linked.
///
/// A8 deletes this.
private struct LaunchPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("OpenSheets")
                .font(.largeTitle.weight(.semibold))
            Text(Flags.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("OpenSheets")
    }
}
