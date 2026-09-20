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
        guard !groups.isEmpty else { return TransferPlan(folders: [], jobs: []) }

        var folders: [PlannedFolder] = []

        switch structure {
        case .folderPerDay:
            for group in groups {
                let target = targets[group.day] ?? .new(title: "")
                folders.append(folder(for: group.day, target: target, files: group.files, destination: destination, dateFormat: dateFormat))
            }
        case .oneFolder:
            let firstDay = groups.first?.day
            let target = targets[firstDay] ?? targets[nil] ?? .new(title: "")
            let allFiles = groups.flatMap(\.files)
            folders.append(folder(for: firstDay, target: target, files: allFiles, destination: destination, dateFormat: dateFormat))
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
