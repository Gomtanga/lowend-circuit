import AppKit
import Accelerate
import AudioToolbox
import AVFoundation
import AudioRingBufferC
import Combine
import CoreAudio
import Darwin
import Foundation
import LowEndSupport
import Metal
import MetalKit
import SceneKit
import SwiftUI

enum AppError: Error, CustomStringConvertible {
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

private final class DynamicsMeterModel: ObservableObject {
    struct Levels {
        var peak: Float
        var rms: Float
        var crestFactor: Float
    }

    @Published private(set) var levels = Levels(peak: -100, rms: -100, crestFactor: 0)

    func update(peak: Float, rms: Float, crestFactor: Float) {
        levels = Levels(peak: peak, rms: rms, crestFactor: crestFactor)
    }

    func reset() {
        update(peak: -100, rms: -100, crestFactor: 0)
    }
}

private final class SpectrumModel {
    static let binCount = Int(LC_SPECTRUM_BIN_COUNT)
    private let snapshot: OpaquePointer

    init() {
        guard let snapshot = lc_spectrum_snapshot_create() else {
            fatalError("Could not allocate spectrum snapshot.")
        }
        self.snapshot = snapshot
    }

    deinit {
        lc_spectrum_snapshot_destroy(snapshot)
    }

    func publish(_ values: [Float]) {
        values.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            lc_spectrum_snapshot_publish(snapshot, baseAddress, UInt32(pointer.count))
        }
    }

    func copySnapshot(
        into destination: UnsafeMutablePointer<Float>,
        after previousSequence: UInt64
    ) -> UInt64? {
        var newSequence: UInt64 = previousSequence
        let copied = lc_spectrum_snapshot_copy_if_new(
            snapshot,
            destination,
            UInt32(Self.binCount),
            previousSequence,
            &newSequence
        )
        return copied == UInt32(Self.binCount) ? newSequence : nil
    }

    func setAnalysisActive(_ active: Bool) {
        lc_spectrum_snapshot_set_active(snapshot, active ? 1 : 0)
    }

    var isAnalysisActive: Bool {
        lc_spectrum_snapshot_is_active(snapshot) != 0
    }

    func reset() {
        lc_spectrum_snapshot_clear(snapshot)
    }
}

private final class SpatialControlModel: ObservableObject {
    @Published var settings: SpatialSettings

    init(settings: SpatialSettings = SpatialSettings()) {
        self.settings = settings
    }

    func update(_ newSettings: SpatialSettings) {
        var clamped = newSettings
        clamped.listenerX = clamp(clamped.listenerX, -3.0, 3.0)
        clamped.listenerZ = clamp(clamped.listenerZ, -2.8, 2.8)
        clamped.speakerWidth = clamp(clamped.speakerWidth, 0.6, 3.0)
        clamped.amount = clamp(clamped.amount, 0, 100)
        settings = clamped
    }
}

private enum DynamicsMeterStyle {
    case compactHorizontal
    case analysis
}

private struct DynamicsMeterView: View {
    @ObservedObject var model: DynamicsMeterModel
    var style: DynamicsMeterStyle = .compactHorizontal

    var body: some View {
        switch style {
        case .compactHorizontal:
            compactBody
        case .analysis:
            analysisBody
        }
    }

    private var compactBody: some View {
        VStack(spacing: 4) {
            horizontalLevelBar(title: "Peak", db: model.levels.peak, color: Color(red: 0.96, green: 0.75, blue: 0.31), showValue: false)
            horizontalLevelBar(title: "RMS", db: model.levels.rms, color: Color(red: 0.34, green: 0.80, blue: 0.92), showValue: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
    }

    private var analysisBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dynamics")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.78, green: 0.81, blue: 0.86))
                    Text("Crest Factor")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.58, green: 0.62, blue: 0.68))
                }
                Spacer(minLength: 8)
                Text(String(format: "%.1f dB", model.levels.crestFactor))
                    .font(.system(size: 30, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color(red: 0.96, green: 0.75, blue: 0.31))
                    .minimumScaleFactor(0.72)
            }

            VStack(spacing: 9) {
                horizontalLevelBar(title: "Peak", db: model.levels.peak, color: Color(red: 0.96, green: 0.75, blue: 0.31), showValue: true)
                horizontalLevelBar(title: "RMS", db: model.levels.rms, color: Color(red: 0.34, green: 0.80, blue: 0.92), showValue: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
    }

    private func horizontalLevelBar(title: String, db: Float, color: Color, showValue: Bool) -> some View {
        let normalized = max(0, min(1, Double((db + 60) / 60)))
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(red: 0.78, green: 0.81, blue: 0.86))
                .frame(width: showValue ? 42 : 28, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: 0.18, green: 0.21, blue: 0.25))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(2, proxy.size.width * normalized))
                }
            }
            .frame(height: showValue ? 14 : 6)
            if showValue {
                Text(String(format: "%.1f dB", db))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }

}

private struct MetalSpectrumUniforms {
    var viewportAndCount = SIMD4<Float>(0, 0, Float(SpectrumModel.binCount), 0)
    var layout = SIMD4<Float>(42, 5, 1.5, 0)
}

@available(macOS 14.4, *)
private struct MetalSpectrumView: NSViewRepresentable {
    let model: SpectrumModel
    var isActive = true

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        model.setAnalysisActive(isActive)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = !isActive || !context.coordinator.isReady
        view.presentsWithTransaction = false
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        model.setAnalysisActive(isActive)
        nsView.isPaused = !isActive || !context.coordinator.isReady
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.setAnalysisActive(false)
        nsView.isPaused = true
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let model: SpectrumModel
        private let commandQueue: MTLCommandQueue?
        private let pipelineState: MTLRenderPipelineState?
        private let amplitudeBuffers: [MTLBuffer]
        private let uniformBuffers: [MTLBuffer]
        private var bufferIndex = 0
        private var drawableSize = SIMD2<Float>(0, 0)
        private var lastSequence = UInt64.max

        var isReady: Bool {
            device != nil &&
                commandQueue != nil &&
                pipelineState != nil &&
                amplitudeBuffers.count == 3 &&
                uniformBuffers.count == 3
        }

        init(model: SpectrumModel) {
            self.model = model
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            self.pipelineState = Self.makePipeline(device: device)

            var amplitudes: [MTLBuffer] = []
            var uniforms: [MTLBuffer] = []
            if let device {
                let amplitudeLength = SpectrumModel.binCount * MemoryLayout<Float>.stride
                let uniformLength = MemoryLayout<MetalSpectrumUniforms>.stride
                for _ in 0..<3 {
                    if let amplitude = device.makeBuffer(length: amplitudeLength, options: .storageModeShared),
                       let uniform = device.makeBuffer(length: uniformLength, options: .storageModeShared) {
                        memset(amplitude.contents(), 0, amplitudeLength)
                        memset(uniform.contents(), 0, uniformLength)
                        amplitudes.append(amplitude)
                        uniforms.append(uniform)
                    }
                }
            }
            self.amplitudeBuffers = amplitudes
            self.uniformBuffers = uniforms
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            drawableSize = SIMD2(Float(size.width), Float(size.height))
            lastSequence = UInt64.max
        }

        func setAnalysisActive(_ active: Bool) {
            model.setAnalysisActive(active)
        }

        func draw(in view: MTKView) {
            guard isReady,
                  drawableSize.x > 0,
                  drawableSize.y > 0,
                  let commandQueue,
                  let pipelineState,
                  let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }

            let index = bufferIndex
            bufferIndex = (bufferIndex + 1) % 3
            let amplitudeBuffer = amplitudeBuffers[index]
            let amplitudePointer = amplitudeBuffer.contents().bindMemory(
                to: Float.self,
                capacity: SpectrumModel.binCount
            )
            guard let sequence = model.copySnapshot(
                into: amplitudePointer,
                after: lastSequence
            ) else { return }
            lastSequence = sequence

            let uniformBuffer = uniformBuffers[index]
            let uniformPointer = uniformBuffer.contents().bindMemory(
                to: MetalSpectrumUniforms.self,
                capacity: 1
            )
            uniformPointer.pointee.viewportAndCount = SIMD4(
                drawableSize.x,
                drawableSize.y,
                Float(SpectrumModel.binCount),
                0
            )

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(amplitudeBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: SpectrumModel.binCount
            )
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
            guard let device,
                  let shaderURL = Bundle.main.url(forResource: "SpectrumShaders", withExtension: "metal"),
                  let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8),
                  let library = try? device.makeLibrary(source: shaderSource, options: nil),
                  let vertexFunction = library.makeFunction(name: "spectrumVertex"),
                  let fragmentFunction = library.makeFunction(name: "spectrumFragment") else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "LowEnd Spectrum Bars"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
    }
}

@available(macOS 14.4, *)
private struct SpatialStageRepresentable: NSViewRepresentable {
    @ObservedObject var model: SpatialControlModel
    let onChange: (SpatialSettings) -> Void

    func makeNSView(context: Context) -> SpatialStageView {
        let view = SpatialStageView(frame: .zero)
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.onChange = { settings in
            model.update(settings)
            onChange(model.settings)
        }
        view.setSettings(model.settings)
        return view
    }

    func updateNSView(_ nsView: SpatialStageView, context: Context) {
        nsView.setSettings(model.settings)
    }
}

@available(macOS 14.4, *)
private struct RightPanelContainerView: View {
    private enum PanelTab: String, CaseIterable, Identifiable {
        case spatial = "Spatial Stage"
        case analysis = "Analysis"

        var id: String { rawValue }
    }

    @State private var selectedTab: PanelTab = .spatial
    @ObservedObject var spatialModel: SpatialControlModel
    let dynamicsModel: DynamicsMeterModel
    let spectrumModel: SpectrumModel
    let onSpatialChange: (SpatialSettings) -> Void

    var body: some View {
        VStack(spacing: 12) {
            Picker("", selection: $selectedTab) {
                ForEach(PanelTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack {
                switch selectedTab {
                case .spatial:
                    spatialTab
                        .transition(.opacity)
                case .analysis:
                    analysisTab
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.16), value: selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.12, green: 0.14, blue: 0.17))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var spatialTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Spatial Stage")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color(red: 0.96, green: 0.75, blue: 0.31))
                Spacer()
                Button("원위치") {
                    applySpatialChange { settings in
                        settings.listenerX = 0
                        settings.listenerZ = 0
                    }
                }
                .buttonStyle(.bordered)
                Toggle("공간음향", isOn: spatialEnabledBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12, weight: .semibold))
            }

            SpatialStageRepresentable(model: spatialModel, onChange: onSpatialChange)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 310)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(spacing: 8) {
                spatialSlider(title: "나 X", value: listenerXBinding, range: -3.0...3.0, suffix: "m")
                spatialSlider(title: "나 Z", value: listenerZBinding, range: -2.8...2.8, suffix: "m")
                spatialSlider(title: "Width", value: speakerWidthBinding, range: 0.6...3.0, suffix: "m")
                spatialSlider(title: "Space", value: spatialAmountBinding, range: 0...100, suffix: "%")
            }

