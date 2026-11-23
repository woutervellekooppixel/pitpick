// Small helpers: reading bytes, reading parts of files, orientation, names.
import Foundation
import CoreGraphics

extension Data {
    @inline(__always) func u8(_ o: Int) -> UInt8 { (o >= 0 && o < count) ? self[startIndex + o] : 0 }
    func be16(_ o: Int) -> UInt16 { UInt16(u8(o)) << 8 | UInt16(u8(o + 1)) }
    func be32(_ o: Int) -> UInt32 { UInt32(u8(o)) << 24 | UInt32(u8(o + 1)) << 16 | UInt32(u8(o + 2)) << 8 | UInt32(u8(o + 3)) }
    func be64(_ o: Int) -> UInt64 { UInt64(be32(o)) << 32 | UInt64(be32(o + 4)) }
    func le16(_ o: Int) -> UInt16 { UInt16(u8(o)) | UInt16(u8(o + 1)) << 8 }
    func le32(_ o: Int) -> UInt32 { UInt32(u8(o)) | UInt32(u8(o + 1)) << 8 | UInt32(u8(o + 2)) << 16 | UInt32(u8(o + 3)) << 24 }
    func fourcc(_ o: Int) -> String { String(bytes: [u8(o), u8(o + 1), u8(o + 2), u8(o + 3)], encoding: .isoLatin1) ?? "????" }
    func bytes(_ o: Int, _ n: Int) -> [UInt8] { (0..<n).map { u8(o + $0) } }
}

/// Reads parts of a file without loading all of it (pread, safe from several threads).
final class RAFile {
    let fd: Int32
    let size: UInt64
    /// st_flags: UF_IMMUTABLE is set for a photo protected in the camera (the card's read-only attribute).
    let flags: UInt32

    init?(_ url: URL) {
        let f = open(url.path, O_RDONLY)
        if f < 0 { return nil }
        var st = stat()
        if fstat(f, &st) != 0 { close(f); return nil }
        fd = f
        size = UInt64(st.st_size)
        flags = st.st_flags
    }

    deinit { close(fd) }

    func read(_ offset: UInt64, _ length: Int) -> Data? {
        if length <= 0 || offset >= size { return nil }
        let n = Int(min(UInt64(length), size - offset))
        var data = Data(count: n)
        var done = 0
        let ok: Bool = data.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            while done < n {
                let r = pread(fd, base + done, n - done, off_t(offset) + off_t(done))
                if r <= 0 { return false }
                done += r
            }
            return true
        }
        return ok ? data : nil
    }
}

enum Orientation {
    /// EXIF 5-8: the image is turned a quarter, width and height swap.
    static func swapsAxes(_ o: Int) -> Bool { o >= 5 && o <= 8 }

    /// Rotation angle in a y-up coordinate system (counterclockwise is positive).
    static func angle(_ o: Int) -> CGFloat {
        switch o {
        case 3, 4: return .pi
        case 5, 6: return -.pi / 2
        case 7, 8: return .pi / 2
        default: return 0
        }
    }
}

func nowMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

/// Makes a safe file name: no / \ : * ? " < > |, no dot or space at the start (a leading dot hides
/// the file in Finder) or at the end, and at most 200 bytes, so -2 and the extension still fit in 255.
func safeFileName(_ s: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
    var out = s.components(separatedBy: bad).joined(separator: "-")
    out = out.trimmingCharacters(in: .whitespaces)
    while out.hasPrefix(".") || out.hasPrefix(" ") { out.removeFirst() }
    while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
    if out.utf8.count > 200 {
        var cut = "", bytes = 0
        for ch in out {
            let n = String(ch).utf8.count
            if bytes + n > 200 { break }
            bytes += n
            cut.append(ch)
        }
        out = cut
        while out.hasSuffix(".") || out.hasSuffix(" ") || out.hasSuffix("-") || out.hasSuffix("_") { out.removeLast() }
    }
    return out
}

enum ExifDate {
    /// "2025:11:29 19:46:16" + subseconds "48" + time zone "+01:00".
    static func parse(_ s: String?, subSec: String?, offset: String?) -> Date? {
        guard let s = s else { return nil }
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" }).compactMap { Int($0) }
        guard parts.count >= 6, parts[0] > 1900 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        c.hour = parts[3]; c.minute = parts[4]; c.second = parts[5]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = offset.flatMap(timeZone(from:)) ?? TimeZone.current
        guard var d = cal.date(from: c) else { return nil }
        if let ss = subSec?.trimmingCharacters(in: .whitespaces), !ss.isEmpty, let v = Double("0." + ss) { d += v }
        return d
    }

    static func timeZone(from s: String) -> TimeZone? {
        let digits = s.filter { $0.isNumber }
        guard digits.count >= 4, let h = Int(digits.prefix(2)), let m = Int(digits.dropFirst(2).prefix(2)) else { return nil }
        let sign = s.hasPrefix("-") ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60))
    }

    /// "2026:11:19 21:04:37+01:00", as exiftool writes XMP dates.
    static func xmpString(_ d: Date, zone: TimeZone?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone ?? .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
        return f.string(from: d)
    }

    /// A clock correction as text: +0:01:12, -0:00:05.
    static func offsetText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        let a = abs(s)
        return (s < 0 ? "-" : "+") + String(format: "%d:%02d:%02d", a / 3600, a / 60 % 60, a % 60)
    }

    /// Reads +1:12 (minutes and seconds), +0:01:12, -5 (seconds) or 1h2m3s. Nil when it cannot be read.
    static func parseOffset(_ text: String) -> TimeInterval? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return 0 }
        var sign = 1.0
        if t.hasPrefix("-") { sign = -1; t.removeFirst() } else if t.hasPrefix("+") { t.removeFirst() }
        if t.contains("h") || t.contains("m") || t.contains("s") {
            var total = 0.0, num = ""
            for ch in t {
                if ch.isNumber || ch == "." { num.append(ch); continue }
                guard let v = Double(num) else { return nil }
                switch ch { case "h": total += v * 3600; case "m": total += v * 60; case "s": total += v; default: return nil }
                num = ""
            }
            if !num.isEmpty { guard let v = Double(num) else { return nil }; total += v }
            return sign * total
        }
        let parts = t.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        let v = parts.map { $0! }
        let total = v.reduce(0) { $0 * 60 + $1 }
        return sign * total
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "dd-MM-yyyy HH:mm:ss"
        return f
    }()
}
