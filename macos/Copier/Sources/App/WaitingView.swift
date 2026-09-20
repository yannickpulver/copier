import CopierCore
import SwiftUI

/// Screen 1 — no card connected: what Copier checks against and whether it answers.
struct WaitingView: View {
    @Bindable var model: BackupModel

    var body: some View {
        VStack(spacing: 30) {
            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Image(systemName: "sdcard")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    Text("Insert an SD card")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Copier scans it automatically and shows what isn't backed up yet.")
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if !model.locations.isEmpty {
                VStack(spacing: 10) {
                    SectionLabel(text: "Checking against")
                    LocationChips(locations: model.locations)
                    if model.locations.contains(where: { $0.reachable == false }) {
                        Button("Check again") { Task { await model.checkLocations() } }
                            .buttonStyle(.link)
                            .font(Theme.secondary)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Text("No check locations configured yet.")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                    SettingsLink { Text("Open Settings") }
                        .buttonStyle(.link)
                        .font(Theme.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 60)
    }
}

/// The pill row: a dot per location, greyed when it did not answer.
struct LocationChips: View {
    let locations: [LocationStatus]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(locations) { location in
                HStack(spacing: 7) {
                    Circle()
                        .fill(color(for: location))
                        .frame(width: 7, height: 7)
                    Text(label(for: location))
                        .font(Theme.secondary)
                        .foregroundStyle(location.reachable == true ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(location.reachable == true ? AnyShapeStyle(Theme.surface) : AnyShapeStyle(.clear))
                .clipShape(.capsule)
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
            }
        }
    }

    private func color(for location: LocationStatus) -> Color {
        switch location.reachable {
        case true: return Theme.success
        case false: return Theme.hairline
        default: return Color.secondary.opacity(0.4)
        }
    }

    private func label(for location: LocationStatus) -> String {
        switch location.reachable {
        case true: return location.name
        case false: return "\(location.name) — \(location.isNAS ? "no connection" : "not connected")"
        default: return "\(location.name) — checking…"
        }
    }
}
