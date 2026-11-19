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

    init?(_ url: URL) {
        let f = open(url.path, O_RDONLY)
        if f < 0 { return nil }
        var st = stat()
        if fstat(f, &st) != 0 { close(f); return nil }
        fd = f
        size = UInt64(st.st_size)
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

/// Makes a safe file name: no / \ : * ? " < > | and no dot or space at the end.
func safeFileName(_ s: String) -> String {
    let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
    var out = s.components(separatedBy: bad).joined(separator: "-")
    out = out.trimmingCharacters(in: .whitespaces)
    while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
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
