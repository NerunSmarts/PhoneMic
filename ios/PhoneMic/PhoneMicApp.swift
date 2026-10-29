import SwiftUI
import AVFAudio
import Combine

@MainActor
final class MicrophoneModel: ObservableObject {
    @Published var running = false
    @Published var starting = false
    @Published var stats: [String: NSNumber] = [:]
    @Published var message: String?
    private let audio = AudioBridge()

    func value(_ key: String) -> Double { stats[key]?.doubleValue ?? 0 }
    var connected: Bool { stats["connected"]?.boolValue ?? false }
    var estimatedMS: Double {
        value("input") + value("buffer") + 5 + value("rtt") / 2 + value("queue") + value("quantum") / 48
    }
    func start(host: String, port: String, code: String) async {
        guard !running, !starting else { return }
        starting = true
        defer { starting = false }
        message = nil
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(port), port >= 1024,
              cleanCode.count == 16, let token = UInt64(cleanCode, radix: 16), token != 0 else {
            message = "Use a port from 1024–65535 and the receiver's 16-digit pairing code."
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "Allow microphone access in Settings → Apps → PhoneMic."
            return
        }
        do {
            try audio.start(withHost: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port, token: token)
            running = true
            UIApplication.shared.isIdleTimerDisabled = true
            refresh()
        } catch { message = error.localizedDescription }
    }
    func stop(reason: String? = nil) {
        audio.stop()
        running = false
        stats = [:]
        UIApplication.shared.isIdleTimerDisabled = false
        if let reason { message = reason }
    }
    func refresh() { if running { stats = audio.snapshot() } }
}

@main
struct PhoneMicApp: App {
    var body: some Scene { WindowGroup { MicrophoneView() } }
}

