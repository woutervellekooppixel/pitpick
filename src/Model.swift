// Photos and the state of the open folder.
import Foundation
import AppKit

enum FileKind { case cr3, raw, embedded }

enum ColorLabel: Int, CaseIterable {
    case red = 1, yellow, green, blue, purple

    var englishName: String { ["", "Red", "Yellow", "Green", "Blue", "Purple"][rawValue] }
    var dutchName: String { ["", "Rood", "Geel", "Groen", "Blauw", "Paars"][rawValue] }

    var color: NSColor {
        switch self {
        case .red: return NSColor(calibratedRed: 0.90, green: 0.24, blue: 0.22, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.95, green: 0.80, blue: 0.22, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.32, green: 0.74, blue: 0.36, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.27, green: 0.52, blue: 0.94, alpha: 1)
        case .purple: return NSColor(calibratedRed: 0.63, green: 0.40, blue: 0.86, alpha: 1)
        }
    }

    static func parse(_ s: String) -> ColorLabel? {
        let l = s.trimmingCharacters(in: .whitespaces).lowercased()
        return allCases.first { $0.englishName.lowercased() == l || $0.dutchName.lowercased() == l }
    }
}

/// Fixed snapshot for background work (nothing that changes while renaming).
struct SourceRef {
    let id: Int
    let url: URL
    let kind: FileKind
    let cr3: CR3Info?
}

final class Photo {
    let id: Int
    var url: URL
    var sidecar: URL?
    var companions: [URL]
    let kind: FileKind
    let cr3: CR3Info?
    let captureDate: Date
    /// The camera's time zone when the file records it (OffsetTime); otherwise the Mac's.
    var captureZone: TimeZone?
    let orientation: Int
    var tagged = false
    var rating = 0
    var label: ColorLabel?
    var originalFileName: String
    var hasStoredOriginal = false

    init(id: Int, url: URL, kind: FileKind, cr3: CR3Info?, captureDate: Date, orientation: Int, companions: [URL]) {
        self.id = id
        self.url = url
        self.kind = kind
        self.cr3 = cr3
        self.captureDate = captureDate
        self.orientation = orientation
        self.companions = companions
        self.originalFileName = url.lastPathComponent
    }

    var name: String { url.lastPathComponent }

    /// Date and time on the camera's clock, for {shootdate} (2026-11-19) and {time} (21-04-37).
    var shootDate: String { let c = captureParts; return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0) }
    var shootTime: String { let c = captureParts; return String(format: "%02d-%02d-%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0) }
    private var captureParts: DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = captureZone ?? .current
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: captureDate)
    }
    var ref: SourceRef { SourceRef(id: id, url: url, kind: kind, cr3: cr3) }
    var originalBase: String { (originalFileName as NSString).deletingPathExtension }

    /// Trailing digits of the camera file name, for example 3777 from _V1_3777.
    var frameNumber: String {
        let digits = originalBase.reversed().prefix { $0.isNumber }
        return String(digits.reversed())
    }

    /// Where the metadata goes: XMP next to a raw, inside the file for JPG/DNG/HEIC.
    var metadataTarget: URL {
        if kind == .embedded { return url }
        return sidecar ?? url.deletingPathExtension().appendingPathExtension("xmp")
    }

    var allFiles: [URL] { [url] + companions + (kind == .embedded ? [] : (sidecar.map { [$0] } ?? [])) }
}

enum ViewMode { case grid, loupe }

final class Session: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var visible: [Photo] = []
    var currentIndex = 0
    @Published var onlyTagged = false
    @Published private(set) var taggedCount = 0
    @Published var title = "No folder open"
    @Published var readOnly = false
    @Published var loading: String?
    @Published var busy: String?
    @Published var message: String?
    var mode: ViewMode = .grid
    @Published var roots: [URL] = []
    @Published var lastRenameLog: URL?
    @Published var lastCopyFolder: URL?
    @Published var scopeTagged = true
    @Published var ingesting = false

    var currentPhoto: Photo? { visible.indices.contains(currentIndex) ? visible[currentIndex] : nil }

    func setPhotos(_ p: [Photo], roots: [URL]) {
        photos = p
        self.roots = roots
        onlyTagged = false
        currentIndex = 0
        lastRenameLog = nil
        message = nil
        rebuildVisible(keeping: nil)
        recount()
    }

    /// Rebuilds the visible list and keeps the same photo (or the nearest one) selected.
    func rebuildVisible(keeping keep: Photo?) {
        let oldIndex = currentIndex
        visible = onlyTagged ? photos.filter { $0.tagged } : photos
        if let k = keep, let i = visible.firstIndex(where: { $0 === k }) {
            currentIndex = i
        } else if let k = keep, let pos = photos.firstIndex(where: { $0 === k }) {
            // the photo drops out of the filter: take the next one that is still visible
            let next = photos[pos...].first { p in visible.contains { $0 === p } }
            currentIndex = next.flatMap { n in visible.firstIndex { $0 === n } } ?? max(0, visible.count - 1)
        } else {
            currentIndex = min(oldIndex, max(0, visible.count - 1))
        }
    }

    func recount() { taggedCount = photos.reduce(0) { $0 + ($1.tagged ? 1 : 0) } }

    /// Adds a photo at the end (ingest delivers them in capture-time order).
    func append(_ p: Photo) {
        photos.append(p)
        if !onlyTagged || p.tagged { visible.append(p) }
        if p.tagged { taggedCount += 1 }
    }
}
