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
    /// and writes the metadata right after each copy. `onPhoto` receives the copy as soon as it is ready,
    /// so culling can start while the rest is still copying. A file that is already there with the same
    /// size counts as ingested before (resume); a different file with the same name gets -2, -3.
    static func ingest(_ sources: [Photo], to dest: URL, name: (Photo, Int) -> String,
                       metadata: ((Photo) -> [String])?, cancelled: () -> Bool,
                       onPhoto: (Photo) -> Void) -> IngestResult {
        let fm = FileManager.default
        var r = IngestResult()
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            r.errors.append("Cannot create \(dest.path): \(error.localizedDescription)")
            return r
        }
        var claimed = Set<String>()
        for (i, src) in sources.enumerated() {
            if cancelled() { break }
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

            if reuse {
                // copied in an earlier run: show it as it is, with its own XMP
                r.alreadyThere += 1
                let xmp = side.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
                let g = Scanner.Group(dir: dest, raw: src.kind == .embedded ? nil : main,
                                      images: src.kind == .embedded ? [main] + comps : comps, xmp: xmp)
                if let p = Scanner.makePhoto(id: i, g) { onPhoto(p) }
                continue
            }
            if b != base { r.suffixed += 1 }
            do {
                try fm.copyItem(at: src.url, to: main)
                for (c, t) in zip(src.companions, comps) where !fm.fileExists(atPath: t.path) { try fm.copyItem(at: c, to: t) }
                if let s = src.sidecar, let t = side, fm.fileExists(atPath: s.path), !fm.fileExists(atPath: t.path) {
                    try fm.copyItem(at: s, to: t)
                }
            } catch {
                r.errors.append("\(src.name): \(error.localizedDescription)")
                continue
            }
            r.copied += 1
            r.bytes += max(0, size)
            let p = Photo(id: i, url: main, kind: src.kind, cr3: src.cr3, captureDate: src.captureDate,
                          orientation: src.orientation, companions: comps)
            p.tagged = src.tagged
            p.rating = src.rating
            p.label = src.label
            p.originalFileName = src.originalFileName
            if let s = side, fm.fileExists(atPath: s.path) { p.sidecar = s }
            if let args = metadata?(p) {
                let res = ExifTool.shared.run([["-overwrite_original"] + args + [p.metadataTarget.path]])
                if res.first?.ok == true {
                    if p.kind != .embedded { p.sidecar = p.metadataTarget }
                    p.hasStoredOriginal = true
                } else {
                    r.errors.append("\(main.lastPathComponent): metadata: \(res.first?.text ?? "?")")
                }
            }
            onPhoto(p)
        }
        return r
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

    /// Renames and writes a log for undo. Updates the photos.
    static func executeRename(_ items: [RenameItem]) -> (done: Int, errors: [String], log: URL?) {
        var moves: [Move] = []
        var errors: [String] = []
        var done = 0
        for it in items {
            let p = it.photo
            var pairs: [(URL, URL)] = [(p.url, it.main)]
            if let s = p.sidecar, let t = it.sidecar { pairs.append((s, t)) }
            for (c, t) in zip(p.companions, it.companions) { pairs.append((c, t)) }
            var ok = true
            for (f, t) in pairs {
                do {
                    try move(f, t)
                    moves.append(Move(from: f.path, to: t.path))
                } catch {
                    errors.append("\(f.lastPathComponent): \(error.localizedDescription)")
                    ok = false
                    break
                }
            }
            for (f, t) in pairs where moves.contains(where: { $0.from == f.path && $0.to == t.path }) {
                if f == p.url { p.url = t }
                else if f == p.sidecar { p.sidecar = t }
                else if let i = p.companions.firstIndex(of: f) { p.companions[i] = t }
            }
            if ok { done += 1 }
        }
        var logURL: URL?
        if !moves.isEmpty {
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd_HHmmss"
            let url = logDir.appendingPathComponent("renamed-\(f.string(from: Date())).json")
            if let d = try? JSONEncoder().encode(moves), (try? d.write(to: url)) != nil { logURL = url }
        }
        return (done, errors, logURL)
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
                try fm.copyItem(at: p.url, to: main)
                for (c, t) in zip(p.companions, comps) { try fm.copyItem(at: c, to: t) }
                if let s = p.sidecar, let t = side, fm.fileExists(atPath: s.path) { try fm.copyItem(at: s, to: t) }
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
