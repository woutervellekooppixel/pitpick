// Reads Canon CR3 files without developing the raw: where the camera JPEGs are, plus capture time and orientation.
// Layout (ISO media file): ftyp, moov (Canon uuid with CMT1-4 + traks), uuid with PRVW, mdat.
// Track 1 holds the full-size camera JPEG, the PRVW box a 1620x1080 JPEG.
import Foundation

struct CR3Info {
    var jpegOffset: UInt64 = 0
    var jpegLength = 0
    var prvwOffset: UInt64 = 0
    var prvwLength = 0
    var orientation = 1
    var model: String?
    var dateTimeOriginal: String?
    var subSec: String?
    var offsetTime: String?
}

struct ISOBox {
    let type: String
    let start: Int
    let size: Int
    let header: Int
    var body: Int { start + header }
    var end: Int { start + size }
}

/// Reads the first IFD of a TIFF block (CMT1 = IFD0, CMT2 = Exif IFD).
struct TIFFReader {
    let d: Data
    let base: Int
    let end: Int
    let little: Bool

    struct Entry { let tag: Int; let type: Int; let count: Int; let pos: Int }

    init?(_ d: Data, _ base: Int, _ end: Int) {
        guard end - base >= 8 else { return nil }
        let a = d.u8(base), b = d.u8(base + 1)
        if a == 0x49 && b == 0x49 { little = true }
        else if a == 0x4D && b == 0x4D { little = false }
        else { return nil }
        self.d = d
        self.base = base
        self.end = end
    }

    func u16(_ o: Int) -> Int { Int(little ? d.le16(base + o) : d.be16(base + o)) }
    func u32(_ o: Int) -> Int { Int(little ? d.le32(base + o) : d.be32(base + o)) }

    func firstIFD() -> [Entry] {
        let ifd = u32(4)
        guard ifd >= 8, base + ifd + 2 <= end else { return [] }
        let n = u16(ifd)
        guard n > 0, n < 1000 else { return [] }
        var out: [Entry] = []
        for i in 0..<n {
            let e = ifd + 2 + i * 12
            if base + e + 12 > end { break }
            out.append(Entry(tag: u16(e), type: u16(e + 2), count: u32(e + 4), pos: e + 8))
        }
        return out
    }

    func int(_ e: Entry) -> Int? {
        switch e.type {
        case 3: return u16(e.pos)
        case 4: return u32(e.pos)
        default: return nil
        }
    }

    func string(_ e: Entry) -> String? {
        guard e.type == 2, e.count > 0, e.count < 4096 else { return nil }
        let off = e.count <= 4 ? e.pos : u32(e.pos)
        guard base + off + e.count <= end else { return nil }
        var bytes = d.bytes(base + off, e.count)
        while let last = bytes.last, last == 0 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespaces)
    }
}

enum CR3 {
    static let canonUUID: [UInt8] = [0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0, 0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48]
    static let previewUUID: [UInt8] = [0xea, 0xf4, 0x2b, 0x5e, 0x1c, 0x98, 0x4b, 0x88, 0xb9, 0xfb, 0xb7, 0xdc, 0x40, 0x6e, 0x4d, 0x16]

    static func boxes(_ d: Data, _ from: Int, _ to: Int) -> [ISOBox] {
        var out: [ISOBox] = []
        var p = from
        let limit = min(to, d.count)
        while p + 8 <= limit {
            var size = Int(d.be32(p))
            let type = d.fourcc(p + 4)
            var header = 8
            if size == 1 { size = Int(truncatingIfNeeded: d.be64(p + 8)); header = 16 }
            else if size == 0 { size = limit - p }
            if size < header || p + size > limit { break }
            out.append(ISOBox(type: type, start: p, size: size, header: header))
            p += size
        }
        return out
    }

    static func read(_ url: URL) -> CR3Info? {
        guard let f = RAFile(url) else { return nil }
        return read(f)
    }

