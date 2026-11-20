// Getting images: grid thumbnails from the PRVW, screen and 100% images from the camera JPEG.
// Decoding runs on two threads in order of importance: the current photo first,
// then the photos in the browsing direction. The Mac's JPEG decoder does not scale in parallel.
import Foundation
import ImageIO
import CoreGraphics

final class Decoded {
    let image: CGImage
    /// Pixel size of the full image (for CR3: unrotated, the orientation comes from the photo).
    let fullSize: CGSize
    let isFull: Bool

    init(image: CGImage, fullSize: CGSize, isFull: Bool) {
        self.image = image
        self.fullSize = fullSize
        self.isFull = isFull
    }
}

enum ImageDecoder {
    static func readJPEG(_ r: SourceRef, preview: Bool) -> Data? {
        guard let c = r.cr3, let f = RAFile(r.url) else { return nil }
        let off = preview ? c.prvwOffset : c.jpegOffset
        let len = preview ? c.prvwLength : c.jpegLength
        guard len > 0, let d = f.read(off, len), d.count > 2, d.u8(0) == 0xFF, d.u8(1) == 0xD8 else { return nil }
        return d
    }

    private static func pixelSize(_ src: CGImageSource) -> CGSize {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return CGSize(width: w, height: h)
    }

    private static func uprightSize(_ src: CGImageSource) -> CGSize {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let o = props?[kCGImagePropertyOrientation] as? Int ?? 1
        return Orientation.swapsAxes(o) ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private static func imageIOThumb(_ r: SourceRef, maxPixels: Int) -> Decoded? {
        guard let src = CGImageSourceCreateWithURL(r.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let fromImage = r.kind == .raw ? kCGImageSourceCreateThumbnailFromImageIfAbsent : kCGImageSourceCreateThumbnailFromImageAlways
        let opts: [CFString: Any] = [
            fromImage: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        var full = uprightSize(src)
        if full.width == 0 || r.kind == .raw { full = CGSize(width: img.width, height: img.height) }
        return Decoded(image: img, fullSize: full, isFull: img.width >= Int(full.width))
    }

    static func thumbnail(_ r: SourceRef, maxPixels: Int) -> Decoded? {
        if r.kind == .cr3 {
            guard let d = readJPEG(r, preview: true) ?? readJPEG(r, preview: false),
                  let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return Decoded(image: img, fullSize: pixelSize(src), isFull: false)
        }
        return imageIOThumb(r, maxPixels: maxPixels)
    }

    /// Screen-size image: the camera JPEG at half resolution (4096 px on a Canon R5 II).
    static func screen(_ r: SourceRef) -> Decoded? {
        if r.kind == .cr3 {
            guard let d = readJPEG(r, preview: false), let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
            let size = pixelSize(src)
            let factor = size.width > 5000 ? 2 : 1
            let opts: [CFString: Any] = [kCGImageSourceSubsampleFactor: factor, kCGImageSourceShouldCacheImmediately: true]
            guard let img = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else { return nil }
            let full = size.width > 0 ? size : CGSize(width: img.width * factor, height: img.height * factor)
            return Decoded(image: img, fullSize: full, isFull: factor == 1)
        }
        return imageIOThumb(r, maxPixels: 4096)
    }

    /// Full resolution for the 100% view.
    static func full(_ r: SourceRef) -> Decoded? {
        if r.kind == .cr3 {
            guard let d = readJPEG(r, preview: false), let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
            guard let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            return Decoded(image: img, fullSize: CGSize(width: img.width, height: img.height), isFull: true)
        }
        guard let src = CGImageSourceCreateWithURL(r.url as CFURL, nil) else { return nil }
        let size = uprightSize(src)
        let maxSide = Int(max(size.width, size.height))
        guard maxSide > 0 else { return nil }
        return imageIOThumb(r, maxPixels: maxSide)
    }
}

final class ImagePipeline {
    var onThumbReady: ((Int) -> Void)?
    var onScreenReady: ((Int) -> Void)?
    var onFullReady: ((Int) -> Void)?

    let thumbPixels = 384
    let screenCapacity = 12

    // grid thumbnails
    private let thumbCache = NSCache<NSNumber, Decoded>()
    private let thumbQueue = OperationQueue()
    private let thumbLock = NSLock()
    private var thumbPending = Set<Int>()
    private var thumbWanted = Set<Int>()

    // screen images and 100%
    private let cond = NSCondition()
    private var screenCache: [Int: Decoded] = [:]
    private var screenOrder: [Int] = []
    private var wanted: [SourceRef] = []
    private var inFlight = Set<Int>()
    private var failed = Set<Int>()
    private var fullWanted: SourceRef?
    private var fullImage: Decoded?
    private var fullID: Int?
    private var fullInFlight = false
    private var fullFailed = Set<Int>()
    private var generation = 0

    init() {
        thumbCache.totalCostLimit = 900 * 1024 * 1024
        thumbQueue.maxConcurrentOperationCount = 4
        thumbQueue.qualityOfService = .userInitiated
        for i in 0..<2 {
            let t = Thread { [unowned self] in self.workerLoop() }
            t.name = "pitpick-decode-\(i)"
            t.qualityOfService = .userInteractive
            t.start()
        }
    }

    private var currentGeneration: Int {
        cond.lock(); defer { cond.unlock() }
        return generation
    }

    func reset() {
        cond.lock()
        generation += 1
        screenCache.removeAll()
        screenOrder.removeAll()
        wanted.removeAll()
        failed.removeAll()
        fullWanted = nil
        fullImage = nil
        fullID = nil
        fullFailed.removeAll()
        cond.unlock()
        thumbQueue.cancelAllOperations()
        thumbLock.lock()
        thumbPending.removeAll()
        thumbWanted.removeAll()
        thumbLock.unlock()
        thumbCache.removeAllObjects()
    }

    // MARK: rastertegels

    func thumb(_ id: Int) -> Decoded? { thumbCache.object(forKey: NSNumber(value: id)) }

    /// Requests thumbnails in order of importance; older requests that are no longer needed are dropped.
    func requestThumbs(_ refs: [SourceRef]) {
        let gen = currentGeneration
        var todo: [SourceRef] = []
        thumbLock.lock()
        thumbWanted = Set(refs.map { $0.id })
        for r in refs where thumbCache.object(forKey: NSNumber(value: r.id)) == nil && !thumbPending.contains(r.id) {
            thumbPending.insert(r.id)
            todo.append(r)
        }
        thumbLock.unlock()
        for r in todo {
            thumbQueue.addOperation { [weak self] in self?.runThumb(r, gen) }
        }
    }

    private func runThumb(_ r: SourceRef, _ gen: Int) {
        thumbLock.lock()
        let still = thumbWanted.contains(r.id)
        if !still { thumbPending.remove(r.id) }
        thumbLock.unlock()
        guard still, gen == currentGeneration else { return }
        let d = ImageDecoder.thumbnail(r, maxPixels: thumbPixels)
        thumbLock.lock()
        thumbPending.remove(r.id)
        thumbLock.unlock()
        guard let img = d, gen == currentGeneration else { return }
        thumbCache.setObject(img, forKey: NSNumber(value: r.id), cost: img.image.bytesPerRow * img.image.height)
        DispatchQueue.main.async { [weak self] in self?.onThumbReady?(r.id) }
    }

    // MARK: schermbeelden

    func screen(_ id: Int) -> Decoded? {
        cond.lock(); defer { cond.unlock() }
        guard let d = screenCache[id] else { return nil }
        if let i = screenOrder.firstIndex(of: id) { screenOrder.remove(at: i); screenOrder.append(id) }
        return d
    }

    func full(_ id: Int) -> Decoded? {
        cond.lock(); defer { cond.unlock() }
        return fullID == id ? fullImage : nil
    }

    func want(_ refs: [SourceRef]) {
        cond.lock()
        wanted = refs
        cond.broadcast()
        cond.unlock()
    }

    func wantFull(_ ref: SourceRef?) {
        cond.lock()
        fullWanted = ref
        if ref == nil { fullImage = nil; fullID = nil }
        cond.broadcast()
        cond.unlock()
    }

    private func workerLoop() {
        while true {
            cond.lock()
            var job: (ref: SourceRef, full: Bool, gen: Int)?
            while job == nil {
                if let f = fullWanted, fullID != f.id, !fullInFlight, !fullFailed.contains(f.id) {
                    fullInFlight = true
                    job = (f, true, generation)
                } else if let r = wanted.first(where: { screenCache[$0.id] == nil && !inFlight.contains($0.id) && !failed.contains($0.id) }) {
                    inFlight.insert(r.id)
                    job = (r, false, generation)
                } else {
                    cond.wait()
                }
            }
            cond.unlock()
            guard let j = job else { continue }
            let result = j.full ? ImageDecoder.full(j.ref) : ImageDecoder.screen(j.ref)
            cond.lock()
            if j.full { fullInFlight = false } else { inFlight.remove(j.ref.id) }
            let current = j.gen == generation
            if current {
                if let d = result {
                    if j.full {
                        if fullWanted?.id == j.ref.id { fullImage = d; fullID = j.ref.id }
                    } else {
                        screenCache[j.ref.id] = d
                        screenOrder.append(j.ref.id)
                        evictLocked()
                    }
                } else if j.full {
                    fullFailed.insert(j.ref.id)
                } else {
                    failed.insert(j.ref.id)
                }
            }
            cond.unlock()
            if current && result != nil {
                let id = j.ref.id
                let isFull = j.full
                DispatchQueue.main.async { [weak self] in
                    if isFull { self?.onFullReady?(id) } else { self?.onScreenReady?(id) }
                }
            }
        }
    }

    private func evictLocked() {
        let keep = Set(wanted.map { $0.id })
        var i = 0
        while screenCache.count > screenCapacity && i < screenOrder.count {
            let id = screenOrder[i]
            if keep.contains(id) {
                i += 1
            } else {
                screenCache[id] = nil
                screenOrder.remove(at: i)
            }
        }
    }
}
