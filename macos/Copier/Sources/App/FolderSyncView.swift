import CopierCore
import SwiftUI

/// Folder Sync — one or more sources and a target side by side, what is missing, one button.
struct FolderSyncView: View {
    @Bindable var model: SyncModel

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader("Folder Sync", detail: "Compared by name and size")

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    SourcesCard(
                        sources: model.sources,
                        results: model.results,
                        isBusy: model.isBusy,
                        remove: { model.removeSource($0) },
                        add: {
                            let urls = FolderPanel.chooseFolders(
                                title: "Choose source folders",
                                start: model.sources.last?.deletingLastPathComponent() ?? model.target
                            )
                            if !urls.isEmpty { model.addSources(urls) }
                        }
                    )
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    FolderCard(
                        label: "Target",
                        url: targetURL,
                        countText: targetCountText,
                        isBusy: model.isBusy,
                        choose: {
                            if let url = FolderPanel.chooseFolder(title: "Choose the target folder", start: model.target) {
                                model.target = url
                            }
                        }
                    )
                }

                HStack(spacing: 18) {
                    if model.sources.count <= 1 {
                        Toggle("Add source folder name to target", isOn: $model.appendSourceName)
                            .toggleStyle(.checkbox)
                            .font(Theme.secondary)
                    }
                    Toggle("Sync Finder tags", isOn: $model.syncFinderTags)
                        .toggleStyle(.checkbox)
                        .font(Theme.secondary)
                    Spacer(minLength: 0)
                }

                content

                Spacer(minLength: 0)

                HStack {
                    if let message = model.errorMessage {
                        Text(message)
                            .font(Theme.secondary)
                            .foregroundStyle(Theme.warning)
                    }
                    Spacer()
                    primaryButton
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Body states

    @ViewBuilder
    private var content: some View {
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
            comparedContent
        case let .copying(done, total, file):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("\(Format.count(done)) of \(Format.count(total)) · \(file)")
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case let .finished(copied, tagged, failures, cancelled):
            VStack(alignment: .leading, spacing: 8) {
                InlineBanner(
                    kind: failures.isEmpty && !cancelled ? .warning : .error,
                    message: finishedMessage(copied: copied, tagged: tagged, failures: failures, cancelled: cancelled)
                )
                if !failures.isEmpty {
                    GroupedBox {
                        ForEach(Array(failures.prefix(10).enumerated()), id: \.offset) { index, failure in
                            if index > 0 { Divider() }
                            HStack {
                                Text(failure.file).font(Theme.mono).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(failure.reason).font(Theme.secondary).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                        }
                    }
                }
            }
        }
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

    /// `20 new, 4 replaced` — the target files that get overwritten are called out,
    /// because a "different" file is replaced, not added.
    private var changeSummary: String {
        var parts: [String] = []
        if model.addedCount > 0 { parts.append("\(Format.count(model.addedCount)) new") }
        if model.replacedCount > 0 { parts.append("\(Format.count(model.replacedCount)) replaced") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var comparedContent: some View {
        let files = model.displayFiles
        if files.isEmpty, model.tagUpdates.isEmpty {
            InlineBanner(kind: .warning, message: "Everything in the source is already in the target.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                InlineBanner(
                    kind: .warning,
                    message: "\(Format.count(files.count)) file\(files.count == 1 ? "" : "s") to copy — \(changeSummary) · \(Format.bytes(model.bytesToCopy))"
                        + (model.tagUpdates.isEmpty ? "" : " · \(model.tagUpdates.count) tag updates")
                )
                GroupedBox {
                    ForEach(Array(files.prefix(5).enumerated()), id: \.offset) { index, file in
                        if index > 0 { Divider() }
                        HStack(spacing: 12) {
                            Text(file.path)
                                .font(Theme.mono)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(Format.bytes(file.size))
                                .font(Theme.secondary)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                    if files.count > 5 {
                        Divider()
                        Text("and \(files.count - 5) more")
                            .font(Theme.secondary)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                }
            }
        }
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
        if model.replacedCount == 0 { return "Copy \(Format.count(total)) missing files" }
        if model.addedCount == 0 { return "Replace \(Format.count(model.replacedCount)) files" }
        return "Copy \(Format.count(total)) files (\(Format.count(model.replacedCount)) replaced)"
    }
}

/// Dashed-border card chrome shared by ``FolderCard`` and ``SourcesCard``.
private struct DashedCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(.rect(cornerRadius: Theme.listRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.listRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Theme.hairline)
            )
    }
}

private struct FolderCard: View {
    let label: String
    let url: URL?
    let countText: String?
    var isBusy: Bool = false
    let choose: () -> Void

    var body: some View {
        DashedCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: label)
                Text(url?.path ?? "Not chosen")
                    .font(Theme.mono)
                    .foregroundStyle(url == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(countText ?? " ")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Choose…", action: choose)
                    .disabled(isBusy)
            }
        }
    }
}

/// The Source side once several folders can be chosen: one row per folder, with a
/// per-row file count (once compared) and a remove button, plus an "Add…" button.
private struct SourcesCard: View {
    let sources: [URL]
    let results: [SyncModel.SourceResult]
    let isBusy: Bool
    let remove: (URL) -> Void
    let add: () -> Void

    var body: some View {
        DashedCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Sources")
                if sources.isEmpty {
                    Text("Not chosen")
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if sources.count > Self.scrollThreshold {
                    // A long list scrolls; a short one hugs its rows so the card stays compact.
                    ScrollView { rows }
                        .frame(height: 160)
                } else {
                    rows
                }
                Button("Add…", action: add)
                    .disabled(isBusy)
            }
        }
    }

    private static let scrollThreshold = 6

    private var rows: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(sources, id: \.path) { source in
                HStack(spacing: 8) {
                    Text(source.path)
                        .font(Theme.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let count = results.first(where: { $0.source.path == source.path })?.sourceCount {
                        Text("\(Format.count(count)) files")
                            .font(Theme.secondary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Button {
                        remove(source)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isBusy)
                }
            }
        }
    }
}
