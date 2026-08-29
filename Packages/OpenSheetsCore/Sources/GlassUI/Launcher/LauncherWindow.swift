import SwiftUI

public struct RecentItem: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The containing folder, abbreviated with `~`. The folder is what distinguishes two files
    /// called `budget.xlsx`, so it is shown, not hidden behind a tooltip.
    public var folder: String
    /// "2 hours ago", already formatted.
    public var lastOpened: String
    public var sheetCount: Int
    /// False once the file has been moved or deleted. Shown dimmed with a badge rather than
    /// silently dropped — a recents list that quietly forgets things is a recents list you cannot
    /// trust to tell you where something went.
    public var exists: Bool
    /// Whether the containing folder is an active workspace grant (PLAN.md §7.2).
    public var isGranted: Bool

    public init(
        id: String,
        name: String,
        folder: String,
        lastOpened: String,
        sheetCount: Int,
        exists: Bool = true,
        isGranted: Bool = true
    ) {
        self.id = id
        self.name = name
        self.folder = folder
        self.lastOpened = lastOpened
        self.sheetCount = sheetCount
        self.exists = exists
        self.isGranted = isGranted
    }

    /// `.xlsx` gets a table glyph, `.csv` a text one. Small, and it is the fastest way to tell
    /// the two apart in a grid of eight.
    public var symbolName: String {
        name.lowercased().hasSuffix(".csv") ? "doc.plaintext" : "tablecells"
    }
}

public struct WorkspaceGrantItem: Sendable, Hashable, Identifiable {
    public var id: String
    /// The granted folder, abbreviated with `~`.
    public var path: String
    /// "3 days ago", already formatted.
    public var grantedAt: String
    public var fileCount: Int

    public init(id: String, path: String, grantedAt: String, fileCount: Int) {
        self.id = id
        self.path = path
        self.grantedAt = grantedAt
        self.fileCount = fileCount
    }
}

public struct LauncherState: Sendable, Hashable {
    public var recents: [RecentItem]
    public var grants: [WorkspaceGrantItem]
    /// True while a file is being dragged over the window.
    public var isDropTargeted: Bool
    /// Set when a drop was refused, with the reason. Shown inline, not in an alert.
    public var dropRejection: String?

    public init(
        recents: [RecentItem] = [],
        grants: [WorkspaceGrantItem] = [],
        isDropTargeted: Bool = false,
        dropRejection: String? = nil
    ) {
        self.recents = recents
        self.grants = grants
        self.isDropTargeted = isDropTargeted
        self.dropRejection = dropRejection
    }
}

public enum LauncherAction: Sendable, Hashable {
    case open(String)
    case openFile
    case newSheet
    case dropped([URL])
    case removeRecent(String)
    case revealRecent(String)
    case grantFolder
    case revokeGrant(String)
    case showGrants
}

/// First run, and every run after it. PLAN.md §1.1.
///
/// A single glass panel over the desktop. That is the whole design: the launcher is the one place
/// in the app where glass has something genuinely interesting behind it — the user's actual
/// desktop — so it is the one place the material gets to be the point rather than the frame.
///
/// The drop target is not a dashed rectangle waiting to be noticed. The panel *is* the drop
/// target; dropping anywhere on it works, and the visible state change on drag-over is the glass
/// taking the accent tint, which is the same "something is happening" language the refresh pill
/// uses. One idiom, two places.
public struct LauncherWindow: View {
    private let state: LauncherState
    private let context: AppearanceContext
    private let perform: (LauncherAction) -> Void

    public init(
        state: LauncherState,
        context: AppearanceContext,
        perform: @escaping (LauncherAction) -> Void
    ) {
        self.state = state
        self.context = context
        self.perform = perform
    }

