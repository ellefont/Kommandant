# Kommandant

**A colorful dual-pane file manager for macOS, in the spirit of Total Commander and Midnight Commander.**

Kommandant shows two folders side by side so you can copy and move files between them, browse USB sticks and external disks, find out what is filling up your disk, and keep backups in sync, all in one native SwiftUI app.

The user interface is available in **English, German and Italian** and follows the macOS system language. For any other language it uses English.

---

## Features

### Dual-pane file management
- Two independent columns with sortable lists (name, size, modified date, kind). Folders are always listed first.
- **Copy (F5)** and **move (F6)** go from the active column into the folder of the other column. A banner at the bottom always shows which way the files will go.
- **Drag & drop** between the columns, and to or from Finder. A drag copies; hold **⌘** to move.
- When a file already exists at the destination, you choose what happens: keep both (`File copy.txt`), replace (the old file goes to the Trash), or skip.
- **Rename (F2)**, **new folder (F7)**, **new folder with selection (⌃⌘N)** and **move to Trash (F8)**. Every destructive action asks for confirmation first.
- Back / forward / up navigation, a clickable path bar, a per-column filter and a toggle for hidden files.
- The columns refresh automatically when files change on disk. The last folders are remembered between launches.

### Drives
- A drive bar in every column lists all mounted volumes: the internal disk, USB sticks, external and network disks. It updates live when you plug in or eject a disk.
- Each drive shows its free space and has an **eject** button. If a disk disappears, any column showing it returns to your home folder.

### Storage analysis (F9)
- Scans one disk or folder at a time. It never counts other volumes or system aliases twice.
- **Folders:** drill-down list sorted by size, with colored bars and percentages.
- **Largest files:** the 300 biggest files, which you can filter by age (older than 6 months / 1 year / 2 years).
- **Clean up:** sizes of well-known space wasters, such as the Trash, user caches, logs, Xcode DerivedData, simulators, device backups, the npm cache and old downloads. It also lists developer folders like `node_modules`, `.venv` and `.build` that can be recreated at any time.
- Any item can be revealed in Finder or in Kommandant, or moved to the Trash.

### Synchronize (F10), similar to FreeFileSync
- Pick a **source (left)** and a **target (right)**, for example a folder and a USB backup disk.
- Three modes:
  - **Mirror:** the right side becomes an exact copy of the left. Files that exist only on the right are deleted.
  - **Update:** new and changed files are copied to the right. Nothing is deleted. This is the default.
  - **Two-way:** changes are copied in both directions. The newer file wins.
- **Compare** first to see a color-coded preview of every difference: copy →, copy ←, delete or conflict. You can change the action of any entry before you sync.
- Progress is shown in bytes, with the current speed and the estimated time left.
- **Safe by default:** deleted *and* overwritten files go to the Trash. You can switch this off.
- Exclude patterns, for example `*.tmp, node_modules`. `.DS_Store` and Spotlight folders are excluded out of the box.
- Files keep their original modification dates. A 2-second tolerance covers FAT/exFAT disks, so the next sync copies only what really changed.
- **Saved jobs:** save a folder pair with its settings, for example "Photos → USB backup", and run it again with one click.

### Archive as ZIP (⌥⌘A)
- Zips the selected folder or files onto another disk. The archive is named after the current date and time, for example `20261018-1540.zip`.
- Checks the free space on the target and warns when the target is on the same disk as the source.
- Compression can be switched off for photos and videos, which makes archiving much faster.
- The archives are clean, with no `.DS_Store` files and no `__MACOSX` folders. They support files over 4 GB and keep symbolic links.

---

## Quick guide

### Installation
1. Open `Kommandant.dmg` and drag **Kommandant** onto **Applications**.
2. The app is not signed with an Apple Developer certificate. The first time, right-click the app, choose **Open**, then confirm.
3. Optional: to analyze the whole internal disk, grant **Full Disk Access** in *System Settings → Privacy & Security*.

### Everyday use
| What you want | How |
|---|---|
| Switch between the columns | **⇥ Tab**, or click a column |
| Open a folder or file | Double-click, or **⌘↓** |
| Go up / back / forward | **⌘↑** / **⌘[** / **⌘]** |
| Copy / move to the other column | **F5** / **F6**, or drag & drop (hold **⌘** to move) |
| Rename | **F2** |
| New folder / new folder with the selection | **F7** or **⇧⌘N** / **⌃⌘N** |
| Move to Trash | **F8** |
| Analyze storage | **F9** |
| Synchronize folders | **F10** |
| Archive as ZIP | **⌥⌘A** |
| Swap the columns / same folder on both sides | **⌘U** / **⌘=** |
| Show hidden files | **⇧⌘.** |
| Refresh | **⌘R** |
| Copy the path | **⌥⌘C** |
| Reveal in Finder | **⌥⌘R** |

> On Mac keyboards the F-keys may need **fn** (for example **fn+F5**), unless you set them up as standard function keys in *System Settings → Keyboard*. Every action is also available from the buttons at the bottom of the window, from the menus and from the right-click menu.

### Backing up a folder to a USB disk
1. Show the folder in the left column and the USB disk in the right column. The disk appears in the drive bar as soon as you plug it in.
2. Press **F10**. The sync window opens with both folders filled in.
3. Choose **Update** (keeps everything already on the disk) or **Mirror** (exact copy).
4. Click **Compare**, check the preview, then click **Synchronize**.
5. Click **Save as Job** so you can repeat the backup with one click next time.

### Freeing up disk space
1. Press **F9**. Choose a disk or folder at the top right.
2. In **Folders**, double-click to drill down to whatever is big.
3. In **Largest files**, filter for *Older than 1 year* to find forgotten files.
4. In **Clean up**, empty caches, logs and the Trash, or delete old `node_modules` folders.

---

## Building from source

Requirements: macOS 14 or later and the Xcode Command Line Tools (`xcode-select --install`). The full Xcode app is not required.

```sh
./build.sh      # builds Kommandant.app (release)
./make-dmg.sh   # builds Kommandant.dmg (drag & drop installer)
```

- The version number lives in the [`VERSION`](VERSION) file.
- All UI texts are in [`Scripts/translations.py`](Scripts/translations.py). German is the source language; English and Italian are the translations. `build.sh` turns this file into the macOS `.lproj` folders.
- The app icon and the DMG background are drawn in code by [`Scripts/make-icon.swift`](Scripts/make-icon.swift) and [`Scripts/make-dmg-background.swift`](Scripts/make-dmg-background.swift).

### Project layout
| File | Contents |
|---|---|
| `KommandantApp.swift` | App entry, windows, menus and keyboard shortcuts |
| `ContentView.swift`, `PaneView.swift` | Main window, the two columns, drive bar and dialogs |
| `AppModel.swift`, `PaneModel.swift` | Copy, move, rename, trash and navigation |
| `Volumes.swift` | Live list of mounted drives, eject |
| `StorageAnalyzer.swift`, `StorageView.swift` | Storage analysis window |
| `SyncEngine.swift`, `SyncModel.swift`, `SyncView.swift` | Folder comparison and synchronization |
| `Archive.swift`, `ArchiveSheet.swift` | ZIP archiving |
| `Localization.swift` | Translation helper |