    static func read(_ f: RAFile) -> CR3Info? {
        var info = CR3Info()
        var p: UInt64 = 0
        var sawMoov = false
        var steps = 0
        while p + 8 <= f.size && steps < 32 {
            steps += 1
            guard let h = f.read(p, 40), h.count >= 8 else { break }
            var size = UInt64(h.be32(0))
            let type = h.fourcc(4)
            var header: UInt64 = 8
            if size == 1 { size = h.be64(8); header = 16 } else if size == 0 { size = f.size - p }
            if size < header || p + size > f.size { break }
            if steps == 1 && (type != "ftyp" || h.fourcc(8) != "crx ") { return nil }
            if type == "moov" {
                guard size < 32_000_000, let m = f.read(p, Int(size)) else { return nil }
                parseMoov(m, &info)
                sawMoov = true
            } else if type == "uuid" && h.bytes(Int(header), 16) == previewUUID {
                findPreview(f, p + header + 16, p + size, &info)
            } else if type == "mdat" {
                break
            }
            p += size
        }
        guard sawMoov, info.jpegLength > 0, info.jpegOffset > 0,
              info.jpegOffset + UInt64(info.jpegLength) <= f.size else { return nil }
        return info
    }

    private static func findPreview(_ f: RAFile, _ start: UInt64, _ end: UInt64, _ info: inout CR3Info) {
        guard end > start, let b = f.read(start, 64) else { return }
        guard let r = b.range(of: Data("PRVW".utf8)) else { return }
        let payload = r.upperBound - b.startIndex
        // PRVW: 4 + 2 unknown bytes, width, height, 2 bytes, length (4), then the JPEG
        let size = Int(b.be32(payload + 12))
        var offset = start + UInt64(payload + 16)
        if !(b.u8(payload + 16) == 0xFF && b.u8(payload + 17) == 0xD8) {
            guard let s = b.range(of: Data([0xFF, 0xD8, 0xFF]), in: r.upperBound..<b.endIndex) else { return }
            offset = start + UInt64(s.lowerBound - b.startIndex)
        }
        guard end > offset else { return }
        let maxLen = Int(end - offset)
        info.prvwOffset = offset
        info.prvwLength = (size > 0 && size <= maxLen) ? size : maxLen
    }

    private static func parseMoov(_ m: Data, _ info: inout CR3Info) {
        let kids = boxes(m, 8, m.count)
        for b in kids where b.type == "uuid" && m.bytes(b.body, 16) == canonUUID {
            for c in boxes(m, b.body + 16, b.end) where c.type == "CMT1" || c.type == "CMT2" {
                guard let t = TIFFReader(m, c.body, c.end) else { continue }
                for e in t.firstIFD() {
                    switch (c.type, e.tag) {
                    case ("CMT1", 0x0112): info.orientation = t.int(e) ?? 1
                    case ("CMT1", 0x0110): info.model = t.string(e)
                    case ("CMT2", 0x9003): info.dateTimeOriginal = t.string(e)
                    case ("CMT2", 0x9291): info.subSec = t.string(e)
                    case ("CMT2", 0x9011): info.offsetTime = t.string(e)
                    default: break
                    }
                }
            }
        }
        guard let trak = kids.first(where: { $0.type == "trak" }) else { return }
        var cur = trak
        for name in ["mdia", "minf", "stbl"] {
            guard let n = boxes(m, cur.body, cur.end).first(where: { $0.type == name }) else { return }
            cur = n
        }
        let st = boxes(m, cur.body, cur.end)
        if let b = st.first(where: { $0.type == "co64" }) { info.jpegOffset = m.be64(b.body + 8) }
        else if let b = st.first(where: { $0.type == "stco" }) { info.jpegOffset = UInt64(m.be32(b.body + 8)) }
        if let b = st.first(where: { $0.type == "stsz" }) {
            let fixed = Int(m.be32(b.body + 4))
            info.jpegLength = fixed != 0 ? fixed : Int(m.be32(b.body + 12))
        }
    }
}
