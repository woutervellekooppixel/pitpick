// A small index per folder on a network drive (the archive on the NAS): what Pitpick read from each photo and its
// XMP, with the files' size and date. Opening the folder again reads only what changed: the size and date of every
// file come along with the folder listing itself, so nothing else has to cross the network. Kept on this Mac in
// ~/Library/Caches/Pitpick/index; nothing is ever written on the drive.
import Foundation
import CryptoKit

/// What one photo looked like when it was read.
struct IndexEntry: Codable {
    var size: Int64
    var mtime: Double
    var xmpSize: Int64?
    var xmpMtime: Double?
    var companions: [String]
    var kind: Int
    var cr3: CR3Info?
    /// Seconds since 2001 (Date's own count: exactly the same Date back)
    var cameraDate: Double
    var zone: Int?
    var orientation: Int
    var model: String?
    var body: String?
    var tagged: Bool
    var rating: Int
    var label: Int?
    var original: String?
    var people: [String]?
}

final class FolderIndex {
    /// Version of the entries: a new one makes Pitpick read everything again once.
    static let version = 2
    let file: URL
    private var entries: [String: IndexEntry]
    private var fresh: [String: IndexEntry] = [:]
    private let lock = NSLock()

    /// Size and date of each file, from the folder listing.
    struct Stamp { let size: Int64; let mtime: Double }

    static var directory: URL {
        if let d = ProcessInfo.processInfo.environment["PITPICK_INDEX_DIR"] { return URL(fileURLWithPath: d) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pitpick/index", isDirectory: true)
    }

    /// Only for folders on a network drive: there every small file costs a round trip; on a local disk reading is
    /// faster than keeping an index.
    static func wanted(for roots: [URL]) -> Bool {
        !roots.isEmpty && roots.allSatisfy { (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false }
    }

    init(roots: [URL], directory: URL? = nil) {
        let key = "v\(FolderIndex.version)|" + roots.map { $0.standardizedFileURL.path }.sorted().joined(separator: "|")
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        file = (directory ?? FolderIndex.directory).appendingPathComponent(name + ".plist")
        if let d = try? Data(contentsOf: file), let e = try? PropertyListDecoder().decode([String: IndexEntry].self, from: d) {
            entries = e
        } else {
            entries = [:]
        }
    }

    var count: Int { entries.count }
    /// Photos taken from the index in this reading (for the self test).
    var used: Int { lock.lock(); defer { lock.unlock() }; return usedCount }
    private var usedCount = 0

    /// The photo as it was read before, when its files did not change since.
    func photo(id: Int, _ g: Scanner.Group, stamps: [String: Stamp]) -> Photo? {
        let main = g.raw ?? g.images.first
        guard let m = main, let st = stamps[m.path], let e = entries[m.path],
              e.size == st.size, e.mtime == st.mtime else { return nil }
        if let x = g.xmp {
            guard let xs = stamps[x.path], e.xmpSize == xs.size, e.xmpMtime == xs.mtime else { return nil }
        } else if e.xmpSize != nil {
            return nil
        }
        let comps = g.raw == nil ? Array(g.images.dropFirst()) : g.images
        guard comps.map({ $0.lastPathComponent }) == e.companions else { return nil }
        let kind: FileKind = e.kind == 0 ? .cr3 : e.kind == 1 ? .raw : .embedded
        let p = Photo(id: id, url: m, kind: kind, cr3: e.cr3, captureDate: Date(timeIntervalSinceReferenceDate: e.cameraDate),
                      orientation: e.orientation, companions: comps)
        p.captureZone = e.zone.flatMap { TimeZone(secondsFromGMT: $0) }
        p.model = e.model
        p.body = e.body
        p.tagged = e.tagged
        p.rating = e.rating
        p.label = e.label.flatMap { ColorLabel(rawValue: $0) }
        if let o = e.original {
            p.originalFileName = o
            p.hasStoredOriginal = true
        }
        p.people = e.people
        p.sidecar = g.xmp
        p.locked = e.cr3?.locked ?? false
        // remembered as it was read, so it is written again unchanged when nothing changed
        lock.lock(); fresh[m.path] = e; usedCount += 1; lock.unlock()
        return p
    }

    /// Remembers a photo that was read from its files.
    func remember(_ p: Photo, _ g: Scanner.Group, stamps: [String: Stamp]) {
        guard let st = stamps[p.url.path] else { return }
        let xs = g.xmp.flatMap { stamps[$0.path] }
        if g.xmp != nil && xs == nil { return }
        let e = IndexEntry(size: st.size, mtime: st.mtime, xmpSize: xs?.size, xmpMtime: xs?.mtime,
                           companions: p.companions.map { $0.lastPathComponent },
                           kind: p.kind == .cr3 ? 0 : p.kind == .raw ? 1 : 2, cr3: p.cr3,
                           cameraDate: p.cameraDate.timeIntervalSinceReferenceDate, zone: p.captureZone?.secondsFromGMT(),
                           orientation: p.orientation, model: p.model, body: p.body,
                           tagged: p.tagged, rating: p.rating, label: p.label?.rawValue,
                           original: p.hasStoredOriginal ? p.originalFileName : nil, people: p.people)
        lock.lock(); fresh[p.url.path] = e; lock.unlock()
    }

    /// Writes the index of this reading (photos that are gone are left out).
    func save() {
        lock.lock(); let e = fresh; lock.unlock()
        guard !e.isEmpty, let d = try? PropertyListEncoder().encode(e) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
    }
}
