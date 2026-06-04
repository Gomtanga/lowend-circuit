import AppKit
import AudioToolbox
import AVFoundation
import AudioRingBufferC
import CoreAudio
import Darwin
import Foundation
import SceneKit

private struct SpatialSettings {
    var enabled: Bool = true
    var listenerX: Float = 0.0
    var listenerZ: Float = 0.0
    var speakerWidth: Float = 1.65
    var amount: Float = 35.0
}

private struct Settings {
    var mode: Mode = .all
    var intensity: Float = 55.0
    var body: Float = 30.0
    var outputDb: Float = -1.5
    var dspModel: DSPModel = .circuit
    var spatial: SpatialSettings = SpatialSettings()

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

private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
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
        case "--spatial":
            guard let value = iterator.next() else {
                throw AppError.message("--spatial needs on or off")
            }
            settings.spatial.enabled = ["on", "true", "1", "yes"].contains(value.lowercased())
        case "--listener-x":
            guard let value = iterator.next(), let number = Float(value) else {
                throw AppError.message("--listener-x needs a number")
            }
            settings.spatial.listenerX = number
        case "--listener-z":
            guard let value = iterator.next(), let number = Float(value) else {
                throw AppError.message("--listener-z needs a number")
            }
            settings.spatial.listenerZ = number
        case "--stage-width":
            guard let value = iterator.next(), let number = Float(value) else {
                throw AppError.message("--stage-width needs a number")
            }
            settings.spatial.speakerWidth = number
        case "--space":
            guard let value = iterator.next(), let number = Float(value) else {
                throw AppError.message("--space needs a number")
            }
            settings.spatial.amount = number
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
private final class SpatialStageView: SCNView {
    var onChange: ((SpatialSettings) -> Void)?

    private let listenerNode = SCNNode()
    private let listenerRingNode = SCNNode()
    private let leftSpeakerNode = SCNNode()
    private let rightSpeakerNode = SCNNode()
    private let speakerWidthNode = SCNNode()
    private let cameraNode = SCNNode()
    private var settings = SpatialSettings()
    private let xRange: Float = 3.0
    private let zRange: Float = 2.8

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        setupScene()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScene()
    }

    func setSettings(_ newSettings: SpatialSettings) {
        settings = newSettings
        updateNodes()
    }

    override func layout() {
        super.layout()
        updateCameraScale()
    }

    override func mouseDown(with event: NSEvent) {
        updateListener(from: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateListener(from: event)
    }

    private func setupScene() {
        let scene = SCNScene()
        self.scene = scene
        backgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)
        allowsCameraControl = false
        rendersContinuously = false

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 6.2, 0)
        cameraNode.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        updateCameraScale()

        let floor = SCNNode(geometry: SCNPlane(width: 6.0, height: 5.6))
        floor.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
        floor.eulerAngles.x = -CGFloat.pi / 2
        floor.position = SCNVector3(0, -0.025, 0)
        scene.rootNode.addChildNode(floor)

        addGrid(to: scene)
        addFrontMarker(to: scene)