            DynamicsMeterView(model: dynamicsModel, style: .compactHorizontal)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var analysisTab: some View {
        VStack(spacing: 12) {
            MetalSpectrumView(model: spectrumModel, isActive: selectedTab == .analysis)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 330)
                .overlay(alignment: .topLeading) {
                    Text("Spectrum")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.78, green: 0.81, blue: 0.86))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            DynamicsMeterView(model: dynamicsModel, style: .analysis)
                .frame(maxWidth: .infinity)
                .frame(height: 162)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func spatialSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.78, green: 0.81, blue: 0.86))
                .frame(width: 46, alignment: .leading)
            Slider(value: value, in: range)
            Text(valueText(value.wrappedValue, suffix: suffix))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private var spatialEnabledBinding: Binding<Bool> {
        Binding(
            get: { spatialModel.settings.enabled },
            set: { newValue in
                applySpatialChange { settings in settings.enabled = newValue }
            }
        )
    }

    private var listenerXBinding: Binding<Double> {
        spatialBinding(\.listenerX)
    }

    private var listenerZBinding: Binding<Double> {
        spatialBinding(\.listenerZ)
    }

    private var speakerWidthBinding: Binding<Double> {
        spatialBinding(\.speakerWidth)
    }

    private var spatialAmountBinding: Binding<Double> {
        spatialBinding(\.amount)
    }

    private func spatialBinding(_ keyPath: WritableKeyPath<SpatialSettings, Float>) -> Binding<Double> {
        Binding(
            get: { Double(spatialModel.settings[keyPath: keyPath]) },
            set: { newValue in
                applySpatialChange { settings in settings[keyPath: keyPath] = Float(newValue) }
            }
        )
    }

    private func applySpatialChange(_ change: (inout SpatialSettings) -> Void) {
        var settings = spatialModel.settings
        change(&settings)
        spatialModel.update(settings)
        onSpatialChange(spatialModel.settings)
    }

    private func valueText(_ value: Double, suffix: String) -> String {
        if suffix == "%" {
            return "\(Int(value.rounded()))\(suffix)"
        }
        return String(format: "%.2f %@", value, suffix)
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
            guard let value = iterator.next(), let model = Settings.DSPModel.fromArgument(value) else {
                throw AppError.message("--model needs clean, circuit, or highexciter")
            }
            settings.dspModel = model
        case "--exciter-os":
            guard let value = iterator.next() else {
                throw AppError.message("--exciter-os needs auto, 1x, 2x, or 4x")
            }
            switch value.lowercased() {
            case "auto": settings.exciterOversamplingMode = .auto
            case "1", "1x": settings.exciterOversamplingMode = .one
            case "2", "2x": settings.exciterOversamplingMode = .two
            case "4", "4x": settings.exciterOversamplingMode = .four
            default:
                throw AppError.message("--exciter-os needs auto, 1x, 2x, or 4x")
            }
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
        case "--self-test":
            settings.mode = .selfTest
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

private final class AudioSpectrumAnalyzer: NSObject {
    private static let fftSize = 16384
    private static let halfSize = 8192
    private static let barCount = 128

    private let ringBuffer: LockFreeFloatRingBuffer
    private let dynamicsModel: DynamicsMeterModel
    private let spectrumModel: SpectrumModel
    private let fftSize = AudioSpectrumAnalyzer.fftSize
    private let halfSize = AudioSpectrumAnalyzer.halfSize
    private let log2n = vDSP_Length(14)
    private let barCount = AudioSpectrumAnalyzer.barCount
    private var sampleRate: Float
    private var timer: Timer?
    private var fftSetup: FFTSetup?
    private var drainBuffer = [Float](repeating: 0, count: 32_768)
    private var history = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize)
    private var window = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize)
    private var windowed = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize)
    private var real = [Float](repeating: 0, count: AudioSpectrumAnalyzer.halfSize)
    private var imag = [Float](repeating: 0, count: AudioSpectrumAnalyzer.halfSize)
    private var powerBins = [Float](repeating: 0, count: AudioSpectrumAnalyzer.halfSize)
    private var dbBins = [Float](repeating: -120, count: AudioSpectrumAnalyzer.halfSize)
    private var magnitudes = [Float](repeating: 0, count: AudioSpectrumAnalyzer.barCount)
    private var binCenters = [Float](repeating: 1, count: AudioSpectrumAnalyzer.barCount)
    private var filledSamples = 0
    private var smoothedPeakDb: Float = -100
    private var smoothedRMSDb: Float = -100
    private var smoothedCrestDb: Float = 0
    private var dynamicsPublishCounter = 0
    private let levelReleaseDbPerTick: Float = 1.10
    private let crestReleaseDbPerTick: Float = 0.40

    init(ringBuffer: LockFreeFloatRingBuffer,
         sampleRate: Float,
         dynamicsModel: DynamicsMeterModel,
         spectrumModel: SpectrumModel) {
        self.ringBuffer = ringBuffer
        self.dynamicsModel = dynamicsModel
        self.spectrumModel = spectrumModel
        self.sampleRate = sampleRate
        super.init()
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        rebuildLogBins()
    }

    deinit {
        stop()
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func start() {
        stop()
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .modalPanel)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateSampleRate(_ sampleRate: Float) {
        self.sampleRate = sampleRate
        rebuildLogBins()
    }

    @objc private func tick() {
        guard drainAudio(),
              spectrumModel.isAnalysisActive,
              filledSamples >= fftSize else { return }
        computeSpectrum()
        spectrumModel.publish(magnitudes)
    }

    @discardableResult
    private func drainAudio() -> Bool {
        let available = min(ringBuffer.availableSamples(), drainBuffer.count)
        let sampleCount = available - (available % 2)
        guard sampleCount >= 2 else { return false }

        drainBuffer.withUnsafeMutableBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                ringBuffer.popInterleaved(into: baseAddress, count: sampleCount)
            }
        }
        updateDynamics(sampleCount: sampleCount)

        let frameCount = sampleCount / 2
        if frameCount >= fftSize {
            let startFrame = frameCount - fftSize
            downmixStereo(
                sourceStartFrame: startFrame,
                destinationStartFrame: 0,
                frameCount: fftSize
            )
            filledSamples = fftSize
            return true
        }

        let keepCount = fftSize - frameCount
        history.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            memmove(
                baseAddress,
                baseAddress.advanced(by: frameCount),
                keepCount * MemoryLayout<Float>.stride
            )
        }
        downmixStereo(
            sourceStartFrame: 0,
            destinationStartFrame: keepCount,
            frameCount: frameCount
        )
        filledSamples = min(fftSize, filledSamples + frameCount)
        return true
    }

    private func downmixStereo(
        sourceStartFrame: Int,
        destinationStartFrame: Int,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        drainBuffer.withUnsafeBufferPointer { sourcePointer in
            history.withUnsafeMutableBufferPointer { destinationPointer in
                guard let sourceBase = sourcePointer.baseAddress,
                      let destinationBase = destinationPointer.baseAddress else { return }
                let left = sourceBase.advanced(by: sourceStartFrame * 2)
                let right = left.advanced(by: 1)
                let destination = destinationBase.advanced(by: destinationStartFrame)
                let count = vDSP_Length(frameCount)
                var half: Float = 0.5
                vDSP_vadd(left, 2, right, 2, destination, 1, count)
                vDSP_vsmul(destination, 1, &half, destination, 1, count)
            }
        }
    }

    private func computeSpectrum() {
        guard let fftSetup else { return }

        vDSP_vmul(history, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        windowed.withUnsafeBufferPointer { windowPointer in
            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    guard let windowBase = windowPointer.baseAddress,
                          let realBase = realPointer.baseAddress,
                          let imagBase = imagPointer.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)

                    windowBase.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfSize))
                    }

                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    var scale = 1 / Float(fftSize)
                    vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(halfSize))
                    vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(halfSize))

                    powerBins.withUnsafeMutableBufferPointer { powerPointer in
                        guard let powerBase = powerPointer.baseAddress else { return }
                        vDSP_zvmags(&split, 1, powerBase, 1, vDSP_Length(halfSize))
                    }
                }
            }
        }

        var floor: Float = 1.0e-12
        vDSP_vthr(powerBins, 1, &floor, &powerBins, 1, vDSP_Length(halfSize))
        var reference: Float = 1
        vDSP_vdbcon(powerBins, 1, &reference, &dbBins, 1, vDSP_Length(halfSize), 0)

        for bar in 0..<barCount {
            let sampledDb = interpolatedDb(at: binCenters[bar])
            let normalized = clamp((sampledDb + 96) / 78, 0, 1)
            magnitudes[bar] = magnitudes[bar] * 0.68 + normalized * 0.32
        }
    }

    private func interpolatedDb(at fractionalBin: Float) -> Float {
        let clampedBin = clamp(fractionalBin, 1, Float(halfSize - 2))
        let lowerIndex = Int(clampedBin)
        let upperIndex = lowerIndex + 1
        let fraction = clampedBin - Float(lowerIndex)
        let lower = dbBins[lowerIndex]
        let upper = dbBins[upperIndex]
        return lower + (upper - lower) * fraction
    }

    private func updateDynamics(sampleCount: Int) {
        var peak: Float = 0
        var rms: Float = 0

        drainBuffer.withUnsafeBufferPointer { sourcePointer in
            guard let sourceBase = sourcePointer.baseAddress else { return }
            let count = vDSP_Length(sampleCount)
            vDSP_maxmgv(sourceBase, 1, &peak, count)
            vDSP_rmsqv(sourceBase, 1, &rms, count)
        }

        let peakDb = amplitudeToDb(peak)
        let rmsDb = amplitudeToDb(rms)
        let crestDb = max(0, peakDb - rmsDb)

        smoothedPeakDb = releaseSmooth(current: smoothedPeakDb, target: peakDb, step: levelReleaseDbPerTick)
        smoothedRMSDb = releaseSmooth(current: smoothedRMSDb, target: rmsDb, step: levelReleaseDbPerTick)
        smoothedCrestDb = releaseSmooth(current: smoothedCrestDb, target: crestDb, step: crestReleaseDbPerTick)

        dynamicsPublishCounter += 1
        if dynamicsPublishCounter >= 2 {
            dynamicsPublishCounter = 0
            dynamicsModel.update(peak: smoothedPeakDb, rms: smoothedRMSDb, crestFactor: smoothedCrestDb)
        }
    }

    private func amplitudeToDb(_ value: Float) -> Float {
        let clamped = max(value, 0.00001)
        return max(20 * log10(clamped), -100)
    }

    private func releaseSmooth(current: Float, target: Float, step: Float) -> Float {
        if target >= current {
            return target
        }
        return max(current - step, target)
    }

    private func rebuildLogBins() {
        let nyquist = max(sampleRate * 0.5, 1_000)
        let minHz: Float = 28
        let bassMaxHz: Float = min(420, nyquist * 0.75)
        let maxHz = min(nyquist, 20_000)
        let bassBarRatio: Float = 0.38
        let bassCurve: Float = 0.82
        let minLog = log(max(bassMaxHz, minHz + 1))
        let maxLog = log(max(maxHz, bassMaxHz + 1))

        for bar in 0..<barCount {
            let ratio = (Float(bar) + 0.5) / Float(barCount)
            let centerHz: Float
            if ratio < bassBarRatio {
                let bassRatio = ratio / bassBarRatio
                centerHz = minHz + pow(bassRatio, bassCurve) * (bassMaxHz - minHz)
            } else {
                let trebleRatio = (ratio - bassBarRatio) / (1 - bassBarRatio)
                centerHz = exp(minLog + (maxLog - minLog) * trebleRatio)
            }
            binCenters[bar] = clamp((centerHz / sampleRate) * Float(fftSize), 1, Float(halfSize - 2))
        }
    }
}

