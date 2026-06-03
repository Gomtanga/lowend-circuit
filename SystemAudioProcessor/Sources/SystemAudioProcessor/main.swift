import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import Darwin
import Foundation

private struct Settings {
    var mode: Mode = .all
    var intensity: Float = 55.0
    var body: Float = 30.0
    var outputDb: Float = -1.5
    var dspModel: DSPModel = .circuit

    enum Mode {
        case all
        case bundleIDs([String])
        case listApps
    }

    enum DSPModel: String {
        case clean
        case circuit
    }
}

private enum AppError: Error, CustomStringConvertible {
    case message(String)
    case osStatus(String, OSStatus)

    var description: String {
        switch self {
        case .message(let value):
            return value
        case .osStatus(let label, let status):
            return "\(label) failed: \(status) \(fourCC(status))"
        }
    }
}

private func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let chars = [
        Character(UnicodeScalar((value >> 24) & 255) ?? " "),
        Character(UnicodeScalar((value >> 16) & 255) ?? " "),
        Character(UnicodeScalar((value >> 8) & 255) ?? " "),
        Character(UnicodeScalar(value & 255) ?? " ")
    ]
    let text = String(chars)
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "'\(text)'"
}

private func check(_ status: OSStatus, _ label: String) throws {
    guard status == noErr else { throw AppError.osStatus(label, status) }
}

private func parseArguments() throws -> Settings {
    var settings = Settings()
    var bundleIDs: [String] = []
    var iterator = CommandLine.arguments.dropFirst().makeIterator()

    while let arg = iterator.next() {
        switch arg {
        case "--all":
            settings.mode = .all
        case "--bundle-id":
            guard let value = iterator.next(), !value.isEmpty else {
                throw AppError.message("--bundle-id needs a value")
            }
            bundleIDs.append(value)
        case "--intensity":
            guard let value = iterator.next(), let number = Float(value) else {
                throw AppError.message("--intensity needs a number")
            }
            settings.intensity = number
        case "--body":
            guard let value = iterator.next(), let number = Float(value) else {
                throw AppError.message("--body needs a number")
            }
            settings.body = number
        case "--output":
            guard let value = iterator.next(), let number = Float(value) else {
                throw AppError.message("--output needs a number")
            }
            settings.outputDb = number
        case "--model":
            guard let value = iterator.next(), let model = Settings.DSPModel(rawValue: value.lowercased()) else {
                throw AppError.message("--model needs clean or circuit")
            }
            settings.dspModel = model
        case "--list-apps":
            settings.mode = .listApps
        case "--help", "-h":
            printUsageAndExit()
        default:
            throw AppError.message("Unknown argument: \(arg)")
        }
    }

    if !bundleIDs.isEmpty {
        settings.mode = .bundleIDs(bundleIDs)
    }

    return settings
}

