import CopierCore
import SwiftUI

/// Screen 3 — percent, speed, time left, current file, state per folder. Only action: Cancel.
struct CopyingView: View {
    @Bindable var model: BackupModel

    private var progress: CopyProgress? { model.progress }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text("\(Int(((progress?.fraction ?? 0) * 100).rounded()))%")
                        .font(Theme.big)
                        .monospacedDigit()
                    Text(countsLine)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                ProgressView(value: progress?.fraction ?? 0)
                    .progressViewStyle(.linear)

                VStack(alignment: .leading, spacing: 6) {
                    Text(speedLine)
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(progress?.currentFile ?? "")
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let folders = progress?.folders, !folders.isEmpty {
                GroupedBox {
                    ForEach(Array(folders.enumerated()), id: \.element.id) { index, folder in
                        if index > 0 { Divider() }
                        FolderProgressRow(folder: folder)
                    }
                }
            }

            Text("You can keep using your Mac. Copier verifies every file after copying.")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button("Cancel") { model.cancel() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var countsLine: String {
        guard let progress else { return "" }
        return "\(Format.count(progress.filesDone)) of \(Format.count(progress.filesTotal)) files · "
            + "\(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.bytesTotal))"
    }

    private var speedLine: String {
        var parts = [Format.speed(model.bytesPerSecond)]
        if let left = Format.timeLeft(model.secondsRemaining) { parts.append(left) }
        return parts.joined(separator: " · ")
    }
}

private struct FolderProgressRow: View {
    let folder: FolderProgress

    var body: some View {
        HStack(spacing: 12) {
            Text(folder.url.lastPathComponent)
                .font(Theme.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(folder.state == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(countLabel)
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            switch folder.state {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.success)
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warning)
            case .copying:
                ProgressView(value: Double(folder.filesDone), total: Double(max(folder.filesTotal, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 72)
            case .pending:
                Text("waiting")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var countLabel: String {
        switch folder.state {
        case .copying:
            return "\(folder.filesDone) of \(folder.filesTotal)"
        default:
            return "\(folder.filesTotal) file\(folder.filesTotal == 1 ? "" : "s")"
        }
    }
}
