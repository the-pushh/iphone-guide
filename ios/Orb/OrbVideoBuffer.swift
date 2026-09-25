import CoreVideo

/// PiP crosses process boundaries on a phone, so frames need shareable IOSurface backing.
func makeOrbVideoBuffer(size: Int = 240) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
        kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        kCVPixelBufferMetalCompatibilityKey: true
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                              attributes as CFDictionary, &buffer) == kCVReturnSuccess else { return nil }
    return buffer
}
