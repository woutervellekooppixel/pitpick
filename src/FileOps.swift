// Ingest, rename (with an undo log) and copying the selection. Never overwrites, never deletes.
import Foundation

struct Move: Codable {
    let from: String
    let to: String
}

struct RenameItem {
    let photo: Photo
    let main: URL
    let sidecar: URL?
    let companions: [URL]
}

struct IngestResult {
    var copied = 0
    var alreadyThere = 0
    var suffixed = 0
    var bytes: Int64 = 0
    var errors: [String] = []
    /// The destination ran out of space; the ingest stopped there (run it again to continue).
    var diskFull = false
}

/// One photo of an ingest, planned before anything is copied.
struct IngestJob {
    let index: Int
    let src: Photo
    let main: URL
    let side: URL?
    let comps: [URL]
    /// Already copied in an earlier run (same name and size).
    let reuse: Bool
    let suffixed: Bool
    /// Bytes still to copy (0 when reused).
    let bytes: Int64
}

enum FileOps {
    static var logDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Pitpick/renames", isDirectory: true)
    }

    static func fileSize(_ u: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    // MARK: ingest

    /// Copies every photo (with its JPG twin and any existing XMP) into `dest`, under its new name,
    /// and writes the metadata right after each copy.
    ///
    /// Speed: every card (volume) gets its own copy stream, so two cards in two readers copy at the same
    /// time, like Photo Mechanic. All names are planned first, in capture order, so the streams can never
    /// claim the same name. The XMP is written on a separate queue, so copying never waits for exiftool.
    /// `onPhoto` receives the copies in capture order as soon as all earlier photos are in, so culling can
    /// start while the rest is still copying. A file that is already there with the same size counts as
    /// ingested before (resume); a different file with the same name gets -2, -3.
    /// Plans every target name, in capture order. A file that is already there with the same size counts
    /// as ingested before (resume); a different file with the same name gets -2, -3. Nothing is written.
    static func planIngest(_ sources: [Photo], to dest: URL, name: (Photo, Int) -> String) -> [IngestJob] {
        let fm = FileManager.default
        var jobs: [IngestJob] = []
        var claimed = Set<String>()
        for (i, src) in sources.enumerated() {
            let base = safeFileName(name(src, i + 1))
            let ext = src.url.pathExtension.lowercased()
            let size = fileSize(src.url)
            var b = base
            var n = 2
            var reuse = false
            while n < 1000 {
                let main = dest.appendingPathComponent(b + "." + ext)
                if claimed.contains(main.path.lowercased()) { b = "\(base)-\(n)"; n += 1; continue }
                if fm.fileExists(atPath: main.path) {
                    if fileSize(main) == size { reuse = true; break }
                    b = "\(base)-\(n)"; n += 1; continue
                }
                break
            }
            let main = dest.appendingPathComponent(b + "." + ext)
            let side: URL? = src.kind == .embedded ? nil : dest.appendingPathComponent(b + ".xmp")
            let comps = src.companions.map { dest.appendingPathComponent(b + "." + $0.pathExtension.lowercased()) }
            claimed.insert(main.path.lowercased())
            if let s = side { claimed.insert(s.path.lowercased()) }
            comps.forEach { claimed.insert($0.path.lowercased()) }
            let bytes = reuse ? 0 : max(0, size) + src.companions.reduce(Int64(0)) { $0 + max(0, fileSize($1)) }
            jobs.append(IngestJob(index: i, src: src, main: main, side: side, comps: comps, reuse: reuse, suffixed: b != base, bytes: bytes))
        }
        return jobs
    }

    /// Copies under a hidden temporary name and renames when complete, so an interrupted copy
    /// (power cut, crash) can never sit under the real name. A leftover temporary file from an
    /// earlier interrupted run is Pitpick's own and gets replaced. Never overwrites a real file.
    static func copyAtomically(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        let tmp = to.deletingLastPathComponent().appendingPathComponent("." + to.lastPathComponent + ".pitpick-partial")
        if fm.fileExists(atPath: tmp.path) { try fm.removeItem(at: tmp) }
        try fm.copyItem(at: from, to: tmp)
        do {
            try fm.moveItem(at: tmp, to: to)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// The destination is full (Cocoa or POSIX error, possibly wrapped).
    static func isDiskFull(_ e: Error) -> Bool {
        let ns = e as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isDiskFull(u) }
        return false
    }

    static func ingest(_ sources: [Photo], to dest: URL, name: (Photo, Int) -> String,
                       metadata: ((Photo) -> [String])?, cancelled: () -> Bool,
                       onPhoto: @escaping (Photo) -> Void) -> IngestResult {
        let fm = FileManager.default
        var r = IngestResult()
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            r.errors.append("Cannot create \(dest.path): \(error.localizedDescription)")
            return r
        }

        // 1. Plan every target name, in capture order.
        let jobs = planIngest(sources, to: dest, name: name)

        // 2. Metadata and hand-over on one serial queue. A photo is handed over once every earlier one is,
        //    so the grid fills in capture order even when one card is ahead of the other.
        let lock = NSLock()
        let after = DispatchQueue(label: "nl.wouter.pitpick.ingest", qos: .userInitiated)
        var ready: [Int: Photo?] = [:]
        var next = 0
        func handOver(_ index: Int, _ photo: Photo?) {   // runs on `after`
            ready[index] = .some(photo)
            while let entry = ready[next] {
                ready.removeValue(forKey: next)
                if let p = entry { onPhoto(p) }
                next += 1
            }
        }
        func note(_ change: (inout IngestResult) -> Void) { lock.lock(); change(&r); lock.unlock() }

        // 3. One copy stream per card, all at the same time; each card in capture order.
        var byVolume: [String: [IngestJob]] = [:]
        var volumeOrder: [String] = []
        for job in jobs {
            let key = volumeKey(job.src.url)
            if byVolume[key] == nil { volumeOrder.append(key) }
            byVolume[key, default: []].append(job)
        }
        let streams = volumeOrder.map { byVolume[$0]! }
        var full = false   // the destination ran out of space: every stream stops
        DispatchQueue.concurrentPerform(iterations: streams.count) { s in
            for job in streams[s] {
                lock.lock(); let stop = full; lock.unlock()
                if stop || cancelled() { break }
                let src = job.src
                if job.reuse {
                    // copied in an earlier run: show it as it is, with its own XMP
                    // (a JPG twin that did not make it last time, for example on a full disk, is copied now)
                    note { $0.alreadyThere += 1 }
                    for (c, t) in zip(src.companions, job.comps) where !fm.fileExists(atPath: t.path) { try? copyAtomically(c, to: t) }
                    let xmp = job.side.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
                    let g = Scanner.Group(dir: dest, raw: src.kind == .embedded ? nil : job.main,
                                          images: src.kind == .embedded ? [job.main] + job.comps : job.comps, xmp: xmp)
                    let p = Scanner.makePhoto(id: job.index, g)
                    after.async { handOver(job.index, p) }
                    continue
                }
                do {
                    try copyAtomically(src.url, to: job.main)
                    for (c, t) in zip(src.companions, job.comps) where !fm.fileExists(atPath: t.path) { try copyAtomically(c, to: t) }
                    if let sc = src.sidecar, let t = job.side, fm.fileExists(atPath: sc.path), !fm.fileExists(atPath: t.path) {
                        try copyAtomically(sc, to: t)
                    }
                } catch {
                    if isDiskFull(error) {
                        lock.lock()
                        if !full {
                            full = true
                            r.diskFull = true
                            r.errors.append("The destination disk is full. Free up space and run Ingest again: it continues where it stopped.")
                        }
                        lock.unlock()
                    } else {
                        note { $0.errors.append("\(src.name): \(error.localizedDescription)") }
                    }
                    after.async { handOver(job.index, nil) }
                    continue
                }
                let size = max(0, fileSize(job.main))
                note { $0.copied += 1; $0.bytes += size; if job.suffixed { $0.suffixed += 1 } }
                let p = Photo(id: job.index, url: job.main, kind: src.kind, cr3: src.cr3, captureDate: src.captureDate,
                              orientation: src.orientation, companions: job.comps)
                p.captureZone = src.captureZone
                p.tagged = src.tagged
                p.rating = src.rating
                p.label = src.label
                p.originalFileName = src.originalFileName
                if let sd = job.side, fm.fileExists(atPath: sd.path) { p.sidecar = sd }
                let args = metadata?(p)
                after.async {
                    if let args = args {
                        let res = ExifTool.shared.run([["-overwrite_original"] + args + [p.metadataTarget.path]])
                        if res.first?.ok == true {
                            if p.kind != .embedded { p.sidecar = p.metadataTarget }
                            p.hasStoredOriginal = true
                        } else {
                            note { $0.errors.append("\(job.main.lastPathComponent): metadata: \(res.first?.text ?? "?")") }
                        }
                    }
                    handOver(job.index, p)
                }
            }
        }
        // Stopped early or a photo failed: hand over whatever is still waiting, in order.
        after.sync {
            for k in ready.keys.sorted() { if let p = ready[k] ?? nil { onPhoto(p) } }
            ready.removeAll()
        }
        lock.lock(); defer { lock.unlock() }
        return r
    }

    /// The volume a file is on: one copy stream per card.
    static func volumeKey(_ u: URL) -> String {
        (try? u.resourceValues(forKeys: [.volumeURLKey]).volume?.path) ?? "/"
    }

    // MARK: rename

    /// Works out the new names. A name that is taken gets -2, -3.
    static func planRename(_ photos: [Photo], name: (Photo, Int) -> String) -> (items: [RenameItem], skipped: [String]) {
        let fm = FileManager.default
        var claimed = Set<String>()
        var items: [RenameItem] = []
        var skipped: [String] = []
        var currentOwner: [String: Int] = [:]
        for p in photos {
            for u in p.allFiles { currentOwner[u.path.lowercased()] = p.id }
        }
        for (i, p) in photos.enumerated() {
            let dir = p.url.deletingLastPathComponent()
            let base = safeFileName(name(p, i + 1))
            if base.isEmpty { skipped.append(p.name); continue }
            func targets(_ b: String) -> RenameItem {
                let main = dir.appendingPathComponent(b + "." + p.url.pathExtension.lowercased())
                let side = (p.kind != .embedded && p.sidecar != nil) ? dir.appendingPathComponent(b + ".xmp") : nil
                let comps = p.companions.map { dir.appendingPathComponent(b + "." + $0.pathExtension.lowercased()) }
                return RenameItem(photo: p, main: main, sidecar: side, companions: comps)
            }
            func clashes(_ t: RenameItem) -> Bool {
                let all = [t.main] + (t.sidecar.map { [$0] } ?? []) + t.companions
                for u in all {
                    let key = u.path.lowercased()
                    if claimed.contains(key) { return true }
                    if let owner = currentOwner[key] { if owner != p.id { return true } }
                    else if fm.fileExists(atPath: u.path) { return true }
                }
                return false
            }
            var t = targets(base)
            var n = 2
            while clashes(t) && n < 1000 { t = targets("\(base)-\(n)"); n += 1 }
            if clashes(t) { skipped.append(p.name); continue }
            for u in [t.main] + (t.sidecar.map { [$0] } ?? []) + t.companions { claimed.insert(u.path.lowercased()) }
            if t.main.path == p.url.path && t.sidecar?.path == p.sidecar?.path && t.companions.map(\.path) == p.companions.map(\.path) { continue }
            items.append(t)
        }
        return (items, skipped)
    }

    private static func move(_ from: URL, _ to: URL) throws {
        if from.path == to.path { return }
        let fm = FileManager.default
        if from.path.lowercased() == to.path.lowercased() {
            // only the case differs: go through a temporary name
            let tmp = from.deletingLastPathComponent().appendingPathComponent(".pitpick-\(UUID().uuidString)")
            try fm.moveItem(at: from, to: tmp)
            try fm.moveItem(at: tmp, to: to)
        } else {
            if fm.fileExists(atPath: to.path) {
                throw NSError(domain: "Pitpick", code: 17, userInfo: [NSLocalizedDescriptionKey: "\(to.lastPathComponent) already exists"])
            }
            try fm.moveItem(at: from, to: to)
        }
    }

    /// Where a photo's files are after a rename, to apply on the main thread.
    struct RenameUpdate {
        let photo: Photo
        let url: URL
        let sidecar: URL?
        let companions: [URL]
    }

    /// Moves the files and writes a log for undo. Changes no Photo, so it can run off the main thread;
    /// apply the updates afterwards with `apply`.
    static func performRename(_ items: [RenameItem], progress: ((Int) -> Void)? = nil)
        -> (done: Int, errors: [String], log: URL?, updates: [RenameUpdate]) {
        var moves: [Move] = []
        var errors: [String] = []
        var updates: [RenameUpdate] = []
        var done = 0
        for (k, it) in items.enumerated() {
            let p = it.photo
            var url = p.url, side = p.sidecar, comps = p.companions
            // -1 = the photo, -2 = its XMP, 0... = a companion (JPG twin)
            var pairs: [(from: URL, to: URL, which: Int)] = [(p.url, it.main, -1)]
            if let s = p.sidecar, let t = it.sidecar { pairs.append((s, t, -2)) }
            for (i, (c, t)) in zip(p.companions, it.companions).enumerated() { pairs.append((c, t, i)) }
            var ok = true
            for pair in pairs {
                do {
                    try move(pair.from, pair.to)
                    moves.append(Move(from: pair.from.path, to: pair.to.path))
                    switch pair.which {
                    case -1: url = pair.to
                    case -2: side = pair.to
                    default: comps[pair.which] = pair.to
                    }
                } catch {
                    errors.append("\(pair.from.lastPathComponent): \(error.localizedDescription)")
                    ok = false
                    break
                }
            }
            updates.append(RenameUpdate(photo: p, url: url, sidecar: side, companions: comps))
            if ok { done += 1 }
            if (k + 1) % 50 == 0 { progress?(k + 1) }
        }
        var logURL: URL?
        if !moves.isEmpty {
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd_HHmmss"
            let url = logDir.appendingPathComponent("renamed-\(f.string(from: Date())).json")
            if let d = try? JSONEncoder().encode(moves), (try? d.write(to: url)) != nil { logURL = url }
        }
        return (done, errors, logURL, updates)
    }

    /// Points the photos at their new names (main thread).
    static func apply(_ updates: [RenameUpdate]) {
        for u in updates {
            u.photo.url = u.url
            u.photo.sidecar = u.sidecar
            u.photo.companions = u.companions
        }
    }

    /// Renames, writes a log for undo and updates the photos, all on the calling thread.
    static func executeRename(_ items: [RenameItem]) -> (done: Int, errors: [String], log: URL?) {
        let r = performRename(items)
        apply(r.updates)
        return (r.done, r.errors, r.log)
    }

    /// Undoes a rename, in reverse order. Skips whatever no longer matches.
    static func undo(_ log: URL) -> (restored: Int, skipped: Int) {
        guard let d = try? Data(contentsOf: log), let moves = try? JSONDecoder().decode([Move].self, from: d) else { return (0, 0) }
        let fm = FileManager.default
        var restored = 0, skipped = 0
        for m in moves.reversed() {
            let from = URL(fileURLWithPath: m.from), to = URL(fileURLWithPath: m.to)
            guard fm.fileExists(atPath: to.path) else { skipped += 1; continue }
            if fm.fileExists(atPath: from.path) && from.path.lowercased() != to.path.lowercased() { skipped += 1; continue }
            do { try move(to, from); restored += 1 } catch { skipped += 1 }
        }
        let done = log.deletingPathExtension().appendingPathExtension("undone.json")
        try? fm.moveItem(at: log, to: done)
        return (restored, skipped)
    }

    // MARK: copy the selection

    struct CopyPlanItem {
        let photo: Photo
        let main: URL
        let sidecar: URL?
        let companions: [URL]
        var metadataTarget: URL { photo.kind == .embedded ? main : (sidecar ?? main.deletingPathExtension().appendingPathExtension("xmp")) }
    }

    /// Copies photos (with their XMP and JPG twin) into dest. If something is already there, that photo is skipped.
    static func copy(_ photos: [Photo], to dest: URL, name: (Photo, Int) -> String?,
                     progress: (Int) -> Void, cancelled: () -> Bool) -> (copied: [CopyPlanItem], skipped: [String], errors: [String]) {
        let fm = FileManager.default
        var copied: [CopyPlanItem] = []
        var skipped: [String] = []
        var errors: [String] = []
        var claimed = Set<String>()
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            return ([], [], ["Cannot create \(dest.path): \(error.localizedDescription)"])
        }
        for (i, p) in photos.enumerated() {
            if cancelled() { break }
            let newName = name(p, i + 1)
            let base = newName.map(safeFileName) ?? p.url.deletingPathExtension().lastPathComponent
            let ext = newName == nil ? p.url.pathExtension : p.url.pathExtension.lowercased()
            let main = dest.appendingPathComponent(base + "." + ext)
            let side: URL? = p.kind == .embedded ? nil : dest.appendingPathComponent(base + ".xmp")
            let comps = p.companions.map { dest.appendingPathComponent(base + "." + $0.pathExtension.lowercased()) }
            let all = [main] + (side.map { [$0] } ?? []) + comps
            if all.contains(where: { fm.fileExists(atPath: $0.path) || claimed.contains($0.path.lowercased()) }) {
                skipped.append(p.name)
                progress(i + 1)
                continue
            }
            do {
                try copyAtomically(p.url, to: main)
                for (c, t) in zip(p.companions, comps) { try copyAtomically(c, to: t) }
                if let s = p.sidecar, let t = side, fm.fileExists(atPath: s.path) { try copyAtomically(s, to: t) }
                all.forEach { claimed.insert($0.path.lowercased()) }
                copied.append(CopyPlanItem(photo: p, main: main, sidecar: side, companions: comps))
            } catch {
                errors.append("\(p.name): \(error.localizedDescription)")
            }
            progress(i + 1)
        }
        return (copied, skipped, errors)
    }
}
