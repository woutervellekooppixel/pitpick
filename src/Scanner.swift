// Reads folders (also cards with DCIM subfolders) into a list of photos sorted by capture time.
import Foundation
import ImageIO

enum Scanner {
    static let rawExts: Set<String> = ["cr3", "cr2", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
                                       "rw2", "pef", "srw", "3fr", "iiq", "x3f", "rwl", "erf", "mef", "mos", "dcr", "kdc"]
    static let embeddedExts: Set<String> = ["jpg", "jpeg", "heic", "heif", "tif", "tiff", "dng", "png"]
    static let maxFiles = 40000

    struct Group {
        var dir: URL
        var raw: URL?
        var images: [URL] = []
        var xmp: URL?
    }

    static func collectFiles(_ roots: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                out.append(root)
                continue
            }
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let u as URL in en {
                if en.level > 6 { en.skipDescendants(); continue }
                let ext = u.pathExtension.lowercased()
                if rawExts.contains(ext) || embeddedExts.contains(ext) || ext == "xmp" { out.append(u) }
                if out.count >= maxFiles { break }
            }
        }
        return out
    }

    static func group(_ files: [URL]) -> [Group] {
        var map: [String: Group] = [:]
        var order: [String] = []
        for u in files {
            let dir = u.deletingLastPathComponent()
            let key = dir.path + "/" + u.deletingPathExtension().lastPathComponent.lowercased()
            var g = map[key] ?? Group(dir: dir)
            if map[key] == nil { order.append(key) }
            let ext = u.pathExtension.lowercased()
            if ext == "xmp" { g.xmp = u }
            else if rawExts.contains(ext) { if g.raw == nil { g.raw = u } else { g.images.append(u) } }
            else { g.images.append(u) }
            map[key] = g
        }
        return order.compactMap { map[$0] }.filter { $0.raw != nil || !$0.images.isEmpty }
    }

    static func load(_ groups: [Group], progress: @escaping (Int) -> Void) -> [Photo] {
        var results = [Photo?](repeating: nil, count: groups.count)
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: groups.count) { i in
            let p = makePhoto(id: i, groups[i])
            lock.lock()
            results[i] = p
            done += 1
            let d = done
            lock.unlock()
            if d % 64 == 0 { progress(d) }
        }
        let photos = results.compactMap { $0 }
        return photos.sorted { a, b in
            if a.captureDate != b.captureDate { return a.captureDate < b.captureDate }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func rank(_ u: URL) -> Int {
        switch u.pathExtension.lowercased() {
        case "jpg", "jpeg": return 0
        case "heic", "heif": return 1
        case "dng": return 2
        default: return 3
        }
    }

    static func makePhoto(id: Int, _ g: Group) -> Photo? {
        let main: URL
        var companions: [URL] = []
        var kind: FileKind
        if let raw = g.raw {
            main = raw
            companions = g.images
            kind = raw.pathExtension.lowercased() == "cr3" ? .cr3 : .raw
        } else {
            let sorted = g.images.sorted { rank($0) < rank($1) }
            guard let first = sorted.first else { return nil }
            main = first
            companions = Array(sorted.dropFirst())
            kind = .embedded
        }
        var date: Date?
        var orientation = 1
        var cr3: CR3Info?
        if kind == .cr3, let info = CR3.read(main) {
            cr3 = info
            orientation = info.orientation
            date = ExifDate.parse(info.dateTimeOriginal, subSec: info.subSec, offset: info.offsetTime)
        } else {
            if kind == .cr3 { kind = .raw }
            date = imageIODate(main)
        }
        if date == nil {
            date = (try? main.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        let photo = Photo(id: id, url: main, kind: kind, cr3: cr3, captureDate: date ?? Date.distantPast,
                          orientation: orientation, companions: companions)
        var xmp: String?
        if kind == .embedded {
            xmp = embeddedXMP(main)
        } else if let x = g.xmp {
            photo.sidecar = x
            xmp = try? String(contentsOf: x, encoding: .utf8)
        }
        if let t = xmp { XMPState.apply(t, to: photo) }
        return photo
    }

    static func imageIODate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
        return ExifDate.parse(exif[kCGImagePropertyExifDateTimeOriginal] as? String,
                              subSec: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                              offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
    }

    static func embeddedXMP(_ url: URL) -> String? {
        guard let f = RAFile(url), let d = f.read(0, Int(min(f.size, 3_000_000))) else { return nil }
        guard let s = d.range(of: Data("<x:xmpmeta".utf8)),
              let e = d.range(of: Data("</x:xmpmeta>".utf8), in: s.upperBound..<d.endIndex) else { return nil }
        return String(data: d[s.lowerBound..<e.upperBound], encoding: .utf8)
    }
}

/// Reads tag, stars, label and the original file name from XMP text (Photo Mechanic, Lightroom, Snelkeus).
enum XMPState {
    static let rating = try! NSRegularExpression(pattern: #"(?:xmp|xap):Rating(?:\s*=\s*["']|>)\s*(-?\d+)"#)
    static let label = try! NSRegularExpression(pattern: #"(?:xmp|xap):Label(?:\s*=\s*["']|>)([^"'<]*)"#)
    static let tagged = try! NSRegularExpression(pattern: #"photomechanic:Tagged(?:\s*=\s*["']|>)\s*([A-Za-z0-9]+)"#)
    static let preserved = try! NSRegularExpression(pattern: #"xmpMM:PreservedFileName(?:\s*=\s*["']|>)([^"'<]*)"#)

    static func first(_ re: NSRegularExpression, _ s: String) -> String? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// All values of one XMP property: attribute, simple element, or an rdf:Alt/Seq/Bag list.
    static func values(_ name: String, in s: String) -> [String] {
        let n = NSRegularExpression.escapedPattern(for: name)
        if let re = try? NSRegularExpression(pattern: "<" + n + #">\s*<rdf:(?:Alt|Seq|Bag)>(.*?)</rdf:(?:Alt|Seq|Bag)>"#, options: [.dotMatchesLineSeparators]),
           let block = first(re, s),
           let li = try? NSRegularExpression(pattern: #"<rdf:li[^>]*>([^<]*)</rdf:li>"#) {
            let ns = block as NSString
            let items = li.matches(in: block, range: NSRange(location: 0, length: ns.length))
                .map { decode(ns.substring(with: $0.range(at: 1))) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !items.isEmpty { return items }
        }
        let patterns = [n + #"\s*=\s*"([^"]*)""#, n + #"\s*=\s*'([^']*)'"#, "<" + n + #">([^<]+)</"# + n + ">"]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p), let v = first(re, s), !v.trimmingCharacters(in: .whitespaces).isEmpty {
                return [decode(v)]
            }
        }
        return []
    }

    static func apply(_ s: String, to p: Photo) {
        if let r = first(rating, s), let v = Int(r) { p.rating = max(0, min(5, v)) }
        if let l = first(label, s) { p.label = ColorLabel.parse(decode(l)) }
        if let t = first(tagged, s) { p.tagged = ["true", "yes", "1"].contains(t.lowercased()) }
        if let o = first(preserved, s), !o.isEmpty {
            p.originalFileName = decode(o)
            p.hasStoredOriginal = true
        }
    }
}
