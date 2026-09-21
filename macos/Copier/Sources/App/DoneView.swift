import CopierCore
import SwiftUI

/// Screen 4 — what was created, with "Show in Finder"; primary action ejects the card.
struct DoneView: View {
    @Bindable var model: BackupModel

    private var failures: [CopyFailure] { model.result?.failures ?? [] }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(failures.isEmpty ? Theme.success : Theme.warning)
                VStack(spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(Format.count(copiedCount))
                            .font(.system(size: 36, weight: .semibold))
                            .monospacedDigit()
                        Text("files backed up")
                            .font(.system(size: 20, weight: .semibold))
                    }
                    Text(summary)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }
            }

            if let folders = model.result?.folders, !folders.isEmpty {
                GroupedBox {
                    ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(folder.lastPathComponent)
                                .font(Theme.mono)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Show in Finder") { FolderPanel.reveal(folder) }
                                .buttonStyle(.link)
                                .font(Theme.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                    }
                }
                .frame(width: 460)
            }

            if !failures.isEmpty {
                GroupedBox {
                    ForEach(Array(failures.enumerated()), id: \.offset) { index, failure in
                        if index > 0 { Divider() }
                        HStack(spacing: 10) {
                            Text(failure.file)
                                .font(Theme.mono)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(failure.reason)
                                .font(Theme.secondary)
                                .foregroundStyle(Theme.warning)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                    }
                }
                .frame(width: 460)
            }

            HStack(spacing: 10) {
                Button {
                    model.ejectCard()
                } label: {
                    Label("Eject \(model.selectedCard?.name ?? "card")", systemImage: "eject")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Done") { model.finish() }
                    .controlSize(.large)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var copiedCount: Int {
        (model.progress?.filesTotal ?? 0) - failures.count
    }

    private var summary: String {
        var parts: [String] = []
        if let progress = model.progress { parts.append(Format.bytes(progress.bytesTotal)) }
        if let destination = model.destination { parts.append("to \(Format.destinationLabel(destination))") }
        parts.append(failures.isEmpty ? "all verified" : "\(failures.count) failed")
        return parts.joined(separator: " · ")
    }
}

/// Shown when a backup could not continue — most often because the card was pulled.
struct FailedView: View {
    @Bindable var model: BackupModel
    let error: BackupError

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.warning)
            VStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                Text(error.localizedDescription)
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button("Try again") { model.retry() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Back") { model.finish() }
                    .controlSize(.large)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch error {
        case .cardRemoved: return "The card was removed"
        case .nasUnreachable: return "The NAS did not answer"
        case .insufficientSpace: return "Not enough space"
        default: return "Backup stopped"
        }
    }
}
