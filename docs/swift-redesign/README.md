# Copier Swift Redesign

Design for rewriting Copier as a native macOS app in SwiftUI. Nothing here is implemented yet. The Electron app stays the shipping version until the rewrite replaces it.

Open `index.html` in a browser to see all screens. Every screen in `screens/` also opens on its own and follows the system appearance (`?dark` / `?light` forces one).

## Why

The Electron UI grew into one long scrolling page. Every section is shown or hidden by hand, the transfer area stacks two mode toggles, a checkbox and several inputs, and all feedback goes through one status line. `src/renderer.ts` is a single 1900-line file with global mutable state. A SwiftUI app with a small model and bindings removes most of that by construction.

## Principles

- One state at a time, with exactly one primary button: waiting, review, backing up, done.
- A card is detected the moment it is inserted; the user picks which locations to check for existing backups and then starts the scan.
- The file list gets the space. Settings that rarely change sit in one bar at the bottom.
- Settings live in a native Settings window (⌘,), not in a tab.
- Follows the system appearance. Blue is the only accent color.

## Screens

| Screen | File | Notes |
|---|---|---|
| 1 · Waiting for card | `screens/Main.html` | Shows which locations are checked for existing backups and whether they are reachable. |
| 2 · Review, folder per day | `screens/Review.html` | One row per day: checkbox, date, folder field, counts. The open day shows all files. |
| 2b · Choosing an existing folder | `screens/ReviewPicker.html` | Open state of the folder field. |
| 2c · Review, one folder | `screens/ReviewOneFolder.html` | A single folder field for all files. Days are still listed to tick files on or off. |
| 3 · Backing up | `screens/Copying.html` | Percent, speed, time left, current file, state per folder. Only action: Cancel. |
| 4 · Done | `screens/Done.html` | Created folders with "Show in Finder". Primary action: eject the card. |
| Folder Sync | `screens/FolderSync.html` | Source and target side by side, missing files, one button. |
| Settings window | `screens/Settings.html` | Tabs: Locations, NAS, Naming, AI. |

## Review: how folders work

This replaces the old "New folder / Existing folder" and "Single folder / Folder per date" toggles.

- One switch decides the structure: **Folder per day** or **One folder**.
- New or existing is decided per folder, in the same field. The field shows the fixed date prefix (`2026.09.18 -`) followed by the title.
  - Typing a title creates a new folder.
  - The arrow lists the folders that already exist at the destination. Picking one adds the files to it. A folder from the same day is preselected.
- This covers every combination: per day or all together, into new or existing folders, and a mix of both across days.
- A title suggested by Gemini carries a "suggested" tag. A chosen existing folder carries an "existing" tag.
- "One folder" takes its date from the first day.

## Review: the file list

- Every day is a collapsible group. The open group is a scrollable list of all files from that day.
- Columns: checkbox, file name, reason tag, camera, capture time, size.
- Files that Copier leaves out by default are listed too, in capture order. They are greyed out, unticked, and tagged `backed up` or `other` (sidecar files such as `.XML`). Ticking one includes it anyway.
- The line under the title sums it up: "206 backed up · 4 other".

## Bottom bar

Destination picker with free space, the "Camera subfolders" switch, the total size and the "Back up N files" button. There is no side panel and no folder tree preview.

## Design tokens

| Token | Light | Dark |
|---|---|---|
| Window background | `#F5F6F8` | `#1B1C1F` |
| Sidebar | `#EBEDF0` | `#232529` |
| Surface | `#FFFFFF` | `#292B30` |
| Hairline | `#DADDE3` | `#393C43` |
| Text | `#16181D` | `#F0F1F4` |
| Secondary text | `#565B66` | `#A3A8B3` |
| Accent | `#1D5FD1` | `#6BA4FF` |
| Text on accent | `#FFFFFF` | `#0E1320` |
| Accent tint | `#E4EDFB` | `#1B2A44` |
| Success | `#1F7A3D` | `#5CC483` |
| Warning | `#8A5A00` | `#E5B454` |
| Selection | `#DCE0E7` | `#363940` |

In SwiftUI most of these map to system colors (`.background`, `.secondary`, `Color.accentColor`). Set the accent color to the blue above and keep custom colors to a minimum.

- Type: system font. 13 pt body, 12 pt secondary, never below 11 pt, 21 pt screen titles, SF Mono for file names and paths, tabular figures for numbers.
- Shape: 8 pt controls, 10 pt grouped lists, 1 pt hairlines, no shadows except popovers.
- Window: 920 × 620 minimum, resizable, 200 pt sidebar.

## Not designed yet

- Error states: NAS unreachable, not enough space at the destination, copy or verify failure, card removed during backup.
- Scanning state between card insert and review, including the fast scan that skips the duplicate check.
- All files already backed up (today's "All files backed up" state).
- Merge and split of several sessions on the same day. The Electron app has it, the design leaves it out for now.
- Several cards at once.
- Settings tabs NAS, Naming and AI. Only Locations is drawn.
- At 920 pt the folder field truncates long titles, and the destination path in the bottom bar truncates too. Both need to grow with the window, or the counts column has to give way.

## Files

- `index.html` shows all screens on one page.
- `screens/` holds standalone HTML, one file per screen, no dependencies.
- `canvas/` holds the source artboards (`.dc.html` plus `canvas.json`) from the Claude design canvas. They only render inside that canvas. To change the design, edit there, copy the artboards back into `canvas/` and run `python3 build-screens.py`.
- Sample data such as `SONY_A7IV`, the file names and folder titles is made up.
