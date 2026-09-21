import CopierCore
import SwiftUI

/// Between card insert and review: the same check-locations row, plus what Copier is
/// doing right now and the fast-scan escape hatch.
struct ScanningView: View {
    @Bindable var model: BackupModel
    let event: ScanEvent?
    var router: SettingsRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CheckLocationsRow(model: model, router: router)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)

            Divider()

            VStack(spacing: 22) {
                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    VStack(spacing: 6) {
                        Text(phaseTitle)
                            .font(.system(size: 20, weight: .semibold))
                        Text(detail)
                            .font(Theme.body)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 10) {
                    Button("Cancel") { model.cancel() }
                    Button("Skip duplicate check") { model.startScan(skipCheck: true) }
                        .help("Treat every file as new and only read capture dates — much faster, but nothing is deduplicated.")
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 60)
        }
    }

    private var phaseTitle: String {
        switch event?.phase {
        case .sources: return "Checking existing backups"
        case .metadata: return "Reading capture dates"
        default: return "Scanning card"
        }
    }

    private var detail: String {
        guard let event else { return "Reading the card…" }
        switch event.phase {
        case .card:
            return "\(Format.count(event.count)) files · \(event.detail)"
        case .sources:
            return event.detail
        case .metadata:
            if let total = event.total, total > 0 {
                return "\(Format.count(event.count)) of \(Format.count(total))"
            }
            return event.detail
        }
    }
}