        let speakerMaterial = SCNMaterial()
        speakerMaterial.diffuse.contents = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.31, alpha: 1)
        let speakerGeometry = SCNBox(width: 0.28, height: 0.22, length: 0.44, chamferRadius: 0.04)
        speakerGeometry.materials = [speakerMaterial]
        leftSpeakerNode.geometry = speakerGeometry.copy() as? SCNGeometry
        rightSpeakerNode.geometry = speakerGeometry.copy() as? SCNGeometry
        scene.rootNode.addChildNode(leftSpeakerNode)
        scene.rootNode.addChildNode(rightSpeakerNode)

        let widthMaterial = SCNMaterial()
        widthMaterial.diffuse.contents = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.31, alpha: 0.95)
        speakerWidthNode.geometry = SCNBox(width: 1.65, height: 0.025, length: 0.055, chamferRadius: 0)
        speakerWidthNode.geometry?.materials = [widthMaterial]
        speakerWidthNode.position = SCNVector3(0, 0.02, 1.47)
        scene.rootNode.addChildNode(speakerWidthNode)

        let listenerMaterial = SCNMaterial()
        listenerMaterial.diffuse.contents = NSColor(calibratedRed: 0.34, green: 0.80, blue: 0.92, alpha: 1)
        listenerNode.geometry = SCNSphere(radius: 0.20)
        listenerNode.geometry?.materials = [listenerMaterial]
        scene.rootNode.addChildNode(listenerNode)

        let ringMaterial = SCNMaterial()
        ringMaterial.diffuse.contents = NSColor(calibratedRed: 0.34, green: 0.80, blue: 0.92, alpha: 0.65)
        listenerRingNode.geometry = SCNTorus(ringRadius: 0.33, pipeRadius: 0.018)
        listenerRingNode.geometry?.materials = [ringMaterial]
        listenerRingNode.eulerAngles.x = CGFloat.pi / 2
        scene.rootNode.addChildNode(listenerRingNode)

        updateNodes()
    }

    private func updateCameraScale() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let aspect = Float(bounds.width / bounds.height)
        let padding: Float = 0.12
        let halfHeight = max(zRange + padding, (xRange + padding) / max(aspect, 0.2))
        cameraNode.camera?.orthographicScale = CGFloat(halfHeight)
    }

    private func addGrid(to scene: SCNScene) {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.24, green: 0.28, blue: 0.34, alpha: 0.72)

        for x in stride(from: -3.0, through: 3.0, by: 0.75) {
            let line = SCNNode(geometry: SCNBox(width: 0.012, height: 0.012, length: 5.6, chamferRadius: 0))
            line.geometry?.materials = [material]
            line.position = SCNVector3(Float(x), 0, 0)
            scene.rootNode.addChildNode(line)
        }

        for z in stride(from: -2.8, through: 2.8, by: 0.7) {
            let line = SCNNode(geometry: SCNBox(width: 6.0, height: 0.012, length: 0.012, chamferRadius: 0))
            line.geometry?.materials = [material]
            line.position = SCNVector3(0, 0, Float(z))
            scene.rootNode.addChildNode(line)
        }
    }

    private func addFrontMarker(to scene: SCNScene) {
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.31, alpha: 0.85)
        let marker = SCNNode(geometry: SCNBox(width: 5.5, height: 0.026, length: 0.035, chamferRadius: 0))
        marker.geometry?.materials = [material]
        marker.position = SCNVector3(0, 0.01, 2.1)
        scene.rootNode.addChildNode(marker)
    }

    private func updateNodes() {
        let width = clamp(settings.speakerWidth, 0.6, 3.0)
        let halfWidth = width / 2
        leftSpeakerNode.position = SCNVector3(-halfWidth, 0.11, 1.8)
        rightSpeakerNode.position = SCNVector3(halfWidth, 0.11, 1.8)
        speakerWidthNode.geometry = SCNBox(width: CGFloat(width), height: 0.025, length: 0.055, chamferRadius: 0)
        speakerWidthNode.geometry?.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.31, alpha: 0.95)

        let listenerPosition = SCNVector3(
            clamp(settings.listenerX, -xRange, xRange),
            0.14,
            clamp(settings.listenerZ, -zRange, zRange)
        )
        listenerNode.position = listenerPosition
        listenerRingNode.position = SCNVector3(listenerPosition.x, 0.03, listenerPosition.z)
    }

    private func updateListener(from event: NSEvent) {
        guard let point = stagePoint(from: event) else { return }
        settings.listenerX = clamp(Float(point.x), -xRange, xRange)
        settings.listenerZ = clamp(Float(point.z), -zRange, zRange)
        updateNodes()
        onChange?(settings)
    }

    private func stagePoint(from event: NSEvent) -> SCNVector3? {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return nil }

        let near = unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
        let far = unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
        let dy = far.y - near.y
        guard abs(dy) > 0.0001 else { return nil }

        let t = -near.y / dy
        return SCNVector3(
            near.x + (far.x - near.x) * t,
            0,
            near.z + (far.z - near.z) * t
        )
    }
}

