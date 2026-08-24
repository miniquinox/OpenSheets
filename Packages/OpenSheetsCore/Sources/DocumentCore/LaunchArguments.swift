import Foundation

/// What a cold launch's `argv` asks the app to do.
///
/// # Why the app has to read `argv` at all
///
/// There are two ways to hand macOS a file to open, and they do not meet:
///
/// - `open -a OpenSheets budget.xlsx` gives the file to **LaunchServices**, which delivers it as
///   an `odoc` Apple Event. `argv` holds nothing but the executable path, and the file arrives at
///   `application(_:open:)`.
/// - `open OpenSheets --args budget.xlsx` gives the file to the **process**. `argv` holds it, no
///   Apple Event is sent, and `application(_:open:)` is never called.
///
/// The second is the shell convention — it is what happens if you run the binary directly, and
/// what a script or a debugger configuration does — and it produced **no window at all**. The
/// measured reason is specific and worth writing down, because it is not obvious and it is not
/// this app's own window bookkeeping:
///
/// **A bare `argv` token makes SwiftUI skip the `WindowGroup`'s default window.** Launching with
/// `--args -someFlag value` (a flag pair, which `NSUserDefaults`' argument domain consumes) still
/// produces the default window; launching with `--args anything` — a real path or the word
/// `nonsense`, it makes no difference — produces nothing. SwiftUI reads an unconsumed argument as
/// "this launch came with documents, so wait to be told what to open" and never creates a scene.
/// No scene means no `openWindow` action, which means the queued file can never be opened either.
/// So the launch produced a running app with an empty Window menu.
///
/// Nothing here is a workaround for that: the app genuinely was asked to open a file and simply
/// never looked. ``bareArguments`` is what it was asked to open, and
/// ``suppressesTheDefaultWindow`` is the flag that says macOS owes us a window we have to ask for.
public struct LaunchArguments: Sendable, Equatable {
    /// Arguments that are neither the executable path nor part of a `-flag value` pair.
    ///
    /// This is the set AppKit leaves alone, which is exactly the set that both means "open this"
    /// *and* trips SwiftUI's suppression.
    public let bareArguments: [String]

    /// Parses a process's `argv` the way the platform does.
    ///
    /// The rule is `NSUserDefaults`' argument domain: **a token starting with `-` swallows the one
    /// after it, whatever that one is.** Following it is what stops `-NSDocumentRevisionsDebugMode
    /// YES` — which is what an Xcode scheme passes — from being read as a request to open a file
    /// called `YES`.
    ///
    /// The "whatever that one is" part is not a guess; it is what launching the app measured, and
    /// the two readings disagree in a way that matters. Under "a flag swallows the next
    /// *non-flag*", `-one -two file.xlsx` leaves nothing bare and SwiftUI would make its default
    /// window. It does not: that launch comes up with no window, which is only possible if
    /// `file.xlsx` is still bare — so `-one` ate `-two`. Erring the other way is the failure this
    /// type exists to prevent, because a launch we think is windowless-proof and is not is a
    /// launch with nothing on screen.
    ///
    /// An empty argument is bare, and also measured: `--args ""` suppresses the default window
    /// just as a path does. It opens nothing — ``files(existingAt:)`` drops it — but the window
    /// still has to be asked for.
    public init(_ arguments: [String]) {
        var bare: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument.hasPrefix("-") {
                index += 1
            } else {
                bare.append(argument)
            }
        }
        bareArguments = bare
    }

    /// Whether this launch will leave the app with no window unless one is asked for.
    ///
    /// True for *any* bare argument, including one that names nothing on disk. The suppression is
    /// SwiftUI's and it does not check: an unopenable argument would otherwise leave the user
    /// staring at a menu bar with no window behind it, which is the worse of the two failures.
    public var suppressesTheDefaultWindow: Bool { !bareArguments.isEmpty }

    /// The files to open, in the order they were given, keeping only the ones that exist.
    ///
    /// A path that is not there is dropped rather than opened into an error window: `argv` is not
    /// a user gesture the way a Finder double-click is, and a typo in a shell command should not
    /// leave a broken document window behind. The launcher still appears, because
    /// ``suppressesTheDefaultWindow`` does not depend on this.
    public func files(
        existingAt exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        bareArguments
            .filter(exists)
            .map { URL(fileURLWithPath: $0) }
    }
}
