import Foundation

/// One file to copy into one folder.
public struct CopyJob: Sendable, Hashable, Identifiable {
    public var file: MediaFile
    /// Where the bytes are written — includes the camera subfolder when that option is on.
    public var destinationFolder: URL
    /// The planned day folder this job belongs to. Progress rows, ``TransferResult/folders``
    /// and "Show in Finder" use this, so camera subfolders never show up as separate targets.
    public var plannedFolder: URL

    public var id: String { destinationFolder.path + "/" + file.name + "|" + file.url.path }

    public init(file: MediaFile, destinationFolder: URL, plannedFolder: URL? = nil) {
        self.file = file
        self.destinationFolder = destinationFolder
        self.plannedFolder = plannedFolder ?? destinationFolder
    }
}

/// A destination folder the plan will write into.
public struct PlannedFolder: Sendable, Identifiable {
    /// The day these files came from — `nil` for the one-folder structure or undated files.
    public var day: Day?
    /// The folder itself (without camera subfolders).
    public var url: URL
    /// `true` when the folder has to be created.
    public var isNew: Bool
    public var files: [MediaFile]

    public var id: URL { url }

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public init(day: Day?, url: URL, isNew: Bool, files: [MediaFile]) {
        self.day = day
        self.url = url
        self.isNew = isNew
        self.files = files
    }
}

/// The full result of planning a backup.
public struct TransferPlan: Sendable {
    public var folders: [PlannedFolder]
    public var jobs: [CopyJob]

    public init(folders: [PlannedFolder], jobs: [CopyJob]) {
        self.folders = folders
        self.jobs = jobs
    }

    public var fileCount: Int { jobs.count }
    public var totalBytes: Int64 { jobs.reduce(0) { $0 + $1.file.size } }
}

/// Files that go into one folder, with the folder choice for them.
public struct PlanGroup: Sendable {
    /// The day the folder takes its date from.
    public var day: Day?
    public var target: FolderTarget
    public var files: [MediaFile]

    public init(day: Day?, target: FolderTarget, files: [MediaFile]) {
        self.day = day
        self.target = target
        self.files = files
    }
}

/// Turns the review screen's state into copy jobs.
public enum TransferPlanner {
    /// Build the copy jobs.
    ///
    /// - Parameters:
    ///   - files: the files the user ticked.
    ///   - structure: folder per day, or everything into one folder.
    ///   - targets: per-day folder choice. For ``Structure/oneFolder`` the target of
    ///     the first (oldest) day is used, matching "One folder takes its date from
    ///     the first day".
    ///   - destination: the destination root a new folder is created in.
    ///   - cameraSubfolders: when `true`, files go to `<folder>/<camera ?? "Unknown">/`.
    ///   - dateFormat: token format for the date prefix of new folders.
    public static func plan(
        files: [MediaFile],
        structure: Structure,
        targets: [Day?: FolderTarget],
        destination: URL,
        cameraSubfolders: Bool = false,
        dateFormat: String = FolderNaming.defaultDateFormat,
        calendar: Calendar = .current
    ) -> TransferPlan {
        let groups = DayGrouping.group(files, calendar: calendar)
        switch structure {
        case .folderPerDay:
            return plan(
                groups: groups.map { PlanGroup(day: $0.day, target: targets[$0.day] ?? .new(title: ""), files: $0.files) },
                destination: destination,
                cameraSubfolders: cameraSubfolders,
                dateFormat: dateFormat
            )
        case .oneFolder:
            let firstDay = groups.first?.day
            let target = targets[firstDay] ?? targets[nil] ?? .new(title: "")
            return plan(
                groups: [PlanGroup(day: firstDay, target: target, files: groups.flatMap(\.files))],
                destination: destination,
                cameraSubfolders: cameraSubfolders,
                dateFormat: dateFormat
            )
        }
    }

    /// Build the copy jobs from groups the caller already formed — one day, one part of a
    /// split day, or everything for one folder. Groups that resolve to the same folder
    /// (two parts given the same title) share it; empty groups are dropped.
    public static func plan(
        groups: [PlanGroup],
        destination: URL,
        cameraSubfolders: Bool = false,
        dateFormat: String = FolderNaming.defaultDateFormat
    ) -> TransferPlan {
        var folders: [PlannedFolder] = []
        for group in groups where !group.files.isEmpty {
            let planned = folder(for: group.day, target: group.target, files: group.files, destination: destination, dateFormat: dateFormat)
            if let index = folders.firstIndex(where: { $0.url.path == planned.url.path }) {
                folders[index].files += planned.files
                folders[index].isNew = folders[index].isNew && planned.isNew
            } else {
                folders.append(planned)
            }
        }

        var jobs: [CopyJob] = []
        for planned in folders {
            if cameraSubfolders {
                for (camera, cameraFiles) in DayGrouping.groupByCamera(planned.files) {
                    let sub = planned.url.appendingPathComponent(camera)
                    jobs.append(
                        contentsOf: cameraFiles.map {
                            CopyJob(file: $0, destinationFolder: sub, plannedFolder: planned.url)
                        }
                    )
                }
            } else {
                jobs.append(contentsOf: planned.files.map { CopyJob(file: $0, destinationFolder: planned.url) })
            }
        }

        return TransferPlan(folders: folders, jobs: jobs)
    }

    private static func folder(
        for day: Day?,
        target: FolderTarget,
        files: [MediaFile],
        destination: URL,
        dateFormat: String
    ) -> PlannedFolder {
        switch target {
        case let .new(title):
            let name = FolderNaming.folderName(day: day, title: title, format: dateFormat)
            return PlannedFolder(day: day, url: destination.appendingPathComponent(name), isNew: true, files: files)
        case let .existing(url):
            return PlannedFolder(day: day, url: url, isNew: false, files: files)
        }
    }
}
