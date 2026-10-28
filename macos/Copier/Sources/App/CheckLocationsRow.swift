import CopierCore
import SwiftUI

/// The row the Electron app had: "CHECK LOCATIONS" plus one pill per source, with a
/// status dot each. Clicking a pill switches that source off for the next scan.
/// Shown on Waiting and Scanning; Review shows ``CheckedLocationsLine`` instead.
struct CheckLocationsRow: View {
    @Bindable var model: BackupModel
    @Environment(\.openSettings) private var openSettings
    var router: SettingsRouter

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            SectionLabel(text: "Check locations")
                .fixedSize()

            if model.locations.isEmpty {
                Text("No check locations. Every file will look new.")
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                Button("Add location…") { open(.locations) }
                    .buttonStyle(.link)
                    .font(Theme.secondary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(model.locations) { location in
                            LocationPill(
                                location: location,
                                isDisabled: model.isDisabled(location),
                                toggle: { model.toggleLocation(location) }
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.never)

                Button("Edit…") { open(.locations) }
                    .buttonStyle(.link)
                    .font(Theme.secondary)
                    .fixedSize()
            }

            Spacer(minLength: 0)
        }
    }

    private func open(_ tab: SettingsTab) {
        router.tab = tab
        openSettings()
    }
}

/// One source: dot + short name. Dimmed and struck through when switched off.
private struct LocationPill: View {
    let location: LocationStatus
    let isDisabled: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                StatusDot(reachable: location.reachable)

                Text(location.isFallback ? "\(location.displayName) (fallback)" : location.displayName)
                    .font(Theme.secondary)
                    .strikethrough(isDisabled)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Theme.surface)
            .clipShape(.capsule)
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            .opacity(isDisabled ? 0.4 : 1)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(location.reachable == true && !isDisabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(helpText)
    }

    private var helpText: String {
        let state: String
        switch location.reachable {
        case nil: state = "checking…"
        case true?: state = "checked"
        case false?: state = "not available"
        }
        return "\(location.detail) — \(state). Click to \(isDisabled ? "include again" : "skip on the next scan")."
    }
}

/// Review's version of the row: what the scan checked, as one quiet line.
/// The locations are picked before the scan, on the Card inserted screen.
struct CheckedLocationsLine: View {
    var model: BackupModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.locations.isEmpty ? "No check locations, every file looks new" : "Checked")
            ForEach(model.locations) { location in
                HStack(spacing: 5) {
                    StatusDot(reachable: location.reachable)
                    Text(location.displayName)
                        .strikethrough(model.isDisabled(location))
                }
                .opacity(model.isDisabled(location) ? 0.5 : 1)
                .help(location.detail)
            }
        }
        .font(Theme.secondary)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Green when the location answered, grey when it did not, a spinner while checking.
private struct StatusDot: View {
    let reachable: Bool?

    var body: some View {
        switch reachable {
        case nil:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.6)
                .frame(width: 7, height: 7)
        case true?:
            Circle().fill(Theme.success).frame(width: 7, height: 7)
        case false?:
            Circle().fill(Color.secondary.opacity(0.45)).frame(width: 7, height: 7)
        }
    }
}