@available(macOS 14.4, *)
@MainActor
private final class NativeAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var bundleField: NSTextField!
    private var appsView: NSTextView!
    private var intensitySlider: NSSlider!
    private var bodySlider: NSSlider!
    private var outputSlider: NSSlider!
    private var intensityValueLabel: NSTextField!
    private var bodyValueLabel: NSTextField!
    private var outputValueLabel: NSTextField!
    private var modelPopup: NSPopUpButton!
    private var processor: SystemAudioProcessor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        print("Opening XBass Native System Audio control window.")
        let rect = NSRect(x: 0, y: 0, width: 740, height: 760)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "XBass Native System Audio"
        window.center()

        let content = NSView(frame: rect)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).cgColor
        window.contentView = content

        let title = makeLabel("XBass Native System Audio", size: 28, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.31, alpha: 1)
        title.frame = NSRect(x: 28, y: 702, width: 560, height: 34)
        content.addSubview(title)

        let subtitle = makeLabel("BlackHole 없이 시스템 전체 또는 특정 앱 오디오에 XBass를 적용합니다.", size: 14, weight: .regular)
        subtitle.frame = NSRect(x: 30, y: 674, width: 680, height: 22)
        content.addSubview(subtitle)

        statusLabel = makeLabel("대기 중", size: 14, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.frame = NSRect(x: 30, y: 638, width: 440, height: 26)
        content.addSubview(statusLabel)

        let modelLabel = makeLabel("Model", size: 13, weight: .semibold)
        modelLabel.frame = NSRect(x: 498, y: 638, width: 52, height: 26)
        content.addSubview(modelLabel)

        modelPopup = NSPopUpButton(frame: NSRect(x: 552, y: 635, width: 158, height: 30), pullsDown: false)
        modelPopup.addItems(withTitles: ["Circuit", "Clean DSP"])
        modelPopup.selectItem(at: 0)
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.toolTip = "Circuit은 가상 RC 회로/포화 모델이고, Clean DSP는 기존 필터 기반 모델입니다."
        content.addSubview(modelPopup)

        let explanation = makeExplanationSection()
        explanation.frame = NSRect(x: 30, y: 546, width: 680, height: 76)
        content.addSubview(explanation)

        let controls = makeControlSection()
        controls.frame = NSRect(x: 30, y: 392, width: 680, height: 128)
        content.addSubview(controls)

        let presets = makePresetSection()
        presets.frame = NSRect(x: 30, y: 338, width: 680, height: 38)
        content.addSubview(presets)

        let startAll = makeButton("전체 시스템 적용", action: #selector(startAllAudio))
        startAll.frame = NSRect(x: 30, y: 286, width: 190, height: 42)
        content.addSubview(startAll)
        startAll.toolTip = "Mac에서 나오는 대부분의 소리에 XBass를 적용합니다."

        let stop = makeButton("중지", action: #selector(stopAudio))
        stop.frame = NSRect(x: 238, y: 286, width: 110, height: 42)
        content.addSubview(stop)
        stop.toolTip = "처리를 멈추고 원래 소리로 되돌립니다."

        bundleField = NSTextField(frame: NSRect(x: 30, y: 234, width: 440, height: 32))
        bundleField.placeholderString = "예: com.spotify.client 또는 com.kakao.KakaoTalkMac"
        bundleField.stringValue = ""
        content.addSubview(bundleField)

        let startApp = makeButton("특정 앱 적용", action: #selector(startSelectedApp))
        startApp.frame = NSRect(x: 488, y: 230, width: 150, height: 40)
        content.addSubview(startApp)
        startApp.toolTip = "입력한 bundle id를 가진 앱의 소리에만 XBass를 적용합니다."

        let listButton = makeButton("실행 중인 앱 목록 새로고침", action: #selector(refreshApps))
        listButton.frame = NSRect(x: 30, y: 184, width: 220, height: 38)
        content.addSubview(listButton)
        listButton.toolTip = "아래 목록을 갱신합니다. 특정 앱 적용 때 bundle id를 참고하세요."

        let scroll = NSScrollView(frame: NSRect(x: 30, y: 28, width: 680, height: 148))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        appsView = NSTextView(frame: scroll.bounds)
        appsView.isEditable = false
        appsView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        appsView.textColor = .white
        appsView.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1)
        scroll.documentView = appsView
        content.addSubview(scroll)

        refreshApps()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor(calibratedRed: 0.80, green: 0.83, blue: 0.88, alpha: 1)
        return label
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        return button
    }

    private func makeExplanationSection() -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1).cgColor
        view.layer?.cornerRadius = 8

        let lines = [
            "소리 흐름: Mac 소리 -> XBass 처리 -> 현재 선택된 스피커/헤드폰",
            "전체 시스템 적용: 브라우저, 음악 앱, 게임 등 대부분의 출력에 적용",
            "특정 앱 적용: 아래 목록에서 bundle id를 확인하고 입력한 뒤 실행"
        ]

        for (index, line) in lines.enumerated() {
            let label = makeLabel(line, size: 12.5, weight: index == 0 ? .semibold : .regular)
            label.frame = NSRect(x: 18, y: 48.0 - CGFloat(index) * 22.0, width: 640, height: 20)
            view.addSubview(label)
        }

        return view
    }

    private func makeControlSection() -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1).cgColor
        view.layer?.cornerRadius = 8

        intensitySlider = makeSlider(value: 55, min: 0, max: 100)
        bodySlider = makeSlider(value: 30, min: 0, max: 100)
        outputSlider = makeSlider(value: -1.5, min: -18, max: 6)

        intensityValueLabel = makeLabel("", size: 13, weight: .semibold)
        bodyValueLabel = makeLabel("", size: 13, weight: .semibold)
        outputValueLabel = makeLabel("", size: 13, weight: .semibold)

        addSliderRow(to: view, y: 86, title: "XBass", slider: intensitySlider, valueLabel: intensityValueLabel)
        addSliderRow(to: view, y: 48, title: "Body", slider: bodySlider, valueLabel: bodyValueLabel)
        addSliderRow(to: view, y: 10, title: "Output", slider: outputSlider, valueLabel: outputValueLabel)
        intensitySlider.toolTip = "저역 부스트의 강도입니다. 높일수록 베이스가 앞으로 나옵니다."
        bodySlider.toolTip = "서브 저역의 두께감입니다. 높일수록 묵직하지만 과하면 부풀 수 있습니다."
        outputSlider.toolTip = "최종 출력 보정입니다. 저역을 많이 올릴수록 낮춰두는 편이 안전합니다."
        updateSliderLabels()
        return view
    }

    private func makePresetSection() -> NSView {
        let view = NSView(frame: .zero)
        let buttons = [
            makeButton("IEM", action: #selector(applyIEMPreset)),
            makeButton("Gentle", action: #selector(applyGentlePreset)),
            makeButton("XBass", action: #selector(applyXBassPreset)),
            makeButton("Deep", action: #selector(applyDeepPreset)),
            makeButton("Clear", action: #selector(applyClearPreset))
        ]
        let tooltips = [
            "민감한 이어폰용입니다. 낮은 포화와 충분한 헤드룸을 둡니다.",
            "가볍게 저역만 보강합니다.",
            "일반적인 추천 시작점입니다.",
            "저역을 더 밀지만 IEM에서도 덜 거칠게 조정했습니다.",
            "처리를 거의 끈 기준점입니다."
        ]

        let gap: CGFloat = 10
        let width = (680.0 - gap * 4) / 5
        for index in 0..<buttons.count {
            buttons[index].frame = NSRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: 36)
            buttons[index].toolTip = tooltips[index]
            view.addSubview(buttons[index])
        }

        return view
    }

    private func makeSlider(value: Double, min: Double, max: Double) -> NSSlider {
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: #selector(sliderChanged))
        slider.isContinuous = true
        return slider
    }

    private func addSliderRow(to view: NSView, y: CGFloat, title: String, slider: NSSlider, valueLabel: NSTextField) {
        let label = makeLabel(title, size: 13, weight: .semibold)
        label.frame = NSRect(x: 18, y: y, width: 72, height: 24)
        slider.frame = NSRect(x: 96, y: y, width: 420, height: 24)
        valueLabel.frame = NSRect(x: 530, y: y, width: 92, height: 24)
        view.addSubview(label)
        view.addSubview(slider)
        view.addSubview(valueLabel)
    }

    @objc private func sliderChanged() {
        updateSliderLabels()
        processor?.updateDSP(intensity: Float(intensitySlider.doubleValue),
                             body: Float(bodySlider.doubleValue),
                             outputDb: Float(outputSlider.doubleValue),
                             dspModel: selectedDSPModel())
    }

    @objc private func modelChanged() {
        sliderChanged()
        statusLabel.stringValue = "모델 변경: \(selectedDSPModel() == .circuit ? "Circuit" : "Clean DSP")"
    }

    private func updateSliderLabels() {
        intensityValueLabel.stringValue = "\(Int(intensitySlider.doubleValue.rounded()))%"
        bodyValueLabel.stringValue = "\(Int(bodySlider.doubleValue.rounded()))%"
        outputValueLabel.stringValue = String(format: "%.1f dB", outputSlider.doubleValue)
    }

    @objc private func applyIEMPreset() {
        applyPreset(name: "IEM", intensity: 36, body: 10, outputDb: -3.0)
    }

    @objc private func applyGentlePreset() {
        applyPreset(name: "Gentle", intensity: 26, body: 10, outputDb: -1.2)
    }

    @objc private func applyXBassPreset() {
        applyPreset(name: "XBass", intensity: 48, body: 22, outputDb: -2.0)
    }

    @objc private func applyDeepPreset() {
        applyPreset(name: "Deep", intensity: 62, body: 28, outputDb: -4.0)
    }

    @objc private func applyClearPreset() {
        applyPreset(name: "Clear", intensity: 0, body: 0, outputDb: 0)
    }

    private func applyPreset(name: String, intensity: Double, body: Double, outputDb: Double) {
        intensitySlider.doubleValue = intensity
        bodySlider.doubleValue = body
        outputSlider.doubleValue = outputDb
        sliderChanged()
        statusLabel.stringValue = "프리셋 적용: \(name)"
    }

    @objc private func startAllAudio() {
        start(settings(for: .all))
    }

    @objc private func startSelectedApp() {
        let bundleID = bundleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            statusLabel.stringValue = "특정 앱의 bundle id를 입력하세요."
            return
        }

        start(settings(for: .bundleIDs([bundleID])))
    }

    private func settings(for mode: Settings.Mode) -> Settings {
        Settings(mode: mode,
                 intensity: Float(intensitySlider.doubleValue),
                 body: Float(bodySlider.doubleValue),
                 outputDb: Float(outputSlider.doubleValue),
                 dspModel: selectedDSPModel())
    }

    private func selectedDSPModel() -> Settings.DSPModel {
        modelPopup.indexOfSelectedItem == 0 ? .circuit : .clean
    }

    private func start(_ settings: Settings) {
        stopAudio()

        do {
            let processor = SystemAudioProcessor(settings: settings)
            try processor.start()
            self.processor = processor
            statusLabel.stringValue = "처리 중입니다. 소리가 안 나면 중지를 눌러 원래 출력으로 복구하세요."
        } catch {
            statusLabel.stringValue = "실행 실패: \(error)"
            self.processor = nil
        }
    }

    @objc private func stopAudio() {
        processor?.stop()
        processor = nil
        if statusLabel != nil {
            statusLabel.stringValue = "중지됨"
        }
    }

    @objc private func refreshApps() {
        let apps = NSWorkspace.shared.runningApplications
            .compactMap { app -> String? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return "\(app.localizedName ?? bundleID)\t\(bundleID)"
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        appsView.string = apps.joined(separator: "\n")
    }
}

private var nativeAppDelegateHolder: AnyObject?

@available(macOS 14.4, *)
@MainActor
private func launchGUI() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = NativeAppDelegate()
    nativeAppDelegateHolder = delegate
    app.delegate = delegate
    app.finishLaunching()
    app.run()
    exit(0)
}

private func printUsageAndExit() -> Never {
    print("""
    SystemAudioProcessor

    Usage:
      SystemAudioProcessor --all
      SystemAudioProcessor --bundle-id com.spotify.client
      SystemAudioProcessor --list-apps

    Options:
      --intensity 0...100
      --body 0...100
      --output dB
      --model circuit|clean
    """)
    exit(0)
}

private func listRunningApps() {
    let apps = NSWorkspace.shared.runningApplications
        .compactMap { app -> (String, String, pid_t)? in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return (app.localizedName ?? bundleID, bundleID, app.processIdentifier)
        }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

    for app in apps {
        print("\(app.0)\t\(app.1)\tpid=\(app.2)")
    }
}

private final class FloatRingBuffer {
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0
    private let lock = NSLock()

    init(capacityFrames: Int, channels: Int) {
        storage = Array(repeating: 0, count: max(capacityFrames * channels, channels * 512))
    }

    func push(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % storage.count
            if available < storage.count {
                available += 1
            } else {
                readIndex = (readIndex + 1) % storage.count
            }
        }
    }

    func pop(into pointer: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        defer { lock.unlock() }

        for index in 0..<count {
            if available > 0 {
                pointer[index] = storage[readIndex]
                readIndex = (readIndex + 1) % storage.count
                available -= 1
            } else {
                pointer[index] = 0
            }
        }
    }

    func pop(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        var result = Array(repeating: Float(0), count: count)
        for index in 0..<count {
            if available > 0 {
                result[index] = storage[readIndex]
                readIndex = (readIndex + 1) % storage.count
                available -= 1
            }
        }
        return result
    }
}

private struct Biquad {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    var z1: Float = 0
    var z2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    static func lowPass(sampleRate: Float, frequency: Float, q: Float) -> Biquad {
        let w0 = 2 * Float.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 - cosW0) / 2) / a0,
            b1: (1 - cosW0) / a0,
            b2: ((1 - cosW0) / 2) / a0,
            a1: (-2 * cosW0) / a0,
            a2: (1 - alpha) / a0
        )
    }

    static func lowShelf(sampleRate: Float, frequency: Float, q: Float, gainDb: Float) -> Biquad {
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)
        let beta = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * cosW0 + beta

        return Biquad(
            b0: a * ((a + 1) - (a - 1) * cosW0 + beta) / a0,
            b1: 2 * a * ((a - 1) - (a + 1) * cosW0) / a0,
            b2: a * ((a + 1) - (a - 1) * cosW0 - beta) / a0,
            a1: -2 * ((a - 1) + (a + 1) * cosW0) / a0,
            a2: ((a + 1) + (a - 1) * cosW0 - beta) / a0
        )
    }
}