    /// The window's content size. ``WindowChrome/configureLauncherWindow(_:)`` is what applies it.
    ///
    /// The *card* does not use this — it fills whatever it is given. That asymmetry is the point:
    /// there used to be two sizes that disagreed, a 640×460 card inside a window the scene asked
    /// to be 720×520, and every pixel of the difference was transparent, invisible and still
    /// solid to the mouse. One of them has to be the authority and it has to be the window, since
    /// the window is what the titlebar's height gets added to.
    public static let panelSize = CGSize(width: 720, height: 520)

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            header
            contents
            actions
        }
        .padding(DS.Space.xxl)
        // Fills the window rather than sizing itself. A fixed card in a window sized from the same
        // constant still leaves the titlebar's height over: the content area is that much taller
        // than the number both of them were given, and the leftover strip is clear glass over the
        // desktop with the close button sitting in it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // `flush`, not `card`, and for the reason ``DS/Radius/flush`` gives: this fills the window,
        // so a 24pt radius here is a second curve inside the window's own, with a crescent of
        // desktop showing between them at all four corners. One curve, and it is the system's.
        .glassCard(
            context: context,
            radius: DS.Radius.flush,
            signal: state.isDropTargeted ? .agent : .neutral
        )
        .animation(DS.Motion.standard, value: state.isDropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            perform(.dropped(urls))
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("OpenSheets")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("OpenSheets")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(DS.Chrome.primary)
            Text(
                state.isDropTargeted
                    ? "Drop to open."
                    : "Open a workbook, or drop one anywhere on this window."
            )
            .font(DS.Text.body)
            .foregroundStyle(DS.Chrome.secondary)
            .contentTransition(.opacity)

            if let rejection = state.dropRejection {
                Label(rejection, systemImage: "exclamationmark.circle")
                    .font(DS.Text.caption)
                    .foregroundStyle(DS.Signal.errorInk(context))
            }
        }
    }

    private var recentsGrid: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Recent", trailing: "\(state.recents.count)")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: DS.Space.m)],
                spacing: DS.Space.m
            ) {
                ForEach(state.recents) { item in
                    recentCard(item)
                }
            }
        }
    }

    private func recentCard(_ item: RecentItem) -> some View {
        Button { perform(.open(item.id)) } label: {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(DS.Chrome.accent)
                    Spacer(minLength: 0)
                    if !item.exists {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Signal.calmInk(context))
                            .help("This file is no longer where it was.")
                    } else if !item.isGranted {
                        Image(systemName: "shield.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Signal.calmInk(context))
                            .help("Claude cannot reach this folder yet.")
                    }
                }
                Text(item.name)
                    .font(DS.Text.bodyEmphasis)
                    .foregroundStyle(DS.Chrome.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.folder)
                    .font(DS.Text.path)
                    .foregroundStyle(DS.Chrome.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                HStack(spacing: DS.Space.xs) {
                    Text(item.lastOpened)
                        .dsNumeric(DS.Text.numericCaption)
                    Text("·")
                    Text("\(item.sheetCount) \(item.sheetCount == 1 ? "sheet" : "sheets")")
                        .dsNumeric(DS.Text.numericCaption)
                }
                .foregroundStyle(DS.Chrome.tertiary)
            }
            .opacity(item.exists ? 1 : 0.5)
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                DS.Radius.shape(DS.Radius.control).fill(DS.Chrome.separator)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show in Finder") { perform(.revealRecent(item.id)) }
            Divider()
            Button("Remove from recents", role: .destructive) { perform(.removeRecent(item.id)) }
        }
        .accessibilityLabel(
            "\(item.name), in \(item.folder), \(item.sheetCount) sheets, opened \(item.lastOpened)"
                + (item.exists ? "" : ", missing")
        )
    }

    private var emptyRecents: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeader("Recent")
            Text("Nothing yet. The files you open show up here.")
                .font(DS.Text.body)
                .foregroundStyle(DS.Chrome.tertiary)
                .padding(.vertical, DS.Space.xl)
        }
    }

    /// Everything that grows with use: the recents, and the folders that have been granted.
    ///
    /// In a scroll view, which is the whole of the fix. The panel is a fixed size on purpose — a
    /// launcher that is a different shape every morning depending on how much you opened last week
    /// is not a window anybody learns the position of — but `.frame(width:height:)` does not clip.
    /// It stops *reporting* a larger size while still laying the content out, so a thirteenth
    /// recent was placed beyond the card's own edge and drawn directly onto the desktop, with the
    /// glass ending somewhere in the middle of the grid and the granted folders floating below it
    /// on nothing at all. Scrolling is what turns the fixed height into a real boundary instead of
    /// a claim.
    private var contents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                if state.recents.isEmpty {
                    emptyRecents
                } else {
                    recentsGrid
                }
                if !state.grants.isEmpty {
                    grants
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var grants: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            SectionHeader("Folders Claude can reach", trailing: "\(state.grants.count)")
            ForEach(state.grants) { grant in
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Chrome.secondary)
                    Text(grant.path)
                        .font(DS.Text.path)
                        .foregroundStyle(DS.Chrome.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: DS.Space.s)
                    Text("\(grant.fileCount)")
                        .dsNumeric(DS.Text.numericCaption)
                        .foregroundStyle(DS.Chrome.tertiary)
                    Button("Revoke") { perform(.revokeGrant(grant.id)) }
                        .buttonStyle(.plain)
                        .font(DS.Text.caption)
                        .foregroundStyle(DS.Chrome.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(grant.path), granted \(grant.grantedAt)")
            }
        }
    }

    /// Pinned under the scroll view rather than carried along at the bottom of it.
    ///
    /// `Open…` is the reason the window exists. A primary action that scrolls out of reach once
    /// the user has opened enough files is one that gets less reachable the longer they use the
    /// app, which is exactly backwards.
    private var actions: some View {
        HStack(spacing: DS.Space.s) {
            Button("New sheet") { perform(.newSheet) }
                .buttonStyle(.bordered)
            Button("Open…") { perform(.openFile) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("o", modifiers: .command)
            Spacer(minLength: 0)
            Button("Grant a folder…") { perform(.grantFolder) }
                .buttonStyle(.plain)
                .font(DS.Text.control)
                .foregroundStyle(DS.Chrome.accent)
                .help("Lets Claude Code read and write spreadsheets inside a folder you pick.")
        }
        .font(DS.Text.control)
    }
}
