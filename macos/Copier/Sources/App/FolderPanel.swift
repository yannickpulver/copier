import AppKit
import Foundation

/// The one place that opens an `NSOpenPanel` for a folder.
enum FolderPanel {
    @MainActor
    static func chooseFolder(title: String, prompt: String = "Choose", start: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Choose one or more folders at once.
    @MainActor
    static func chooseFolders(title: String, prompt: String = "Choose", start: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Reveal a file or folder in Finder.
    @MainActor
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