struct MicrophoneView: View {
    @StateObject private var model = MicrophoneModel()
    @AppStorage("receiverHost") private var host = ""
    @AppStorage("receiverPort") private var port = "5555"
    @AppStorage("pairingCode") private var code = ""
    @State private var showHelp = false
    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
    private let accent = Color(red: 0.41, green: 0.94, blue: 0.72)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your phone.\nYour microphone.")
                            .font(.system(size: 37, weight: .bold, design: .rounded))
                        Text("Straight to your Linux PC over Wi-Fi.")
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 16) {
                        HStack {
                            Circle().fill(model.connected ? accent : .gray).frame(width: 8, height: 8)
                            Text(model.running ? (model.connected ? "LIVE · 48 kHz mono" : "Waiting for receiver…") : "Ready when you are")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Image(systemName: "waveform").foregroundStyle(accent)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.08))
                                Capsule().fill(model.value("peak") > 0.98 ? .red : accent)
                                    .frame(width: geo.size.width * meterLevel)
                            }
                        }.frame(height: 12)
                        HStack {
                            Text("MIC LEVEL").font(.caption2.weight(.semibold)).tracking(1.5)
                            Spacer()
                            Text(model.value("peak") > 0.98 ? "Clipping · move back" : "Built-in microphone")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(20).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("RECEIVER").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
                        field("PC Wi-Fi IPv4 address", text: $host, placeholder: "192.168.1.100", keyboard: .decimalPad)
                        HStack(alignment: .top, spacing: 12) {
                            field("Port", text: $port, placeholder: "5555", keyboard: .numberPad).frame(width: 85)
                            field("Pairing code", text: $code, placeholder: "16 hex digits", keyboard: .asciiCapable)
                        }
                    }.disabled(model.running || model.starting)

                    if let message = model.message {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Button {
                        if model.running { model.stop() }
                        else { Task { await model.start(host: host, port: port, code: code) } }
                    } label: {
                        Label(model.starting ? "Starting…" : (model.running ? "Stop streaming" : "Start streaming"),
                              systemImage: model.running ? "stop.fill" : "mic.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent).tint(model.running ? Color.red : accent)
                    .foregroundStyle(model.running ? .white : .black).disabled(model.starting)

                    if model.running { diagnostics }
                    Text("Use the same Wi-Fi network as your PC. Audio is sent directly over your LAN; use a trusted network.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }
            .background(Color(red: 0.045, green: 0.065, blue: 0.075))
            .navigationTitle("PhoneMic").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Setup", systemImage: "questionmark.circle") { showHelp = true }
            } }
            .sheet(isPresented: $showHelp) { help }
            .onReceive(timer) { _ in model.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
                if model.running,
                   let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   type == AVAudioSession.InterruptionType.began.rawValue {
                    model.stop(reason: "Audio was interrupted. Tap Start to reconnect when ready.")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                if model.running, [1, 2, 4, 8].contains(reason) {
                    model.stop(reason: "The audio route changed. Tap Start to reconnect.")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
                model.stop(reason: "The audio service restarted. Tap Start to reconnect.")
            }
        }.preferredColorScheme(.dark).tint(accent)
    }
    private var meterLevel: Double {
        guard model.running else { return 0 }
        return min(1, max(0, (20 * log10(max(model.value("peak"), 0.0001)) + 60) / 60))
    }
    private func field(_ label: String, text: Binding<String>, placeholder: String, keyboard: UIKeyboardType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text).keyboardType(keyboard)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(.body, design: .monospaced)).padding(12)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
    }
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LATENCY & HEALTH").font(.caption.weight(.semibold)).tracking(1.5).foregroundStyle(.secondary)
            if model.connected {
                LabeledContent("Network round trip", value: String(format: "%.1f ms", model.value("rtt")))
                LabeledContent("Estimated audio path", value: String(format: "~%.0f ms", model.estimatedMS))
                LabeledContent("Receiver queue", value: String(format: "%.1f ms", model.value("queue")))
                LabeledContent("PipeWire quantum", value: "\(Int(model.value("quantum"))) frames")
                LabeledContent("Lost / late packets", value: "\(Int(model.value("gaps"))) / \(Int(model.value("late")))")
                LabeledContent("Underruns", value: "\(Int(model.value("underruns")))")
                Text("Estimate uses half the network RTT and reported buffers. It excludes the game's input buffering. Measure the acoustic loop with the Linux calibration tool.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Check the PC address, pairing code, local network permission, and UDP firewall rule. The receiver must be running.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("Packets sent", value: "\(Int(model.value("packets")))")
            LabeledContent("Local drops / send errors", value: "\(Int(model.value("drops"))) / \(Int(model.value("sendErrors")))")
            if model.value("audioErrors") > 0 {
                Text("Capture errors: \(Int(model.value("audioErrors"))). Stop and reconnect.")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }.font(.subheadline).monospacedDigit()
    }
    private var help: some View {
        NavigationStack {
            List {
                Section("Connect") {
                    Text("1. On CachyOS, build and run phonemic. The terminal prints a pairing code.")
                    Text("2. Enter the PC's LAN IPv4 address (hostname -I), port, and pairing code here.")
                    Text("3. Allow microphone and local network access, then tap Start streaming.")
                    Text("4. Choose PhoneMic as the game's microphone. Emulators may also require an emulated USB microphone.")
                }
                Section("Keep latency low") {
                    Text("Prefer 5 or 6 GHz Wi-Fi near the access point, with the PC on Ethernet. Avoid Bluetooth audio. Start the receiver with --jitter-ms 5 for the smallest buffer; increase it if you hear dropouts.")
                }
                Section("Measure the full acoustic loop") {
                    Text("Run tools/calibrate.py on Linux while streaming. It plays short chirps through your PC speaker and measures their return through PhoneMic. Keep the phone close to the speaker and select PhoneMic as the recording source. The result includes speaker output, sound travel, and microphone delivery, but excludes the game's own buffering.")
                }
            }.navigationTitle("Setup").toolbar { Button("Done") { showHelp = false } }
        }.preferredColorScheme(.dark)
    }
}
