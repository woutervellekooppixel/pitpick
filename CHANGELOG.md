# Changelog

What changed in each version of Pitpick (formerly Snelkeus), newest first. Downloads are on the [Releases](https://github.com/woutervellekooppixel/pitpick/releases) page.

## 1.5 - 2026-11-23

### Added
- **Incremental ingest**, like Photo Mechanic. Pitpick remembers every photo it ingested (camera file name and capture time). Ingest the same card again and only the new photos are copied, also when the first copies were renamed, moved or culled. Opening a card that was ingested before continues that job, with its fields and folder.
- **Several photos at once.** Shift-click, ⌘-click, shift-arrows and ⌘A select photos in the grid; `T`, stars and labels work on all of them. Write and rename and Copy can work on the selection.
- **Undo** for tags, stars and labels: ⌘Z and ⇧⌘Z, also for a selection.
- **Filters** on stars (at least that many) and colour labels, next to Tagged only: click a star or a colour dot in the panel, or ⌥⌘1-5; ⌥⌘0 shows everything again.
- **Next photo after a tag, stars or label**, as a setting, or keep Caps Lock on as in Lightroom.
- **Compare.** `C` shows the selected photos (two to four), or this photo and the next, side by side. Space or a click zooms all of them to 100% on the same spot and dragging moves them together; the arrows choose the active photo, and keys work on that one.
- **Camera clocks.** With photos from two or more bodies, the panel lists each body (by serial number) with its clock correction. Type one, or select two photos of the same moment and click Same moment. The shooting order, `{shootdate}`, `{time}` and the capture time in the XMP follow.
- **Camera JPEG.** Copy selection can deliver the JPEG the camera made, taken out of the raw: full size (not compressed again) or 3000 or 2048 px, with the camera's EXIF, its colour profile (Adobe RGB when the camera is set to it) and your caption.
- **A second copy during the ingest**, on another disk: the card is read once and written twice. With **Check every copy against the card**, each copy is read back from its disk and its SHA-256 compared with the card's, while the next photo comes off the card.
- **Protected and rated in the camera.** A photo you protected in the camera shows a padlock and counts as tagged on the card (a setting); stars given in the camera are read. **Tagged and rated photos first** copies those first, from all cards.
- **Eject the cards when done**, as a setting.
- **T also sets a label**, as a setting, for Lightroom, which does not read the tag.
- **Person shown per photo.** `P` sets who is in this photo (or the selection); `{personshown}` in the caption follows it.
- **Code replacements**, as in Photo Mechanic: a text file with a code, a tab and its text on each line. Type `\jb\` in any field, or as the person in a photo, and the metadata says James Bay.
- **Folders on a network drive** get a small index on the Mac (nothing is written on the drive), so opening one again only reads what changed.

### Changed
- Tags, stars and labels: the screen is ready after a key in 0.02 ms (was 3-4 ms), because the panel now only updates the counts.
- Opening a folder replaces the photos directly, without an empty grid in between.
- The colour-label filter and the label for `T` are coloured dots, the star filter is five stars.

### Fixed
- A photo protected in the camera could not be ingested in 1.4 and 1.4.1: the copy kept the card's lock and could not get its real name. Copies are never locked now.

## 1.4.1 - 2026-11-23

### Added
- **Cards.** Pitpick notices a memory card going in and lists it at the top of the panel, checked, with the number of photos and the space in use. Cards that were already in at launch are listed too.
- **View** opens the checked cards together, in shooting order, so you can cull right on the cards. **Ingest** copies them straight away.
- Before you open something else, close the window or quit, Pitpick asks if photos on a card have a tag, stars or a label that would be lost.

### Changed
- Pitpick writes nothing on a memory card. Tags, stars and labels stay in Pitpick and go along with the ingest.
- Only disks that look like a card are checked for a DCIM folder, so an external SSD or a network drive never triggers macOS's access question.

## 1.4 - 2026-11-23

### Added
- On Apple Silicon, libjpeg-turbo decodes the camera's JPEG on three cores next to the Mac's hardware JPEG decoder, which handles one image at a time. Browsing at 30 photos a second, every photo is sharp when it appears (was 6 of 40).
- When you browse even faster, the camera's own preview (1620 px) fills the gap: never a blank screen.
- Zoomed in, the next and previous photo are prepared at 100%: the next photo is there in 0.8 ms (was 208 ms). Look at a photo for a moment and 100% shows in 2-3 ms (was 136 ms).

### Changed
- The default file name ends with the camera's frame number, so frames shot in the same second sort in shooting order. If you used the old default name, Pitpick moves to the new one by itself.
- Ingest copies under a temporary name first, so an interrupted copy never sits under the real name. It stops at a full disk, and only what still has to be copied counts in the space check.
- A locked card is read-only: tags stay in Pitpick and go along with the ingest.
- An unknown token (a typo such as `{evnt}`) or an unclear date is caught before anything is named. A date typed as `19-11-2026` reads as `2026-11-19`. Names never start with a dot and are cut at 200 bytes.
- JPG and DNG files: the XMP is read from the first 256 KB instead of 3 MB. A network folder of 331 Lightroom exports opens in 1.1 s instead of 9 s.
- Renaming runs in the background, with progress.
- exiftool starts after the first folder is read, and is restarted if it ever hangs.
- The self test works on anyone's photos.

## 1.3.2 - 2026-11-20

### Changed
- A glassier app icon.

## 1.3.1 - 2026-11-20

### Added
- App icon: the rock hand between two crop marks, in macOS style.

## 1.3 - 2026-11-20

### Changed
- Ingest copies every card at the same time, each from its own reader, like Photo Mechanic. The XMP is written alongside.

### Added
- When the Photographer field is empty, Pitpick tells you where to find it and opens the Metadata template.
- `--bench-ingest` measures an ingest from the command line.

## 1.2 - 2026-11-20

### Changed
- Snelkeus is now Pitpick. Presets are `.pitpick` files; older `.snelkeus` presets still load. On the first start Pitpick takes over the settings and rename history of Snelkeus.
- The default file name is `{shootdate}_{time}_{event}-{location}-{city}_{photographer}`, with the date and time from the camera.

### Added
- Tokens `{shootdate}`, `{time}` and `{photographer}` (the IPTC Creator field, now labelled Photographer).
- Spaces become dashes in folder and file names. You can turn this off.

## 1.1 - 2026-11-19

First public release, as Snelkeus.

- Fast culling: shows the camera's embedded JPEG (Canon CR3 fast path), preloads in the browsing direction, 100% focus check.
- Ingest from two cards into `<ingest folder>/<job folder>/raw`, with names from your metadata; cull while it copies.
- Open IPTC metadata with tokens such as `{event}` and `{date}`, pinned and per-job fields, presets.
- Tag (Photo Mechanic compatible), stars and Lightroom colour labels, in XMP.
- Rename with undo; copy the selection with new names and metadata.
- Writes XMP only, never touches raws, never overwrites, never deletes.