@available(macOS 14.4, *)
@MainActor
private final class NativeAppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
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
    private var spatialEnabledButton: NSButton!
    private var spatialStageView: SpatialStageView!
    private var listenerXField: NSTextField!
    private var listenerZField: NSTextField!
    private var speakerWidthField: NSTextField!
    private var spatialAmountSlider: NSSlider!
    private var spatialAmountValueLabel: NSTextField!
    private var processor: SystemAudioProcessor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func buildWindow() {
        print("Opening LowEnd Native Audio control window.")
        let rect = NSRect(x: 0, y: 0, width: 1200, height: 760)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LowEnd Native Audio"
        window.center()

        let content = NSView(frame: rect)
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).cgColor
        window.contentView = content

        let title = makeLabel("LowEnd Native Audio", size: 28, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.31, alpha: 1)
        title.frame = NSRect(x: 28, y: 702, width: 560, height: 34)
        content.addSubview(title)

        let subtitle = makeLabel("시스템 전체 또는 특정 앱 오디오에 저역 보강 처리를 적용합니다.", size: 14, weight: .regular)
        subtitle.frame = NSRect(x: 30, y: 674, width: 680, height: 22)
        content.addSubview(subtitle)

        let spatial = makeSpatialSection()
        spatial.frame = NSRect(x: 740, y: 28, width: 430, height: 636)
        content.addSubview(spatial)

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
        startAll.toolTip = "Mac에서 나오는 대부분의 소리에 LowEnd를 적용합니다."

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
        startApp.toolTip = "입력한 bundle id를 가진 앱의 소리에만 LowEnd를 적용합니다."

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
            "소리 흐름: Mac 소리 -> LowEnd 처리 -> 현재 선택된 스피커/헤드폰",
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

        addSliderRow(to: view, y: 86, title: "LowEnd", slider: intensitySlider, valueLabel: intensityValueLabel)
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
            makeButton("LowEnd", action: #selector(applyLowEndPreset)),
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

    private func makeSpatialSection() -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1).cgColor
        view.layer?.cornerRadius = 8

        let title = makeLabel("Spatial Stage", size: 18, weight: .bold)
        title.textColor = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.31, alpha: 1)
        title.frame = NSRect(x: 16, y: 594, width: 170, height: 26)
        view.addSubview(title)

        let resetButton = NSButton(title: "원위치", target: self, action: #selector(resetSpatialPosition))
        resetButton.bezelStyle = .rounded
        resetButton.font = .systemFont(ofSize: 12, weight: .semibold)
        resetButton.frame = NSRect(x: 220, y: 592, width: 78, height: 26)
        resetButton.toolTip = "나 위치를 중앙 기준점으로 되돌립니다. Width와 Space 값은 유지됩니다."
        view.addSubview(resetButton)

        spatialEnabledButton = NSButton(checkboxWithTitle: "공간음향", target: self, action: #selector(spatialControlChanged))
        spatialEnabledButton.frame = NSRect(x: 310, y: 592, width: 96, height: 26)
        spatialEnabledButton.state = .on
        spatialEnabledButton.toolTip = "3D 위치 기반 거리, 지연, 크로스피드 처리를 켜거나 끕니다."
        view.addSubview(spatialEnabledButton)

        let description = makeLabel("파란 점을 드래그하거나 아래 숫자를 입력하세요.", size: 12, weight: .regular)
        description.frame = NSRect(x: 16, y: 566, width: 398, height: 20)
        view.addSubview(description)

        spatialStageView = SpatialStageView(frame: NSRect(x: 16, y: 222, width: 398, height: 340))
        spatialStageView.wantsLayer = true
        spatialStageView.layer?.cornerRadius = 6
        spatialStageView.onChange = { [weak self] settings in
            self?.spatialStageChanged(settings)
        }
        view.addSubview(spatialStageView)

        listenerXField = makeNumberField(value: 0.0)
        listenerZField = makeNumberField(value: 0.0)
        speakerWidthField = makeNumberField(value: 1.65)
        addNumberRow(to: view, y: 180, title: "나 X", field: listenerXField, suffix: "m", tooltip: "좌우 위치입니다. 음수는 왼쪽, 양수는 오른쪽입니다.")
        addNumberRow(to: view, y: 142, title: "나 Z", field: listenerZField, suffix: "m", tooltip: "앞뒤 위치입니다. 양수는 스피커 쪽, 음수는 뒤쪽입니다.")
        addNumberRow(to: view, y: 104, title: "Width", field: speakerWidthField, suffix: "m", tooltip: "가상 좌우 스피커 사이의 거리입니다.")

        let amountLabel = makeLabel("Space", size: 13, weight: .semibold)
        amountLabel.frame = NSRect(x: 16, y: 66, width: 62, height: 24)
        view.addSubview(amountLabel)

        spatialAmountSlider = NSSlider(value: 35, minValue: 0, maxValue: 100, target: self, action: #selector(spatialControlChanged))
        spatialAmountSlider.isContinuous = true
        spatialAmountSlider.frame = NSRect(x: 82, y: 66, width: 250, height: 24)
        spatialAmountSlider.toolTip = "원본 스테레오와 공간 처리 신호의 혼합량입니다. 높일수록 거리, 귀 사이 딜레이, 크로스피드 영향이 커집니다."
        view.addSubview(spatialAmountSlider)

        spatialAmountValueLabel = makeLabel("", size: 13, weight: .semibold)
        spatialAmountValueLabel.frame = NSRect(x: 342, y: 66, width: 56, height: 24)
        view.addSubview(spatialAmountValueLabel)

        let spaceHelp = makeLabel("Space: 원본과 공간 처리 신호를 섞는 양입니다.", size: 11.5, weight: .regular)
        spaceHelp.frame = NSRect(x: 16, y: 32, width: 398, height: 18)
        view.addSubview(spaceHelp)

        let hint = makeLabel("권장 25-45%. IEM에서 위상이 거칠면 먼저 낮추세요.", size: 11.5, weight: .regular)
        hint.frame = NSRect(x: 16, y: 12, width: 398, height: 18)
        view.addSubview(hint)

        updateSpatialControls(from: spatialSettingsFromControls(), notifyProcessor: false)
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

    private func makeNumberField(value: Double) -> NSTextField {
        let field = NSTextField(frame: .zero)
        field.stringValue = String(format: "%.2f", value)
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.target = self
        field.action = #selector(spatialFieldChanged)
        field.delegate = self
        return field
    }

    private func addNumberRow(to view: NSView,
                              y: CGFloat,
                              title: String,
                              field: NSTextField,
                              suffix: String,
                              tooltip: String) {
        let label = makeLabel(title, size: 13, weight: .semibold)
        label.frame = NSRect(x: 16, y: y, width: 62, height: 24)
        field.frame = NSRect(x: 82, y: y - 2, width: 250, height: 28)
        field.toolTip = tooltip
        let unit = makeLabel(suffix, size: 12, weight: .regular)
        unit.frame = NSRect(x: 342, y: y, width: 44, height: 24)
        view.addSubview(label)
        view.addSubview(field)
        view.addSubview(unit)
    }

    @objc private func sliderChanged() {
        updateSliderLabels()
        processor?.updateDSP(intensity: Float(intensitySlider.doubleValue),
                             body: Float(bodySlider.doubleValue),
                             outputDb: Float(outputSlider.doubleValue),
                             dspModel: selectedDSPModel())
    }

    @objc private func spatialControlChanged() {
        updateSpatialControls(from: spatialSettingsFromControls(), notifyProcessor: true)
    }

    @objc private func spatialFieldChanged() {
        spatialControlChanged()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        spatialControlChanged()
    }

    private func spatialStageChanged(_ settings: SpatialSettings) {
        var updated = spatialSettingsFromControls()
        updated.listenerX = settings.listenerX
        updated.listenerZ = settings.listenerZ
        updateSpatialControls(from: updated, notifyProcessor: true)
    }

    @objc private func resetSpatialPosition() {
        var updated = spatialSettingsFromControls()
        updated.listenerX = 0
        updated.listenerZ = 0
        updateSpatialControls(from: updated, notifyProcessor: true)
        statusLabel.stringValue = "공간음향 위치를 원위치로 되돌렸습니다."
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

    private func spatialSettingsFromControls() -> SpatialSettings {
        SpatialSettings(
            enabled: spatialEnabledButton?.state == .on,
            listenerX: clamp(Float(listenerXField?.doubleValue ?? 0), -3.0, 3.0),
            listenerZ: clamp(Float(listenerZField?.doubleValue ?? 0), -2.8, 2.8),
            speakerWidth: clamp(Float(speakerWidthField?.doubleValue ?? 1.65), 0.6, 3.0),
            amount: clamp(Float(spatialAmountSlider?.doubleValue ?? 35.0), 0, 100)
        )
    }

    private func updateSpatialControls(from settings: SpatialSettings, notifyProcessor: Bool) {
        spatialEnabledButton.state = settings.enabled ? .on : .off
        listenerXField.stringValue = String(format: "%.2f", settings.listenerX)
        listenerZField.stringValue = String(format: "%.2f", settings.listenerZ)
        speakerWidthField.stringValue = String(format: "%.2f", settings.speakerWidth)
        spatialAmountSlider.doubleValue = Double(settings.amount)
        spatialAmountValueLabel.stringValue = "\(Int(settings.amount.rounded()))%"
        spatialStageView.setSettings(settings)

        if notifyProcessor {
            processor?.updateSpatial(settings)
        }
    }

    @objc private func applyIEMPreset() {
        applyPreset(name: "IEM", intensity: 36, body: 10, outputDb: -3.0)
    }

    @objc private func applyGentlePreset() {
        applyPreset(name: "Gentle", intensity: 26, body: 10, outputDb: -1.2)
    }

    @objc private func applyLowEndPreset() {
        applyPreset(name: "LowEnd", intensity: 48, body: 22, outputDb: -2.0)
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
                 dspModel: selectedDSPModel(),
                 spatial: spatialSettingsFromControls())
    }

    private func selectedDSPModel() -> Settings.DSPModel {
        modelPopup.indexOfSelectedItem == 0 ? .circuit : .clean
    }

    private func start(_ settings: Settings) {
        stopAudio()

        do {
            let processor = try SystemAudioProcessor(settings: settings)
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
      --spatial on|off
      --listener-x meters
      --listener-z meters
      --stage-width meters
      --space 0...100
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

private final class LockFreeFloatRingBuffer {
    private let handle: OpaquePointer

    init(capacityFrames: Int, channels: Int) throws {
        let requestedSamples = UInt32(max(capacityFrames * channels, channels * 512))
        guard let handle = lc_ring_buffer_create(requestedSamples) else {
            throw AppError.message("Could not allocate audio ring buffer.")
        }
        self.handle = handle
    }

    deinit {
        lc_ring_buffer_destroy(handle)
    }

    func push(_ samples: UnsafePointer<Float>, count: Int) {
        _ = lc_ring_buffer_push(handle, samples, UInt32(max(count, 0)))
    }

    func popInterleaved(into pointer: UnsafeMutablePointer<Float>, count: Int) {
        _ = lc_ring_buffer_pop(handle, pointer, UInt32(max(count, 0)))
    }

    func popStereo(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        _ = lc_ring_buffer_pop_deinterleaved_stereo(handle, left, right, UInt32(max(frameCount, 0)))
    }

    func clear() {
        lc_ring_buffer_clear(handle)
    }
}

private final class LockFreeControlEventQueue {
    private let handle: OpaquePointer
    private let sampleRate: Float

    init(capacity: Int = 4096, sampleRate: Float) throws {
        guard let handle = lc_control_event_queue_create(UInt32(max(capacity, 16))) else {
            throw AppError.message("Could not allocate audio control event queue.")
        }
        self.handle = handle
        self.sampleRate = sampleRate
    }

    deinit {
        lc_control_event_queue_destroy(handle)
    }

    func pushDSP(intensity: Float, body: Float, outputDb: Float, dspModel: Settings.DSPModel) {
        var event = LCControlEvent()
        event.type = UInt32(LC_CONTROL_EVENT_DSP)
        event.dsp = DSPPrecompute.makeDSPSettings(
            sampleRate: sampleRate,
            intensity: intensity,
            body: body,
            outputDb: outputDb,
            dspModel: dspModel
        )
        _ = withUnsafePointer(to: &event) { lc_control_event_queue_push(handle, $0) }
    }

    func pushSpatial(_ settings: SpatialSettings) {
        var event = LCControlEvent()
        event.type = UInt32(LC_CONTROL_EVENT_SPATIAL)
        event.spatial = DSPPrecompute.makeSpatialSettings(sampleRate: sampleRate, settings: settings)
        _ = withUnsafePointer(to: &event) { lc_control_event_queue_push(handle, $0) }
    }

    func pop(into event: UnsafeMutablePointer<LCControlEvent>) -> Bool {
        lc_control_event_queue_pop(handle, event) != 0
    }
}

private enum DSPPrecompute {
    static func makeDSPSettings(sampleRate: Float,
                                intensity: Float,
                                body: Float,
                                outputDb: Float,
                                dspModel: Settings.DSPModel) -> LCDSPSettings {
        let normalIntensity = clamp(intensity / 100, 0, 1)
        let normalBody = clamp(body / 100, 0, 1)
        let shelfDb = normalIntensity * 8.5
        let shelfFreq = 72 + normalIntensity * 33
        let outputGain = pow(10, outputDb / 20)

        return LCDSPSettings(
            intensity: normalIntensity,
            body: normalBody,
            outputGain: outputGain,
            headroomGain: pow(10, (-3 * normalIntensity) / 20),
            dspModel: dspModel == .circuit ? 1 : 0,
            shelf: makeLowShelf(sampleRate: sampleRate, frequency: shelfFreq, q: 0.72, gainDb: shelfDb),
            warmthAmount: 0.014 * normalIntensity + 0.010 * normalBody,
            virtualFeedbackGain: 0.48 * normalIntensity,
            bodyInjectionGain: (0.08 + 0.14 * normalIntensity) * normalBody,
            circuitHeadroomGain: pow(10, (-4.2 * normalIntensity - 2.0 * normalBody) / 20),
            drive: 1 + 0.20 * normalIntensity + 0.10 * normalBody,
            wetMix: min(max(0.62 * normalIntensity + 0.18 * normalBody, 0), 0.82),
            bassAlpha: makeRcAlpha(sampleRate: sampleRate, frequency: 72 + normalIntensity * 36),
            subAlpha: makeRcAlpha(sampleRate: sampleRate, frequency: 38 + normalBody * 26)
        )
    }

    static func makeSpatialSettings(sampleRate: Float, settings: SpatialSettings) -> LCSpatialSettings {
        let width = clamp(settings.speakerWidth, 0.6, 3.0)
        let listenerX = clamp(settings.listenerX, -3.0, 3.0)
        let listenerZ = clamp(settings.listenerZ, -2.8, 2.8)
        let earOffset: Float = 0.09
        let speakerZ: Float = 1.8
        let amount = clamp(settings.amount / 100, 0, 1)
        let crossfeed = 0.16 + amount * 0.30

        let leftSpeaker = (x: -width / 2, z: speakerZ)
        let rightSpeaker = (x: width / 2, z: speakerZ)
        let leftEar = (x: listenerX - earOffset, z: listenerZ)
        let rightEar = (x: listenerX + earOffset, z: listenerZ)

        let llDistance = distance(leftSpeaker, leftEar)
        let lrDistance = distance(leftSpeaker, rightEar)
        let rlDistance = distance(rightSpeaker, leftEar)
        let rrDistance = distance(rightSpeaker, rightEar)
        let minimumDistance = min(llDistance, lrDistance, rlDistance, rrDistance)

        let llGain = inverseDistanceGain(llDistance)
        let rrGain = inverseDistanceGain(rrDistance)
        let lrGain = inverseDistanceGain(lrDistance) * crossfeed
        let rlGain = inverseDistanceGain(rlDistance) * crossfeed
        let normalizer = 1 / max((llGain + rrGain) * 0.5, 0.001)

        return LCSpatialSettings(
            enabled: settings.enabled ? 1 : 0,
            amount: amount,
            ll: makeSpatialPath(distanceOffset: llDistance - minimumDistance, gain: llGain * normalizer, sampleRate: sampleRate),
            lr: makeSpatialPath(distanceOffset: lrDistance - minimumDistance, gain: lrGain * normalizer, sampleRate: sampleRate),
            rl: makeSpatialPath(distanceOffset: rlDistance - minimumDistance, gain: rlGain * normalizer, sampleRate: sampleRate),
            rr: makeSpatialPath(distanceOffset: rrDistance - minimumDistance, gain: rrGain * normalizer, sampleRate: sampleRate)
        )
    }

    static func makeLowPass(sampleRate: Float, frequency: Float, q: Float) -> LCBiquadCoefficients {
        let w0 = 2 * Float.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        return LCBiquadCoefficients(
            b0: ((1 - cosW0) / 2) / a0,
            b1: (1 - cosW0) / a0,
            b2: ((1 - cosW0) / 2) / a0,
            a1: (-2 * cosW0) / a0,
            a2: (1 - alpha) / a0
        )
    }

    static func makeLowShelf(sampleRate: Float, frequency: Float, q: Float, gainDb: Float) -> LCBiquadCoefficients {
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)
        let beta = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * cosW0 + beta

        return LCBiquadCoefficients(
            b0: a * ((a + 1) - (a - 1) * cosW0 + beta) / a0,
            b1: 2 * a * ((a - 1) - (a + 1) * cosW0) / a0,
            b2: a * ((a + 1) - (a - 1) * cosW0 - beta) / a0,
            a1: -2 * ((a - 1) + (a + 1) * cosW0) / a0,
            a2: ((a + 1) + (a - 1) * cosW0 - beta) / a0
        )
    }

    static func makeRcAlpha(sampleRate: Float, frequency: Float) -> Float {
        let clampedFrequency = min(max(frequency, 5), sampleRate * 0.45)
        return 1 - exp(-2 * Float.pi * clampedFrequency / sampleRate)
    }

    private static func distance(_ a: (x: Float, z: Float), _ b: (x: Float, z: Float)) -> Float {
        let dx = a.x - b.x
        let dz = a.z - b.z
        return max(sqrt(dx * dx + dz * dz), 0.12)
    }

    private static func inverseDistanceGain(_ meters: Float) -> Float {
        1 / max(0.45 + meters * 0.62, 0.2)
    }

    private static func makeSpatialPath(distanceOffset: Float, gain: Float, sampleRate: Float) -> LCSpatialPathSettings {
        let speedOfSound: Float = 343.0
        let samples = Int((max(distanceOffset, 0) / speedOfSound * sampleRate).rounded())
        return LCSpatialPathSettings(delaySamples: UInt32(max(samples, 0)), gain: gain)
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

    mutating func update(_ coefficients: LCBiquadCoefficients) {
        b0 = coefficients.b0
        b1 = coefficients.b1
        b2 = coefficients.b2
        a1 = coefficients.a1
        a2 = coefficients.a2
    }

    static func lowPass(sampleRate: Float, frequency: Float, q: Float) -> Biquad {
        var biquad = Biquad()
        biquad.update(DSPPrecompute.makeLowPass(sampleRate: sampleRate, frequency: frequency, q: q))
        return biquad
    }

    static func lowShelf(sampleRate: Float, frequency: Float, q: Float, gainDb: Float) -> Biquad {
        var biquad = Biquad()
        biquad.update(DSPPrecompute.makeLowShelf(sampleRate: sampleRate, frequency: frequency, q: q, gainDb: gainDb))
        return biquad
    }
}

private protocol BassProcessor: AnyObject {
    func process(left: Float, right: Float) -> (Float, Float)
}

private final class LowEndDSP: BassProcessor {
    private var shelfL = Biquad()
    private var shelfR = Biquad()
    private var subL: Biquad
    private var subR: Biquad
    private var intensity: Float = 0
    private var body: Float = 0
    private var outputGain: Float = 1
    private var headroomGain: Float = 1

    init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float) {
        self.subL = .lowPass(sampleRate: sampleRate, frequency: 135, q: 0.68)
        self.subR = .lowPass(sampleRate: sampleRate, frequency: 135, q: 0.68)
        update(DSPPrecompute.makeDSPSettings(
            sampleRate: sampleRate,
            intensity: intensity,
            body: body,
            outputDb: outputDb,
            dspModel: .clean
        ))
    }

    func update(_ settings: LCDSPSettings) {
        self.intensity = settings.intensity
        self.body = settings.body
        self.outputGain = settings.outputGain
        self.headroomGain = settings.headroomGain
        shelfL.update(settings.shelf)
        shelfR.update(settings.shelf)
    }

    func process(left: Float, right: Float) -> (Float, Float) {
        var lShelf = shelfL.process(left)
        var rShelf = shelfR.process(right)
        let lSub = tanh(subL.process(left) * 2.4) * 0.18 * body
        let rSub = tanh(subR.process(right) * 2.4) * 0.18 * body
        lShelf = tanh((lShelf + lSub) * headroomGain * outputGain * 1.05) / 1.05
        rShelf = tanh((rShelf + rSub) * headroomGain * outputGain * 1.05) / 1.05
        return (lShelf, rShelf)
    }
}

private final class RcLowPass {
    private var alpha: Float = 0
    private var z: Float = 0

    init(sampleRate: Float, frequency: Float) {
        update(alpha: DSPPrecompute.makeRcAlpha(sampleRate: sampleRate, frequency: frequency))
    }

    func update(alpha: Float) {
        self.alpha = alpha
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
        private var intensity: Float = 0
        private var body: Float = 0
        private var outputGain: Float = 1
        private var warmthAmount: Float = 0
        private var virtualFeedbackGain: Float = 0
        private var bodyInjectionGain: Float = 0
        private var headroomGain: Float = 1
        private var drive: Float = 1
        private var wetMix: Float = 0

        init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float) {
            self.bassPole = RcLowPass(sampleRate: sampleRate, frequency: 72)
            self.subPole = RcLowPass(sampleRate: sampleRate, frequency: 38)
            update(DSPPrecompute.makeDSPSettings(
                sampleRate: sampleRate,
                intensity: intensity,
                body: body,
                outputDb: outputDb,
                dspModel: .circuit
            ))
        }

        func update(_ settings: LCDSPSettings) {
            self.intensity = settings.intensity
            self.body = settings.body
            self.outputGain = settings.outputGain
            self.warmthAmount = settings.warmthAmount
            self.virtualFeedbackGain = settings.virtualFeedbackGain
            self.bodyInjectionGain = settings.bodyInjectionGain
            self.headroomGain = settings.circuitHeadroomGain
            self.drive = settings.drive
            self.wetMix = settings.wetMix
            bassPole.update(alpha: settings.bassAlpha)
            subPole.update(alpha: settings.subAlpha)
        }

        func process(_ input: Float) -> Float {
            if intensity < 0.001 && body < 0.001 {
                return input * outputGain
            }

            let softened = input + ((tanh(input * 1.8) / 1.8) - input) * warmthAmount
            let bassNode = bassPole.process(softened)
            let subNode = subPole.process(softened)

            let summed = softened + bassNode * virtualFeedbackGain + subNode * bodyInjectionGain

            let opAmpStage = tanh(summed * headroomGain * drive) / drive

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

    func update(_ settings: LCDSPSettings) {
        left.update(settings)
        right.update(settings)
    }

    func process(left inputLeft: Float, right inputRight: Float) -> (Float, Float) {
        (left.process(inputLeft), right.process(inputRight))
    }
}

private final class DelayLine {
    private var buffer: [Float]
    private var writeIndex = 0

    init(capacity: Int) {
        buffer = Array(repeating: 0, count: max(capacity, 32))
    }

    func process(_ input: Float, delaySamples: Int) -> Float {
        let delay = min(max(delaySamples, 0), buffer.count - 1)
        let readIndex = (writeIndex - delay + buffer.count) % buffer.count
        let output = buffer[readIndex]
        buffer[writeIndex] = input
        writeIndex = (writeIndex + 1) % buffer.count
        return output
    }
}

private final class Spatializer {
    private struct Path {
        var delaySamples: Int = 0
        var gain: Float = 1
    }

    private let leftToLeft = DelayLine(capacity: 2048)
    private let leftToRight = DelayLine(capacity: 2048)
    private let rightToLeft = DelayLine(capacity: 2048)
    private let rightToRight = DelayLine(capacity: 2048)
    private var enabled = true
    private var amount: Float = 0
    private var ll = Path()
    private var lr = Path()
    private var rl = Path()
    private var rr = Path()

    init(sampleRate: Float, settings: SpatialSettings) {
        update(DSPPrecompute.makeSpatialSettings(sampleRate: sampleRate, settings: settings))
    }

    func update(_ settings: LCSpatialSettings) {
        enabled = settings.enabled != 0
        amount = settings.amount
        ll = Path(delaySamples: Int(settings.ll.delaySamples), gain: settings.ll.gain)
        lr = Path(delaySamples: Int(settings.lr.delaySamples), gain: settings.lr.gain)
        rl = Path(delaySamples: Int(settings.rl.delaySamples), gain: settings.rl.gain)
        rr = Path(delaySamples: Int(settings.rr.delaySamples), gain: settings.rr.gain)
    }

    func process(left: Float, right: Float) -> (Float, Float) {
        guard enabled, amount > 0.001 else {
            return (left, right)
        }

        let wetLeft =
            leftToLeft.process(left, delaySamples: ll.delaySamples) * ll.gain +
            rightToLeft.process(right, delaySamples: rl.delaySamples) * rl.gain
        let wetRight =
            rightToRight.process(right, delaySamples: rr.delaySamples) * rr.gain +
            leftToRight.process(left, delaySamples: lr.delaySamples) * lr.gain

        let trim: Float = 0.82
        let outLeft = left * (1 - amount) + wetLeft * trim * amount
        let outRight = right * (1 - amount) + wetRight * trim * amount
        return (tanh(outLeft * 1.02) / 1.02, tanh(outRight * 1.02) / 1.02)
    }
}

@available(macOS 14.4, *)
private final class SystemAudioProcessor {
    private let settings: Settings
    private let sampleRate: Double = 48_000
    private let ringBuffer: LockFreeFloatRingBuffer
    private let controlQueue: LockFreeControlEventQueue
    private let scratchFrameCapacity = 8192
    private let inputScratch: UnsafeMutablePointer<Float>
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let cleanDSP: LowEndDSP
    private let circuitDSP: VirtualCircuitBassDSP
    private var activeDSPModel: Settings.DSPModel
    private lazy var spatializer = Spatializer(sampleRate: Float(sampleRate), settings: settings.spatial)

    init(settings: Settings) throws {
        self.settings = settings
        self.ringBuffer = try LockFreeFloatRingBuffer(capacityFrames: 48_000 * 4, channels: 2)
        self.controlQueue = try LockFreeControlEventQueue(sampleRate: Float(sampleRate))
        self.inputScratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrameCapacity * 2)
        self.cleanDSP = LowEndDSP(
            sampleRate: Float(sampleRate),
            intensity: settings.intensity,
            body: settings.body,
            outputDb: settings.outputDb
        )
        self.circuitDSP = VirtualCircuitBassDSP(
            sampleRate: Float(sampleRate),
            intensity: settings.intensity,
            body: settings.body,
            outputDb: settings.outputDb
        )
        self.activeDSPModel = settings.dspModel
    }

    deinit {
        inputScratch.deallocate()
    }

    func start() throws {
        try startOutput()
        try createProcessTapAndAggregateDevice()
        try startCapture()
        print("LowEnd system audio processing is running. Press Ctrl-C to stop.")
    }

    func updateDSP(intensity: Float, body: Float, outputDb: Float, dspModel: Settings.DSPModel) {
        controlQueue.pushDSP(intensity: intensity, body: body, outputDb: outputDb, dspModel: dspModel)
    }

    func updateSpatial(_ settings: SpatialSettings) {
        controlQueue.pushSpatial(settings)
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
                guard let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                    return noErr
                }
                ringBuffer.popStereo(left: left, right: right, frameCount: frames)
            } else if let buffer = abl.first,
                      let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                let channels = max(Int(buffer.mNumberChannels), 1)
                ringBuffer.popInterleaved(into: data, count: frames * channels)
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

        description.name = "LowEnd Native System Tap"
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
        let aggregateUID = "com.codexaudiolab.lowendcircuit.aggregate.\(UUID().uuidString)"
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LowEnd Native Audio",
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
        applyPendingControlEvents()

        if buffers.count >= 2,
           let leftData = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           let rightData = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            processAndPushStereo(left: leftData, right: rightData, frameCount: frameCount)
        } else if first.mNumberChannels == 2,
                  let interleaved = first.mData?.assumingMemoryBound(to: Float.self) {
            let stereoFrames = frameCount / 2
            processAndPushInterleavedStereo(interleaved, frameCount: stereoFrames)
        } else if let mono = first.mData?.assumingMemoryBound(to: Float.self) {
            processAndPushMono(mono, frameCount: frameCount)
        }
    }

    private func applyPendingControlEvents() {
        var event = LCControlEvent()
        var latestDSP = LCDSPSettings()
        var hasDSP = false
        var latestSpatial = LCSpatialSettings()
        var hasSpatial = false

        while controlQueue.pop(into: &event) {
            switch event.type {
            case UInt32(LC_CONTROL_EVENT_DSP):
                latestDSP = event.dsp
                hasDSP = true
            case UInt32(LC_CONTROL_EVENT_SPATIAL):
                latestSpatial = event.spatial
                hasSpatial = true
            default:
                break
            }
        }

        if hasDSP {
            activeDSPModel = latestDSP.dspModel == 1 ? .circuit : .clean
            switch activeDSPModel {
            case .clean:
                cleanDSP.update(latestDSP)
            case .circuit:
                circuitDSP.update(latestDSP)
            }
        }

        if hasSpatial {
            spatializer.update(latestSpatial)
        }
    }

    private func processAndPushStereo(left: UnsafePointer<Float>,
                                      right: UnsafePointer<Float>,
                                      frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let chunkFrames = min(scratchFrameCapacity, frameCount - offset)
            let leftChunk = left.advanced(by: offset)
            let rightChunk = right.advanced(by: offset)

            for frame in 0..<chunkFrames {
                let processed = processBass(left: leftChunk[frame], right: rightChunk[frame])
                let spatial = spatializer.process(left: processed.0, right: processed.1)
                inputScratch[frame * 2] = spatial.0
                inputScratch[frame * 2 + 1] = spatial.1
            }

            ringBuffer.push(inputScratch, count: chunkFrames * 2)
            offset += chunkFrames
        }
    }

    private func processAndPushInterleavedStereo(_ interleaved: UnsafePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let chunkFrames = min(scratchFrameCapacity, frameCount - offset)
            let chunk = interleaved.advanced(by: offset * 2)

            for frame in 0..<chunkFrames {
                let processed = processBass(left: chunk[frame * 2], right: chunk[frame * 2 + 1])
                let spatial = spatializer.process(left: processed.0, right: processed.1)
                inputScratch[frame * 2] = spatial.0
                inputScratch[frame * 2 + 1] = spatial.1
            }

            ringBuffer.push(inputScratch, count: chunkFrames * 2)
            offset += chunkFrames
        }
    }

    private func processAndPushMono(_ mono: UnsafePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let chunkFrames = min(scratchFrameCapacity, frameCount - offset)
            let chunk = mono.advanced(by: offset)

            for frame in 0..<chunkFrames {
                let processed = processBass(left: chunk[frame], right: chunk[frame])
                let spatial = spatializer.process(left: processed.0, right: processed.1)
                inputScratch[frame * 2] = spatial.0
                inputScratch[frame * 2 + 1] = spatial.1
            }

            ringBuffer.push(inputScratch, count: chunkFrames * 2)
            offset += chunkFrames
        }
    }

    private func processBass(left: Float, right: Float) -> (Float, Float) {
        switch activeDSPModel {
        case .clean:
            return cleanDSP.process(left: left, right: right)
        case .circuit:
            return circuitDSP.process(left: left, right: right)
        }
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

    let processor = try SystemAudioProcessor(settings: settings)
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
