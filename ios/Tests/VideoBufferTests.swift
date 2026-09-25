import CoreVideo
import Foundation

@main
struct VideoBufferTests {
    static func main() {
        guard let buffer = makeOrbVideoBuffer(), CVPixelBufferGetIOSurface(buffer) != nil else {
            print("FAIL: PiP frames must be IOSurface backed on a physical device")
            exit(1)
        }
        precondition(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
        print("PASS: PiP frames have shareable IOSurface backing and BGRA pixels")
    }
}
