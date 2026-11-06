import SwiftUI
import ReplayKit
import AVKit

@main
struct CarromAimApp: App {
    @StateObject private var link = LinkReceiver()
    @StateObject private var pip = PiPManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(link)
                .environmentObject(pip)
                .onAppear {
                    let p = pip
                    link.onResult = { r in p.update(r) }
                    link.start()
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var link: LinkReceiver
    @EnvironmentObject var pip: PiPManager

    private var connected: Bool {
        guard let d = link.lastSeen else { return false }
        return Date().timeIntervalSince(d) < 3
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Carrom Aim").font(.largeTitle.bold())
                Text("مساعد التصويب لكيرم سوا بلاي").foregroundColor(.secondary)

                // live preview (this layer is also what floats in PiP)
                PiPLayerView(layer: pip.displayLayer)
                    .aspectRatio(480.0 / 560.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                step(1, "شغّل بث الشاشة", "اضغط الزر، اختر Carrom Aim، ثم «بدء البث».")
                BroadcastButton()
                    .frame(height: 56)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                step(2, "شغّل النافذة العائمة", "بعدها روح لسوا بلاي — النافذة تبقى فوق اللعبة.")
                Button(action: { pip.start() }) {
                    Text(pip.isActive ? "إيقاف النافذة العائمة" : "تشغيل النافذة العائمة")
                        .font(.headline).frame(maxWidth: .infinity).padding()
                        .background(Color.accentColor).foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                HStack {
                    Circle().fill(connected ? Color.green : Color.gray).frame(width: 10, height: 10)
                    Text(connected ? "البث متصل — \(link.latest?.status ?? "")" : "البث غير متصل")
                        .font(.subheadline)
                }

                step(3, "صوّب", "اسحب السهم الأخضر في اللعبة — المسارات تظهر في النافذة العائمة لحظياً.")
                Text("لإيقاف البث: اضغط الشريط الأحمر أعلى الشاشة أو من مركز التحكم.")
                    .font(.footnote).foregroundColor(.secondary)
            }
            .padding()
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func step(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.2)).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundColor(.secondary)
            }
        }
    }
}

/// Hosts the AVSampleBufferDisplayLayer (PiP needs it in the view hierarchy).
struct PiPLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> LayerHost { LayerHost(displayLayer: layer) }
    func updateUIView(_ uiView: LayerHost, context: Context) {}

    final class LayerHost: UIView {
        let displayLayer: AVSampleBufferDisplayLayer
        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            layer.addSublayer(displayLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() { super.layoutSubviews(); displayLayer.frame = bounds }
    }
}

/// System broadcast picker pre-selecting our extension.
struct BroadcastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let v = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 56, height: 56))
        v.showsMicrophoneButton = false
        if let id = Bundle.main.bundleIdentifier { v.preferredExtension = id + ".broadcast" }
        return v
    }
    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
