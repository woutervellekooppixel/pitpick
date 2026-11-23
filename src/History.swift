// Incremental ingest, like Photo Mechanic: every photo that was ever ingested is remembered by its camera
// file name and capture time (to the millisecond: no two photos share both, and nothing extra is read). Ingest the same card again later (after the encore, the next day) and
// only the new photos are copied, also when the copies were renamed, moved or culled in the meantime.
// Each line: key, a tab, and the job folder the photo went into, so opening those cards again continues that job.
import Foundation

final class IngestHistory {
    static let shared = IngestHistory(file: FileOps.appSupport.appendingPathComponent("ingested.txt"))

    let file: URL
    private let lock = NSLock()
    /// key -> job folder (the raw folder the photo was copied into)
    private var keys: [String: String]?

    init(file: URL) { self.file = file }

    /// Camera file name and capture time to the millisecond: the same photo on a card, every time.
    static func key(_ p: Photo) -> String {
        "\(p.originalFileName.lowercased())|\(String(format: "%.3f", p.cameraDate.timeIntervalSince1970))"
    }

    /// Reads the history in the background, so the first card that goes in does not wait for it.
    func preload() { DispatchQueue.global(qos: .utility).async { _ = self.count } }

    private func loaded() -> [String: String] {
        if let k = keys { return k }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var k: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if let key = parts.first { k[key] = parts.count > 1 ? parts[1] : "" }
        }
        keys = k
        return k
    }

    func contains(_ p: Photo) -> Bool {
        let k = IngestHistory.key(p)
        lock.lock(); defer { lock.unlock() }
        return loaded()[k] != nil
    }

    /// The job folder most of these photos were ingested into before, and how many of them were.
    func previousJob(of photos: [Photo]) -> (folder: String, count: Int)? {
        let found = photos.map { IngestHistory.key($0) }
        lock.lock(); defer { lock.unlock() }
        let all = loaded()
        var counts: [String: Int] = [:]
        for k in found { if let f = all[k], !f.isEmpty { counts[f, default: 0] += 1 } }
        guard let best = counts.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, counts.values.reduce(0, +))
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return loaded().count
    }

    /// Remembers an ingested photo and its job folder (one line appended to the history file).
    func add(_ key: String, folder: String) {
        lock.lock(); defer { lock.unlock() }
        if keys == nil { _ = loaded() }
        guard keys?[key] == nil else { return }
        keys?[key] = folder   // in place: no copy of the whole history per photo
        let line = Data((key + "\t" + folder + "\n").utf8)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: file) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
            try? h.close()
        } else {
            try? line.write(to: file)
        }
    }

    /// Starts over: the old history is kept next to it under a dated name, never deleted.
    func forget() {
        lock.lock(); defer { lock.unlock() }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        let kept = file.deletingLastPathComponent().appendingPathComponent("ingested-until-\(f.string(from: Date())).txt")
        try? FileManager.default.moveItem(at: file, to: kept)
        keys = [:]
    }
}
