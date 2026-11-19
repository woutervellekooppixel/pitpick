# Snelkeus

**Fast culling, IPTC metadata and renaming for photographers on macOS. Nothing else.**

Free and open source. *Snelkeus* is Dutch for "quick pick".

![Snelkeus loupe view](docs/loupe.jpg)

## Why

I'm a concert photographer and shoot with two Canon EOS R5 Mark II bodies. After a show I need to get from two full cards to a captioned, well-named selection, and I need it fast.

Photo Mechanic is fast because it never renders the raw: it shows the JPEG the camera already embedded in every file. Snelkeus does the same, and only the few things I actually use: ingest, cull, caption, rename, copy. No catalog, no editing, no subscription.

## What it does

- **Fast.** Snelkeus never develops a raw.
  - For Canon CR3 it reads the camera's full-size embedded JPEG (8192x5464 on an R5 II) straight out of the file.
  - On a Mac mini M4 Pro, with real concert files:
    - a photo at screen size takes about 35-50 ms
    - a 100% focus check takes about 85 ms
    - a grid thumbnail takes 3-6 ms
  - It preloads in the direction you browse. In tests at 8 photos per second every frame was already sharp when it appeared; at 15 per second, 31 of 33 were.
- **Ingest.** Put both cards in, drag them onto the window and fill in the job.
  - Everything is copied to `<ingest folder>/<job folder>/raw`, with folder and file names built from your metadata.
  - You can start culling while it is still copying.
  - Run it again and it continues where it stopped. Nothing is copied twice.
  - If two bodies produce the same name, the second one gets `-2`.
- **Cull.**
  - `T` tags. It is the same XMP tag Photo Mechanic uses, so the two apps read each other's tags.
  - `1`-`5` set stars and `6`-`9` set colour labels, Lightroom style.
  - Return opens the loupe. Space, `Z` or a click shows 100%.
  - `⌘T` shows only the tagged photos.
  - Photos from both bodies are merged in capture-time order.
- **Open metadata.**
  - Every common IPTC field is there: event, location, city, person shown, headline, caption, keywords, creator, credit, copyright, usage terms and more.
  - Any field can use tokens such as `{event}`, `{location}`, `{date}` or the name of another field.
  - **Pin** the fields that stay the same for every job. Unpinned fields start empty for each new job.
  - Locations remember their city.
  - Save the whole setup as a `.snelkeus` preset and double-click it on another Mac.
- **Rename** with a template, and undo it if needed. **Copy the selection** to an archive folder with new names and metadata.
- **Safe.**
  - Snelkeus writes only XMP: a sidecar next to a raw, and inside the file for JPG, DNG and HEIC.
  - It never modifies a raw, never overwrites a file and never deletes anything.
  - Folders you mark as read-only (for example an archive drive) are view and copy only.
- **Lightroom friendly.** Lightroom Classic reads the stars, colour labels and IPTC fields when you import. Rename before you import.

![Grid view](docs/grid.jpg)

## Keys

| Key | Action |
| --- | --- |
| `T` | Tag / untag |
| `1`-`5`, `0` | Stars, no stars |
| `6` `7` `8` `9` | Red, yellow, green, blue label |
| `←` `→` (`↑` `↓` in the grid) | Browse |
| Return or double-click | Loupe, and back |
| Space, `Z` or click | 100% at the mouse, drag to pan |
| Esc | Out of 100%, back to the grid |
| `⌘T` | Tagged only |
| `⌘+` `⌘-` | Thumbnail size |
| Tab | Show or hide the panel |

## Tokens

Use them in any metadata field, the file name and the folder name.

| Token | Value |
| --- | --- |
| `{event}`, `{location}`, `{city}`, `{creator}`, ... | Any field, by its name |
| `{date}` | Job date, `2026-11-19` (the first capture day, editable; one date for the whole set, also after midnight) |
| `{date-dmy}`, `{year}`, `{month}`, `{day}` | `19-11-2026`, `2026`, `11`, `19` |
| `{frame}` | Frame number from the camera file name (`3777` from `_MG_3777.CR3`) |
| `{filename}` | Original camera file name without extension |
| `{seq}` | Sequence number in the selection, `0001` |

The default file name is `{date}_{event}-{location}_{filename}` and the default folder name is `{date}_{event}-{location}`.

## Formats

Canon CR3 uses the fast path. Other raws (CR2, NEF, ARW, RAF, ORF, RW2, DNG, ...) and JPG, HEIC and TIFF work through macOS ImageIO, using the embedded previews where the camera provides them.

## Install

1. Download `Snelkeus.zip` from [Releases](../../releases/latest), unzip it and move `Snelkeus.app` to Applications.
2. The app is not notarized by Apple. The first time you open it, macOS blocks it: open System Settings > Privacy & Security and click **Open Anyway**.

You need macOS 14 or later, on Apple Silicon or Intel. ExifTool is included.

## Build from source

You need Xcode's Command Line Tools (no full Xcode), plus exiftool from Homebrew to bundle it.

```sh
brew install exiftool
./build.sh            # universal app in build/, zip in dist/
./build.sh quick      # Apple Silicon only, faster
```

Self test, run on copies of your own files in a temporary folder:

```sh
build/Snelkeus.app/Contents/MacOS/Snelkeus --selftest /path/to/folder/with/CR3s
build/Snelkeus.app/Contents/MacOS/Snelkeus --bench /path/to/folder
```

## Credits

- Made by [Wouter Vellekoop](https://wouter.photo), concert and event photographer.
- Includes [ExifTool](https://exiftool.org) by Phil Harvey; see [THIRD-PARTY.md](THIRD-PARTY.md).

## License

MIT. See [LICENSE](LICENSE). The screenshots show my own photos, and those are not covered by the license.
