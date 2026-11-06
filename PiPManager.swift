import AVKit
import AVFoundation
import UIKit
import CoreMedia

/// Floating Picture-in-Picture window that shows the board with predicted paths.
/// PiP is the only way an iOS app can draw on top of another app.
final class PiPManager: NSObject, ObservableObject, AVPictureInPictureSampleBufferPlaybackDelegate,
                        AVPictureInPictureControllerDelegate {
    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private var timer: Timer?
    private let renderer = BoardRenderer()
    private var latest: AimResult?
    private let lock = NSLock()
    @Published var isActive = false
    @Published var possible = false

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                    playbackDelegate: self)
            let c = AVPictureInPictureController(contentSource: source)
            c.delegate = self
            c.canStartPictureInPictureAutomaticallyFromInline = true
            controller = c
        }
        startRendering()
    }

    func update(_ r: AimResult) {
        lock.lock(); latest = r; lock.unlock()
    }

    func start() {
        guard let c = controller else { return }
        possible = c.isPictureInPicturePossible
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    private func startRendering() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.pushFrame()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func pushFrame() {
        lock.lock(); let r = latest; lock.unlock()
        guard let pb = renderer.render(r) else { return }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let fmt = format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sample = sb else { return }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = atts.first {
            first.setObject(kCFBooleanTrue as Any, forKey: kCMSampleAttachmentKey_DisplayImmediately as NSString)
        }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sample)
        if let c = controller, possible != c.isPictureInPicturePossible {
            possible = c.isPictureInPicturePossible
        }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate (a "live" stream that never ends)
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { false }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    // MARK: AVPictureInPictureControllerDelegate
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isActive = true }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async { self.isActive = false }
    }
}

/// Draws board + paths into a BGRA pixel buffer.
final class BoardRenderer {
    let W = 480, H = 560          // board 480x480 + status bar 80
    var P = PhysicsParams()
    private var pool: CVPixelBufferPool?

    init() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: W, kCVPixelBufferHeightKey as String: H,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    private func color(_ k: Kind) -> UIColor {
        switch k {
        case .striker: return UIColor(red: 0.23, green: 0.84, blue: 0.77, alpha: 1)
        case .white: return UIColor(red: 1, green: 0.91, blue: 0.66, alpha: 1)
        case .black: return UIColor(red: 1, green: 0.62, blue: 0.26, alpha: 1)
        case .queen: return UIColor(red: 1, green: 0.37, blue: 0.64, alpha: 1)
        }
    }

    func render(_ r: AimResult?) -> CVPixelBuffer? {
        guard let pool = pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // top-left origin like UIKit
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        let S = CGFloat(W), top: CGFloat = 80
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: CGFloat(x) * S, y: top + CGFloat(y) * S) }

        // background + board
        UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1).setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        UIColor(red: 0.85, green: 0.70, blue: 0.51, alpha: 1).setFill()
        ctx.fill(CGRect(x: 0, y: top, width: S, height: S))
        UIColor(red: 0.29, green: 0.14, blue: 0.06, alpha: 1).setFill()
        for p in P.pockets {
            let c = pt(p.0, p.1), rr = CGFloat(P.pocketR) * S
            ctx.fillEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        }
        UIColor(white: 0.35, alpha: 0.6).setStroke()
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: S * 0.5 - S * 0.172, y: top + S * 0.5 - S * 0.172, width: S * 0.344, height: S * 0.344))

        // status bar
        let title: String
        let sub: String
        if let r = r, CFAbsoluteTimeGetCurrent() - r.t < 3 {
            title = r.status
            if let a = r.angle, let p = r.power { sub = String(format: "%.2f°   •   %d%%", a, Int(p * 100)) } else { sub = r.boardFound ? "جاهز" : "افتح اللعبة" }
        } else {
            title = "شغّل بث الشاشة"
            sub = "Carrom Aim"
        }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        (title as NSString).draw(in: CGRect(x: 8, y: 10, width: S - 16, height: 34),
                                 withAttributes: [.font: UIFont.boldSystemFont(ofSize: 26), .foregroundColor: UIColor.white, .paragraphStyle: para])
        (sub as NSString).draw(in: CGRect(x: 8, y: 46, width: S - 16, height: 28),
                               withAttributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold),
                                                .foregroundColor: UIColor(red: 1, green: 0.7, blue: 0.28, alpha: 1), .paragraphStyle: para])

        guard let res = r, CFAbsoluteTimeGetCurrent() - res.t < 3 else {
            return pb
        }
        // paths
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for (b, flat) in res.paths.enumerated() where b < res.pieces.count && flat.count >= 4 {
            ctx.setStrokeColor(color(res.pieces[b].kind).cgColor)
            ctx.setLineWidth(res.pieces[b].kind == .striker ? 4 : 3.5)
            ctx.beginPath()
            ctx.move(to: pt(Double(flat[0]), Double(flat[1])))
            var k = 2
            while k + 1 < flat.count { ctx.addLine(to: pt(Double(flat[k]), Double(flat[k + 1]))); k += 2 }
            ctx.strokePath()
        }
        // long aim line (white)
        if let a = res.aimLine, a.count >= 4 {
            ctx.setStrokeColor(UIColor.white.cgColor); ctx.setLineWidth(2)
            ctx.beginPath(); ctx.move(to: pt(Double(a[0]), Double(a[1])))
            var k = 2
            while k + 1 < a.count { ctx.addLine(to: pt(Double(a[k]), Double(a[k + 1]))); k += 2 }
            ctx.strokePath()
        }
        // pieces
        for p in res.pieces {
            let c = pt(p.x, p.y), rr = CGFloat(P.radius(p.kind)) * S
            let fill: UIColor
            switch p.kind {
            case .white: fill = UIColor(red: 0.95, green: 0.92, blue: 0.85, alpha: 1)
            case .black: fill = UIColor(white: 0.22, alpha: 1)
            case .queen: fill = UIColor(red: 0.85, green: 0.15, blue: 0.17, alpha: 1)
            case .striker: fill = UIColor(red: 0.97, green: 0.93, blue: 0.83, alpha: 1)
            }
            fill.setFill()
            ctx.fillEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            if p.kind == .striker {
                color(.striker).setStroke(); ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            }
        }
        // ghost ball
        if let g = res.ghost, g.count == 2 {
            let c = pt(g[0], g[1]), rr = CGFloat(P.strikerR) * S
            UIColor.white.setStroke(); ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        }
        // pockets result
        let si = res.pieces.firstIndex(where: { $0.kind == .striker }) ?? -1
        for (k, b) in res.pocketedBodies.enumerated() where k < res.pocketedPockets.count {
            let q = P.pockets[res.pocketedPockets[k]], c = pt(q.0, q.1), rr = CGFloat(P.pocketR) * S * 1.15
            (b == si ? UIColor.systemRed : UIColor.systemGreen).setStroke()
            ctx.setLineWidth(5)
            ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
        }
        return pb
    }
}
