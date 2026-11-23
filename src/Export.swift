// The camera's own JPEG out of the raw, with your IPTC: the fastest delivery the same night, without Lightroom.
// A CR3 holds an 8192-px JPEG; unpacking it takes under a millisecond. Full size is written as it is (no second
// compression); a smaller size is made with ImageIO. The colour space goes along: a Canon set to Adobe RGB stores
// its JPEG in Adobe RGB without a profile, so Pitpick adds that profile. Never overwrites.
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Export {
    struct Item {
        let photo: Photo
        let url: URL
        let adobeRGB: Bool
        let fullSize: Bool
    }

    static let adobeProfile = "/System/Library/ColorSync/Profiles/AdobeRGB1998.icc"

    /// Exif ColorSpace 65535 (uncalibrated) on a Canon: the camera was set to Adobe RGB.
    static func isAdobeRGB(_ p: Photo) -> Bool { p.cr3?.colorSpace == 65535 }

    /// The JPEG to deliver: the camera's own (CR3), the JPG itself, or the largest image in another raw or a HEIC.
    static func cameraJPEG(_ p: Photo) -> Data? {
        if let d = ImageDecoder.readJPEG(p.ref, preview: false) { return d }
        if p.kind == .embedded, ["jpg", "jpeg"].contains(p.url.pathExtension.lowercased()) { return try? Data(contentsOf: p.url) }
        guard let src = CGImageSourceCreateWithURL(p.url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 100_000,
                                                                     kCGImageSourceCreateThumbnailWithTransform: false] as CFDictionary)
        else { return nil }
        return encode(img, quality: 0.92)
    }

    static func encode(_ img: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }

    /// The long edge to `longEdge` pixels. The pixels stay as the camera stored them; the orientation tag turns them.
    static func resized(_ jpeg: Data, longEdge: Int, adobeRGB: Bool) -> Data? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              var img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: longEdge,
                                                                     kCGImageSourceCreateThumbnailWithTransform: false] as CFDictionary)
        else { return nil }
        // the numbers are Adobe RGB already: label them so, and the profile goes into the file
        if adobeRGB, let cs = CGColorSpace(name: CGColorSpace.adobeRGB1998), let labelled = img.copy(colorSpace: cs) { img = labelled }
        return encode(img, quality: 0.9)
    }

    /// Writes the JPEGs into `dest` under their new names. A photo whose JPEG is already there is skipped.
    static func run(_ photos: [Photo], to dest: URL, name: (Photo, Int) -> String?, longEdge: Int?,
                    progress: (Int) -> Void, cancelled: () -> Bool) -> (done: [Item], skipped: [String], errors: [String], bytes: Int64) {
        let fm = FileManager.default
        var done: [Item] = [], skipped: [String] = [], errors: [String] = []
        var bytes: Int64 = 0
        var claimed = Set<String>()
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            return ([], [], ["Cannot create \(dest.path): \(error.localizedDescription)"], 0)
        }
        for (i, p) in photos.enumerated() {
            if cancelled() { break }
            defer { progress(i + 1) }
            let base = name(p, i + 1).map(safeFileName) ?? p.url.deletingPathExtension().lastPathComponent
            let target = dest.appendingPathComponent(base + ".jpg")
            if fm.fileExists(atPath: target.path) || claimed.contains(target.path.lowercased()) { skipped.append(p.name); continue }
            guard var data = cameraJPEG(p) else { errors.append("\(p.name): no JPEG inside"); continue }
            let adobe = isAdobeRGB(p)
            if let e = longEdge {
                guard let small = resized(data, longEdge: e, adobeRGB: adobe) else { errors.append("\(p.name): could not make it smaller"); continue }
                data = small
            }
            do {
                // under a temporary name first, so a half-written JPEG never sits under the real name
                let tmp = dest.appendingPathComponent("." + target.lastPathComponent + ".pitpick-partial")
                try data.write(to: tmp)
                try fm.moveItem(at: tmp, to: target)
                claimed.insert(target.path.lowercased())
                bytes += Int64(data.count)
                done.append(Item(photo: p, url: target, adobeRGB: adobe, fullSize: longEdge == nil))
            } catch {
                errors.append("\(p.name): \(error.localizedDescription)")
            }
        }
        return (done, skipped, errors, bytes)
    }

    /// exiftool: the camera's EXIF (time, lens, orientation) from the raw, the colour profile, then your fields.
    static func metadataCommand(_ item: Item, fields: [String]) -> [String] {
        // (not the raw's pixel size: a smaller JPEG has its own)
        var a = ["-overwrite_original", "-tagsFromFile", item.photo.url.path, "-EXIF:all", "-GPS:all", "--ExifImageWidth", "--ExifImageHeight"]
        if item.adobeRGB && item.fullSize && FileManager.default.fileExists(atPath: adobeProfile) { a.append("-ICC_Profile<=" + adobeProfile) }
        return a + fields + [item.url.path]
    }
}
