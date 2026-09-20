import CopierCore
import SwiftUI

/// A card is inserted but nothing has been scanned yet: pick the check locations,
/// then start the scan. Scanning never starts on its own.
struct ReadyView: View {
    @Bindable var model: BackupModel
    var router: SettingsRouter

    private var card: RemovableVolume? { model.selectedCard }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary)
                Text(card?.name ?? "Card")
                    .font(.system(size: 20, weight: .semibold))
                if let capacity {
                    Text(capacity)
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(spacing: 8) {
                CheckLocationsRow(model: model, router: router)
                    .frame(maxWidth: 620)
                if !model.disabledLocationNames.isEmpty {
                    Text("Deselected locations are skipped.")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("Scan card") { model.startScan() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                Menu("More") {
                    Button("Scan without duplicate check") { model.startScan(skipCheck: true) }
                    Button("Eject card") { model.ejectCard() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("A fast scan treats every file as new and only reads capture dates.")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
    }

    /// `64 GB · 12.3 GB free`, when the volume reports its capacity.
    private var capacity: String? {
        guard let card, card.totalBytes > 0 else { return nil }
        var parts = [Format.bytes(card.totalBytes)]
        if card.freeBytes > 0 {
            parts.append("\(Format.bytes(card.totalBytes - card.freeBytes)) used")
            parts.append("\(Format.bytes(card.freeBytes)) free")
        }
        return parts.joined(separator: " · ")
    }
}
