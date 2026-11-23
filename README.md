# DiskDrill

<img src="Icon/AppIcon.png" width="128" alt="DiskDrill icon">

A small native macOS app (SwiftUI) for finding out where your disk space went.

It opens on your home folder, shows its total size on disk, and lists every
folder and file in it — hidden ones included — sorted by size. Double-click a
folder to drill into it; go back with ⌘[ or the breadcrumb.

## Features

- Scans the whole tree once in the background; sizes stream in as they're
  measured, and drilling into an already-measured folder is instant.
- Drilling into a folder that's still being measured splits its scan per
  subfolder so results appear sooner.
- Size, share-of-folder bar and file count for every row; sortable columns.
- Hidden items (dot-files and items with the macOS hidden flag, like
  `~/Library`) shown in grey.
- Right-click to Reveal in Finder, Copy Path, or Move to Trash (also ⌘⌫ on
  the selection). Trashing asks for confirmation, shows how much space it
  frees, and updates the totals of every parent folder without a rescan.
- ⌘O picks a different start folder, ⌘R rescans.

Sizes are allocated bytes on disk (what `du` reports): hard links are counted
once, symlinks aren't followed, and other volumes mounted inside a folder are
skipped.

## Build

Requires macOS 14+ and Xcode command-line tools.

```bash
./build.sh
open build/DiskDrill.app

# start somewhere other than ~/
open build/DiskDrill.app --args -start /Volumes/External
```

The app icon is drawn in code by `Icon/make_icon.swift`; after editing it, run
`swift Icon/make_icon.swift` to regenerate `Resources/AppIcon.icns` (and the
`Icon/AppIcon.png` preview), then rebuild.

## Full Disk Access

macOS blocks some folders (parts of `~/Library`, Mail, Safari, etc.), so their
sizes come out low and get a warning icon. Use the "Grant Full Disk Access…"
button in the footer, add DiskDrill, then press ⌘R.