private protocol BassProcessor: AnyObject {
    func process(left: Float, right: Float) -> (Float, Float)
}

private final class XBassDSP: BassProcessor {
    private var shelfL: Biquad
    private var shelfR: Biquad
    private var subL: Biquad
    private var subR: Biquad
    private let intensity: Float
    private let body: Float
    private let outputGain: Float

    init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float) {
        let normalIntensity = min(max(intensity / 100, 0), 1)
        let shelfDb = normalIntensity * 8.5
        let shelfFreq = 72 + normalIntensity * 33
        self.intensity = normalIntensity
        self.body = min(max(body / 100, 0), 1)
        self.outputGain = pow(10, outputDb / 20)
        self.shelfL = .lowShelf(sampleRate: sampleRate, frequency: shelfFreq, q: 0.72, gainDb: shelfDb)
        self.shelfR = .lowShelf(sampleRate: sampleRate, frequency: shelfFreq, q: 0.72, gainDb: shelfDb)
        self.subL = .lowPass(sampleRate: sampleRate, frequency: 135, q: 0.68)
        self.subR = .lowPass(sampleRate: sampleRate, frequency: 135, q: 0.68)
    }

    func process(left: Float, right: Float) -> (Float, Float) {
        var lShelf = shelfL.process(left)
        var rShelf = shelfR.process(right)
        let lSub = tanh(subL.process(left) * 2.4) * 0.18 * body
        let rSub = tanh(subR.process(right) * 2.4) * 0.18 * body
        let headroom = pow(10, (-3 * intensity) / 20)
        lShelf = tanh((lShelf + lSub) * headroom * outputGain * 1.05) / 1.05
        rShelf = tanh((rShelf + rSub) * headroom * outputGain * 1.05) / 1.05
        return (lShelf, rShelf)
    }
}

