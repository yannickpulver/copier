import CopierCore
import SwiftUI

/// Folder Sync — one or more sources and a target side by side, what is missing, one button.
struct FolderSyncView: View {
    @Bindable var model: SyncModel

    var body: some View {
        // AppKit makes the screen's minimum size a hard constraint on the window's detail
        // column, and SwiftUI measures that minimum at the view's minimum *width*, where
        // every label wraps: ~690 pt, more than the ~640 pt a minimum-height window has.
        // The column then grew past the window and pushed the action row off the bottom.
        // A GeometryReader reports the height it is offered instead of one derived from
        // the content, so the screen is laid out in the space that actually exists.
        GeometryReader { _ in screen }
            .navigationTitle("Folder Sync")
            .navigationSubtitle("Compared by name and size")
    }

    /// The route strip, the status line and the file list, and the bottom bar pinned
    /// under them.
    private var screen: some View {
        VStack(spacing: 0) {
            // The file list scrolls inside its box and takes the remaining height, so the
            // bottom bar stays pinned and the copy button is always reachable.
            VStack(alignment: .leading, spacing: 14) {
                RouteStrip(
                    sources: model.sources,
                    results: model.results,
                    target: targetURL,
                    targetCountText: targetCountText,
                    suggestions: model.suggestedTargets,
                    isBusy: model.isBusy,
                    remove: { model.removeSource($0) },
                    drop: { model.addSources($0) },
                    add: {
                        let urls = FolderPanel.chooseFolders(
                            title: "Choose source folders",
                            start: model.sources.last?.deletingLastPathComponent() ?? model.target
                        )
                        if !urls.isEmpty { model.addSources(urls) }
                    },
                    select: { model.target = $0 },
                    choose: {
                        if let url = FolderPanel.chooseFolder(title: "Choose the target folder", start: model.target) {
                            model.target = url
                        }
                    }
                )
                // Every text in the strip is line-limited, so its minimum height is bounded.
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    status
                    Spacer(minLength: 12)
                    options
                }

                // The list takes every point left over.
                content
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Both switches change what a compare finds, so they are locked while one runs.
    private var options: some View {
        HStack(spacing: 14) {
            if model.sources.count <= 1 {
                Toggle("Add folder name", isOn: $model.appendSourceName)
                    .help("Copy into a subfolder of the target named like the source folder.")
            }
            Toggle("Finder tags", isOn: $model.syncFinderTags)
                .help("Copy Finder tags onto the files the target already has.")
        }
        .toggleStyle(.checkbox)
        .font(Theme.secondary)
        .disabled(model.isBusy)
        .fixedSize()
    }

    /// Review's bottom bar: Rescan and errors on the left, size and the action on the right.
    private var bottomBar: some View {
        HStack(spacing: 12) {
            if showsRescan {
                Button {
                    model.compare()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(Theme.secondary)
                .help("Compare the folders again — picks up files that changed since the last scan.")
                .fixedSize()
            }
            if let message = model.errorMessage {
                Text(message)
                    .font(Theme.secondary)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            // A long error message must not squeeze the size or the button out of the row.
            if showsRescan, !model.filesToCopy.isEmpty {
                Text(Format.bytes(model.bytesToCopy))
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            primaryButton
                .fixedSize()
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    /// The line under the strip: what the compare found, or what is happening.
    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            Text("Pick a source and a target, then compare.")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
        case let .comparing(step):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Comparing — \(step)…")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
            }
        case .compared:
            if model.filesToCopy.isEmpty, model.tagUpdates.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(Theme.success)
                    Text("Everything in the source is already in the target.")
                }
            } else {
                HStack(spacing: 0) {
                    Text(summaryTitle)
                        .font(Theme.bodySemibold)
                        .fixedSize()
                    Text(summaryDetail)
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .monospacedDigit()
            }
        case let .copying(done, total, _):
            Text("Copying — \(Format.count(done)) of \(Format.count(total)) files · \(Format.bytes(model.bytesCopied)) of \(Format.bytes(model.bytesTotal))")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case let .finished(copied, tagged, failures, cancelled):
            let isClean = failures.isEmpty && !cancelled
            HStack(spacing: 7) {
                Image(systemName: isClean ? "checkmark.circle" : "exclamationmark.octagon")
                    .foregroundStyle(isClean ? Theme.success : Color(nsColor: .systemRed))
                Text(finishedMessage(copied: copied, tagged: tagged, failures: failures, cancelled: cancelled))
                    .lineLimit(2)
            }
        }
    }

    // MARK: Body states

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .comparing:
            EmptyView()
        case .compared:
            comparedContent
        case let .copying(done, total, file):
            VStack(alignment: .leading, spacing: 8) {
                if model.bytesTotal > 0 {
                    ProgressView(value: Double(model.bytesCopied), total: Double(model.bytesTotal))
                } else {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(speedLine)
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(file)
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case let .finished(_, _, failures, _):
            VStack(alignment: .leading, spacing: 8) {
                if !failures.isEmpty {
                    GroupedBox {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(failures.enumerated()), id: \.offset) { index, failure in
                                    if index > 0 { Divider() }
                                    HStack {
                                        Text(failure.file).font(Theme.mono).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(failure.reason)
                                            .font(Theme.secondary)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .help(failure.reason)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
            // The failures list fills what is left.
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var speedLine: String {
        var parts = [Format.speed(model.bytesPerSecond)]
        if let left = Format.timeLeft(model.secondsRemaining) { parts.append(left) }
        return parts.joined(separator: " · ")
    }

    private func finishedMessage(copied: Int, tagged: Int, failures: [CopyFailure], cancelled: Bool) -> String {
        var message = "\(Format.count(copied)) file\(copied == 1 ? "" : "s") copied"
        if tagged > 0 { message += ", \(tagged) tag update\(tagged == 1 ? "" : "s") written" }
        if !failures.isEmpty { message += ", \(failures.count) failed" }
        message += cancelled ? " — cancelled, the rest is still listed." : "."
        return message
    }

    /// The Target card's path: the raw target once there is more than one source
    /// (each source gets its own subfolder), otherwise the resolved single-source destination.
    private var targetURL: URL? {
        model.sources.count > 1 ? model.target : model.effectiveTarget
    }

    /// The Target card's count line: "N folders inside" for several sources,
    /// otherwise the target's own file count.
    private var targetCountText: String? {
        if model.sources.count > 1 { return "\(Format.count(model.sources.count)) folders inside" }
        return model.targetCount.map { "\(Format.count($0)) files" }
    }

    /// `216 new files`, or `200 new, 16 replaced` — a "different" file is replaced, not
    /// added, so the files that get overwritten are called out.
    private var summaryTitle: String {
        let added = model.addedCount, replaced = model.replacedCount
        if added + replaced == 0 {
            let updates = model.tagUpdates.count
            return "\(Format.count(updates)) tag update\(updates == 1 ? "" : "s")"
        }
        if replaced == 0 { return "\(Format.count(added)) new file\(added == 1 ? "" : "s")" }
        if added == 0 { return "\(Format.count(replaced)) to replace" }
        return "\(Format.count(added)) new, \(Format.count(replaced)) replaced"
    }

    /// ` · 991 MB · 3,464 already in the target`.
    private var summaryDetail: String {
        var parts: [String] = []
        if !model.filesToCopy.isEmpty {
            parts.append(Format.bytes(model.bytesToCopy))
            if !model.tagUpdates.isEmpty { parts.append("\(Format.count(model.tagUpdates.count)) tag updates") }
        }
        parts.append("\(Format.count(model.identicalCount)) already in the target")
        return " · " + parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var comparedContent: some View {
        let groups = model.fileGroups
        if !groups.isEmpty {
            GroupedBox {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups) { group in
                            let isOpen = model.expandedGroups.contains(group.id)
                            if group.id != groups.first?.id { Divider() }
                            FolderGroupRow(group: group, isOpen: isOpen) {
                                withAnimation(.snappy(duration: 0.2)) {
                                    if isOpen {
                                        model.expandedGroups.remove(group.id)
                                    } else {
                                        model.expandedGroups.insert(group.id)
                                    }
                                }
                            }
                            if isOpen {
                                ForEach(group.rows) { row in
                                    Divider()
                                    SyncFileRow(row: row)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    /// The copy button takes the primary slot, so re-running the comparison needs its
    /// own button: source folders keep changing on disk while the list is up.
    private var showsRescan: Bool {
        guard case .compared = model.phase else { return false }
        return !model.filesToCopy.isEmpty || !model.tagUpdates.isEmpty
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.phase {
        case .comparing, .copying:
            Button("Cancel") { model.cancel() }
                .controlSize(.large)
        case .compared where !model.filesToCopy.isEmpty || !model.tagUpdates.isEmpty:
            Button(copyButtonTitle) { model.copyMissing() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .help(
                    model.replacedCount > 0
                        ? "\(model.replacedCount) file\(model.replacedCount == 1 ? "" : "s") in the target will be overwritten."
                        : "Only files that are missing in the target are copied."
                )
        default:
            Button("Compare") { model.compare() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canCompare)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Says plainly how many files are added and how many are overwritten.
    private var copyButtonTitle: String {
        let total = model.filesToCopy.count
        if total == 0 { return "Write \(Format.count(model.tagUpdates.count)) tag updates" }
        if model.replacedCount == 0 { return "Copy \(Format.count(total)) file\(total == 1 ? "" : "s")" }
        if model.addedCount == 0 { return "Replace \(Format.count(model.replacedCount)) files" }
        return "Copy \(Format.count(total)) files (\(Format.count(model.replacedCount)) replaced)"
    }
}

/// Source → target in one row. The left half lists the source folders, one row each, and
/// takes dropped folders; the right half shows the target and its quick picks.
private struct RouteStrip: View {
    let sources: [URL]
    let results: [SyncModel.SourceResult]
    let target: URL?
    let targetCountText: String?
    let suggestions: [URL]
    let isBusy: Bool
    let remove: (URL) -> Void
    let drop: ([URL]) -> Void
    let add: () -> Void
    let select: (URL) -> Void
    let choose: () -> Void
    @State private var isDropTarget = false

    var body: some View {
        GroupedBox {
            HStack(spacing: 0) {
                sourceSide
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                targetSide
            }
        }
    }

    // MARK: Sources

    /// From five folders on, the rows scroll instead of pushing the list down.
    private static let scrollThreshold = 4

    private var sourceSide: some View {
        HStack(spacing: 8) {
            Group {
                if sources.isEmpty {
                    Button(action: add) {
                        RouteEnd(symbol: "folder", title: "Choose a source", detail: "or drop folders here", isPlaceholder: true)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy)
                } else if sources.count > Self.scrollThreshold {
                    ScrollView { rows }
                        .frame(height: 176)
                } else {
                    rows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: add) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add source folders…")
            .disabled(isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(.rect)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.controlRadius)
                .strokeBorder(.tint, lineWidth: 2)
                .padding(3)
                .opacity(isDropTarget ? 1 : 0)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !isBusy else { return false }
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            drop(folders)
            return true
        } isTargeted: { isDropTarget = $0 && !isBusy }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sources, id: \.path) { source in
                HStack(spacing: 8) {
                    RouteEnd(symbol: "folder", title: source.lastPathComponent, detail: detail(for: source))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        remove(source)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove this source")
                    .disabled(isBusy)
                }
                .help(source.path)
            }
        }
    }

    /// `YANU-SSD · 3,680 files` — the count once a compare has run.
    private func detail(for source: URL) -> String {
        let count = results.first(where: { $0.source.path == source.path })?.sourceCount
        return Self.joined(Format.parentTrail(source), count.map { "\(Format.count($0)) files" })
    }

    // MARK: Target

    private var targetSide: some View {
        HStack(spacing: 8) {
            RouteEnd(
                symbol: "externaldrive",
                title: target?.lastPathComponent ?? "Choose a target",
                detail: target.map { Self.joined(Format.parentTrail($0), targetCountText) } ?? "where the files go",
                isPlaceholder: target == nil
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(target?.path ?? "")

            Menu {
                ForEach(suggestions, id: \.path) { suggestion in
                    Button {
                        select(suggestion)
                    } label: {
                        if suggestion.path == target?.path {
                            Label(suggestion.path, systemImage: "checkmark")
                        } else {
                            Text(suggestion.path)
                        }
                    }
                }
                if !suggestions.isEmpty { Divider() }
                Button("Other…", action: choose)
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose the target folder")
            .disabled(isBusy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private static func joined(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One end of the route: an icon tile, the folder name, and where it lives.
private struct RouteEnd: View {
    let symbol: String
    let title: String
    let detail: String
    var isPlaceholder = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(.quaternary, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.bodySemibold)
                    .foregroundStyle(isPlaceholder ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

/// `› export  216 files · 991 MB` — opens and closes one folder of the file list.
private struct FolderGroupRow: View {
    let group: SyncModel.FileGroup
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    // Both chevrons get the same width, so the title does not shift.
                    .frame(width: 10)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(Theme.bodySemibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(Format.count(group.rows.count)) file\(group.rows.count == 1 ? "" : "s") · \(Format.bytes(group.bytes))")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One file to copy: kind icon, name, a chip when it overwrites a file, and its size.
private struct SyncFileRow: View {
    let row: SyncModel.SyncRow

    var body: some View {
        let kind = FileKind(fileName: row.name)
        HStack(spacing: 8) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(kind.color)
                .frame(width: 14)
                .help(kind.rawValue)
            Text(row.name)
                .font(Theme.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.path)
            if row.replaces {
                TagChip(text: "replaces")
            }
            Text(Format.bytes(row.size))
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.leading, 32)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
    }
}
