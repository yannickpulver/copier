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

/// Screen 2 — what will be copied where. The days on the left, newest first; the day
/// picked there on the right with its folder, shoots and files; the destination, total
/// and the primary action at the bottom.
struct ReviewView: View {
    @Bindable var model: BackupModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                CheckedLocationsLine(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(model.failedSources, id: \.name) { source in
                    InlineBanner(
                        kind: .warning,
                        message: "\(source.name) was not checked — \(source.errorDescription ?? "no connection"). Files stored there look new.",
                        actionTitle: "Retry",
                        action: { model.startScan() }
                    )
                }

                if model.allBackedUp {
                    allBackedUpNotice
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            HStack(spacing: 0) {
                DayList(model: model)
                    .frame(width: 260)
                Divider()
                if let day = model.selectedDay {
                    DayDetail(model: model, day: day)
                        .id(day.id)
                } else {
                    Text("Pick a day on the left.")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)

            if let shortfall = model.shortfall {
                InlineBanner(
                    kind: .error,
                    message: "Not enough space on \(shortfall.destination.lastPathComponent): \(Format.bytes(shortfall.shortfallBytes)) short of the \(Format.bytes(shortfall.requiredBytes)) needed."
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            BottomBar(model: model)
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
                    Text("Tick files to copy them again.")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Eject card") { model.ejectCard() }
            }
            .padding(12)
        }
    }
}

// MARK: - Day list

/// The days, newest first under month headers. Days that share a folder sit together in
/// one frame; the fully backed-up days fold into one row at the end.
private struct DayList: View {
    @Bindable var model: BackupModel
    @State private var showsBackedUpDays = false

    var body: some View {
        let groups = model.folderGroups
        let active = model.orderedDays.filter { !model.isBackedUpOnly($0) }
        let settled = model.orderedDays.filter { model.isBackedUpOnly($0) }
        let joinable = model.joinableDays

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.canSelectAll {
                    quickPicks
                }
                if joinable.count > 1 {
                    joinBar(joinable)
                }
                ForEach(items(active: active, groups: groups)) { item in
                    switch item {
                    case let .month(title):
                        Text(title.uppercased())
                            .font(.system(size: 10.5, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 3)
                    case let .day(day):
                        DayRow(model: model, day: day)
                    case let .group(days):
                        GroupFrame(model: model, days: days)
                    }
                }
                if !settled.isEmpty {
                    BackedUpDaysRow(days: settled, isOpen: $showsBackedUpDays)
                        .padding(.top, 4)
                    if showsBackedUpDays {
                        ForEach(settled) { day in
                            DayRow(model: model, day: day, isSettled: true)
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .background(Theme.surface)
    }

    /// `Since last backup` · `All new`: tapping the ticked choice again clears it.
    private var quickPicks: some View {
        HStack(spacing: 6) {
            if model.hasBackedUpDays {
                Chip(title: "Since last backup", isOn: model.isSinceLastBackupTicked) {
                    if model.isSinceLastBackupTicked { model.setTickedAll(false) } else { model.tickSinceLastBackup() }
                }
            }
            Chip(title: "All new", isOn: model.isAllTicked && !model.isSinceLastBackupTicked) {
                model.setTickedAll(!model.isAllTicked || model.isSinceLastBackupTicked)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func joinBar(_ days: [ReviewDay]) -> some View {
        HStack(spacing: 8) {
            Text("\(days.count) days ticked")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("One folder") {
                withAnimation(.snappy(duration: 0.2)) { model.join(days) }
            }
            .controlSize(.small)
            .help("Put these days into one folder, dated after the first of them")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private enum Item: Identifiable {
        case month(String)
        case day(ReviewDay)
        case group([ReviewDay])

        var id: String {
            switch self {
            case let .month(title): return "month-\(title)"
            case let .day(day): return day.id
            case let .group(days): return "group-\(days.map(\.id).joined(separator: ","))"
            }
        }
    }

    /// Month headers, rows and group frames in list order. A group sits where its newest
    /// day would.
    private func items(active: [ReviewDay], groups: [[ReviewDay]]) -> [Item] {
        var result: [Item] = []
        var month: String?
        var placed: Set<String> = []
        for day in active where !placed.contains(day.id) {
            let title = Format.month(day.day)
            if title != month {
                month = title
                result.append(.month(title))
            }
            if let group = groups.first(where: { $0.contains { $0.id == day.id } }) {
                result.append(.group(group))
                placed.formUnion(group.map(\.id))
            } else {
                result.append(.day(day))
            }
        }
        return result
    }
}

/// A rounded toggle button for the quick picks above the list.
private struct Chip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.secondary))
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: .capsule)
                .overlay(Capsule().strokeBorder(isOn ? Color.accentColor.opacity(0.6) : Theme.hairline))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

/// Days that share one folder: the folder on top, the days below it.
private struct GroupFrame: View {
    @Bindable var model: BackupModel
    let days: [ReviewDay]

    var body: some View {
        let continues = days.contains { model.continuedDayIDs.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text(days.first.map(model.folderName(for:)) ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button("Separate") {
                    if let first = days.first {
                        withAnimation(.snappy(duration: 0.2)) { model.separate(first) }
                    }
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("Give each day its own folder again")
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            if continues {
                Text("Continues your last backup")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 1)
            }
            ForEach(days) { day in
                DayRow(model: model, day: day, isGrouped: true)
            }
            .padding(.horizontal, -6)
        }
        .padding(.bottom, 2)
        .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.4)))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

/// One day: checkbox, date, where it goes (or when it was taken) and how many are new.
private struct DayRow: View {
    @Bindable var model: BackupModel
    let day: ReviewDay
    /// A day with nothing to copy: greyed.
    var isSettled: Bool = false
    /// Inside a group frame, which already names the folder.
    var isGrouped: Bool = false

    var body: some View {
        let isTicked = model.isTicked(day: day)
        let isSelected = model.selectedDayID == day.id
        HStack(spacing: 9) {
            Toggle("", isOn: Binding(get: { isTicked }, set: { model.setTicked(day: day, $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Include \(Format.day(day.day))")

            VStack(alignment: .leading, spacing: 1) {
                Text(Format.shortDay(day.day))
                    .font(isTicked ? Theme.bodySemibold : Theme.body)
                    .foregroundStyle(isTicked ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Text(detail(isTicked: isTicked))
                    .font(.system(size: 10.5, design: isTicked && !isGrouped ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
            }

            Spacer(minLength: 4)

            Text(Format.count(isSettled ? day.files.count : day.newFiles.count))
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 6))
        .contentShape(.rect)
        .onTapGesture { model.selectedDayID = day.id }
        .padding(.horizontal, 6)
        .opacity(isSettled ? 0.6 : 1)
    }

    /// The folder a ticked day goes into, otherwise its time span.
    private func detail(isTicked: Bool) -> String {
        let range = Format.timeRange(day.files.map(\.file))
        guard isTicked, !isSettled, !isGrouped else { return range.isEmpty ? " " : range }
        if model.isSplit(day) { return "\(day.clusters.count) folders" }
        return model.folderName(for: day)
    }
}

// MARK: - Day detail

/// The picked day: its folder, what kinds of files it holds, its shoots and its files.
private struct DayDetail: View {
    @Bindable var model: BackupModel
    let day: ReviewDay

    private var isSettled: Bool { model.isBackedUpOnly(day) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                        folder
                        if model.isSplit(day), !isSettled {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(day.clusters.enumerated()), id: \.element.id) { block, cluster in
                                    BlockRow(model: model, day: day, block: block, cluster: cluster)
                                }
                            }
                        } else {
                            ShootGrid(clusters: day.clusters) { cluster in
                                withAnimation { proxy.scrollTo(cluster.id, anchor: .top) }
                            }
                        }
                    }
                    .padding(.bottom, 8)

                    ForEach(day.clusters) { cluster in
                        Section {
                            ForEach(cluster.files) { file in
                                FileRow(model: model, file: file)
                            }
                            Spacer(minLength: 10)
                        } header: {
                            ClusterHeader(cluster: cluster)
                                .id(cluster.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(get: { model.isTicked(day: day) }, set: { model.setTicked(day: day, $0) })
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel("Include \(Format.day(day.day))")

            VStack(alignment: .leading, spacing: 1) {
                Text(Format.dayWithWeekday(day.day))
                    .font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(isSettled ? day.placesDetail : "")
            }

            Spacer(minLength: 8)

            if !isSettled {
                if model.isSplit(day) {
                    Button {
                        model.merge(day)
                    } label: {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                    }
                    .controlSize(.small)
                    .help("Put the whole day back into one folder")
                } else if model.canSplit(day), model.isTicked(day: day) {
                    Button {
                        model.split(day)
                    } label: {
                        Label("Split into \(day.clusters.count) folders", systemImage: "scissors")
                    }
                    .controlSize(.small)
                    .help("One folder per shoot")
                }
            }
        }
    }

    @ViewBuilder private var folder: some View {
        if isSettled {
            EmptyView()
        } else if !model.isTicked(day: day) {
            Text("Tick this day to back it up.")
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
        } else if !model.isSplit(day) {
            VStack(alignment: .leading, spacing: 6) {
                FolderField(model: model, day: day)
                if let note {
                    HStack(spacing: 8) {
                        Text(note)
                            .font(Theme.secondary)
                            .foregroundStyle(.secondary)
                        Button("Separate") {
                            withAnimation(.snappy(duration: 0.2)) { model.separate(day) }
                        }
                        .buttonStyle(.link)
                        .font(Theme.secondary)
                    }
                }
            }
        }
        KindCounts(counts: day.kindCounts)
            .opacity(isSettled ? 0.55 : 1)
    }

    /// Why this day shares its folder: it continues the last backup, or it was joined.
    private var note: String? {
        if model.continuedDayIDs.contains(day.id) { return "Continues your last backup" }
        guard let group = model.group(of: day) else { return nil }
        let others = group.filter { $0.id != day.id }.map { Format.shortDay($0.day) }
        return "Shared with \(others.formatted(.list(type: .and)))"
    }

    /// `82 new · 3 backed up · 10:00–15:00`, or where a fully backed-up day was found.
    private var detail: String {
        let range = Format.timeRange(day.files.map(\.file))
        let counts = isSettled ? day.backedUpNote : day.countsNote
        return [counts, range].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The shoots of a day as larger previews; a click jumps to the shoot's files.
private struct ShootGrid: View {
    let clusters: [FileCluster]
    let onPick: (FileCluster) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 10, alignment: .topLeading)], alignment: .leading, spacing: 10) {
            ForEach(clusters) { cluster in
                Button {
                    onPick(cluster)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let file = cluster.previewFile {
                            Thumbnail(file: file, size: CGSize(width: 132, height: 88))
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                                .frame(width: 132, height: 88)
                        }
                        Text("\(Format.span(from: cluster.start, to: cluster.end)) · \(Format.count(cluster.files.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                        if let title = cluster.title {
                            Label(title, systemImage: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Show these files")
            }
        }
    }
}

/// One time block of a split day: its preview, time span and its own folder field.
private struct BlockRow: View {
    @Bindable var model: BackupModel
    let day: ReviewDay
    let block: Int
    let cluster: FileCluster

    var body: some View {
        HStack(spacing: 10) {
            if let file = cluster.previewFile { Thumbnail(file: file) }
            VStack(alignment: .leading, spacing: 1) {
                Text(Format.span(from: cluster.start, to: cluster.end))
                    .font(Theme.secondary)
                    .monospacedDigit()
                Text("\(Format.count(cluster.files.count)) file\(cluster.files.count == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .fixedSize()
            FolderField(model: model, day: day, block: block)
        }
    }
}

/// `› 4 days already backed up · 68 files` — folds the days with nothing to copy.
private struct BackedUpDaysRow: View {
    let days: [ReviewDay]
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                Text("\(days.count) day\(days.count == 1 ? "" : "s") already backed up · \(Format.count(files)) file\(files == 1 ? "" : "s")")
                    .font(Theme.secondary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var files: Int { days.reduce(0) { $0 + $1.files.count } }
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

// MARK: - Files

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
            if let title = cluster.title {
                Label(title, systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
        // A click anywhere but the checkbox shows the file on the card in Finder.
        .contentShape(.rect)
        .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([file.file.url]) }
        .help("Show in Finder")
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @Bindable var model: BackupModel

    var body: some View {
        HStack(spacing: 12) {
            destinationField

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
            // A macOS menu label shows only its icon and first text, so the free space
            // sits beside the menu, inside the same field.
            Label(model.destination.map(Format.destinationLabel) ?? "Choose a destination", systemImage: "externaldrive")
                .font(Theme.secondary)
                .fontWeight(.medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var destinationField: some View {
        HStack(spacing: 8) {
            destinationMenu
            if let free = model.destinationFreeBytes {
                Text("\(Format.bytes(free)) free")
                    .monospacedDigit()
            }
        }
        .font(Theme.secondary)
        .foregroundStyle(.secondary)
        .lineLimit(1)
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
