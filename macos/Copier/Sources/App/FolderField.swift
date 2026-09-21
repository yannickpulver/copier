import CopierCore
import SwiftUI

/// The folder field from the design: a fixed date prefix plus an editable title makes
/// a new folder; the chevron opens a popover that lists the folders that already exist
/// at the destination, same-day folder first.
struct FolderField: View {
    @Bindable var model: BackupModel
    let day: ReviewDay
    @State private var showsPicker = false

    private var target: FolderTarget { model.target(for: day) }

    private var titleBinding: Binding<String> {
        Binding(
            get: {
                if case let .new(title) = model.target(for: day) { return title }
                return ""
            },
            set: { model.setTitle($0, for: day) }
        )
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            switch target {
            case .new:
                Text(model.datePrefix(for: day.day))
                    .font(Theme.mono)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TextField("Folder title (optional)", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(Theme.secondary)
                    .frame(minWidth: 40)
            case let .existing(url):
                Text(url.lastPathComponent)
                    .font(Theme.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TagChip(text: "existing")
            }

            Button {
                showsPicker = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose existing folder")
            .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                FolderPicker(model: model, day: day, isPresented: $showsPicker)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 2)
        .frame(height: 30)
        .background(Theme.fieldBackground)
        .clipShape(.rect(cornerRadius: Theme.fieldRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.fieldRadius)
                .strokeBorder(showsPicker ? Color.accentColor : Theme.hairline, lineWidth: 1)
        )
    }
}

/// Popover contents: make a new folder, or add the files to one that exists.
private struct FolderPicker: View {
    @Bindable var model: BackupModel
    let day: ReviewDay
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                model.setExistingFolder(nil, for: day)
                isPresented = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                    Text("New folder").font(Theme.secondary).fontWeight(.semibold)
                    Text("\(model.datePrefix(for: day.day)) …")
                        .font(Theme.mono)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(PickerRowStyle(isSelected: isNew))

            let choices = model.folderChoices(for: day)
            if !choices.isEmpty {
                Divider().padding(.vertical, 4)
                SectionLabel(text: "Existing in \(model.destination?.lastPathComponent ?? "destination")")
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(choices, id: \.self) { name in
                            Button {
                                if let destination = model.destination {
                                    model.setExistingFolder(destination.appending(path: name, directoryHint: .notDirectory), for: day)
                                }
                                isPresented = false
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .opacity(isSelected(name) ? 1 : 0)
                                    Text(name)
                                        .font(Theme.mono)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    if model.isSameDay(name, as: day) {
                                        Text("same day")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(PickerRowStyle(isSelected: isSelected(name)))
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            Divider().padding(.vertical, 4)
            Button {
                if let url = FolderPanel.chooseFolder(title: "Choose a folder", start: model.destination) {
                    model.setExistingFolder(url, for: day)
                }
                isPresented = false
            } label: {
                HStack {
                    Text("Choose another folder…").font(Theme.secondary).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(PickerRowStyle(isSelected: false))
        }
        .padding(4)
        .frame(width: 340)
    }

    private var isNew: Bool {
        if case .new = model.target(for: day) { return true }
        return false
    }

    private func isSelected(_ name: String) -> Bool {
        if case let .existing(url) = model.target(for: day) { return url.lastPathComponent == name }
        return false
    }
}

/// Menu-like row: blue when selected, hover highlight otherwise.
private struct PickerRowStyle: ButtonStyle {
    let isSelected: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(height: 28)
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .background(background(pressed: configuration.isPressed))
            .clipShape(.rect(cornerRadius: 5))
            .onHover { hovering = $0 }
    }

    private func background(pressed: Bool) -> some ShapeStyle {
        if isSelected || pressed { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
    }
}