private final class RcLowPass {
    private let alpha: Float
    private var z: Float = 0

    init(sampleRate: Float, frequency: Float) {
        let clampedFrequency = min(max(frequency, 5), sampleRate * 0.45)
        alpha = 1 - exp(-2 * Float.pi * clampedFrequency / sampleRate)
    }

    func process(_ input: Float) -> Float {
        z += alpha * (input - z)
        return z
    }
}

private final class VirtualCircuitBassDSP: BassProcessor {
    private final class Channel {
        private let bassPole: RcLowPass
        private let subPole: RcLowPass
        private let intensity: Float
        private let body: Float
        private let outputGain: Float

        init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float) {
            self.intensity = min(max(intensity / 100, 0), 1)
            self.body = min(max(body / 100, 0), 1)
            self.outputGain = pow(10, outputDb / 20)

            let bassFrequency = 72 + self.intensity * 36
            let subFrequency = 38 + self.body * 26
            bassPole = RcLowPass(sampleRate: sampleRate, frequency: bassFrequency)
            subPole = RcLowPass(sampleRate: sampleRate, frequency: subFrequency)
        }

        func process(_ input: Float) -> Float {
            if intensity < 0.001 && body < 0.001 {
                return input * outputGain
            }

            let warmthAmount = 0.014 * intensity + 0.010 * body
            let softened = input + ((tanh(input * 1.8) / 1.8) - input) * warmthAmount
            let bassNode = bassPole.process(softened)
            let subNode = subPole.process(softened)

            let virtualFeedbackGain = 0.48 * intensity
            let bodyInjectionGain = (0.08 + 0.14 * intensity) * body
            let summed = softened + bassNode * virtualFeedbackGain + subNode * bodyInjectionGain

            let headroom = pow(10, (-4.2 * intensity - 2.0 * body) / 20)
            let drive = 1 + 0.20 * intensity + 0.10 * body
            let opAmpStage = tanh(summed * headroom * drive) / drive

            let wetMix = min(max(0.62 * intensity + 0.18 * body, 0), 0.82)
            let blended = input + (opAmpStage - input) * wetMix
            return tanh(blended * outputGain * 1.015) / 1.015
        }
    }

    private let left: Channel
    private let right: Channel

    init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float) {
        left = Channel(sampleRate: sampleRate, intensity: intensity, body: body, outputDb: outputDb)
        right = Channel(sampleRate: sampleRate, intensity: intensity, body: body, outputDb: outputDb)
    }

    func process(left inputLeft: Float, right inputRight: Float) -> (Float, Float) {
        (left.process(inputLeft), right.process(inputRight))
    }
}

