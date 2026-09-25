import AVKit
import SwiftUI

/// A live visual for the ongoing voice call, presented through Apple's video-call PiP API.
@MainActor
final class OrbPictureInPicture: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    private var controller: AVPictureInPictureController?
    private let callView = AVPictureInPictureVideoCallViewController()
    private let video = OrbVideoView()
    private var timer: Timer?
    private var startResult: Bool?
    var level: Double = 0
    var muted = false
    var speaking = false
    @Published private(set) var failure: String?

    func attach(_ source: UIView) {
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        // Preferred compact content size; iOS still owns the floating window's minimum size.
        callView.preferredContentSize = CGSize(width: 64, height: 64)
        video.prepareAvatar()
        callView.view.addSubview(video)
        video.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: callView.view.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: callView.view.trailingAnchor),
            video.topAnchor.constraint(equalTo: callView.view.topAnchor),
            video.bottomAnchor.constraint(equalTo: callView.view.bottomAnchor)
        ])
        let content = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: source, contentViewController: callView)
        controller = AVPictureInPictureController(contentSource: content)
        controller?.delegate = self
    }

    func setConnected(_ connected: Bool) {
        controller?.canStartPictureInPictureAutomaticallyFromInline = connected
        if connected {
            guard timer == nil else { return }
            video.render(level: level, muted: muted, speaking: speaking)
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.video.render(level: self.level, muted: self.muted, speaking: self.speaking)
                }
            }
        } else {
            controller?.stopPictureInPicture()
            timer?.invalidate()
            timer = nil
        }
    }

    func start() async -> Bool {
        failure = nil
        guard let controller else {
            failure = "Picture in Picture isn’t available on this device."
            return false
        }
        if controller.isPictureInPictureActive { return true }
        for _ in 0..<30 {
            if controller.isPictureInPicturePossible { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard controller.isPictureInPicturePossible else {
            failure = "The floating call window isn’t ready. Check Settings → General → Picture in Picture, then try again."
            return false
        }
        startResult = nil
        controller.startPictureInPicture()
        for _ in 0..<40 {
            if let startResult { return startResult }
            try? await Task.sleep(for: .milliseconds(100))
        }
        failure = "The floating call window couldn’t start. Try again."
        controller.stopPictureInPicture()
        return false
    }

    func restore() { controller?.stopPictureInPicture() }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.startResult = true }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: Error) {
        let description = error.localizedDescription
        Task { @MainActor in
            self.failure = "Couldn’t start the floating call window: \(description)"
            self.startResult = false
        }
    }
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

struct OrbPictureInPictureSource: UIViewRepresentable {
    let pip: OrbPictureInPicture
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        pip.attach(view)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private final class OrbVideoView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    var avatar: CGImage?

    @MainActor func prepareAvatar() {
        let renderer = ImageRenderer(content: OrbView().frame(width: 180, height: 180).padding(20))
        renderer.scale = 2
        avatar = renderer.cgImage
    }

    func render(level: Double, muted: Bool, speaking: Bool) {
        let size = 240
        guard let buffer = makeOrbVideoBuffer(size: size) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: size, height: size,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return
        }
        context.setFillColor(UIColor(red: 0.06, green: 0.065, blue: 0.09, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let pulse = speaking && !reduceMotion ? (sin(ProcessInfo.processInfo.systemUptime * 5) + 1) / 2 : 0
        let radius = 82 + (speaking ? 4 + pulse * 7 + min(level, 1) * 6 : 0)
        if let avatar {
            // Draw the exact same SwiftUI mark used in chat, with an audio-reactive profile pulse.
            let side = radius * 2.35
            context.draw(avatar, in: CGRect(x: 120-side/2, y: 120-side/2, width: side, height: side))
        } else {
            context.saveGState()
            context.addEllipse(in: CGRect(x: 120-radius, y: 120-radius, width: radius*2, height: radius*2))
            context.clip()
            let colors = [UIColor.systemPurple.cgColor, UIColor.systemIndigo.cgColor, UIColor.systemCyan.cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.5, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 60, y: 60), end: CGPoint(x: 180, y: 180), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            context.restoreGState()
        }
        if muted {
            context.setFillColor(UIColor.systemOrange.cgColor)
            context.fillEllipse(in: CGRect(x: 112, y: 20, width: 16, height: 16))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
                                       presentationTimeStamp: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        if display.status == .failed { display.flush() }
        if display.isReadyForMoreMediaData { display.enqueue(sample) }
    }
}

#if DEBUG
/// Uses the exact video layer and frames shown in PiP, without starting a microphone session.
struct OrbCallPreview: View {
    @State private var speaking = true
    var body: some View {
        VStack(spacing: 24) {
            TimelineView(.animation(minimumInterval: 0.1)) { timeline in
                CallFrame(speaking: speaking, time: timeline.date).frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Toggle("Speaking pulse", isOn: $speaking).frame(width: 230)
        }
    }
    private struct CallFrame: UIViewRepresentable {
        let speaking: Bool
        let time: Date
        func makeUIView(context: Context) -> OrbVideoView {
            let view = OrbVideoView()
            view.prepareAvatar()
            return view
        }
        func updateUIView(_ view: OrbVideoView, context: Context) {
            view.render(level: 0.3, muted: false, speaking: speaking)
        }
    }
}
#endif
