import CopierCore
import SwiftUI

/// Screen 2 — what will be copied where. Day groups, one open day with its file list,
/// and the bottom bar with destination, camera subfolders, total and the primary action.
struct ReviewView: View {
    @Bindable var model: BackupModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header

                ForEach(model.failedSources, id: \.name) { source in
                    InlineBanner(
                        kind: .warning,
                        message: "\(source.name) was not checked — \(source.errorDescription ?? "no connection"). Files from it may be copied again.",
                        actionTitle: "Retry",
                        action: { model.startScan() }
                    )
                }

                if model.allBackedUp {
                    allBackedUpNotice
                }

                if model.structure == .oneFolder {
                    oneFolderCard
                }

                GroupedBox {
                    dayList
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let shortfall = model.shortfall {
                InlineBanner(
                    kind: .error,
                    message: "Not enough space on \(shortfall.destination.lastPathComponent): \(Format.bytes(shortfall.shortfallBytes)) short of the \(Format.bytes(shortfall.requiredBytes)) needed."
                )
                .padding(.horizontal, 22)
                .padding(.bottom, 10)
            }

            BottomBar(model: model)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(Format.count(model.tickedCount)) new file\(model.tickedCount == 1 ? "" : "s") on \(model.selectedCard?.name ?? "card")")
                    .font(Theme.sectionTitle)
                    .lineLimit(1)
                Text(model.reviewSubtitle)
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Picker("", selection: Binding(get: { model.structure }, set: { model.structure = $0 })) {
                Text("Folder per day").tag(Structure.folderPerDay)
                Text("One folder").tag(Structure.oneFolder)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .font(Theme.secondary)
        }
    }

    private var allBackedUpNotice: some View {
        GroupedBox {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything on this card is already backed up")
                        .font(Theme.bodySemibold)
                    Text("Tick files below to copy them again.")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Eject card") { model.ejectCard() }
            }
            .padding(14)
        }
    }

    private var oneFolderCard: some View {
        GroupedBox {
            HStack(spacing: 12) {
                Text("One folder for all \(Format.count(model.tickedCount)) files")
                    .font(Theme.bodySemibold)
                    .fixedSize()
                if let first = model.days.first {
                    FolderField(model: model, day: first)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: Day list

    private var dayList: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.days.enumerated()), id: \.element.id) { index, day in
                if index > 0 { Divider() }
                let isExpanded = model.expandedDayID == day.id
                VStack(spacing: 9) {
                    DayHeaderRow(model: model, day: day, isExpanded: isExpanded)
                    if isExpanded {
                        FileList(model: model, day: day)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxHeight: isExpanded ? .infinity : nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Day header

private struct DayHeaderRow: View {
    @Bindable var model: BackupModel
    let day: ReviewDay
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { model.isTicked(day: day) },
                    set: { model.setTicked(day: day, $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel("Include \(Format.day(day.day))")

            Button {
                model.expandedDayID = isExpanded ? nil : day.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    Text(Format.day(day.day))
                        .font(Theme.bodySemibold)
                    let range = Format.timeRange(day.files.map(\.file))
                    if !range.isEmpty {
                        Text(range)
                            .font(Theme.secondary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .fixedSize()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if model.structure == .folderPerDay {
                FolderField(model: model, day: day)
            } else {
                Spacer(minLength: 8)
            }

            // The counts column is the first thing to give way in a narrow window.
            ViewThatFits(in: .horizontal) {
                Text(Format.mediaCounts(day.files.map(\.file)))
                    .font(Theme.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text("")
            }
        }
        .frame(height: 30)
    }
}

// MARK: - File list

private struct FileList: View {
    @Bindable var model: BackupModel
    let day: ReviewDay

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(day.files) { file in
                    FileRow(model: model, file: file)
                }
            }
        }
        .padding(.leading, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Files from \(Format.day(day.day))")
    }
}

private struct FileRow: View {
    @Bindable var model: BackupModel
    let file: ReviewFile

    var body: some View {
        let isOn = model.isTicked(file)
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { isOn }, set: { model.setTicked(file, $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Include \(file.file.name)")

            Text(file.file.name)
                .font(Theme.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)

            if file.reason != .new {
                TagChip(text: file.reason.rawValue)
            }

            Text(file.file.camera ?? "")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)

            Text(Format.time(file.file.captureDate ?? file.file.modificationDate))
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)

            Text(Format.bytes(file.file.size))
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .frame(height: 22)
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @Bindable var model: BackupModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Back up to")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .fixedSize()

            destinationMenu

            Toggle(
                "Camera subfolders",
                isOn: Binding(get: { model.cameraSubfolders }, set: { model.cameraSubfolders = $0 })
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(Theme.secondary)
            .fixedSize()

            Spacer(minLength: 8)

            Text(Format.bytes(model.tickedBytes))
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()

            Button {
                model.startBackup()
            } label: {
                Text("Back up \(Format.count(model.tickedCount)) file\(model.tickedCount == 1 ? "" : "s")")
                    .fontWeight(.semibold)
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.tickedCount == 0 || model.destination == nil)
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider() }
    }

    private var destinationMenu: some View {
        Menu {
            ForEach(model.dependencies.settings.transferDestinations, id: \.self) { path in
                Button(path) { model.setDestination(URL(fileURLWithPath: path)) }
            }
            Divider()
            Button("Choose…") {
                if let url = FolderPanel.chooseFolder(title: "Choose a backup destination", start: model.destination) {
                    model.setDestination(url)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(.secondary)
                Text(model.destination.map(Format.destinationLabel) ?? "Choose a destination")
                    .font(Theme.secondary)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let free = model.destinationFreeBytes {
                    Text("\(Format.bytes(free)) free")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 140)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Theme.fieldBackground)
        .clipShape(.rect(cornerRadius: Theme.controlRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.controlRadius)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }
}
