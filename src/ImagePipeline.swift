// Getting images: grid thumbnails and loupe stand-ins from the PRVW, screen and 100% images from the camera JPEG.
// The Mac's hardware JPEG decoder handles one image at a time (about 25 screen images a second). On Apple
// Silicon, libjpeg-turbo decodes on three more threads next to it, so fast browsing stays sharp and 100% comes
// sooner. Order of importance: the 100% image when zoomed, the current photo, the photos in the browsing
// direction, then the 100% images of the neighbours (zoomed browsing) and of the photo you are looking at.
import Foundation
import ImageIO
import CoreGraphics
import IOSurface

final class Decoded {
    let image: CGImage
    /// Pixel size of the full image (for CR3: unrotated, the orientation comes from the photo).
    let fullSize: CGSize
    let isFull: Bool
    /// Set when libjpeg-turbo decoded it: the loupe shows the surface itself, without a copy.
    let surface: IOSurfaceRef?

    init(image: CGImage, fullSize: CGSize, isFull: Bool, surface: IOSurfaceRef? = nil) {
        self.image = image
        self.fullSize = fullSize
        self.isFull = isFull
        self.surface = surface
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

    /// The loupe's stand-in while the screen image is on its way: the camera's PRVW (1620x1080 on a CR3),
    /// decoded in software, so it never waits for the hardware decoder. Much sharper than a grid thumbnail.
    static func preview(_ r: SourceRef) -> Decoded? {
        if r.kind == .cr3 {
            guard let d = readJPEG(r, preview: true) else { return nil }
            if let t = TurboDecoder.forThisThread, let res = t.decode(d, scale: { _, _ in 1 }) {
                return Decoded(image: res.image, fullSize: CGSize(width: res.width, height: res.height), isFull: false, surface: res.surface)
            }
            guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1620,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return Decoded(image: img, fullSize: pixelSize(src), isFull: false)
        }
        return imageIOThumb(r, maxPixels: 1620)
    }

    /// Screen-size image: the camera JPEG at half resolution (4096 px on a Canon R5 II).
    /// With a TurboDecoder in software, otherwise through ImageIO (the hardware decoder).
    static func screen(_ r: SourceRef, turbo: TurboDecoder? = nil) -> Decoded? {
        if r.kind == .cr3 {
            guard let d = readJPEG(r, preview: false) else { return nil }
            if let t = turbo, let res = t.decode(d, scale: { w, _ in w > 5000 ? 2 : 1 }) {
                return Decoded(image: res.image, fullSize: CGSize(width: res.width, height: res.height), isFull: res.image.width >= res.width, surface: res.surface)
            }
            guard let src = CGImageSourceCreateWithData(d as CFData, nil) else { return nil }
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
    static func full(_ r: SourceRef, turbo: TurboDecoder? = nil) -> Decoded? {
        if r.kind == .cr3 {
            guard let d = readJPEG(r, preview: false) else { return nil }
            if let t = turbo, let res = t.decode(d, scale: { _, _ in 1 }) {
                return Decoded(image: res.image, fullSize: CGSize(width: res.width, height: res.height), isFull: true, surface: res.surface)
            }
            guard let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
            return Decoded(image: img, fullSize: CGSize(width: img.width, height: img.height), isFull: true)
        }
        guard let src = CGImageSourceCreateWithURL(r.url as CFURL, nil) else { return nil }
        let size = uprightSize(src)
        let maxSide = Int(max(size.width, size.height))
        guard maxSide > 0 else { return nil }
        return imageIOThumb(r, maxPixels: maxSide)
    }
}

/// A 100% image to prepare. Urgent: the photo you zoomed into. Otherwise: its neighbours while zoomed,
/// or the photo you are looking at, so space or a click shows 100% at once.
struct FullRequest {
    let ref: SourceRef
    let urgent: Bool
}

final class ImagePipeline {
    var onThumbReady: ((Int) -> Void)?
    var onPreviewReady: ((Int) -> Void)?
    var onScreenReady: ((Int) -> Void)?
    var onFullReady: ((Int) -> Void)?

    let thumbPixels = 384
    let screenCapacity = 12
    /// 100% images kept (about 180 MB each on an R5 II): the current photo and its neighbours.
    let fullCapacity = ProcessInfo.processInfo.physicalMemory >= 16 << 30 ? 3 : 2

    /// Decoding threads, true = libjpeg-turbo. Apple Silicon: the hardware decoder plus three in software.
    /// PITPICK_DECODERS=hw,turbo,... overrides it (for measuring).
    static let decoderPlan: [Bool] = {
        if let s = ProcessInfo.processInfo.environment["PITPICK_DECODERS"], !s.isEmpty {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) == "turbo" }
        }
        #if TURBO
        return [false, true, true, true]
        #else
        return [false, false]
        #endif
    }()

    // grid thumbnails and loupe stand-ins (software, several at once)
    private let thumbCache = NSCache<NSNumber, Decoded>()
    private let thumbQueue = OperationQueue()
    private let thumbLock = NSLock()
    private var thumbPending = Set<Int>()
    private var thumbWanted = Set<Int>()
    private let previewCache = NSCache<NSNumber, Decoded>()
    private let previewQueue = OperationQueue()
    private var previewPending = Set<Int>()
    private var previewWanted = Set<Int>()

    // screen images and 100%
    private let cond = NSCondition()
    private var screenCache: [Int: Decoded] = [:]
    private var screenOrder: [Int] = []
    private var wanted: [SourceRef] = []
    private var inFlight = Set<Int>()
    private var failed = Set<Int>()
    private var fullWanted: [FullRequest] = []
    private var fullCache: [Int: Decoded] = [:]
    private var fullOrder: [Int] = []
    private var fullInFlight = Set<Int>()
    private var fullFailed = Set<Int>()
    private var generation = 0
    private let hasTurbo: Bool

    init() {
        thumbCache.totalCostLimit = 900 * 1024 * 1024
        thumbQueue.maxConcurrentOperationCount = 4
        thumbQueue.qualityOfService = .userInitiated
        previewCache.totalCostLimit = 120 * 1024 * 1024   // about 17 stand-ins of 7 MB
        previewQueue.maxConcurrentOperationCount = 3
        previewQueue.qualityOfService = .userInitiated
        hasTurbo = ImagePipeline.decoderPlan.contains(true) && TurboDecoder() != nil
        for (i, useTurbo) in ImagePipeline.decoderPlan.enumerated() {
            let t = Thread { [unowned self] in self.workerLoop(turbo: useTurbo ? TurboDecoder() : nil) }
            t.name = "pitpick-decode-\(i)\(useTurbo ? "-turbo" : "")"
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
        fullWanted.removeAll()
        fullCache.removeAll()
        fullOrder.removeAll()
        fullFailed.removeAll()
        cond.unlock()
        thumbQueue.cancelAllOperations()
        previewQueue.cancelAllOperations()
        thumbLock.lock()
        thumbPending.removeAll()
        thumbWanted.removeAll()
        previewPending.removeAll()
        previewWanted.removeAll()
        thumbLock.unlock()
        thumbCache.removeAllObjects()
        previewCache.removeAllObjects()
    }

    /// After a rename: decodes that failed because a file was being moved may run again.
    func clearFailures() {
        cond.lock()
        failed.removeAll()
        fullFailed.removeAll()
        cond.unlock()
    }

    // MARK: grid thumbnails

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

    // MARK: loupe stand-ins

    func preview(_ id: Int) -> Decoded? { previewCache.object(forKey: NSNumber(value: id)) }

    /// Requests the PRVW stand-ins in the browsing direction; a photo whose screen image is ready is skipped.
    func requestPreviews(_ refs: [SourceRef]) {
        let gen = currentGeneration
        var todo: [SourceRef] = []
        thumbLock.lock()
        previewWanted = Set(refs.map { $0.id })
        for r in refs where previewCache.object(forKey: NSNumber(value: r.id)) == nil && !previewPending.contains(r.id) {
            previewPending.insert(r.id)
            todo.append(r)
        }
        thumbLock.unlock()
        for r in todo {
            previewQueue.addOperation { [weak self] in self?.runPreview(r, gen) }
        }
    }

    private func hasScreen(_ id: Int) -> Bool {
        cond.lock(); defer { cond.unlock() }
        return screenCache[id] != nil
    }

    private func runPreview(_ r: SourceRef, _ gen: Int) {
        thumbLock.lock()
        let still = previewWanted.contains(r.id)
        if !still { previewPending.remove(r.id) }
        thumbLock.unlock()
        guard still, gen == currentGeneration, !hasScreen(r.id) else {
            thumbLock.lock(); previewPending.remove(r.id); thumbLock.unlock()
            return
        }
        let d = ImageDecoder.preview(r)
        thumbLock.lock()
        previewPending.remove(r.id)
        thumbLock.unlock()
        guard let img = d, gen == currentGeneration else { return }
        previewCache.setObject(img, forKey: NSNumber(value: r.id), cost: img.image.bytesPerRow * img.image.height)
        DispatchQueue.main.async { [weak self] in self?.onPreviewReady?(r.id) }
    }

    // MARK: screen images and 100%

    func screen(_ id: Int) -> Decoded? {
        cond.lock(); defer { cond.unlock() }
        guard let d = screenCache[id] else { return nil }
        if let i = screenOrder.firstIndex(of: id) { screenOrder.remove(at: i); screenOrder.append(id) }
        return d
    }

    func full(_ id: Int) -> Decoded? {
        cond.lock(); defer { cond.unlock() }
        guard let d = fullCache[id] else { return nil }
        if let i = fullOrder.firstIndex(of: id) { fullOrder.remove(at: i); fullOrder.append(id) }
        return d
    }

    func want(_ refs: [SourceRef]) {
        cond.lock()
        wanted = refs
        cond.broadcast()
        cond.unlock()
    }

    /// The 100% images to prepare, most important first. Images already made stay until they are pushed out.
    func wantFull(_ requests: [FullRequest]) {
        cond.lock()
        fullWanted = requests
        cond.broadcast()
        cond.unlock()
    }

    /// Back in the grid: no 100% images needed, give the memory back.
    func releaseFulls() {
        cond.lock()
        fullWanted.removeAll()
        fullCache.removeAll()
        fullOrder.removeAll()
        cond.unlock()
    }

    private func needsFull(_ id: Int) -> Bool {
        fullCache[id] == nil && !fullInFlight.contains(id) && !fullFailed.contains(id)
    }

    private func workerLoop(turbo: TurboDecoder?) {
        // the hardware thread leaves 100% to the software threads: they are faster at it (56 against 78 ms)
        // and it keeps the hardware free for screen images
        let takesFull = turbo != nil || !hasTurbo
        while true {
            cond.lock()
            var job: (ref: SourceRef, full: Bool, gen: Int)?
            while job == nil {
                if takesFull, let f = fullWanted.first, f.urgent, needsFull(f.ref.id) {
                    fullInFlight.insert(f.ref.id)
                    job = (f.ref, true, generation)
                } else if let r = wanted.first(where: { screenCache[$0.id] == nil && !inFlight.contains($0.id) && !failed.contains($0.id) }) {
                    inFlight.insert(r.id)
                    job = (r, false, generation)
                } else if takesFull, let f = fullWanted.first(where: { needsFull($0.ref.id) }) {
                    fullInFlight.insert(f.ref.id)
                    job = (f.ref, true, generation)
                } else {
                    cond.wait()
                }
            }
            cond.unlock()
            guard let j = job else { continue }
            let result = j.full ? ImageDecoder.full(j.ref, turbo: turbo) : ImageDecoder.screen(j.ref, turbo: turbo)
            cond.lock()
            if j.full { fullInFlight.remove(j.ref.id) } else { inFlight.remove(j.ref.id) }
            let current = j.gen == generation
            if current {
                if let d = result {
                    if j.full {
                        fullCache[j.ref.id] = d
                        fullOrder.removeAll { $0 == j.ref.id }
                        fullOrder.append(j.ref.id)
                        evictFullLocked()
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

    private func evictFullLocked() {
        let keep = Set(fullWanted.map { $0.ref.id })
        var i = 0
        while fullCache.count > fullCapacity && i < fullOrder.count {
            let id = fullOrder[i]
            if keep.contains(id) {
                i += 1
            } else {
                fullCache[id] = nil
                fullOrder.remove(at: i)
            }
        }
    }
}