@available(macOS 14.4, *)
private final class SystemAudioProcessor {
    private let settings: Settings
    private let sampleRate: Double = 48_000
    private let ringBuffer = FloatRingBuffer(capacityFrames: 48_000 * 4, channels: 2)
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let dspLock = NSLock()
    private lazy var dsp: BassProcessor = makeBassProcessor(
        dspModel: settings.dspModel,
        intensity: settings.intensity,
        body: settings.body,
        outputDb: settings.outputDb
    )

    init(settings: Settings) {
        self.settings = settings
    }

    func start() throws {
        try startOutput()
        try createProcessTapAndAggregateDevice()
        try startCapture()
        print("XBass system audio processing is running. Press Ctrl-C to stop.")
    }

    func updateDSP(intensity: Float, body: Float, outputDb: Float, dspModel: Settings.DSPModel) {
        dspLock.lock()
        dsp = makeBassProcessor(dspModel: dspModel, intensity: intensity, body: body, outputDb: outputDb)
        dspLock.unlock()
    }

    private func makeBassProcessor(dspModel: Settings.DSPModel,
                                   intensity: Float,
                                   body: Float,
                                   outputDb: Float) -> BassProcessor {
        switch dspModel {
        case .clean:
            return XBassDSP(sampleRate: Float(sampleRate), intensity: intensity, body: body, outputDb: outputDb)
        case .circuit:
            return VirtualCircuitBassDSP(sampleRate: Float(sampleRate), intensity: intensity, body: body, outputDb: outputDb)
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        engine.stop()
    }

    private func startOutput() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let node = AVAudioSourceNode { [ringBuffer] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            if abl.count >= 2 {
                let samples = ringBuffer.pop(count: frames * 2)
                for channel in 0..<min(2, abl.count) {
                    guard let data = abl[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    for frame in 0..<frames {
                        data[frame] = samples[frame * 2 + channel]
                    }
                }
            } else if let buffer = abl.first,
                      let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                let channels = max(Int(buffer.mNumberChannels), 1)
                ringBuffer.pop(into: data, count: frames * channels)
            }

            return noErr
        }

        sourceNode = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    private func makeTapDescription() throws -> CATapDescription {
        let description: CATapDescription

        switch settings.mode {
        case .all:
            let ownProcess = try audioProcessObjectID(for: getpid())
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        case .bundleIDs(let bundleIDs):
            if #available(macOS 26.0, *) {
                description = CATapDescription()
                description.bundleIDs = bundleIDs
                description.isExclusive = false
                description.isProcessRestoreEnabled = true
            } else {
                throw AppError.message("Bundle-ID app selection requires macOS 26.0 or newer.")
            }
        case .listApps:
            throw AppError.message("Cannot start capture while listing apps.")
        }

        description.name = "XBass Native System Tap"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private func audioProcessObjectID(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let status = withUnsafePointer(to: &processID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                qualifier,
                &dataSize,
                &processObjectID
            )
        }

        try check(status, "AudioObjectGetPropertyData TranslatePIDToProcessObject")

        if processObjectID == kAudioObjectUnknown {
            throw AppError.message("Could not find current Core Audio process object.")
        }

        return processObjectID
    }

