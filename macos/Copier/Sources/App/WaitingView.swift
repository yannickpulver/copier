import CopierCore
import SwiftUI

/// Screen 1 — no card connected. Calm: the check-locations row, and one hint.
struct WaitingView: View {
    @Bindable var model: BackupModel
    var router: SettingsRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CheckLocationsRow(model: model, router: router)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)

            Divider()

            VStack(spacing: 14) {
                Spacer(minLength: 0)
                Image(systemName: "sdcard")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Insert a card")
                    .font(.system(size: 20, weight: .semibold))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
