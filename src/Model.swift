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
    /// The camera's own clock, as in the file (also the key of the ingest history).
    let cameraDate: Date
    /// Seconds to add to this body's clock, so two cameras sort and name as one (set per body in the panel).
    var clockOffset: TimeInterval = 0
    /// When the photo was taken: the camera's clock plus the correction for this body.
    var captureDate: Date { clockOffset == 0 ? cameraDate : cameraDate.addingTimeInterval(clockOffset) }
    /// The camera body: its serial number, or the model when the file has none.
    var body: String?
    var model: String?
    /// The camera's time zone when the file records it (OffsetTime); otherwise the Mac's.
    var captureZone: TimeZone?
    let orientation: Int
    var tagged = false
    var rating = 0
    var label: ColorLabel?
    var originalFileName: String
    var hasStoredOriginal = false
    /// Protected in the camera (locked on the card).
    var locked = false
    /// Who is in this photo, when it differs from the job's Person shown (nil = the job's). May hold codes (\jb\).
    var people: [String]?

    init(id: Int, url: URL, kind: FileKind, cr3: CR3Info?, captureDate: Date, orientation: Int, companions: [URL]) {
        self.id = id
        self.url = url
        self.kind = kind
        self.cr3 = cr3
        self.cameraDate = captureDate
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

enum ViewMode { case grid, loupe, compare }

/// One camera body in the open folders.
struct CameraBody: Identifiable, Equatable {
    let id: String
    let name: String
    let count: Int
}

/// Counters that change with almost every key press (tags, the selection). They are kept apart from the session,
/// so a tag only updates the few texts in the panel that show a count: rebuilding the whole panel took most of
/// the time of a key press.
final class Counts: ObservableObject {
    @Published var tagged = 0
    @Published var selected = 0
}

/// What Write metadata, Rename and Copy work on.
enum Scope: Hashable { case tagged, shown, selected, all }

final class Session: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var visible: [Photo] = []
    var currentIndex = 0
    @Published var onlyTagged = false
    /// Show only photos with at least this many stars (0 = any).
    @Published var minRating = 0
    /// Show only photos with this colour label (nil = any).
    @Published var labelFilter: ColorLabel?
    let counts = Counts()
    /// Not published: `counts.tagged` is, and only the texts with a count follow it.
    private(set) var taggedCount = 0 { didSet { if counts.tagged != taggedCount { counts.tagged = taggedCount } } }
    @Published var title = "No folder open"
    @Published var readOnly = false
    /// The open card or disk is locked (read-only volume), as opposed to a folder set as read-only.
    @Published var lockedVolume = false
    /// The open folders are on a memory card: Pitpick writes nothing there, tags go along with the ingest.
    @Published var onCard = false
    @Published var loading: String?
    @Published var busy: String?
    @Published var message: String?
    var mode: ViewMode = .grid
    @Published var roots: [URL] = []
    @Published var lastRenameLog: URL?
    /// The camera bodies in the open folders, for the clock corrections in the panel.
    @Published var bodies: [CameraBody] = []
    @Published var lastCopyFolder: URL?
    /// Which photos Write metadata, Rename and Copy work on.
    @Published var scope: Scope = .tagged
    /// Photos selected with shift- or cmd-click (or ⌘A): key presses and actions work on all of them.
    /// Not published (see `counts.selected`).
    var selection = Set<ObjectIdentifier>() {
        didSet {
            if scope == .selected && selection.count < 2 { scope = .tagged }
            if counts.selected != selection.count { counts.selected = selection.count }
        }
    }

    var selectedPhotos: [Photo] { selection.isEmpty ? [] : visible.filter { selection.contains(ObjectIdentifier($0)) } }
    @Published var ingesting = false
    /// Asks the panel to open (and scroll to) the metadata template, for a pinned field that is still empty.
    @Published var openTemplate = false

    var currentPhoto: Photo? { visible.indices.contains(currentIndex) ? visible[currentIndex] : nil }

    var filtering: Bool { onlyTagged || minRating > 0 || labelFilter != nil }

    func passes(_ p: Photo) -> Bool {
        (!onlyTagged || p.tagged) && p.rating >= minRating && (labelFilter == nil || p.label == labelFilter)
    }

    func setPhotos(_ p: [Photo], roots: [URL]) {
        photos = p
        self.roots = roots
        onlyTagged = false
        minRating = 0
        labelFilter = nil
        selection = []
        lockedVolume = false
        onCard = false
        currentIndex = 0
        lastRenameLog = nil
        message = nil
        rebuildVisible(keeping: nil)
        recount()
    }

    /// Rebuilds the visible list and keeps the same photo (or the nearest one) selected.
    func rebuildVisible(keeping keep: Photo?) {
        let oldIndex = currentIndex
        visible = filtering ? photos.filter(passes) : photos
        if let k = keep, let i = visible.firstIndex(where: { $0 === k }) {
            currentIndex = i
        } else if let k = keep, let pos = photos.firstIndex(where: { $0 === k }) {
            // the photo drops out of the filter: take the next one that is still visible
            let shown = Set(visible.map { ObjectIdentifier($0) })
            let next = photos[pos...].first { shown.contains(ObjectIdentifier($0)) }
            currentIndex = next.flatMap { n in visible.firstIndex { $0 === n } } ?? max(0, visible.count - 1)
        } else {
            currentIndex = min(oldIndex, max(0, visible.count - 1))
        }
        // photos that are no longer shown are no longer selected
        if !selection.isEmpty {
            let kept = selection.intersection(visible.map { ObjectIdentifier($0) })
            if kept.count != selection.count { selection = kept }
        }
    }

    func recount() { taggedCount = photos.reduce(0) { $0 + ($1.tagged ? 1 : 0) } }

    /// Adds a photo at the end (ingest delivers them in capture-time order).
    func append(_ p: Photo) {
        photos.append(p)
        if passes(p) { visible.append(p) }
        if p.tagged { taggedCount += 1 }
    }

    /// After a clock correction: shooting order again, with the same photo selected.
    func resort(keeping keep: Photo?) {
        photos.sort(by: Session.before)
        rebuildVisible(keeping: keep)
    }

    /// Shooting order: capture time, then name (as the scanner sorts).
    static func before(_ a: Photo, _ b: Photo) -> Bool {
        if a.captureDate != b.captureDate { return a.captureDate < b.captureDate }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static func insertionIndex(_ list: [Photo], _ p: Photo) -> Int {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if before(list[mid], p) { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Adds a photo in shooting order among the ones already there (a job folder that grows during an ingest);
    /// the selected photo stays selected.
    func insertSorted(_ p: Photo) {
        photos.insert(p, at: Session.insertionIndex(photos, p))
        if passes(p) {
            let vi = Session.insertionIndex(visible, p)
            visible.insert(p, at: vi)
            if vi <= currentIndex && visible.count > 1 { currentIndex += 1 }
        }
        if p.tagged { taggedCount += 1 }
    }
}
