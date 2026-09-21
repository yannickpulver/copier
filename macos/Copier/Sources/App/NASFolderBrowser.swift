import CopierCore
import SwiftUI

/// A lazy outline of the NAS: shares at the root, subfolders on demand, so a path like
/// `/photo/2026` is two clicks instead of something to type.
struct NASFolderBrowser: View {
    @Bindable var model: SettingsModel
    @State private var rows: [BrowserRow] = []
    @State private var expanded: Set<String> = []
    @State private var loading: Set<String> = []
    @State private var errorMessage: String?
    @State private var isLoadingRoot = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Folders on this NAS")
                    .font(Theme.bodySemibold)
                Spacer()
                if isLoadingRoot { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.secondary)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }

            if rows.isEmpty, !isLoadingRoot, errorMessage == nil {
                Text("No shared folders found.")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        BrowserRowView(
                            row: row,
                            isExpanded: expanded.contains(row.path),
                            isLoading: loading.contains(row.path),
                            isAdded: model.synologyFolders.contains(row.path),
                            toggle: { Task { await toggle(row) } },
                            add: { model.addSynologyFolder(row.path) }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 280)
        }
        .frame(width: 380)
        .task { await loadRoot() }
    }

    // MARK: Loading

    private func loadRoot() async {
        isLoadingRoot = true
        defer { isLoadingRoot = false }
        switch await model.browseFolders(in: nil) {
        case let .folders(shares):
            rows = shares.map { BrowserRow(path: $0, depth: 0) }
            errorMessage = nil
        case let .failed(message):
            errorMessage = message
        }
    }

    /// Expand or collapse one folder, fetching its children the first time.
    private func toggle(_ row: BrowserRow) async {
        guard let index = rows.firstIndex(where: { $0.path == row.path }) else { return }

        if expanded.contains(row.path) {
            expanded.remove(row.path)
            // Drop everything nested under this row.
            var end = index + 1
            while end < rows.count, rows[end].depth > row.depth { end += 1 }
            rows.removeSubrange((index + 1)..<end)
            return
        }

        loading.insert(row.path)
        defer { loading.remove(row.path) }
        switch await model.browseFolders(in: row.path) {
        case let .folders(children):
            guard let freshIndex = rows.firstIndex(where: { $0.path == row.path }) else { return }
            expanded.insert(row.path)
            errorMessage = nil
            let inserted = children.map { BrowserRow(path: $0, depth: row.depth + 1) }
            rows.insert(contentsOf: inserted, at: freshIndex + 1)
        case let .failed(message):
            errorMessage = message
        }
    }
}

/// One line of the outline.
private struct BrowserRow: Identifiable, Hashable {
    let path: String
    let depth: Int

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

private struct BrowserRowView: View {
    let row: BrowserRow
    let isExpanded: Bool
    let isLoading: Bool
    let isAdded: Bool
    let toggle: () -> Void
    let add: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(isLoading ? 0 : 1)
            .overlay {
                if isLoading { ProgressView().controlSize(.mini).scaleEffect(0.6) }
            }

            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(row.name)
                .font(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.path)

            Spacer(minLength: 8)

            if isAdded {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .help("Already indexed")
            } else {
                Button("Add", action: add)
                    .buttonStyle(.borderless)
                    .font(Theme.secondary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 12)
        .padding(.trailing, 12)
        .frame(height: 24)
    }
}
