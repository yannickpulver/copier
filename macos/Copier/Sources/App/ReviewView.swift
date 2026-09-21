import CopierCore
import SwiftUI

extension FileKind {
    /// Muted system colours, one per kind, used by the row badge and the header dots.
    var color: Color {
        switch self {
        case .photo: return Color(nsColor: .systemBlue)
        case .raw: return Color(nsColor: .systemIndigo)
        case .video: return Color(nsColor: .systemPurple)
        case .other: return Color(nsColor: .systemGray)
        }
    }
}

/// Screen 2 — what will be copied where. Day blocks, time clusters inside the open day,
/// and the bottom bar with destination, camera subfolders, total and the primary action.
struct ReviewView: View {
    @Bindable var model: BackupModel
    var router: SettingsRouter

    var body: some View {
        VStack(spacing: 0) {
            CheckLocationsRow(model: model, router: router)
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                header

                ForEach(model.failedSources, id: \.name) { source in
                    InlineBanner(
                        kind: .warning,
                        message: "\(source.name) was not checked — \(source.errorDescription ?? "no connection"). Its pill above is grey, and files stored there look new.",
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
            .padding(.top, 14)
            .padding(.bottom, 14)
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
                Text("\(Format.count(model.tickedCount)) file\(model.tickedCount == 1 ? "" : "s") selected on \(model.selectedCard?.name ?? "card")")
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
            ForEach(Array(model.orderedDays.enumerated()), id: \.element.id) { index, day in
                let isSettled = model.isBackedUpOnly(day)
                // The first fully backed-up day opens the second block.
                let startsSettledBlock = isSettled
                    && (index == 0 || !model.isBackedUpOnly(model.orderedDays[index - 1]))

                if startsSettledBlock {
                    HStack(spacing: 8) {
                        SectionLabel(text: "Already backed up")
                        VStack { Divider() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 2)
                } else if index > 0 {
                    Divider()
                }

                let isExpanded = model.expandedDayID == day.id
                VStack(spacing: 0) {
                    DayHeaderRow(model: model, day: day, isExpanded: isExpanded, isSettled: isSettled)
                    if isExpanded {
                        Divider()
                        FileList(model: model, day: day)
                    }
                }
                .frame(maxHeight: isExpanded ? .infinity : nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Day header

/// The tinted band that separates one day from the next.
private struct DayHeaderRow: View {
    @Bindable var model: BackupModel
    let day: ReviewDay
    let isExpanded: Bool
    /// A day with nothing to copy: no band, greyed, no folder field.
    var isSettled: Bool = false

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
                    Text(Format.dayWithWeekday(day.day))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    let range = Format.timeRange(day.files.map(\.file))
                    if !range.isEmpty {
                        Text(range)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                .fixedSize()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isSettled {
                // Nothing to copy here, so there is no folder to choose either.
                Text(day.backedUpNote)
                    .font(Theme.secondary)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            } else if model.structure == .folderPerDay {
                FolderField(model: model, day: day)
            } else {
                Spacer(minLength: 8)
            }

            // The counts column is the first thing to give way in a narrow window.
            ViewThatFits(in: .horizontal) {
                KindCounts(counts: day.kindCounts)
                EmptyView()
            }
            .opacity(isSettled ? 0.55 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(isSettled ? AnyShapeStyle(.clear) : AnyShapeStyle(Color.accentColor.opacity(0.07)))
    }
}

/// `● 112 photos  ● 36 videos` — the colours match the row badges.
private struct KindCounts: View {
    let counts: [(kind: FileKind, count: Int)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(counts, id: \.kind) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.kind.color)
                        .frame(width: 6, height: 6)
                    Text("\(entry.count) \(entry.kind.label(count: entry.count))")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .fixedSize()
    }
}

// MARK: - File list

private struct FileList: View {
    @Bindable var model: BackupModel
    let day: ReviewDay

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(day.clusters) { cluster in
                    Section {
                        ForEach(cluster.files) { file in
                            FileRow(model: model, file: file)
                        }
                        Spacer(minLength: 10)
                    } header: {
                        ClusterHeader(cluster: cluster)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Files from \(Format.day(day.day))")
    }
}

/// `10:00 – 10:42 · 18 files`, pinned while its cluster scrolls past.
private struct ClusterHeader: View {
    let cluster: FileCluster

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.span(from: cluster.start, to: cluster.end))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text("\(Format.count(cluster.files.count)) file\(cluster.files.count == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider() }
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

            Image(systemName: file.file.kind.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(file.file.kind.color)
                .frame(width: 14)
                .opacity(isOn ? 1 : 0.55)
                .help(file.file.kind.rawValue)

            Text(file.file.name)
                .font(Theme.mono)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)

            if file.reason != .new {
                TagChip(text: file.reason.rawValue)
            }

            if let camera = file.file.camera, !camera.isEmpty {
                TagChip(text: camera)
                    .lineLimit(1)
            }

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
        .frame(height: 24)
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
            if !model.dependencies.settings.transferDestinations.isEmpty { Divider() }
            // Always reachable, so an empty destination list is never a dead end.
            Button("Add destination…") {
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
