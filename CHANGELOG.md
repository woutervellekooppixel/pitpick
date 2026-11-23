# Changelog

What changed in each version of Pitpick (formerly Snelkeus), newest first. Downloads are on the [Releases](https://github.com/woutervellekooppixel/pitpick/releases) page.

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