    private func createProcessTapAndAggregateDevice() throws {
        let tapDescription = try makeTapDescription()
        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")

        let tapUID = tapDescription.uuid.uuidString
        let aggregateUID = "com.codexaudiolab.xbassinspired.aggregate.\(UUID().uuidString)"
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "XBass Native System Audio",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [tapEntry],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
            "AudioHardwareCreateAggregateDevice"
        )
    }

    private func startCapture() throws {
        let callback: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let processor = Unmanaged<SystemAudioProcessor>.fromOpaque(clientData).takeUnretainedValue()
            processor.handleInput(inputData)
            return noErr
        }

        try check(
            AudioDeviceCreateIOProcID(aggregateDeviceID, callback, Unmanaged.passUnretained(self).toOpaque(), &ioProcID),
            "AudioDeviceCreateIOProcID"
        )

        try check(AudioDeviceStart(aggregateDeviceID, ioProcID), "AudioDeviceStart")
    }

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return }

        let frameCount = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        var output = Array(repeating: Float(0), count: frameCount * 2)

        dspLock.lock()
        defer { dspLock.unlock() }

        if buffers.count >= 2,
           let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           let rightData = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            for frame in 0..<frameCount {
                let processed = dsp.process(left: leftData[frame], right: rightData[frame])
                output[frame * 2] = processed.0
                output[frame * 2 + 1] = processed.1
            }
        } else if first.mNumberChannels == 2,
                  let interleaved = first.mData?.assumingMemoryBound(to: Float.self) {
            let stereoFrames = frameCount / 2
            output.removeAll(keepingCapacity: true)
            output.reserveCapacity(stereoFrames * 2)
            for frame in 0..<stereoFrames {
                let processed = dsp.process(left: interleaved[frame * 2], right: interleaved[frame * 2 + 1])
                output.append(processed.0)
                output.append(processed.1)
            }
        } else if let mono = first.mData?.assumingMemoryBound(to: Float.self) {
            for frame in 0..<frameCount {
                let processed = dsp.process(left: mono[frame], right: mono[frame])
                output[frame * 2] = processed.0
                output[frame * 2 + 1] = processed.1
            }
        }

        ringBuffer.push(output)
    }
}

do {
    if CommandLine.arguments.count == 1 {
        guard #available(macOS 14.4, *) else {
            throw AppError.message("Native system audio processing requires macOS 14.4 or newer.")
        }
        launchGUI()
    }

    let settings = try parseArguments()

    if case .listApps = settings.mode {
        listRunningApps()
        exit(0)
    }

    guard #available(macOS 14.4, *) else {
        throw AppError.message("Native system audio processing requires macOS 14.4 or newer.")
    }

    let processor = SystemAudioProcessor(settings: settings)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler {
        processor.stop()
        exit(0)
    }
    signalSource.resume()

    try processor.start()
    RunLoop.main.run()
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
