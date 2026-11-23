// Software JPEG decoding with libjpeg-turbo (Apple Silicon build only; see vendor/libjpeg-turbo).
// The Mac's hardware JPEG decoder handles one image at a time: about 25 screen images or 13 full-size
// images a second, whatever the number of threads. libjpeg-turbo is about as fast per image and runs on
// every core, so a few threads next to the hardware decode several times as many images a second.
import Foundation
import CoreGraphics
import IOSurface

#if TURBO
final class TurboDecoder {
    private let handle: tjhandle

    init?() {
        guard let h = pitpick_tj3_init(Int32(TJINIT_DECOMPRESS.rawValue)) else { return nil }
        handle = h
    }

    deinit { tj3Destroy(handle) }

    /// One decoder per thread (a libjpeg-turbo handle must not be shared between threads).
    static var forThisThread: TurboDecoder? {
        let key = "nl.wouter.pitpick.turbo"
        if let d = Thread.current.threadDictionary[key] as? TurboDecoder { return d }
        let d = TurboDecoder()
        Thread.current.threadDictionary[key] = d
        return d
    }

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let sRGBPropertyList: CFPropertyList = sRGB.copyPropertyList()!

    /// Decodes at 1/scale (1, 2, 4 or 8), with `scale` chosen from the JPEG's own size, straight into an
    /// IOSurface: Core Animation shows that without copying it (a 179 MB full-size image from ordinary memory
    /// costs the main thread over 100 ms to show). The CGImage shares the same memory, for drawing and tests.
    /// Tagged sRGB, like ImageIO does with these camera JPEGs (they carry no profile).
    func decode(_ data: Data, scale: (Int, Int) -> Int) -> (image: CGImage, surface: IOSurfaceRef, width: Int, height: Int)? {
        data.withUnsafeBytes { raw -> (image: CGImage, surface: IOSurfaceRef, width: Int, height: Int)? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            guard tj3DecompressHeader(handle, base, raw.count) == 0 else { return nil }
            let w = Int(tj3Get(handle, Int32(TJPARAM_JPEGWIDTH.rawValue)))
            let h = Int(tj3Get(handle, Int32(TJPARAM_JPEGHEIGHT.rawValue)))
            guard w > 0, h > 0 else { return nil }
            let s = max(1, scale(w, h))
            guard tj3SetScalingFactor(handle, tjscalingfactor(num: 1, denom: Int32(s))) == 0 else { return nil }
            let ow = (w + s - 1) / s, oh = (h + s - 1) / s
            let props: [CFString: Any] = [
                kIOSurfaceWidth: ow,
                kIOSurfaceHeight: oh,
                kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, ow * 4),
                kIOSurfacePixelFormat: 0x4247_5241,   // 'BGRA'
            ]
            guard let surface = IOSurfaceCreate(props as CFDictionary) else { return nil }
            IOSurfaceSetValue(surface, kIOSurfaceColorSpace, TurboDecoder.sRGBPropertyList)
            IOSurfaceLock(surface, [], nil)
            let dst = IOSurfaceGetBaseAddress(surface)
            let rowBytes = IOSurfaceGetBytesPerRow(surface)
            let r = tj3Decompress8(handle, base, raw.count, dst.assumingMemoryBound(to: UInt8.self), Int32(rowBytes), Int32(TJPF_BGRX.rawValue))
            IOSurfaceUnlock(surface, [], nil)
            // a warning (for example a few missing bytes at the end) still gives a complete image
            if r != 0 && tj3GetErrorCode(handle) != Int32(TJERR_WARNING.rawValue) { return nil }
            let info = Unmanaged.passRetained(surface).toOpaque()
            guard let provider = CGDataProvider(dataInfo: info, data: dst, size: rowBytes * oh, releaseData: { info, _, _ in
                if let info = info { Unmanaged<IOSurfaceRef>.fromOpaque(info).release() }
            }) else {
                Unmanaged<IOSurfaceRef>.fromOpaque(info).release()
                return nil
            }
            guard let img = CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                    space: TurboDecoder.sRGB,
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
            return (img, surface, w, h)
        }
    }
}
#else
/// Intel build: no libjpeg-turbo, everything goes through ImageIO.
final class TurboDecoder {
    init?() { return nil }
    static var forThisThread: TurboDecoder? { nil }
    func decode(_ data: Data, scale: (Int, Int) -> Int) -> (image: CGImage, surface: IOSurfaceRef, width: Int, height: Int)? { nil }
}
#endif