@available(macOS 14.4, *)
@MainActor
private final class NativeAppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private var statusLabel: NSTextField!
    private var sourceFormatLabel: NSTextField!
    private var formatLabel: NSTextField!
    private var oversamplingLabel: NSTextField!
    private var rateMatchPreviewLabel: NSTextField!
    private var diagnosticsLabel: NSTextField!
    private var automaticRateMatchButton: NSButton!
    private var rightPanelView: NSHostingView<AnyView>!
    private var bundleField: NSTextField!
    private var appsView: NSTextView!
    private var intensitySlider: NSSlider!
    private var bodySlider: NSSlider!
    private var outputSlider: NSSlider!
    private var intensityNameLabel: NSTextField!
    private var bodyNameLabel: NSTextField!
    private var outputNameLabel: NSTextField!
    private var intensityValueLabel: NSTextField!
    private var bodyValueLabel: NSTextField!
    private var outputValueLabel: NSTextField!
    private var modelPopup: NSPopUpButton!
    private var oversamplingModeLabel: NSTextField!
    private var oversamplingModeControl: NSSegmentedControl!
    private var presetButtons: [NSButton] = []
    private var spatialEnabledButton: NSButton!
    private var spatialStageView: SpatialStageView!
    private var listenerXField: NSTextField!
    private var listenerZField: NSTextField!
    private var speakerWidthField: NSTextField!
    private var spatialAmountSlider: NSSlider!
    private var spatialAmountValueLabel: NSTextField!
    private var processor: SystemAudioProcessor?
    private var spectrumAnalyzer: AudioSpectrumAnalyzer?
    private var sourceFormatTracker: SourceFormatTracker?
    private var diagnosticsTimer: Timer?
    private let dynamicsMeterModel = DynamicsMeterModel()
    private let spectrumModel = SpectrumModel()
    private let spatialControlModel = SpatialControlModel()
    private var currentProcessingSampleRate: Double?
    private var currentSourceSampleRate: Double?
    private var currentDeviceSampleRate: Double?
    private var supportedDeviceSampleRates: [Double] = []
    private var isDeviceSampleRateSettable = false
    private var automaticRateMatchingEnabled = UserDefaults.standard.bool(
        forKey: "automaticRateMatchingEnabled"
    )
    private var rateMatchStatusText = "Auto OFF"
    private var exciterOversamplingMode: ExciterOversamplingMode = {
        let rawValue = UInt32(UserDefaults.standard.integer(forKey: "exciterOversamplingMode"))
        return ExciterOversamplingMode(rawValue: rawValue) ?? .auto
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        rateMatchStatusText = automaticRateMatchingEnabled
            ? "Auto ON: source 안정화 대기"
            : "Auto OFF"
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioFormatDidChange(_:)),
            name: AudioFormatNotifications.didChange,
            object: nil
        )
        buildWindow()
        refreshRateMatchDeviceCapabilities()
        startSourceFormatTracking()
    }

    deinit {
        sourceFormatTracker?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        stopAudio()
        return .terminateNow
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

        sourceFormatLabel = makeLabel("Source: Apple Music/TIDAL 대기 중", size: 12.5, weight: .semibold)
        sourceFormatLabel.alignment = .right
        sourceFormatLabel.frame = NSRect(x: 740, y: 710, width: 430, height: 20)
        sourceFormatLabel.toolTip = "플레이어 메타데이터 또는 Unified Log에서 감지한 원본 스트림 정보입니다. 확인할 수 없는 값은 추정하지 않고 unknown으로 표시합니다."
        content.addSubview(sourceFormatLabel)

        formatLabel = makeLabel("처리 포맷 대기 중", size: 12, weight: .semibold)
        formatLabel.alignment = .right
        formatLabel.frame = NSRect(x: 740, y: 688, width: 430, height: 20)
        formatLabel.toolTip = "Tap은 Core Audio 공유 믹서에서 캡처한 PCM, Engine은 DSP 처리율, DAC는 출력 장치 레이트입니다."
        content.addSubview(formatLabel)

        oversamplingLabel = makeLabel("", size: 12, weight: .semibold)
        oversamplingLabel.alignment = .right
        oversamplingLabel.frame = NSRect(x: 740, y: 666, width: 430, height: 20)
        oversamplingLabel.toolTip = "전체 음원을 업스케일링하는 기능이 아니라 HighExciter의 비선형 배음 생성 구간에만 적용되는 내부 오버샘플링 상태입니다. Tap 값은 공유 시스템 PCM 처리율입니다."
        oversamplingLabel.isHidden = true
        content.addSubview(oversamplingLabel)

        rateMatchPreviewLabel = makeLabel("Rate Match Preview: source waiting", size: 11.5, weight: .medium)
        rateMatchPreviewLabel.alignment = .right
        rateMatchPreviewLabel.frame = NSRect(x: 740, y: 644, width: 430, height: 18)
        rateMatchPreviewLabel.textColor = NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.75, alpha: 1)
        rateMatchPreviewLabel.toolTip = "원본 음원의 rate와 DAC 지원 rate를 비교한 미리보기입니다. 이 표시만으로 장치 설정을 변경하지 않습니다."
        content.addSubview(rateMatchPreviewLabel)

        rightPanelView = NSHostingView(rootView: AnyView(
            RightPanelContainerView(
                spatialModel: spatialControlModel,
                dynamicsModel: dynamicsMeterModel,
                spectrumModel: spectrumModel,
                onSpatialChange: { [weak self] settings in
                    self?.updateSpatialControls(from: settings, notifyProcessor: true)
                }
            )
        ))
        rightPanelView.frame = NSRect(x: 740, y: 28, width: 430, height: 606)
        rightPanelView.wantsLayer = true
        rightPanelView.layer?.cornerRadius = 8
        content.addSubview(rightPanelView)

        statusLabel = makeLabel("대기 중", size: 14, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.frame = NSRect(x: 30, y: 638, width: 440, height: 26)
        content.addSubview(statusLabel)

        diagnosticsLabel = makeLabel("XRuns 대기 중", size: 10, weight: .regular)
        diagnosticsLabel.textColor = NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.67, alpha: 1)
        diagnosticsLabel.frame = NSRect(x: 30, y: 620, width: 680, height: 16)
        diagnosticsLabel.lineBreakMode = .byTruncatingMiddle
        diagnosticsLabel.toolTip = "출력 underrun, 출력/분석 버퍼 drop, 엔진 재시작 횟수와 실제 캡처 프로세스를 표시합니다."
        content.addSubview(diagnosticsLabel)

        automaticRateMatchButton = NSButton(
            checkboxWithTitle: "자동 Rate Match",
            target: self,
            action: #selector(automaticRateMatchChanged)
        )
        automaticRateMatchButton.frame = NSRect(x: 370, y: 295, width: 180, height: 24)
        automaticRateMatchButton.state = automaticRateMatchingEnabled ? .on : .off
        automaticRateMatchButton.toolTip = "감지된 Apple Music/TIDAL Source rate에 맞춰 기본 출력 DAC의 Nominal Sample Rate를 변경합니다. 기본값은 OFF입니다."
        content.addSubview(automaticRateMatchButton)

        let modelLabel = makeLabel("Model", size: 13, weight: .semibold)
        modelLabel.frame = NSRect(x: 498, y: 638, width: 52, height: 26)
        content.addSubview(modelLabel)

        modelPopup = NSPopUpButton(frame: NSRect(x: 552, y: 635, width: 158, height: 30), pullsDown: false)
        modelPopup.addItems(withTitles: ["Clean", "Circuit", "HighExciter"])
        modelPopup.selectItem(withTitle: "Circuit")
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.toolTip = "Clean은 DSP bypass, Circuit은 저역 회로 모델, HighExciter는 독립 고역 배음 모델입니다."
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
            "Tidal Exclusive Mode처럼 출력 장치를 독점하는 모드는 우회될 수 있습니다."
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

        intensityNameLabel = addSliderRow(to: view, y: 86, title: "LowEnd", slider: intensitySlider, valueLabel: intensityValueLabel)
        bodyNameLabel = addSliderRow(to: view, y: 48, title: "Body", slider: bodySlider, valueLabel: bodyValueLabel)
        outputNameLabel = addSliderRow(to: view, y: 10, title: "Output", slider: outputSlider, valueLabel: outputValueLabel)

        oversamplingModeLabel = makeLabel("Oversampling", size: 13, weight: .semibold)
        oversamplingModeLabel.frame = NSRect(x: 16, y: 10, width: 110, height: 24)
        oversamplingModeControl = NSSegmentedControl(
            labels: ExciterOversamplingMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(oversamplingModeChanged)
        )
        oversamplingModeControl.frame = NSRect(x: 140, y: 7, width: 430, height: 28)
        oversamplingModeControl.selectedSegment = segmentIndex(for: exciterOversamplingMode)
        oversamplingModeControl.toolTip = "Auto는 Engine 처리율에 맞춰 배수를 선택합니다. 수동 선택은 384 kHz 이상의 Engine 처리율에 추가 오버샘플링을 하지 않도록 제한됩니다."
        view.addSubview(oversamplingModeLabel)
        view.addSubview(oversamplingModeControl)
        configureControlsForSelectedModel()
        return view
    }

    private func makePresetSection() -> NSView {
        let view = NSView(frame: .zero)
        presetButtons = [
            makeButton("IEM", action: #selector(applyIEMPreset)),
            makeButton("Gentle", action: #selector(applyGentlePreset)),
            makeButton("LowEnd", action: #selector(applyLowEndPreset)),
            makeButton("Deep", action: #selector(applyDeepPreset)),
            makeButton("Clear", action: #selector(applyClearPreset))
        ]

        let gap: CGFloat = 10
        let width = (680.0 - gap * 4) / 5
        for index in 0..<presetButtons.count {
            presetButtons[index].frame = NSRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: 36)
            view.addSubview(presetButtons[index])
        }
        configurePresetButtons()

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

    @discardableResult
    private func addSliderRow(to view: NSView, y: CGFloat, title: String, slider: NSSlider, valueLabel: NSTextField) -> NSTextField {
        let label = makeLabel(title, size: 13, weight: .semibold)
        label.frame = NSRect(x: 18, y: y, width: 108, height: 24)
        slider.frame = NSRect(x: 132, y: y, width: 384, height: 24)
        valueLabel.frame = NSRect(x: 530, y: y, width: 92, height: 24)
        view.addSubview(label)
        view.addSubview(slider)
        view.addSubview(valueLabel)
        return label
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
        updateOversamplingIndicator()
        processor?.updateDSP(intensity: Float(intensitySlider.doubleValue),
                             body: Float(bodySlider.doubleValue),
                             outputDb: Float(outputSlider.doubleValue),
                             dspModel: selectedDSPModel(),
                             exciterOversamplingMode: exciterOversamplingMode)
    }

    @objc private func oversamplingModeChanged() {
        let modes = ExciterOversamplingMode.allCases
        let index = oversamplingModeControl.selectedSegment
        guard modes.indices.contains(index) else { return }
        exciterOversamplingMode = modes[index]
        UserDefaults.standard.set(
            Int(exciterOversamplingMode.rawValue),
            forKey: "exciterOversamplingMode"
        )
        sliderChanged()
    }

    @objc private func automaticRateMatchChanged() {
        automaticRateMatchingEnabled = automaticRateMatchButton.state == .on
        UserDefaults.standard.set(
            automaticRateMatchingEnabled,
            forKey: "automaticRateMatchingEnabled"
        )
        rateMatchStatusText = automaticRateMatchingEnabled ? "Auto ON: source 안정화 대기" : "Auto OFF"
        updateRateMatchPreview()
        processor?.setAutomaticRateMatchingEnabled(automaticRateMatchingEnabled)
    }

    @objc private func spatialControlChanged() {
        updateSpatialControls(from: spatialControlModel.settings, notifyProcessor: true)
    }

    @objc private func spatialFieldChanged() {
        spatialControlChanged()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        spatialControlChanged()
    }

    private func spatialStageChanged(_ settings: SpatialSettings) {
        var updated = spatialControlModel.settings
        updated.listenerX = settings.listenerX
        updated.listenerZ = settings.listenerZ
        updateSpatialControls(from: updated, notifyProcessor: true)
    }

    @objc private func resetSpatialPosition() {
        var updated = spatialControlModel.settings
        updated.listenerX = 0
        updated.listenerZ = 0
        updateSpatialControls(from: updated, notifyProcessor: true)
        statusLabel.stringValue = "공간음향 위치를 원위치로 되돌렸습니다."
    }

    @objc private func modelChanged() {
        configureControlsForSelectedModel()
        sliderChanged()
        statusLabel.stringValue = "모델 변경: \(selectedDSPModel().displayName)"
    }

    private func configureControlsForSelectedModel() {
        guard intensitySlider != nil,
              bodySlider != nil,
              outputSlider != nil,
              intensityNameLabel != nil,
              bodyNameLabel != nil,
              outputNameLabel != nil else { return }

        switch selectedDSPModel() {
        case .clean:
            intensityNameLabel.stringValue = "Bypass"
            bodyNameLabel.stringValue = "Bypass"
            outputNameLabel.stringValue = "Output"
            intensitySlider.isEnabled = false
            bodySlider.isEnabled = false
            outputSlider.isEnabled = false
            intensitySlider.toolTip = "Clean 모델에서는 DSP 처리를 완전히 우회합니다."
            bodySlider.toolTip = "Clean 모델에서는 DSP 처리를 완전히 우회합니다."
            outputSlider.toolTip = "Clean 모델에서는 출력 게인도 적용하지 않습니다."
            setOversamplingControlsVisible(false)
        case .circuit:
            intensityNameLabel.stringValue = "LowEnd"
            bodyNameLabel.stringValue = "Body"
            outputNameLabel.stringValue = "Output"
            intensitySlider.isEnabled = true
            bodySlider.isEnabled = true
            outputSlider.isEnabled = true
            intensitySlider.toolTip = "저역 부스트의 강도입니다. 높일수록 베이스가 앞으로 나옵니다."
            bodySlider.toolTip = "서브 저역의 두께감입니다. 높일수록 묵직하지만 과하면 부풀 수 있습니다."
            outputSlider.toolTip = "Circuit 모델의 최종 출력 보정입니다. 저역을 많이 올릴수록 낮춰두는 편이 안전합니다."
            setOversamplingControlsVisible(false)
        case .highExciter:
            intensityNameLabel.stringValue = "Exciter Drive"
            bodyNameLabel.stringValue = "Wet Mix"
            outputNameLabel.stringValue = "Output"
            intensitySlider.isEnabled = true
            bodySlider.isEnabled = true
            outputSlider.isEnabled = false
            intensitySlider.toolTip = "11 kHz 이상 고역 성분에 적용할 배음 생성 drive입니다."
            bodySlider.toolTip = "원본 신호에 병렬로 더할 고역 배음 wet mix입니다."
            outputSlider.toolTip = "HighExciter 모델은 dry 신호 보존을 위해 출력 게인을 적용하지 않습니다."
            setOversamplingControlsVisible(true)
        }

        configurePresetButtons()
        updateSliderLabels()
    }

    private func setOversamplingControlsVisible(_ isVisible: Bool) {
        oversamplingModeLabel?.isHidden = !isVisible
        oversamplingModeControl?.isHidden = !isVisible
        outputNameLabel?.isHidden = isVisible
        outputSlider?.isHidden = isVisible
        outputValueLabel?.isHidden = isVisible
    }

    private func segmentIndex(for mode: ExciterOversamplingMode) -> Int {
        ExciterOversamplingMode.allCases.firstIndex(of: mode) ?? 0
    }

    private struct ModelPreset {
        let name: String
        let primary: Double
        let secondary: Double
        let outputDb: Double?
        let toolTip: String
    }

    private func presets(for model: Settings.DSPModel) -> [ModelPreset] {
        switch model {
        case .clean:
            return []
        case .circuit:
            return [
                ModelPreset(name: "IEM", primary: 30, secondary: 8, outputDb: -2.0,
                            toolTip: "민감한 이어폰용입니다. 낮은 포화와 충분한 헤드룸을 둡니다."),
                ModelPreset(name: "Gentle", primary: 22, secondary: 8, outputDb: -1.0,
                            toolTip: "가볍게 저역만 보강합니다."),
                ModelPreset(name: "LowEnd", primary: 42, secondary: 18, outputDb: -1.8,
                            toolTip: "일반적인 저역 보강 시작점입니다."),
                ModelPreset(name: "Deep", primary: 54, secondary: 22, outputDb: -2.8,
                            toolTip: "서브 저역을 더 강조하고 출력 헤드룸을 확보합니다."),
                ModelPreset(name: "Clear", primary: 0, secondary: 0, outputDb: 0,
                            toolTip: "Circuit 파라미터를 0으로 되돌리는 기준점입니다.")
            ]
        case .highExciter:
            return [
                ModelPreset(name: "Soft", primary: 12, secondary: 4, outputDb: nil,
                            toolTip: "고역 배음을 아주 약하게 더합니다."),
                ModelPreset(name: "Air", primary: 22, secondary: 7, outputDb: nil,
                            toolTip: "공기감과 초고역의 개방감을 가볍게 더합니다."),
                ModelPreset(name: "Detail", primary: 35, secondary: 11, outputDb: nil,
                            toolTip: "보컬과 악기의 미세한 고역 디테일을 강조합니다."),
                ModelPreset(name: "Shimmer", primary: 50, secondary: 16, outputDb: nil,
                            toolTip: "고역 배음 효과를 더 분명하게 들려줍니다."),
                ModelPreset(name: "Off", primary: 0, secondary: 0, outputDb: nil,
                            toolTip: "HighExciter 배음 처리를 끕니다.")
            ]
        }
    }

    private func configurePresetButtons() {
        guard !presetButtons.isEmpty else { return }

        let model = selectedDSPModel()
        let modelPresets = presets(for: model)
        for index in 0..<presetButtons.count {
            let button = presetButtons[index]
            guard index < modelPresets.count else {
                button.title = "-"
                button.isEnabled = false
                button.toolTip = "Clean 모델은 완전한 bypass이므로 프리셋을 적용하지 않습니다."
                continue
            }

            button.title = modelPresets[index].name
            button.isEnabled = true
            button.toolTip = modelPresets[index].toolTip
        }
    }

    private func updateSliderLabels() {
        switch selectedDSPModel() {
        case .clean:
            intensityValueLabel.stringValue = "Off"
            bodyValueLabel.stringValue = "Off"
            outputValueLabel.stringValue = "Bypass"
        case .circuit:
            intensityValueLabel.stringValue = "\(Int(intensitySlider.doubleValue.rounded()))%"
            bodyValueLabel.stringValue = "\(Int(bodySlider.doubleValue.rounded()))%"
            outputValueLabel.stringValue = String(format: "%.1f dB", outputSlider.doubleValue)
        case .highExciter:
            intensityValueLabel.stringValue = String(format: "%.2f", intensitySlider.doubleValue / 100)
            bodyValueLabel.stringValue = String(format: "%.2f", bodySlider.doubleValue / 100)
            outputValueLabel.stringValue = "Bypass"
        }
    }

    private func updateOversamplingIndicator() {
        guard oversamplingLabel != nil else { return }
        guard selectedDSPModel() == .highExciter else {
            oversamplingLabel.isHidden = true
            return
        }

        oversamplingLabel.isHidden = false
        let driveActive = intensitySlider.doubleValue >= 0.01
        let wetActive = bodySlider.doubleValue >= 0.01
        guard driveActive && wetActive else {
            oversamplingLabel.stringValue = "HighExciter | Oversampling idle"
            oversamplingLabel.textColor = NSColor(calibratedRed: 0.55, green: 0.58, blue: 0.63, alpha: 1)
            return
        }

        guard let sampleRate = currentProcessingSampleRate else {
            oversamplingLabel.stringValue = "HighExciter | Oversampling format waiting"
            oversamplingLabel.textColor = NSColor(calibratedRed: 0.55, green: 0.74, blue: 0.82, alpha: 1)
            return
        }

        let resolution = ExciterOversamplingPolicy.resolve(
            processingSampleRate: sampleRate,
            mode: exciterOversamplingMode
        )
        oversamplingLabel.stringValue = ExciterOversamplingPolicy.indicator(resolution)
        oversamplingLabel.textColor = NSColor(calibratedRed: 0.31, green: 0.78, blue: 0.94, alpha: 1)
    }

    private func spatialSettingsFromControls() -> SpatialSettings {
        spatialControlModel.settings
    }

    private func updateSpatialControls(from settings: SpatialSettings, notifyProcessor: Bool) {
        spatialControlModel.update(settings)
        spatialEnabledButton?.state = spatialControlModel.settings.enabled ? .on : .off
        listenerXField?.stringValue = String(format: "%.2f", spatialControlModel.settings.listenerX)
        listenerZField?.stringValue = String(format: "%.2f", spatialControlModel.settings.listenerZ)
        speakerWidthField?.stringValue = String(format: "%.2f", spatialControlModel.settings.speakerWidth)
        spatialAmountSlider?.doubleValue = Double(spatialControlModel.settings.amount)
        spatialAmountValueLabel?.stringValue = "\(Int(spatialControlModel.settings.amount.rounded()))%"
        spatialStageView?.setSettings(spatialControlModel.settings)

        if notifyProcessor {
            processor?.updateSpatial(spatialControlModel.settings)
        }
    }

    @objc private func applyIEMPreset() {
        applyPreset(at: 0)
    }

    @objc private func applyGentlePreset() {
        applyPreset(at: 1)
    }

    @objc private func applyLowEndPreset() {
        applyPreset(at: 2)
    }

    @objc private func applyDeepPreset() {
        applyPreset(at: 3)
    }

    @objc private func applyClearPreset() {
        applyPreset(at: 4)
    }

    private func applyPreset(at index: Int) {
        let model = selectedDSPModel()
        let modelPresets = presets(for: model)
        guard model != .clean, index >= 0, index < modelPresets.count else { return }

        let preset = modelPresets[index]
        intensitySlider.doubleValue = preset.primary
        bodySlider.doubleValue = preset.secondary
        if model == .circuit, let outputDb = preset.outputDb {
            outputSlider.doubleValue = outputDb
        }
        sliderChanged()
        statusLabel.stringValue = "\(model.displayName) 프리셋 적용: \(preset.name)"
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
                 exciterOversamplingMode: exciterOversamplingMode,
                 automaticRateMatchingEnabled: automaticRateMatchingEnabled,
                 spatial: spatialSettingsFromControls())
    }

    private func selectedDSPModel() -> Settings.DSPModel {
        switch modelPopup.indexOfSelectedItem {
        case 1:
            return .circuit
        case 2:
            return .highExciter
        default:
            return .clean
        }
    }

    private func start(_ settings: Settings) {
        stopAudio()

        do {
            let processor = try SystemAudioProcessor(settings: settings)
            try processor.start()
            self.processor = processor
            let analyzer = processor.makeSpectrumAnalyzer(
                dynamicsModel: dynamicsMeterModel,
                spectrumModel: spectrumModel
            )
            analyzer.start()
            self.spectrumAnalyzer = analyzer
            statusLabel.stringValue = "처리 중: \(processor.captureTargetSummary)"
            startDiagnosticsTimer()
        } catch {
            statusLabel.stringValue = "실행 실패: \(error)"
            self.processor = nil
            self.spectrumAnalyzer = nil
        }
    }

    @objc private func stopAudio() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        spectrumAnalyzer?.stop()
        spectrumAnalyzer = nil
        dynamicsMeterModel.reset()
        spectrumModel.reset()
        processor?.stop()
        processor = nil
        if statusLabel != nil {
            statusLabel.stringValue = "중지됨"
        }
        if formatLabel != nil {
            formatLabel.stringValue = "처리 포맷 대기 중"
        }
        diagnosticsLabel?.stringValue = "XRuns 대기 중"
        currentProcessingSampleRate = nil
        updateOversamplingIndicator()
    }

    private func startDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(updateDiagnostics),
            userInfo: nil,
            repeats: true
        )
    }

    private func startSourceFormatTracking() {
        let tracker = SourceFormatTracker(
            onUpdate: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sourceFormatLabel?.stringValue = snapshot.indicatorText
                    self.sourceFormatLabel?.toolTip = snapshot.indicatorText
                    self.currentSourceSampleRate = snapshot.format?.sampleRate
                    self.updateRateMatchPreview()
                }
            },
            onObservation: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.processor?.observeSourceFormat(snapshot.format)
                }
            }
        )
        sourceFormatTracker = tracker
        tracker.start()
    }

    @objc private func updateDiagnostics() {
        guard let processor else { return }
        let snapshot = processor.diagnosticsSnapshot()
        diagnosticsLabel.stringValue = snapshot.displayText
        diagnosticsLabel.toolTip = snapshot.displayText
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

    @objc private func audioFormatDidChange(_ notification: Notification) {
        guard let text = notification.userInfo?[AudioFormatNotifications.indicatorTextKey] as? String else {
            return
        }
        formatLabel?.stringValue = text

        if let sampleRate = notification.userInfo?[AudioFormatNotifications.processingSampleRateKey] as? Double {
            currentProcessingSampleRate = sampleRate
            spectrumAnalyzer?.updateSampleRate(Float(sampleRate))
        }
        currentDeviceSampleRate = notification.userInfo?[AudioFormatNotifications.sampleRateKey] as? Double
        supportedDeviceSampleRates =
            notification.userInfo?[AudioFormatNotifications.supportedSampleRatesKey] as? [Double]
            ?? supportedDeviceSampleRates
        isDeviceSampleRateSettable =
            notification.userInfo?[AudioFormatNotifications.isSampleRateSettableKey] as? Bool
            ?? isDeviceSampleRateSettable
        if let enabled =
            notification.userInfo?[AudioFormatNotifications.automaticRateMatchingEnabledKey] as? Bool {
            automaticRateMatchingEnabled = enabled
            automaticRateMatchButton?.state = enabled ? .on : .off
        }
        rateMatchStatusText =
            notification.userInfo?[AudioFormatNotifications.rateMatchStatusKey] as? String
            ?? rateMatchStatusText
        updateRateMatchPreview()
        updateOversamplingIndicator()
    }

    private func refreshRateMatchDeviceCapabilities() {
        do {
            let deviceID = try HardwareSampleRateTracker.defaultOutputDevice()
            let capabilities = try HardwareSampleRateTracker.rateCapabilities(for: deviceID)
            currentDeviceSampleRate = try HardwareSampleRateTracker.nominalSampleRate(for: deviceID)
            supportedDeviceSampleRates = capabilities.supportedRates
            isDeviceSampleRateSettable = capabilities.isSettable
        } catch {
            currentDeviceSampleRate = nil
            supportedDeviceSampleRates = []
            isDeviceSampleRateSettable = false
        }
        updateRateMatchPreview()
    }

    private func updateRateMatchPreview() {
        let preview = SourceRateMatchPolicy.preview(
            sourceRate: currentSourceSampleRate,
            currentDeviceRate: currentDeviceSampleRate,
            supportedRates: supportedDeviceSampleRates,
            isDeviceRateSettable: isDeviceSampleRateSettable
        )
        rateMatchPreviewLabel?.stringValue = "\(preview.indicatorText) | \(rateMatchStatusText)"
        rateMatchPreviewLabel?.toolTip =
            "\(preview.indicatorText)\n자동 Rate Matching: \(rateMatchStatusText)"
    }

}

