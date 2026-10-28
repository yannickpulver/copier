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

/// Screen 2 — what will be copied where. What was checked, the days (all collapsed at
/// first, backed-up days folded into one row) and the bottom bar with the destination,
/// total and the primary action.
struct ReviewView: View {
    @Bindable var model: BackupModel
    /// Whether the folded "already backed up" days are shown.
    @State private var showsBackedUpDays = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    CheckedLocationsLine(model: model)
                    Spacer(minLength: 12)
                    structurePicker
                }

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

                if model.structure == .oneFolder {
                    oneFolderCard
                }

                GroupedBox { days }
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

    private var structurePicker: some View {
        Picker("", selection: Binding(get: { model.structure }, set: { model.structure = $0 })) {
            Text("Folder per day").tag(Structure.folderPerDay)
            Text("One folder").tag(Structure.oneFolder)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .font(Theme.secondary)
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

    /// Collapsed days hug their rows and scroll once they outgrow the window. An open day
    /// fills the space under the other days while that leaves it `FileList.minHeight`; past
    /// that the day list scrolls and the file list keeps a fixed height, so the other days
    /// stay one scroll away.
    @ViewBuilder private var days: some View {
        if model.expandedDayID == nil {
            ViewThatFits(in: .vertical) {
                dayList(fileListHeight: nil)
                ScrollView { dayList(fileListHeight: nil) }
            }
        } else {
            GeometryReader { geometry in
                ViewThatFits(in: .vertical) {
                    dayList(fileListHeight: nil)
                    ScrollViewReader { proxy in
                        ScrollView {
                            dayList(fileListHeight: max(FileList.minHeight, geometry.size.height * 0.6))
                        }
                        .onAppear { scroll(proxy, to: model.expandedDayID) }
                        .onChange(of: model.expandedDayID) { _, id in scroll(proxy, to: id) }
                    }
                }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to id: String?) {
        guard let id else { return }
        withAnimation { proxy.scrollTo(id, anchor: .top) }
    }

    /// Days with something to copy, then one row for the fully backed-up days, which
    /// unfolds into their own rows.
    /// - Parameter fileListHeight: a fixed height for the open day's files; `nil` lets them
    ///   take the space left under the other days.
    private func dayList(fileListHeight: CGFloat?) -> some View {
        // `orderedDays` keeps the backed-up days at the end.
        let split = model.orderedDays.firstIndex { model.isBackedUpOnly($0) } ?? model.orderedDays.count
        let active = model.orderedDays[..<split]
        let settled = model.orderedDays[split...]
        return VStack(spacing: 0) {
            ForEach(Array(active.enumerated()), id: \.element.id) { index, day in
                if index > 0 { Divider() }
                dayBlock(day, isSettled: false, fileListHeight: fileListHeight)
            }
            if !settled.isEmpty {
                if !active.isEmpty { Divider() }
                BackedUpDaysRow(days: Array(settled), isOpen: $showsBackedUpDays)
                if showsBackedUpDays {
                    ForEach(settled) { day in
                        Divider()
                        dayBlock(day, isSettled: true, fileListHeight: fileListHeight)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: model.expandedDayID == nil ? nil : .infinity, alignment: .top)
    }

    private func dayBlock(_ day: ReviewDay, isSettled: Bool, fileListHeight: CGFloat?) -> some View {
        let isExpanded = model.expandedDayID == day.id
        return VStack(spacing: 0) {
            DayHeaderRow(model: model, day: day, isExpanded: isExpanded, isSettled: isSettled)
            if model.isSplit(day), !isSettled, model.structure == .folderPerDay {
                ForEach(Array(day.clusters.enumerated()), id: \.element.id) { block, cluster in
                    BlockRow(model: model, day: day, block: block, cluster: cluster)
                }
            }
            if isExpanded {
                Divider()
                FileList(model: model, day: day, height: fileListHeight)
            }
        }
        .frame(maxHeight: isExpanded ? .infinity : nil)
        .id(day.id)
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

// MARK: - Day header

/// One day: checkbox, previews, date with its counts and times, and its folder. The
/// kind counts and the split button only show while the day is open.
private struct DayHeaderRow: View {
    @Bindable var model: BackupModel
    let day: ReviewDay
    let isExpanded: Bool
    /// A day with nothing to copy: greyed, no folder field.
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

            if !isShowingBlocks {
                HStack(spacing: 3) {
                    ForEach(day.clusters) { cluster in
                        if let file = cluster.previewFile { Thumbnail(file: file) }
                    }
                }
                .opacity(isSettled ? 0.55 : 1)
            }

            Button {
                model.expandedDayID = isExpanded ? nil : day.id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        // Both chevrons get the same width, so the date does not shift.
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Format.dayWithWeekday(day.day))
                            .font(Theme.bodySemibold)
                            .foregroundStyle(isSettled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .help(isSettled ? day.placesDetail : "")
                    }
                }
                .fixedSize()
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                // The counts are the first thing to give way in a narrow window.
                ViewThatFits(in: .horizontal) {
                    KindCounts(counts: day.kindCounts)
                    EmptyView()
                }
                .opacity(isSettled ? 0.55 : 1)
            }

            Spacer(minLength: 8)

            if !isSettled, model.structure == .folderPerDay {
                if model.isSplit(day) {
                    Text("\(day.clusters.count) shoots")
                        .font(Theme.secondary)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Button {
                        model.merge(day)
                    } label: {
                        Label("Merge", systemImage: "arrow.triangle.merge")
                            .font(Theme.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Put the whole day back into one folder")
                    .fixedSize()
                } else {
                    FolderField(model: model, day: day)
                        .frame(maxWidth: 360)
                    if isExpanded, model.canSplit(day) {
                        Button {
                            model.split(day)
                        } label: {
                            Image(systemName: "scissors")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .help("Split into \(day.clusters.count) shoots, one folder each")
                        .accessibilityLabel("Split day")
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// `82 new · 3 backed up · 10:00–15:00`, or where a fully backed-up day was found.
    private var detail: String {
        let range = Format.timeRange(day.files.map(\.file))
        let counts = isSettled ? day.backedUpNote : day.countsNote
        return [counts, range].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A split day lists its blocks below, each with its own thumbnail.
    private var isShowingBlocks: Bool {
        model.isSplit(day) && !isSettled && model.structure == .folderPerDay
    }
}

/// One time block of a split day: its time span and its own folder field.
private struct BlockRow: View {
    @Bindable var model: BackupModel
    let day: ReviewDay
    let block: Int
    let cluster: FileCluster

    var body: some View {
        HStack(spacing: 10) {
            if let file = cluster.previewFile { Thumbnail(file: file) }
            Text(Format.span(from: cluster.start, to: cluster.end))
                .font(Theme.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            Text("\(Format.count(cluster.files.count)) file\(cluster.files.count == 1 ? "" : "s")")
                .font(Theme.secondary)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .fixedSize()
            FolderField(model: model, day: day, block: block)
        }
        .padding(.leading, 42)
        .padding(.trailing, 14)
        .padding(.bottom, 7)
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
    /// Fixed height, or `nil` to fill what the day list leaves.
    var height: CGFloat?

    static let minHeight: CGFloat = 200

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
        .frame(
            maxWidth: .infinity,
            minHeight: height ?? Self.minHeight,
            idealHeight: height ?? Self.minHeight,
            maxHeight: height ?? .infinity
        )
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
            Divider()
            Toggle(
                "Camera subfolders",
                isOn: Binding(get: { model.cameraSubfolders }, set: { model.cameraSubfolders = $0 })
            )
        } label: {
            // A macOS menu label shows only its icon and first text, so the free space
            // and the camera note sit beside the menu, inside the same field.
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
            // The switch lives in the menu, so the field says when it is on.
            if model.cameraSubfolders {
                Text("· per camera")
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
