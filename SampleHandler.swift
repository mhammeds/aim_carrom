import ReplayKit
import CoreImage
import Network

/// Broadcast Upload Extension: receives the whole screen while you play,
/// analyses ~15 frames/s and sends the result to the app over loopback UDP.
class SampleHandler: RPBroadcastSampleHandler {
    private let ciContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    private let work = DispatchQueue(label: "carrom.analyze", qos: .userInteractive)
    private let analyzer = Analyzer()
    private var connection: NWConnection?
    private var lastFrame = 0.0
    private var busy = false
    private let lock = NSLock()
    private let targetWidth = 540

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Link.port)!, using: .udp)
        conn.start(queue: work)
        connection = conn
    }

    override func broadcastFinished() {
        connection?.cancel()
        connection = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if busy || now - lastFrame < 1.0 / 15.0 { lock.unlock(); return }
        busy = true; lastFrame = now
        lock.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { setIdle(); return }
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        if let o = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber,
           let orientation = CGImagePropertyOrientation(rawValue: o.uint32Value) {
            image = image.oriented(orientation)
        }
        let scale = CGFloat(targetWidth) / image.extent.width
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let w = targetWidth, h = Int((image.extent.height).rounded())
        guard h > 0, let cg = ciContext.createCGImage(image, from: image.extent) else { setIdle(); return }

        // draw into our own RGBA buffer: row 0 = top of the screen
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { setIdle(); return }
        let frame = rgba

        work.async { [weak self] in
            guard let self = self else { return }
            let result = self.analyzer.analyze(rgba: frame, w: w, h: h, now: now)
            if let data = try? JSONEncoder().encode(result) {
                self.connection?.send(content: data, completion: .idempotent)
            }
            self.setIdle()
        }
    }

    private func setIdle() {
        lock.lock(); busy = false; lock.unlock()
    }
}