private var nativeAppDelegateHolder: AnyObject?

@available(macOS 14.4, *)
@MainActor
private func launchGUI() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    installMainMenu(for: app)
    let delegate = NativeAppDelegate()
    nativeAppDelegateHolder = delegate
    app.delegate = delegate
    app.finishLaunching()
    app.run()
    exit(0)
}

@available(macOS 14.4, *)
@MainActor
private func installMainMenu(for app: NSApplication) {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: "LowEnd Native Audio")
    let quitItem = NSMenuItem(
        title: "LowEnd Native Audio 종료",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    quitItem.target = app
    appMenu.addItem(quitItem)
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)
    app.mainMenu = mainMenu
}

private func printUsageAndExit() -> Never {
    print("""
    SystemAudioProcessor

    Usage:
      SystemAudioProcessor --all
      SystemAudioProcessor --bundle-id com.spotify.client
      SystemAudioProcessor --list-apps
      SystemAudioProcessor --self-test

    Options:
      --intensity 0...100
      --body 0...100
      --output dB
      --model clean|circuit|highexciter
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

    func droppedWriteSamples() -> UInt64 {
        lc_ring_buffer_dropped_write_samples(handle)
    }

    func underrunSamples() -> UInt64 {
        lc_ring_buffer_underrun_samples(handle)
    }

    func resetDiagnostics() {
        lc_ring_buffer_reset_diagnostics(handle)
    }

    func availableSamples() -> Int {
        Int(lc_ring_buffer_available(handle))
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
    private var sampleRate: Float

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

    func updateSampleRate(_ sampleRate: Float) {
        self.sampleRate = sampleRate
    }

    func pushDSP(intensity: Float,
                 body: Float,
                 outputDb: Float,
                 dspModel: Settings.DSPModel,
                 exciterOversamplingMode: ExciterOversamplingMode) {
        var event = LCControlEvent()
        event.type = UInt32(LC_CONTROL_EVENT_DSP)
        event.dsp = DSPPrecompute.makeDSPSettings(
            sampleRate: sampleRate,
            intensity: intensity,
            body: body,
            outputDb: outputDb,
            dspModel: dspModel,
            exciterOversamplingMode: exciterOversamplingMode
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

    func drain() {
        var event = LCControlEvent()
        while pop(into: &event) {}
    }
}

enum DSPPrecompute {
    static func makeDSPSettings(sampleRate: Float,
                                intensity: Float,
                                body: Float,
                                outputDb: Float,
                                dspModel: Settings.DSPModel,
                                exciterOversamplingMode: ExciterOversamplingMode = .auto) -> LCDSPSettings {
        let normalIntensity = clamp(intensity / 100, 0, 1)
        let normalBody = clamp(body / 100, 0, 1)
        let shelfDb = normalIntensity * 6.5
        let shelfFreq = 68 + normalIntensity * 24
        let outputGain = pow(10, outputDb / 20)
        let transformerShelfDb = 0.7 + normalIntensity * 2.2 + normalBody * 0.7
        let transformerShelfFreq = 78 + normalIntensity * 10 + normalBody * 24
        let transformerDrive = 1.0 + normalIntensity * 0.24 + normalBody * 0.08
        let transformerAsymmetry = 0.002 + normalIntensity * 0.008 + normalBody * 0.004
        let transformerBiasOffset = makePolynomialSoftClip(transformerAsymmetry)
        let transformerMakeupGain: Float = 1 / max(1 + (transformerDrive - 1) * 0.35, 0.001)
        let exciterFrequency = min(Float(11_000), sampleRate * 0.45)
        let exciterDrive = dspModel == .highExciter ? normalIntensity : 0
        let exciterWetMix = dspModel == .highExciter ? normalBody : 0
        let exciterOversampleFactor = makeExciterOversampleFactor(
            sampleRate: sampleRate,
            mode: exciterOversamplingMode
        )
        let exciterLowPassFrequency = min(Float(20_000), sampleRate * 0.40)
        let exciterStage1Rate = sampleRate * 2
        let exciterStage2Rate = sampleRate * 4
        let butterworthQ1: Float = 0.5411961
        let butterworthQ2: Float = 1.306563

        return LCDSPSettings(
            intensity: normalIntensity,
            body: normalBody,
            outputGain: outputGain,
            headroomGain: pow(10, (-3 * normalIntensity) / 20),
            dspModel: dspModel.controlID,
            shelf: makeLowShelf(sampleRate: sampleRate, frequency: shelfFreq, q: 0.72, gainDb: shelfDb),
            warmthAmount: 0.008 * normalIntensity + 0.004 * normalBody,
            virtualFeedbackGain: 0.16 * normalIntensity,
            bodyInjectionGain: (0.46 + 0.06 * normalIntensity) * normalBody,
            circuitHeadroomGain: pow(10, (-1.2 * normalIntensity - 0.4 * normalBody) / 20),
            drive: 1 + 0.10 * normalIntensity + 0.04 * normalBody,
            wetMix: min(max(0.32 * normalIntensity + 0.18 * normalBody, 0), 0.54),
            bassAlpha: makeRcAlpha(sampleRate: sampleRate, frequency: 72 + normalIntensity * 36),
            subAlpha: makeRcAlpha(sampleRate: sampleRate, frequency: 38 + normalBody * 26),
            transformerPreEmphasis: makeLowShelf(sampleRate: sampleRate, frequency: transformerShelfFreq, q: 0.72, gainDb: transformerShelfDb),
            transformerDeEmphasis: makeLowShelf(sampleRate: sampleRate, frequency: transformerShelfFreq, q: 0.72, gainDb: -transformerShelfDb),
            transformerDrive: transformerDrive,
            transformerAsymmetry: transformerAsymmetry,
            transformerBiasOffset: transformerBiasOffset,
            transformerMakeupGain: transformerMakeupGain,
            exciterHighPass: makeHighPass(sampleRate: sampleRate, frequency: exciterFrequency, q: 0.707),
            exciterDrive: exciterDrive,
            exciterWetMix: exciterWetMix,
            exciterOversampleFactor: exciterOversampleFactor,
            exciterStage1LowPass1: makeLowPass(
                sampleRate: exciterStage1Rate,
                frequency: exciterLowPassFrequency,
                q: butterworthQ1
            ),
            exciterStage1LowPass2: makeLowPass(
                sampleRate: exciterStage1Rate,
                frequency: exciterLowPassFrequency,
                q: butterworthQ2
            ),
            exciterStage2LowPass1: makeLowPass(
                sampleRate: exciterStage2Rate,
                frequency: exciterLowPassFrequency,
                q: butterworthQ1
            ),
            exciterStage2LowPass2: makeLowPass(
                sampleRate: exciterStage2Rate,
                frequency: exciterLowPassFrequency,
                q: butterworthQ2
            )
        )
    }

    static func makeExciterOversampleFactor(
        sampleRate: Float,
        mode: ExciterOversamplingMode = .auto
    ) -> UInt32 {
        ExciterOversamplingPolicy.resolve(
            processingSampleRate: Double(sampleRate),
            mode: mode
        ).effectiveFactor
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

    static func makeHighPass(sampleRate: Float, frequency: Float, q: Float) -> LCBiquadCoefficients {
        let clampedFrequency = min(max(frequency, 20), sampleRate * 0.45)
        let w0 = 2 * Float.pi * clampedFrequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        return LCBiquadCoefficients(
            b0: ((1 + cosW0) / 2) / a0,
            b1: (-(1 + cosW0)) / a0,
            b2: ((1 + cosW0) / 2) / a0,
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

    private static func makePolynomialSoftClip(_ input: Float) -> Float {
        if input > 1 {
            return 1
        }
        if input < -1 {
            return -1
        }
        return input - (input * input * input) / 3
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

    mutating func resetState() {
        z1 = 0
        z2 = 0
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

private struct OversamplingLowPass {
    private var section1 = Biquad()
    private var section2 = Biquad()

    mutating func update(_ first: LCBiquadCoefficients, _ second: LCBiquadCoefficients) {
        section1.update(first)
        section2.update(second)
    }

    mutating func resetState() {
        section1.resetState()
        section2.resetState()
    }

    mutating func process(_ input: Float) -> Float {
        section2.process(section1.process(input))
    }
}

private struct Oversampling2xStage {
    private var interpolationFilter = OversamplingLowPass()
    private var decimationFilter = OversamplingLowPass()

    mutating func update(_ first: LCBiquadCoefficients, _ second: LCBiquadCoefficients) {
        interpolationFilter.update(first, second)
        decimationFilter.update(first, second)
    }

    mutating func resetState() {
        interpolationFilter.resetState()
        decimationFilter.resetState()
    }

    mutating func upsample(_ input: Float, first: inout Float, second: inout Float) {
        first = interpolationFilter.process(input * 2)
        second = interpolationFilter.process(0)
    }

    mutating func downsample(_ first: Float, _ second: Float) -> Float {
        let output = decimationFilter.process(first)
        _ = decimationFilter.process(second)
        return output
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

    func resetState() {
        shelfL.resetState()
        shelfR.resetState()
        subL.resetState()
        subR.resetState()
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

    func resetState() {
        z = 0
    }

    func process(_ input: Float) -> Float {
        z += alpha * (input - z)
        return z
    }
}

final class VirtualCircuitBassDSP: BassProcessor {
    private final class Channel {
        private let bassPole: RcLowPass
        private let subPole: RcLowPass
        private var bassShelf = Biquad()
        private var preEmphasis = Biquad()
        private var deEmphasis = Biquad()
        private var intensity: Float = 0
        private var body: Float = 0
        private var outputGain: Float = 1
        private var virtualFeedbackGain: Float = 0
        private var bodyInjectionGain: Float = 0
        private var headroomGain: Float = 1
        private var wetMix: Float = 0
        private var transformerDrive: Float = 1
        private var transformerAsymmetry: Float = 0
        private var transformerBiasOffset: Float = 0
        private var transformerMakeupGain: Float = 1

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
            self.virtualFeedbackGain = settings.virtualFeedbackGain
            self.bodyInjectionGain = settings.bodyInjectionGain
            self.headroomGain = settings.circuitHeadroomGain
            self.wetMix = settings.wetMix
            self.transformerDrive = settings.transformerDrive
            self.transformerAsymmetry = settings.transformerAsymmetry
            self.transformerBiasOffset = settings.transformerBiasOffset
            self.transformerMakeupGain = settings.transformerMakeupGain
            bassShelf.update(settings.shelf)
            preEmphasis.update(settings.transformerPreEmphasis)
            deEmphasis.update(settings.transformerDeEmphasis)
            bassPole.update(alpha: settings.bassAlpha)
            subPole.update(alpha: settings.subAlpha)
        }

        func resetState() {
            bassShelf.resetState()
            preEmphasis.resetState()
            deEmphasis.resetState()
            bassPole.resetState()
            subPole.resetState()
        }

        func process(_ input: Float) -> Float {
            if intensity < 0.001 && body < 0.001 {
                return input * outputGain
            }

            let bassShaped = bassShelf.process(input)
            let bassNode = bassPole.process(input)
            let subNode = subPole.process(input)
            let shaped = bassShaped + subNode * bodyInjectionGain
            let circuitInput = (shaped + bassNode * virtualFeedbackGain) * headroomGain
            let emphasized = preEmphasis.process(circuitInput)
            let saturated = asymmetricSaturate(emphasized)
            let deEmphasized = deEmphasis.process(saturated)
            let blended = shaped + (deEmphasized - shaped) * wetMix
            return fastClamp(blended * outputGain)
        }

        private func asymmetricSaturate(_ input: Float) -> Float {
            let driven = input * transformerDrive
            let biased = driven + transformerAsymmetry
            let clipped: Float

            if biased > 1 {
                clipped = 1
            } else if biased < -1 {
                clipped = -1
            } else {
                clipped = biased - (biased * biased * biased) * 0.33333334
            }

            return (clipped - transformerBiasOffset) * transformerMakeupGain
        }

        private func fastClamp(_ input: Float) -> Float {
            if !input.isFinite {
                return 0
            }
            if input > 1 {
                return 1
            }
            if input < -1 {
                return -1
            }
            return input
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

    func resetState() {
        left.resetState()
        right.resetState()
    }

    func process(left inputLeft: Float, right inputRight: Float) -> (Float, Float) {
        (left.process(inputLeft), right.process(inputRight))
    }
}

final class HighExciterDSP {
    private final class Channel {
        private var highPass = Biquad()
        private var stage1 = Oversampling2xStage()
        private var stage2 = Oversampling2xStage()
        private var drive: Float = 0
        private var wetMix: Float = 0
        private var oversampleFactor: UInt32 = 1
        private var transitionSamplesRemaining: UInt32 = 0

        func update(_ settings: LCDSPSettings) {
            let nextFactor: UInt32
            switch settings.exciterOversampleFactor {
            case 4: nextFactor = 4
            case 2: nextFactor = 2
            default: nextFactor = 1
            }
            if oversampleFactor != nextFactor {
                stage1.resetState()
                stage2.resetState()
                transitionSamplesRemaining = 256
            }
            highPass.update(settings.exciterHighPass)
            stage1.update(settings.exciterStage1LowPass1, settings.exciterStage1LowPass2)
            stage2.update(settings.exciterStage2LowPass1, settings.exciterStage2LowPass2)
            drive = settings.exciterDrive
            wetMix = settings.exciterWetMix
            oversampleFactor = nextFactor
        }

        func resetState() {
            highPass.resetState()
            stage1.resetState()
            stage2.resetState()
        }

        func process(_ input: Float) -> Float {
            let dry = input.isFinite ? input : 0
            if wetMix < 0.0001 || drive < 0.0001 {
                return dry
            }

            let high = highPass.process(dry)
            let harmonic: Float

            switch oversampleFactor {
            case 4:
                var stage1First: Float = 0
                var stage1Second: Float = 0
                stage1.upsample(high, first: &stage1First, second: &stage1Second)

                var sample0: Float = 0
                var sample1: Float = 0
                var sample2: Float = 0
                var sample3: Float = 0
                stage2.upsample(stage1First, first: &sample0, second: &sample1)
                stage2.upsample(stage1Second, first: &sample2, second: &sample3)

                let downsampled0 = stage2.downsample(
                    makeHarmonic(sample0),
                    makeHarmonic(sample1)
                )
                let downsampled1 = stage2.downsample(
                    makeHarmonic(sample2),
                    makeHarmonic(sample3)
                )
                harmonic = stage1.downsample(downsampled0, downsampled1)
            case 2:
                var first: Float = 0
                var second: Float = 0
                stage1.upsample(high, first: &first, second: &second)
                harmonic = stage1.downsample(makeHarmonic(first), makeHarmonic(second))
            default:
                harmonic = makeHarmonic(high)
            }

            var transitionGain: Float = 1
            if transitionSamplesRemaining > 0 {
                transitionGain = Float(256 - transitionSamplesRemaining) / 256
                transitionSamplesRemaining -= 1
            }
            return fastClamp(dry + harmonic * wetMix * transitionGain)
        }

        private func makeHarmonic(_ input: Float) -> Float {
            let driven = input * drive
            let driven2 = driven * driven
            return driven2 + driven2 * driven * 0.5
        }

        private func fastClamp(_ input: Float) -> Float {
            if !input.isFinite {
                return 0
            }
            if input > 1 {
                return 1
            }
            if input < -1 {
                return -1
            }
            return input
        }
    }

    private let left = Channel()
    private let right = Channel()

    init(sampleRate: Float,
         intensity: Float,
         body: Float,
         outputDb: Float,
         dspModel: Settings.DSPModel,
         exciterOversamplingMode: ExciterOversamplingMode = .auto) {
        update(DSPPrecompute.makeDSPSettings(
            sampleRate: sampleRate,
            intensity: intensity,
            body: body,
            outputDb: outputDb,
            dspModel: dspModel,
            exciterOversamplingMode: exciterOversamplingMode
        ))
    }

    func update(_ settings: LCDSPSettings) {
        left.update(settings)
        right.update(settings)
    }

    func resetState() {
        left.resetState()
        right.resetState()
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

    func reset() {
        for index in buffer.indices {
            buffer[index] = 0
        }
        writeIndex = 0
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

    func resetState() {
        leftToLeft.reset()
        leftToRight.reset()
        rightToLeft.reset()
        rightToRight.reset()
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

private final class HardwareSampleRateTracker {
    struct RateCapabilities {
        let supportedRates: [Double]
        let isSettable: Bool
    }

    private static let standardSampleRates: [Double] = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000,
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000,
        352_800, 384_000, 705_600, 768_000
    ]

    private let queue: DispatchQueue
    private let onChange: (AudioObjectID, Double) -> Void
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var isStarted = false

    init(queue: DispatchQueue, onChange: @escaping (AudioObjectID, Double) -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !isStarted else { return }

        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChanged()
        }
        defaultOutputListener = defaultListener

        var address = Self.defaultOutputDeviceAddress()
        try check(
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                defaultListener
            ),
            "AudioObjectAddPropertyListenerBlock DefaultOutputDevice"
        )

        isStarted = true
        do {
            try refreshOutputDevice(forceNotify: true)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        removeSampleRateListener()

        if let defaultOutputListener {
            var address = Self.defaultOutputDeviceAddress()
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                defaultOutputListener
            )
            self.defaultOutputListener = nil
        }

        isStarted = false
    }

    private func handleDefaultOutputChanged() {
        do {
            try refreshOutputDevice(forceNotify: true)
        } catch {
            fputs("Default output change handling failed: \(error)\n", stderr)
        }
    }

    private func handleSampleRateChanged() {
        do {
            let deviceID = outputDeviceID
            guard deviceID != kAudioObjectUnknown else { return }
            onChange(deviceID, try Self.nominalSampleRate(for: deviceID))
        } catch {
            fputs("Sample rate change handling failed: \(error)\n", stderr)
        }
    }

    private func refreshOutputDevice(forceNotify: Bool) throws {
        let newDeviceID = try Self.defaultOutputDevice()
        let deviceChanged = newDeviceID != outputDeviceID

        if deviceChanged {
            removeSampleRateListener()
            outputDeviceID = newDeviceID
            try installSampleRateListener(for: newDeviceID)
        }

        if forceNotify || deviceChanged {
            onChange(newDeviceID, try Self.nominalSampleRate(for: newDeviceID))
        }
    }

    private func installSampleRateListener(for deviceID: AudioObjectID) throws {
        guard deviceID != kAudioObjectUnknown else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleSampleRateChanged()
        }
        sampleRateListener = listener

        var address = Self.nominalSampleRateAddress()
        try check(
            AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener),
            "AudioObjectAddPropertyListenerBlock NominalSampleRate"
        )
    }

    private func removeSampleRateListener() {
        guard outputDeviceID != kAudioObjectUnknown, let sampleRateListener else { return }
        var address = Self.nominalSampleRateAddress()
        AudioObjectRemovePropertyListenerBlock(outputDeviceID, &address, queue, sampleRateListener)
        self.sampleRateListener = nil
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutputDeviceAddress()
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                &deviceID
            ),
            "AudioObjectGetPropertyData DefaultOutputDevice"
        )
        return deviceID
    }

    static func nominalSampleRate(for deviceID: AudioObjectID) throws -> Double {
        guard deviceID != kAudioObjectUnknown else {
            throw AppError.message("Default output device is unknown.")
        }

        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        var address = nominalSampleRateAddress()
        try check(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate),
            "AudioObjectGetPropertyData NominalSampleRate"
        )
        return Double(sampleRate)
    }

    static func setNominalSampleRate(_ sampleRate: Double, for deviceID: AudioObjectID) throws {
        guard deviceID != kAudioObjectUnknown else {
            throw AppError.message("Audio device is unknown.")
        }

        var value = Float64(sampleRate)
        var address = nominalSampleRateAddress()
        try check(
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float64>.size),
                &value
            ),
            "AudioObjectSetPropertyData NominalSampleRate"
        )
    }

    static func rateCapabilities(for deviceID: AudioObjectID) throws -> RateCapabilities {
        guard deviceID != kAudioObjectUnknown else {
            throw AppError.message("Audio device is unknown.")
        }

        var address = availableNominalSampleRatesAddress()
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize),
            "AudioObjectGetPropertyDataSize AvailableNominalSampleRates"
        )

        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.stride
        var ranges = Array(
            repeating: AudioValueRange(mMinimum: 0, mMaximum: 0),
            count: count
        )
        if count > 0 {
            try ranges.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    throw AppError.message("Available sample-rate storage is unavailable.")
                }
                try check(
                    AudioObjectGetPropertyData(
                        deviceID,
                        &address,
                        0,
                        nil,
                        &dataSize,
                        baseAddress
                    ),
                    "AudioObjectGetPropertyData AvailableNominalSampleRates"
                )
            }
        }

        var settable = DarwinBoolean(false)
        var nominalAddress = nominalSampleRateAddress()
        try check(
            AudioObjectIsPropertySettable(deviceID, &nominalAddress, &settable),
            "AudioObjectIsPropertySettable NominalSampleRate"
        )

        let supportedRates = standardSampleRates.filter { rate in
            ranges.contains { range in
                rate >= Double(range.mMinimum) - 0.5
                    && rate <= Double(range.mMaximum) + 0.5
            }
        }
        return RateCapabilities(
            supportedRates: supportedRates,
            isSettable: settable.boolValue
        )
    }

    private static func defaultOutputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func nominalSampleRateAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func availableNominalSampleRatesAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

@available(macOS 14.4, *)
private final class SystemAudioProcessor: @unchecked Sendable {
    private struct AudioProcessInfo {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    private let settings: Settings
    private let ringBuffer: LockFreeFloatRingBuffer
    private let visualizerRingBuffer: LockFreeFloatRingBuffer
    private let outputGainRamp: OpaquePointer
    private let controlQueue: LockFreeControlEventQueue
    private let scratchFrameCapacity = 8192
    private let inputScratch: UnsafeMutablePointer<Float>
    private let managerQueue = DispatchQueue(label: "com.codexaudiolab.lowendcircuit.audio-manager")
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var hardwareTracker: HardwareSampleRateTracker?
    private var tapFormatListener: AudioObjectPropertyListenerBlock?
    private var currentOutputDeviceID: AudioObjectID
    private var currentHardwareSampleRate: Double
    private var currentTapSampleRate: Double
    private var currentSampleRate: Double
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let circuitDSP: VirtualCircuitBassDSP
    private let exciterDSP: HighExciterDSP
    private var activeDSPModelID: UInt32
    private let spatializer: Spatializer
    private var currentIntensity: Float
    private var currentBody: Float
    private var currentOutputDb: Float
    private var currentDSPModel: Settings.DSPModel
    private var currentExciterOversamplingMode: ExciterOversamplingMode
    private var automaticRateMatchingEnabled: Bool
    private var rateMatchGate = SourceRateMatchStabilityGate()
    private var rateMatchSessionDisabled = false
    private var isAutomaticRateTransition = false
    private var originalRateMatchDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var originalRateMatchSampleRate: Double?
    private var rateMatchStatus = "Auto OFF"
    private var currentSpatialSettings: SpatialSettings
    private var currentCaptureTargetSummary = "전체 시스템"
    private var engineRestartCount: UInt64 = 0
    private var isStarted = false

    var captureTargetSummary: String {
        managerQueue.sync { currentCaptureTargetSummary }
    }

    func diagnosticsSnapshot() -> AudioDiagnosticsSnapshot {
        let managerState = managerQueue.sync {
            (engineRestartCount, currentCaptureTargetSummary)
        }
        return AudioDiagnosticsSnapshot(
            outputUnderrunSamples: ringBuffer.underrunSamples(),
            outputDroppedSamples: ringBuffer.droppedWriteSamples(),
            visualizerDroppedSamples: visualizerRingBuffer.droppedWriteSamples(),
            engineRestartCount: managerState.0,
            captureTarget: managerState.1
        )
    }

    init(settings: Settings) throws {
        let outputDeviceID = try HardwareSampleRateTracker.defaultOutputDevice()
        let detectedSampleRate = try HardwareSampleRateTracker.nominalSampleRate(for: outputDeviceID)
        let sampleRate = Self.validSampleRate(detectedSampleRate)

        self.settings = settings
        self.currentOutputDeviceID = outputDeviceID
        self.currentHardwareSampleRate = sampleRate
        self.currentTapSampleRate = sampleRate
        self.currentSampleRate = sampleRate
        self.currentIntensity = settings.intensity
        self.currentBody = settings.body
        self.currentOutputDb = settings.outputDb
        self.currentDSPModel = settings.dspModel
        self.currentExciterOversamplingMode = settings.exciterOversamplingMode
        self.automaticRateMatchingEnabled = settings.automaticRateMatchingEnabled
        self.rateMatchStatus = settings.automaticRateMatchingEnabled
            ? "Auto ON: source 안정화 대기"
            : "Auto OFF"
        self.currentSpatialSettings = settings.spatial
        self.ringBuffer = try LockFreeFloatRingBuffer(capacityFrames: Int(max(sampleRate, 48_000)) * 4, channels: 2)
        self.visualizerRingBuffer = try LockFreeFloatRingBuffer(capacityFrames: Int(max(sampleRate, 48_000)), channels: 2)
        self.controlQueue = try LockFreeControlEventQueue(sampleRate: Float(sampleRate))
        self.inputScratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrameCapacity * 2)
        self.circuitDSP = VirtualCircuitBassDSP(
            sampleRate: Float(sampleRate),
            intensity: settings.intensity,
            body: settings.body,
            outputDb: settings.outputDb
        )
        self.exciterDSP = HighExciterDSP(
            sampleRate: Float(sampleRate),
            intensity: settings.intensity,
            body: settings.body,
            outputDb: settings.outputDb,
            dspModel: settings.dspModel,
            exciterOversamplingMode: settings.exciterOversamplingMode
        )
        self.activeDSPModelID = settings.dspModel.controlID
        self.spatializer = Spatializer(sampleRate: Float(sampleRate), settings: settings.spatial)
        guard let outputGainRamp = lc_output_gain_ramp_create(1) else {
            inputScratch.deallocate()
            throw AppError.message("Could not allocate the output gain ramp.")
        }
        self.outputGainRamp = outputGainRamp
    }

    deinit {
        stop()
        lc_output_gain_ramp_destroy(outputGainRamp)
        inputScratch.deallocate()
    }

    func start() throws {
        try managerQueue.sync {
            guard !isStarted else { return }
            isStarted = true
            try createProcessTapAndAggregateDevice()
            currentSampleRate = syncAggregateSampleRate(preferredSampleRate: currentHardwareSampleRate)
            refreshTapSampleRate()
            controlQueue.updateSampleRate(Float(currentSampleRate))
            applyCurrentSettingsDirectly()
            try startOutput(sampleRate: currentSampleRate)
            try startCapture()
            hardwareTracker = HardwareSampleRateTracker(queue: managerQueue) { [weak self] deviceID, sampleRate in
                self?.handleHardwareFormatChange(deviceID: deviceID, sampleRate: sampleRate)
            }
            try hardwareTracker?.start()
            publishFormatStatus()
        }
        print("Audio format: \(managerQueue.sync { makeFormatStatus().indicatorText })")
        print("Capture target: \(captureTargetSummary)")
        print("LowEnd system audio processing is running. Press Ctrl-C to stop.")
    }

    func updateDSP(intensity: Float,
                   body: Float,
                   outputDb: Float,
                   dspModel: Settings.DSPModel,
                   exciterOversamplingMode: ExciterOversamplingMode) {
        managerQueue.async { [weak self] in
            guard let self else { return }
            currentIntensity = intensity
            currentBody = body
            currentOutputDb = outputDb
            currentDSPModel = dspModel
            currentExciterOversamplingMode = exciterOversamplingMode
            controlQueue.pushDSP(
                intensity: intensity,
                body: body,
                outputDb: outputDb,
                dspModel: dspModel,
                exciterOversamplingMode: exciterOversamplingMode
            )
        }
    }

    func updateSpatial(_ settings: SpatialSettings) {
        managerQueue.async { [weak self] in
            guard let self else { return }
            currentSpatialSettings = settings
            controlQueue.pushSpatial(settings)
        }
    }

    func setAutomaticRateMatchingEnabled(_ enabled: Bool) {
        managerQueue.async { [weak self] in
            guard let self else { return }
            automaticRateMatchingEnabled = enabled
            rateMatchSessionDisabled = false
            rateMatchGate.reset()
            rateMatchStatus = enabled ? "Auto ON: source 안정화 대기" : "Auto OFF"
            if !enabled {
                do {
                    try restoreOriginalRateMatchIfNeeded()
                } catch {
                    rateMatchStatus = "Auto OFF: 원래 rate 복구 실패"
                }
            }
            publishFormatStatus()
        }
    }

    func observeSourceFormat(_ format: SourceAudioFormat?) {
        managerQueue.async { [weak self] in
            guard let self,
                  automaticRateMatchingEnabled,
                  !rateMatchSessionDisabled,
                  isStarted,
                  !isAutomaticRateTransition else {
                return
            }

            do {
                let capabilities = try HardwareSampleRateTracker.rateCapabilities(
                    for: currentOutputDeviceID
                )
                if let targetRate = rateMatchGate.observe(
                    format: format,
                    currentDeviceRate: currentHardwareSampleRate,
                    supportedRates: capabilities.supportedRates,
                    isDeviceRateSettable: capabilities.isSettable,
                    observedAt: Date()
                ) {
                    try performAutomaticRateTransition(to: targetRate)
                }
            } catch {
                disableAutomaticRateMatchingForSession(error)
            }
        }
    }

    func makeSpectrumAnalyzer(dynamicsModel: DynamicsMeterModel,
                              spectrumModel: SpectrumModel) -> AudioSpectrumAnalyzer {
        let sampleRate = managerQueue.sync { currentSampleRate }
        return AudioSpectrumAnalyzer(
            ringBuffer: visualizerRingBuffer,
            sampleRate: Float(sampleRate),
            dynamicsModel: dynamicsModel,
            spectrumModel: spectrumModel
        )
    }

    func stop() {
        managerQueue.sync {
            guard isStarted || hardwareTracker != nil || aggregateDeviceID != kAudioObjectUnknown || tapID != kAudioObjectUnknown else {
                engine.stop()
                return
            }

            hardwareTracker?.stop()
            hardwareTracker = nil
            stopCaptureAndDestroyAggregateDevice()
            destroyProcessTap()
            engine.stop()
            if let sourceNode {
                engine.disconnectNodeOutput(sourceNode)
                engine.detach(sourceNode)
                self.sourceNode = nil
            }
            ringBuffer.clear()
            visualizerRingBuffer.clear()
            ringBuffer.resetDiagnostics()
            visualizerRingBuffer.resetDiagnostics()
            if originalRateMatchSampleRate != nil {
                try? restoreOriginalRateMatchIfNeeded(reconfigureEngine: false)
            }
            isStarted = false
        }
    }

    private func startOutput(sampleRate: Double) throws {
        try configureOutputGraph(sampleRate: sampleRate)
        try engine.start()
    }

    private func configureOutputGraph(sampleRate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw AppError.message("Could not create AVAudioFormat for \(sampleRate) Hz.")
        }

        let node = try sourceNode ?? makeSourceNode()
        if sourceNode == nil {
            sourceNode = node
            engine.attach(node)
        }

        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    private func makeSourceNode() throws -> AVAudioSourceNode {
        AVAudioSourceNode { [ringBuffer, outputGainRamp] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)

            if abl.count >= 2 {
                guard let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                    return noErr
                }
                ringBuffer.popStereo(left: left, right: right, frameCount: frames)
                lc_output_gain_ramp_apply_stereo(
                    outputGainRamp,
                    left,
                    right,
                    UInt32(frames)
                )
            } else if let buffer = abl.first,
                      let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                let channels = max(Int(buffer.mNumberChannels), 1)
                ringBuffer.popInterleaved(into: data, count: frames * channels)
                lc_output_gain_ramp_apply_interleaved(
                    outputGainRamp,
                    data,
                    UInt32(frames),
                    UInt32(channels)
                )
            }

            return noErr
        }
    }

    private func performAutomaticRateTransition(to targetRate: Double) throws {
        guard !isAutomaticRateTransition,
              abs(targetRate - currentHardwareSampleRate) > 1 else {
            return
        }

        if originalRateMatchSampleRate == nil {
            originalRateMatchDeviceID = currentOutputDeviceID
            originalRateMatchSampleRate = currentHardwareSampleRate
        }

        do {
            try performRateTransition(
                to: targetRate,
                successStatus: "Auto matched: \(Self.rateText(targetRate))"
            )
        } catch {
            let originalRate = originalRateMatchSampleRate
            let originalDevice = originalRateMatchDeviceID
            var rollbackSucceeded = false
            if let originalRate, originalDevice == currentOutputDeviceID {
                do {
                    try performRateTransition(
                        to: originalRate,
                        successStatus: "Auto rollback: \(Self.rateText(originalRate))"
                    )
                    rollbackSucceeded = true
                } catch {
                    rollbackSucceeded = false
                }
            }
            if rollbackSucceeded {
                originalRateMatchSampleRate = nil
                originalRateMatchDeviceID = AudioObjectID(kAudioObjectUnknown)
            }
            throw error
        }
    }

    private func restoreOriginalRateMatchIfNeeded(reconfigureEngine: Bool = true) throws {
        guard let originalRate = originalRateMatchSampleRate,
              originalRateMatchDeviceID == currentOutputDeviceID else {
            originalRateMatchSampleRate = nil
            originalRateMatchDeviceID = AudioObjectID(kAudioObjectUnknown)
            return
        }

        defer {
            originalRateMatchSampleRate = nil
            originalRateMatchDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if reconfigureEngine, isStarted {
            try performRateTransition(
                to: originalRate,
                successStatus: "Auto OFF: \(Self.rateText(originalRate)) 복구"
            )
        } else {
            try HardwareSampleRateTracker.setNominalSampleRate(
                originalRate,
                for: currentOutputDeviceID
            )
        }
    }

    private func performRateTransition(to targetRate: Double,
                                       successStatus: String) throws {
        guard !isAutomaticRateTransition else { return }
        isAutomaticRateTransition = true
        rateMatchStatus = "Auto switching: \(Self.rateText(targetRate))"
        publishFormatStatus()
        defer { isAutomaticRateTransition = false }

        requestOutputGain(0, duration: 0.05)
        waitForOutputGain(atMost: 0.001, timeout: 0.25)
        suspendForHardwareReconfigure()

        do {
            try HardwareSampleRateTracker.setNominalSampleRate(
                targetRate,
                for: currentOutputDeviceID
            )
            let confirmedRate = try waitForNominalSampleRate(
                targetRate,
                deviceID: currentOutputDeviceID
            )
            try restartForHardwareFormat(
                deviceID: currentOutputDeviceID,
                hardwareSampleRate: confirmedRate
            )
            rateMatchStatus = successStatus
            requestOutputGain(1, duration: 0.08)
            publishFormatStatus()
        } catch {
            if !engine.isRunning {
                let recoveryRate =
                    (try? HardwareSampleRateTracker.nominalSampleRate(for: currentOutputDeviceID))
                    ?? currentHardwareSampleRate
                try? restartForHardwareFormat(
                    deviceID: currentOutputDeviceID,
                    hardwareSampleRate: Self.validSampleRate(recoveryRate)
                )
            }
            requestOutputGain(1, duration: 0.08)
            throw error
        }
    }

    private func requestOutputGain(_ target: Float, duration: Double) {
        let frameCount = UInt32(max(currentSampleRate * max(duration, 0), 0))
        lc_output_gain_ramp_set_target(outputGainRamp, target, frameCount)
    }

    private func waitForOutputGain(atMost maximumGain: Float,
                                   timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lc_output_gain_ramp_current(outputGainRamp) <= maximumGain {
                return
            }
            usleep(5_000)
        }
    }

    private func waitForNominalSampleRate(_ targetRate: Double,
                                          deviceID: AudioObjectID) throws -> Double {
        var lastRate = try HardwareSampleRateTracker.nominalSampleRate(for: deviceID)
        for _ in 0..<100 {
            if abs(lastRate - targetRate) <= 1 {
                return lastRate
            }
            usleep(10_000)
            lastRate = try HardwareSampleRateTracker.nominalSampleRate(for: deviceID)
        }
        throw AppError.message(
            "DAC did not confirm \(Self.rateText(targetRate)); current \(Self.rateText(lastRate))."
        )
    }

    private func disableAutomaticRateMatchingForSession(_ error: Error) {
        rateMatchSessionDisabled = true
        rateMatchGate.reset()
        rateMatchStatus = "Auto paused: \(error)"
        requestOutputGain(1, duration: 0.08)
        publishFormatStatus()
    }

    private func handleHardwareFormatChange(deviceID: AudioObjectID, sampleRate: Double) {
        let newHardwareSampleRate = Self.validSampleRate(sampleRate)
        let deviceChanged = deviceID != currentOutputDeviceID
        let rateChanged = abs(newHardwareSampleRate - currentHardwareSampleRate) > 0.5

        if (deviceChanged || rateChanged) && !isAutomaticRateTransition {
            originalRateMatchSampleRate = nil
            originalRateMatchDeviceID = AudioObjectID(kAudioObjectUnknown)
            rateMatchGate.reset()
            rateMatchStatus = automaticRateMatchingEnabled
                ? "Auto ON: 외부 장치 변경 감지"
                : "Auto OFF"
        }

        guard isStarted else {
            currentOutputDeviceID = deviceID
            currentHardwareSampleRate = newHardwareSampleRate
            publishFormatStatus()
            return
        }

        guard deviceChanged || rateChanged else {
            publishFormatStatus()
            return
        }

        do {
            try reconfigureForHardwareFormat(deviceID: deviceID, hardwareSampleRate: newHardwareSampleRate)
        } catch {
            fputs("Output format reconfigure failed: \(error)\n", stderr)
        }
    }

    private func reconfigureForHardwareFormat(deviceID: AudioObjectID, hardwareSampleRate: Double) throws {
        suspendForHardwareReconfigure()
        try restartForHardwareFormat(
            deviceID: deviceID,
            hardwareSampleRate: hardwareSampleRate
        )
    }

    private func suspendForHardwareReconfigure() {
        engine.stop()
        stopCaptureForReconfigure()
        ringBuffer.clear()
        visualizerRingBuffer.clear()
        controlQueue.drain()
        resetDSPState()
        engineRestartCount &+= 1
    }

    private func restartForHardwareFormat(deviceID: AudioObjectID,
                                          hardwareSampleRate: Double) throws {
        currentOutputDeviceID = deviceID
        currentHardwareSampleRate = hardwareSampleRate
        currentSampleRate = syncAggregateSampleRate(preferredSampleRate: hardwareSampleRate)
        refreshTapSampleRate()
        controlQueue.updateSampleRate(Float(currentSampleRate))
        applyCurrentSettingsDirectly()

        try configureOutputGraph(sampleRate: currentSampleRate)
        try engine.start()
        try resumeCaptureAfterReconfigure()
        publishFormatStatus()
        print("Output format re-synced: \(makeFormatStatus().indicatorText)")
    }

    private func stopCaptureForReconfigure() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
            }
        }
    }

    private func resumeCaptureAfterReconfigure() throws {
        if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
            try check(AudioDeviceStart(aggregateDeviceID, ioProcID), "AudioDeviceStart")
        }
    }

    private func syncAggregateSampleRate(preferredSampleRate: Double) -> Double {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            return preferredSampleRate
        }

        do {
            try HardwareSampleRateTracker.setNominalSampleRate(preferredSampleRate, for: aggregateDeviceID)
        } catch {
            fputs("Aggregate sample rate set skipped: \(error)\n", stderr)
        }

        do {
            return Self.validSampleRate(try HardwareSampleRateTracker.nominalSampleRate(for: aggregateDeviceID))
        } catch {
            fputs("Aggregate sample rate read failed: \(error)\n", stderr)
            return preferredSampleRate
        }
    }

    private func stopCaptureAndDestroyAggregateDevice() {
        if aggregateDeviceID == kAudioObjectUnknown {
            return
        }

        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func destroyProcessTap() {
        guard tapID != kAudioObjectUnknown else { return }
        removeTapFormatListener()
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func resetDSPState() {
        circuitDSP.resetState()
        exciterDSP.resetState()
        spatializer.resetState()
    }

    private func applyCurrentSettingsDirectly() {
        let sampleRate = Float(currentSampleRate)
        let dspSettings = DSPPrecompute.makeDSPSettings(
            sampleRate: sampleRate,
            intensity: currentIntensity,
            body: currentBody,
            outputDb: currentOutputDb,
            dspModel: currentDSPModel,
            exciterOversamplingMode: currentExciterOversamplingMode
        )
        activeDSPModelID = currentDSPModel.controlID
        circuitDSP.update(dspSettings)
        exciterDSP.update(dspSettings)
        spatializer.update(DSPPrecompute.makeSpatialSettings(sampleRate: sampleRate, settings: currentSpatialSettings))
    }

    private func publishFormatStatus() {
        let status = makeFormatStatus()
        let capabilities = try? HardwareSampleRateTracker.rateCapabilities(for: currentOutputDeviceID)
        let rateMatchingEnabled = automaticRateMatchingEnabled
        let currentRateMatchStatus = rateMatchStatus
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: AudioFormatNotifications.didChange,
                object: nil,
                userInfo: [
                    AudioFormatNotifications.sampleRateKey: status.sampleRate,
                    AudioFormatNotifications.tapSampleRateKey: status.tapSampleRate,
                    AudioFormatNotifications.processingSampleRateKey: status.processingSampleRate,
                    AudioFormatNotifications.sampleFormatKey: status.sampleFormat,
                    AudioFormatNotifications.isSampleRateMatchedKey: status.isSampleRateMatched,
                    AudioFormatNotifications.indicatorTextKey: status.indicatorText,
                    AudioFormatNotifications.supportedSampleRatesKey: capabilities?.supportedRates ?? [],
                    AudioFormatNotifications.isSampleRateSettableKey: capabilities?.isSettable ?? false,
                    AudioFormatNotifications.automaticRateMatchingEnabledKey: rateMatchingEnabled,
                    AudioFormatNotifications.rateMatchStatusKey: currentRateMatchStatus
                ]
            )
        }
    }

    private func makeFormatStatus() -> AudioFormatStatus {
        AudioFormatStatus(
            sampleRate: currentHardwareSampleRate,
            tapSampleRate: currentTapSampleRate,
            processingSampleRate: currentSampleRate,
            sampleFormat: "32-bit Float",
            isSampleRateMatched: abs(currentHardwareSampleRate - currentSampleRate) <= 0.5
        )
    }

    private static func validSampleRate(_ sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate >= 8_000 else { return 48_000 }
        return sampleRate
    }

    private static func rateText(_ sampleRate: Double) -> String {
        String(format: "%.1f kHz", sampleRate / 1_000)
    }

    private func refreshTapSampleRate() {
        guard tapID != kAudioObjectUnknown else { return }
        do {
            currentTapSampleRate = Self.validSampleRate(try Self.tapFormat(for: tapID).mSampleRate)
        } catch {
            fputs("Tap format read failed: \(error)\n", stderr)
        }
    }

    private func installTapFormatListener() throws {
        guard tapID != kAudioObjectUnknown, tapFormatListener == nil else { return }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            refreshTapSampleRate()
            publishFormatStatus()
        }
        tapFormatListener = listener
        var address = Self.tapFormatAddress()
        do {
            try check(
                AudioObjectAddPropertyListenerBlock(tapID, &address, managerQueue, listener),
                "AudioObjectAddPropertyListenerBlock TapFormat"
            )
        } catch {
            tapFormatListener = nil
            throw error
        }
    }

    private func removeTapFormatListener() {
        guard tapID != kAudioObjectUnknown, let tapFormatListener else { return }
        var address = Self.tapFormatAddress()
        AudioObjectRemovePropertyListenerBlock(tapID, &address, managerQueue, tapFormatListener)
        self.tapFormatListener = nil
    }

    private static func tapFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = tapFormatAddress()
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format),
            "AudioObjectGetPropertyData TapFormat"
        )
        return format
    }

    private static func tapFormatAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func makeTapDescription() throws -> CATapDescription {
        let description: CATapDescription

        switch settings.mode {
        case .all:
            let ownProcess = try audioProcessObjectID(for: getpid())
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
            currentCaptureTargetSummary = "전체 시스템"
        case .bundleIDs(let bundleIDs):
            let processes = try resolveAudioProcesses(for: bundleIDs)
            description = CATapDescription(
                stereoMixdownOfProcesses: processes.map(\.objectID)
            )
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                description.isProcessRestoreEnabled = true
            }
#endif
            currentCaptureTargetSummary = processes
                .map { "\($0.bundleID) (pid \($0.pid))" }
                .joined(separator: ", ")
        case .listApps:
            throw AppError.message("Cannot start capture while listing apps.")
        case .selfTest:
            throw AppError.message("Cannot start capture while running self-tests.")
        }

        description.name = "LowEnd Native System Tap"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private func resolveAudioProcesses(for requestedBundleIDs: [String]) throws -> [AudioProcessInfo] {
        let requested = requestedBundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !requested.isEmpty else {
            throw AppError.message("특정 앱 bundle ID가 비어 있습니다.")
        }

        let connected = try Self.audioProcessInfos()
        let descriptors = connected.map {
            AudioProcessDescriptor(
                objectID: $0.objectID,
                pid: $0.pid,
                bundleID: $0.bundleID,
                isRunningOutput: $0.isRunningOutput
            )
        }
        let resolved = AudioProcessMatcher.resolve(
            requestedBundleIDs: requestedBundleIDs,
            from: descriptors
        )
        let resolvedIDs = Set(resolved.map(\.objectID))
        let selected = connected.filter { resolvedIDs.contains($0.objectID) }
        guard !selected.isEmpty else {
            throw AppError.message(
                "Core Audio에서 \(requestedBundleIDs.joined(separator: ", ")) 또는 하위 오디오 프로세스를 찾지 못했습니다. 앱에서 재생을 시작한 뒤 다시 적용하세요."
            )
        }

        var seen = Set<AudioObjectID>()
        return selected.filter { seen.insert($0.objectID).inserted }
    }

    private static func audioProcessInfos() throws -> [AudioProcessInfo] {
        let objectIDs = try audioProcessObjectIDs()
        return objectIDs.compactMap { objectID in
            guard let bundleID = try? processBundleID(for: objectID), !bundleID.isEmpty else {
                return nil
            }
            let pid = (try? processPID(for: objectID)) ?? 0
            let isRunningOutput = (try? processIsRunningOutput(for: objectID)) ?? false
            return AudioProcessInfo(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID,
                isRunningOutput: isRunningOutput
            )
        }
    }

    private static func audioProcessObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ),
            "AudioObjectGetPropertyDataSize ProcessObjectList"
        )

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objectIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = objectIDs.withUnsafeMutableBytes { storage in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                storage.baseAddress!
            )
        }
        try check(status, "AudioObjectGetPropertyData ProcessObjectList")
        return objectIDs.filter { $0 != kAudioObjectUnknown }
    }

    private static func processBundleID(for objectID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &bundleID),
            "AudioObjectGetPropertyData ProcessBundleID"
        )
        return bundleID?.takeRetainedValue() as String? ?? ""
    }

    private static func processPID(for objectID: AudioObjectID) throws -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &pid),
            "AudioObjectGetPropertyData ProcessPID"
        )
        return pid
    }

    private static func processIsRunningOutput(for objectID: AudioObjectID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value),
            "AudioObjectGetPropertyData ProcessIsRunningOutput"
        )
        return value != 0
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
        refreshTapSampleRate()
        do {
            try installTapFormatListener()
        } catch {
            fputs("Tap format listener unavailable: \(error)\n", stderr)
        }

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
            activeDSPModelID = latestDSP.dspModel
            switch activeDSPModelID {
            case DSPModelID.circuit:
                circuitDSP.update(latestDSP)
            case DSPModelID.highExciter:
                exciterDSP.update(latestDSP)
            default:
                break
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
                let processed = processSelectedModel(left: leftChunk[frame], right: rightChunk[frame])
                let output = processPostModel(left: processed.0, right: processed.1)
                inputScratch[frame * 2] = output.0
                inputScratch[frame * 2 + 1] = output.1
            }

            ringBuffer.push(inputScratch, count: chunkFrames * 2)
            visualizerRingBuffer.push(inputScratch, count: chunkFrames * 2)
            offset += chunkFrames
        }
    }

    private func processAndPushInterleavedStereo(_ interleaved: UnsafePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let chunkFrames = min(scratchFrameCapacity, frameCount - offset)
            let chunk = interleaved.advanced(by: offset * 2)

            for frame in 0..<chunkFrames {
                let processed = processSelectedModel(left: chunk[frame * 2], right: chunk[frame * 2 + 1])
                let output = processPostModel(left: processed.0, right: processed.1)
                inputScratch[frame * 2] = output.0
                inputScratch[frame * 2 + 1] = output.1
            }

            ringBuffer.push(inputScratch, count: chunkFrames * 2)
            visualizerRingBuffer.push(inputScratch, count: chunkFrames * 2)
            offset += chunkFrames
        }
    }

    private func processAndPushMono(_ mono: UnsafePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let chunkFrames = min(scratchFrameCapacity, frameCount - offset)
            let chunk = mono.advanced(by: offset)

            for frame in 0..<chunkFrames {
                let processed = processSelectedModel(left: chunk[frame], right: chunk[frame])
                let output = processPostModel(left: processed.0, right: processed.1)
                inputScratch[frame * 2] = output.0
                inputScratch[frame * 2 + 1] = output.1
            }

            ringBuffer.push(inputScratch, count: chunkFrames * 2)
            visualizerRingBuffer.push(inputScratch, count: chunkFrames * 2)
            offset += chunkFrames
        }
    }

    private func processSelectedModel(left: Float, right: Float) -> (Float, Float) {
        let safeLeft = left.isFinite ? left : 0
        let safeRight = right.isFinite ? right : 0

        switch activeDSPModelID {
        case DSPModelID.circuit:
            return circuitDSP.process(left: safeLeft, right: safeRight)
        case DSPModelID.highExciter:
            return exciterDSP.process(left: safeLeft, right: safeRight)
        default:
            return (safeLeft, safeRight)
        }
    }

    private func processPostModel(left: Float, right: Float) -> (Float, Float) {
        if activeDSPModelID == DSPModelID.clean {
            return (left, right)
        }
        return spatializer.process(left: left, right: right)
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
    if case .selfTest = settings.mode {
        try runDSPParityChecks()
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
