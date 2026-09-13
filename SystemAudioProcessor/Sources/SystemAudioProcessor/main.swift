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

fileprivate extension Array {
    /// Bounds-checked subscript used by the output-conditioning pickers.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

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

enum RateMatchPhase: String, Sendable {
    case idle
    case fadingOut
    case stopping
    case changingDeviceRate
    case rebuilding
    case waitingForCapture
    case fadingIn
    case running
    case rollback
    case aborted
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
                    Text("다이내믹스")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.78, green: 0.81, blue: 0.86))
                    Text("크레스트 팩터")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.58, green: 0.62, blue: 0.68))
                }
                Spacer(minLength: 8)
                Text(formatDbText(model.levels.crestFactor))
                    .font(.system(size: 30, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color(red: 0.96, green: 0.75, blue: 0.31))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
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
                Text(formatDbText(db))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }

}

@available(macOS 14.4, *)
private struct PersistentAnalysisView: View {
    let dynamicsModel: DynamicsMeterModel
    let spectrumModel: SpectrumModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("실시간 분석")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(red: 0.55, green: 0.60, blue: 0.68))

            MetalSpectrumView(model: spectrumModel, isActive: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 250)
                .overlay(alignment: .topLeading) {
                    Text("스펙트럼")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.78, green: 0.81, blue: 0.86))
                        .padding(10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

            DynamicsMeterView(model: dynamicsModel, style: .analysis)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.10, green: 0.12, blue: 0.15))
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

func check(_ status: OSStatus, _ label: String) throws {
    guard status == noErr else { throw AppError.osStatus(label, status) }
}

func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
}

/// Format a dB value to one decimal place, collapsing negative zero so that a
/// value which rounds to zero renders as "0.0 dB" instead of "-0.0 dB". This
/// matters for sliders that span 0 (e.g. Output -18…+6, headroom -12…0): a
/// reading like -0.04 would otherwise print "-0.0 dB" alongside "0.0 dB".
/// Display-only — the gain path (pow(10, db/20)) is unaffected.
private func formatDbText(_ db: Double) -> String {
    let tenths = (db * 10).rounded(.toNearestOrAwayFromZero)
    let normalized = tenths == 0 ? 0.0 : tenths / 10
    return String(format: "%.1f dB", normalized)
}

private func formatDbText(_ db: Float) -> String {
    formatDbText(Double(db))
}

private func parseArguments() throws -> Settings {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let diagnostics = ["--list-apps", "--self-test", "--ui-self-test", "--benchmark-output-conditioning"]
    guard arguments.count == 1 || !arguments.contains(where: diagnostics.contains) else {
        throw AppError.message("Diagnostic commands must be used on their own.")
    }
    var settings = Settings()
    var bundleIDs: [String] = []
    var captureAll = false
    var iterator = arguments.makeIterator()

    while let arg = iterator.next() {
        switch arg {
        case "--all":
            captureAll = true
            settings.mode = .all
        case "--bundle-id":
            guard let value = iterator.next(), !value.isEmpty else {
                throw AppError.message("--bundle-id needs a value")
            }
            bundleIDs.append(value)
        case "--intensity":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--intensity needs a number")
            }
            settings.intensity = number
        case "--body":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--body needs a number")
            }
            settings.body = number
        case "--output":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
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
            switch value.lowercased() {
            case "on", "true", "1", "yes": settings.spatial.enabled = true
            case "off", "false", "0", "no": settings.spatial.enabled = false
            default: throw AppError.message("--spatial needs on or off")
            }
        case "--listener-x":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--listener-x needs a number")
            }
            settings.spatial.listenerX = number
        case "--listener-z":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--listener-z needs a number")
            }
            settings.spatial.listenerZ = number
        case "--stage-width":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--stage-width needs a number")
            }
            settings.spatial.speakerWidth = number
        case "--space":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
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
        guard !captureAll else { throw AppError.message("Choose --all or --bundle-id, not both.") }
        settings.mode = .bundleIDs(bundleIDs)
    }

    return settings.normalized()
}

@available(macOS 14.4, *)
@MainActor
private final class NativeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum AppPage: Int, CaseIterable {
        case model
        case spatial
        case routing
        case output
        case settings
        case diagnostics

        var title: String {
            switch self {
            case .model: return "모델"
            case .spatial: return "공간 음향"
            case .routing: return "오디오 적용"
            case .output: return "출력 컨디셔닝"
            case .settings: return "설정"
            case .diagnostics: return "진단"
            }
        }

        var symbolName: String {
            switch self {
            case .model: return "slider.horizontal.3"
            case .spatial: return "move.3d"
            case .routing: return "app.connected.to.app.below.fill"
            case .output: return "waveform"
            case .settings: return "gearshape.fill"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    private var window: NSWindow!
    private var rootView: NSView!
    private var sidebarView: NSView!
    private var pageContainerView: NSView!
    private var analysisContainerView: NSView!
    private var formatHeaderView: NSView!
    private var analysisRailView: NSHostingView<AnyView>!
    private var pageViews: [AppPage: NSView] = [:]
    private var sidebarButtons: [NSButton] = []
    private var selectedPage: AppPage = .model
    private var allSystemButton: NSButton!
    private var modelExplanationView: NSView!
    private var modelControlsView: NSView!
    private var modelPresetsView: NSView!
    private var routingAppsScrollView: NSScrollView!
    private var routingStartAppButton: NSButton!
    private var statusLabel: NSTextField!
    private var sourceFormatLabel: NSTextField!
    private var formatLabel: NSTextField!
    private var oversamplingLabel: NSTextField!
    private var rateMatchPreviewLabel: NSTextField!
    private var compactSourceTitleLabel: NSTextField!
    private var compactSourceValueLabel: NSTextField!
    private var compactOutputLabel: NSTextField!
    private var compactModelLabel: NSTextField!
    private var diagnosticsLabel: NSTextField!
    private var automaticRateMatchButton: NSButton!
    private var expertModeButton: NSButton!
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
    private var modelSelector: NSSegmentedControl!
    private var preferenceStore: UserDefaults = .standard
    private var oversamplingModeLabel: NSTextField!
    private var oversamplingModeControl: NSSegmentedControl!
    private var presetButtons: [NSButton] = []
    private var processor: SystemAudioProcessor?
    private enum AudioOperationPhase { case replacing, creating, starting, stopping }
    private struct PendingAudioOperation {
        let id = UUID()
        var phase: AudioOperationPhase
        var stopRequested = false
        var quitRequested = false
    }
    // Main owns the token and processor. The serial worker retains each
    // blocking call until it really returns; elapsed time never retires it.
    private var pendingAudioOperation: PendingAudioOperation?
    private let audioLifecycleWorker = GUIAudioLifecycleWorker()
    private var audioLifecycleIO = GUIAudioLifecycleIO()
    private var lifecycleStartsDiagnosticsTimer = true
    private var finishRequestedQuit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    private var spectrumAnalyzer: AudioSpectrumAnalyzer?
    private var sourceFormatTracker: SourceFormatTracker?
    private var lastSourceSnapshot: SourceFormatSnapshot?
    private var lastSourceObservation: SourceFormatSnapshot?
    private var lastSpatialSubmissionRevision: UInt64 = 0
    private var diagnosticsTimer: Timer?
    private let dynamicsMeterModel = DynamicsMeterModel()
    private let spectrumModel = SpectrumModel()
    private let spatialControlModel = SpatialControlModel()
    private var currentProcessingSampleRate: Double?
    private var currentSourceSampleRate: Double?
    private var currentDeviceSampleRate: Double?
    private var currentSourcePlayerName: String?
    private var currentSourceBitDepth: Int?
    private var currentOutputSampleFormat = "32-bit Float"

    // Live pipeline state mirrored from AudioFormatNotifications for the
    // read-only Diagnostics panel. Populated in audioFormatDidChange (main).
    private var currentTapSampleRate: Double?
    private var currentLivePCM2xActive = false
    private var currentLivePCM2xFallback = ""
    private var currentStopFailure: String?
    private var currentProcessingFailure: String?
    private var pendingHeadroomEdit = false
    private var supportedDeviceSampleRates: [Double] = []
    private var isDeviceSampleRateSettable = false
    private var automaticRateMatchingEnabled = UserDefaults.standard.bool(
        forKey: "automaticRateMatchingEnabled"
    )
    private var expertModeEnabled = UserDefaults.standard.bool(
        forKey: "expertModeEnabled"
    )
    private var rateMatchStatusText = "자동 꺼짐"
    private var exciterOversamplingMode: ExciterOversamplingMode = {
        let rawValue = UInt32(clamping: UserDefaults.standard.integer(forKey: "exciterOversamplingMode"))
        return ExciterOversamplingMode(rawValue: rawValue) ?? .auto
    }()

    // Output Conditioning (experimental) UI state, persisted via UserDefaults.
    private var outputConditioningEnabled = UserDefaults.standard.bool(
        forKey: "outputConditioningEnabled"
    )
    private var outputConditioningModeRaw: UInt32 = {
        let stored = UInt32(clamping: UserDefaults.standard.integer(forKey: "outputConditioningMode"))
        return OutputConditioningMode(rawValue: stored)?.rawValue ?? OutputConditioningMode.bypass.rawValue
    }()
    private var outputConditioningFactor: Int = {
        let stored = UserDefaults.standard.integer(forKey: "outputConditioningFactor")
        return OutputConditioningParameters.allowedOversamplingFactors.contains(stored) ? stored : 2
    }()
    private var outputConditioningFilterRaw: UInt32 = {
        let stored = UInt32(clamping: UserDefaults.standard.integer(forKey: "outputConditioningFilter"))
        return ResamplingFilterMode(rawValue: stored)?.rawValue ?? ResamplingFilterMode.linearPhaseShort.rawValue
    }()
    private var outputConditioningHeadroomDB: Double = {
        if let value = UserDefaults.standard.object(forKey: "outputConditioningHeadroomDB") as? Double {
            return value
        }
        return -3.0
    }()
    private var outputConditioningDither = UserDefaults.standard.bool(
        forKey: "outputConditioningDither"
    )
    private var outputConditioningNoiseShape = UserDefaults.standard.bool(
        forKey: "outputConditioningNoiseShape"
    )
    private var outputConditioningDSDRaw: UInt32 = {
        let stored = UInt32(clamping: UserDefaults.standard.integer(forKey: "outputConditioningDSD"))
        return DSDMode(rawValue: stored)?.rawValue ?? DSDMode.off.rawValue
    }()
    private var outputConditioningCapability: OutputConditioningCapability?
    private var outputConditioningEnableButton: NSButton!
    private var outputConditioningModePopup: NSPopUpButton!
    private var outputConditioningFactorPopup: NSPopUpButton!
    private var outputConditioningFilterPopup: NSPopUpButton!
    private var outputConditioningHeadroomSlider: NSSlider!
    private var outputConditioningHeadroomCaption: NSTextField!
    private var outputConditioningHeadroomValueLabel: NSTextField!
    private var outputConditioningRuntimeLabel: NSTextField!
    private var outputConditioningDitherButton: NSButton!
    private var outputConditioningNoiseShapeButton: NSButton!
    private var outputConditioningDSDPopup: NSPopUpButton!
    private var outputConditioningStatusLabel: NSTextField!

    // Diagnostics panel — read-only value labels, updated by refreshDiagnosticsPanel.
    private var diagTapValue: NSTextField!
    private var diagEngineValue: NSTextField!
    private var diagDeviceValue: NSTextField!
    private var diagFormatValue: NSTextField!
    private var diagConditioningValue: NSTextField!
    private var diagFallbackValue: NSTextField!
    private var diagHighExciterValue: NSTextField!
    private var diagXRunValue: NSTextField!
    private var diagRestartValue: NSTextField!
    private var diagDeviceNameValue: NSTextField!
    private var diagCaptureValue: NSTextField!
    private var diagAudioFlowValue: NSTextField!

    // Device name is resolved from CoreAudio only when the device changes (it
    // rarely does mid-session), avoiding a main-thread IPC on every 1 Hz tick.
    private var diagCachedDeviceID: AudioObjectID = kAudioObjectUnknown
    private var diagCachedDeviceName: String = "—"

    func applicationDidFinishLaunching(_ notification: Notification) {
        rateMatchStatusText = automaticRateMatchingEnabled
            ? "자동 켜짐: 소스 안정화 대기"
            : "자동 꺼짐"
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioFormatDidChange(_:)),
            name: AudioFormatNotifications.didChange,
            object: nil
        )
        buildWindow()
        refreshRateMatchDeviceCapabilities()
        refreshOutputConditioningCapability()
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
        if pendingAudioOperation == nil && processor == nil { return .terminateNow }
        requestStopAudio(quit: true)
        // Keep the event loop usable even if HAL takes a long time to return.
        // A confirmed asynchronous Stop will request termination again.
        window?.makeKeyAndOrderFront(nil)
        return .terminateCancel
    }

    private func buildWindow() {
        print("Opening LowEnd Native Audio control window.")
        let rect = NSRect(x: 0, y: 0, width: 1080, height: 700)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LowEnd Native Audio"
        window.minSize = NSSize(width: 940, height: 640)
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.center()

        let content = NSView(frame: rect)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1).cgColor
        window.contentView = content
        rootView = content

        sidebarView = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: rect.height))
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor(calibratedRed: 0.065, green: 0.075, blue: 0.095, alpha: 1).cgColor
        content.addSubview(sidebarView)

        let brand = makeLabel("LowEnd", size: 23, weight: .bold)
        brand.textColor = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.31, alpha: 1)
        brand.frame = NSRect(x: 18, y: 642, width: 120, height: 30)
        brand.autoresizingMask = [.minYMargin]
        sidebarView.addSubview(brand)

        let brandCaption = makeLabel("NATIVE AUDIO", size: 9, weight: .bold)
        brandCaption.textColor = NSColor(calibratedRed: 0.48, green: 0.53, blue: 0.61, alpha: 1)
        brandCaption.frame = NSRect(x: 19, y: 625, width: 120, height: 14)
        brandCaption.autoresizingMask = [.minYMargin]
        sidebarView.addSubview(brandCaption)

        for (index, page) in AppPage.allCases.enumerated() {
            let button = makeSidebarButton(page: page)
            button.frame = NSRect(x: 10, y: 560 - CGFloat(index) * 48, width: 140, height: 38)
            button.autoresizingMask = [.minYMargin]
            sidebarView.addSubview(button)
            sidebarButtons.append(button)
        }

        allSystemButton = NSButton(
            image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: "전체 시스템 적용") ?? NSImage(),
            target: self,
            action: #selector(startAllAudio)
        )
        allSystemButton.bezelStyle = .texturedRounded
        allSystemButton.imageScaling = .scaleProportionallyDown
        allSystemButton.contentTintColor = NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.31, alpha: 1)
        allSystemButton.frame = NSRect(x: 59, y: 22, width: 42, height: 42)
        allSystemButton.toolTip = "전체 시스템 오디오 처리를 시작합니다."
        sidebarView.addSubview(allSystemButton)

        pageContainerView = NSView(frame: NSRect(x: 160, y: 0, width: 620, height: rect.height))
        pageContainerView.wantsLayer = true
        pageContainerView.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor
        content.addSubview(pageContainerView)

        analysisContainerView = NSView(frame: NSRect(x: 780, y: 0, width: 300, height: rect.height))
        analysisContainerView.wantsLayer = true
        analysisContainerView.layer?.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.15, alpha: 1).cgColor
        content.addSubview(analysisContainerView)

        formatHeaderView = NSView()
        formatHeaderView.wantsLayer = true
        formatHeaderView.layer?.backgroundColor = NSColor(
            calibratedRed: 0.13,
            green: 0.16,
            blue: 0.20,
            alpha: 1
        ).cgColor
        formatHeaderView.layer?.cornerRadius = 7
        analysisContainerView.addSubview(formatHeaderView)

        compactSourceTitleLabel = makeLabel("음원 재생", size: 10.5, weight: .semibold)
        compactSourceTitleLabel.textColor = NSColor(
            calibratedRed: 0.62,
            green: 0.68,
            blue: 0.76,
            alpha: 1
        )
        formatHeaderView.addSubview(compactSourceTitleLabel)

        compactSourceValueLabel = makeLabel("재생 정보 대기 중", size: 19, weight: .bold)
        compactSourceValueLabel.textColor = .white
        compactSourceValueLabel.lineBreakMode = .byTruncatingTail
        formatHeaderView.addSubview(compactSourceValueLabel)

        compactOutputLabel = makeLabel("출력 포맷 대기 중", size: 11, weight: .medium)
        compactOutputLabel.textColor = NSColor(
            calibratedRed: 0.68,
            green: 0.73,
            blue: 0.80,
            alpha: 1
        )
        compactOutputLabel.lineBreakMode = .byTruncatingMiddle
        formatHeaderView.addSubview(compactOutputLabel)

        compactModelLabel = makeLabel("적용 모델  Circuit", size: 11, weight: .semibold)
        compactModelLabel.textColor = NSColor(
            calibratedRed: 0.31,
            green: 0.78,
            blue: 0.94,
            alpha: 1
        )
        compactModelLabel.lineBreakMode = .byTruncatingTail
        formatHeaderView.addSubview(compactModelLabel)

        sourceFormatLabel = makeLabel("Source: Apple Music/TIDAL 대기 중", size: 11.5, weight: .semibold)
        sourceFormatLabel.lineBreakMode = .byTruncatingMiddle
        sourceFormatLabel.toolTip = "플레이어 메타데이터 또는 Unified Log에서 감지한 원본 스트림 정보입니다. 확인할 수 없는 값은 추정하지 않고 unknown으로 표시합니다."
        formatHeaderView.addSubview(sourceFormatLabel)

        formatLabel = makeLabel("처리 포맷 대기 중", size: 11, weight: .semibold)
        formatLabel.lineBreakMode = .byTruncatingMiddle
        formatLabel.toolTip = "Tap은 Core Audio 공유 믹서에서 캡처한 PCM, Engine은 DSP 처리율, DAC는 출력 장치 레이트입니다."
        formatHeaderView.addSubview(formatLabel)

        oversamplingLabel = makeLabel("", size: 10.5, weight: .semibold)
        oversamplingLabel.lineBreakMode = .byTruncatingMiddle
        oversamplingLabel.toolTip = "전체 음원을 업스케일링하는 기능이 아니라 HighExciter의 비선형 배음 생성 구간에만 적용되는 내부 오버샘플링 상태입니다. Tap 값은 공유 시스템 PCM 처리율입니다."
        oversamplingLabel.isHidden = true
        formatHeaderView.addSubview(oversamplingLabel)

        rateMatchPreviewLabel = makeLabel("Rate Match Preview: source waiting", size: 10, weight: .medium)
        rateMatchPreviewLabel.lineBreakMode = .byTruncatingMiddle
        rateMatchPreviewLabel.textColor = NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.75, alpha: 1)
        rateMatchPreviewLabel.toolTip = "원본 음원의 rate와 DAC 지원 rate를 비교한 미리보기입니다. 이 표시만으로 장치 설정을 변경하지 않습니다."
        formatHeaderView.addSubview(rateMatchPreviewLabel)

        analysisRailView = NSHostingView(rootView: AnyView(
            PersistentAnalysisView(
                dynamicsModel: dynamicsMeterModel,
                spectrumModel: spectrumModel
            )
        ))
        analysisContainerView.addSubview(analysisRailView)

        pageViews[.model] = makeModelPage()
        pageViews[.spatial] = makeSpatialPage()
        pageViews[.routing] = makeRoutingPage()
        pageViews[.settings] = makeSettingsPage()
        pageViews[.output] = makeOutputConditioningPage()
        pageViews[.diagnostics] = makeDiagnosticsPage()
        for page in AppPage.allCases {
            guard let pageView = pageViews[page] else { continue }
            pageView.frame = pageContainerView.bounds
            pageView.isHidden = page != selectedPage
            pageContainerView.addSubview(pageView)
        }

        refreshApps()
        updateFormatHeaderMode()
        updateCompactFormatSummary()
        layoutApplication()
        updateSelectedPage()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResize(_ notification: Notification) {
        layoutApplication()
    }

    private func layoutApplication() {
        guard let content = window?.contentView else { return }
        let bounds = content.bounds
        let sidebarWidth: CGFloat = 160
        let analysisWidth = min(max(bounds.width * 0.28, 260), 320)
        let gap: CGFloat = 1

        sidebarView.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        analysisContainerView.frame = NSRect(
            x: bounds.width - analysisWidth,
            y: 0,
            width: analysisWidth,
            height: bounds.height
        )
        pageContainerView.frame = NSRect(
            x: sidebarWidth + gap,
            y: 0,
            width: max(bounds.width - sidebarWidth - analysisWidth - gap * 2, 1),
            height: bounds.height
        )

        let railWidth = analysisContainerView.bounds.width
        let headerHeight: CGFloat = expertModeEnabled ? 90 : 106
        formatHeaderView.frame = NSRect(
            x: 8,
            y: bounds.height - headerHeight - 8,
            width: railWidth - 16,
            height: headerHeight
        )

        let headerWidth = formatHeaderView.bounds.width
        compactSourceTitleLabel.frame = NSRect(x: 14, y: 80, width: headerWidth - 28, height: 15)
        compactSourceValueLabel.frame = NSRect(x: 14, y: 52, width: headerWidth - 28, height: 25)
        compactOutputLabel.frame = NSRect(x: 14, y: 29, width: headerWidth - 28, height: 17)
        compactModelLabel.frame = NSRect(x: 14, y: 9, width: headerWidth - 28, height: 16)

        sourceFormatLabel.frame = NSRect(x: 12, y: 67, width: headerWidth - 24, height: 17)
        formatLabel.frame = NSRect(x: 12, y: 48, width: headerWidth - 24, height: 16)
        oversamplingLabel.frame = NSRect(x: 12, y: 29, width: headerWidth - 24, height: 16)
        rateMatchPreviewLabel.frame = NSRect(x: 12, y: 10, width: headerWidth - 24, height: 15)
        analysisRailView.frame = NSRect(
            x: 0,
            y: 0,
            width: railWidth,
            height: max(bounds.height - headerHeight - 16, 1)
        )

        for pageView in pageViews.values {
            pageView.frame = pageContainerView.bounds
        }
        layoutModelPage()
        layoutRoutingPage()
    }

    private func makeSidebarButton(page: AppPage) -> NSButton {
        let button = NSButton(title: page.title, target: self, action: #selector(sidebarPageChanged(_:)))
        button.tag = page.rawValue
        button.bezelStyle = .recessed
        button.refusesFirstResponder = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.image = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: page.title)
        button.imagePosition = .imageLeading
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        return button
    }

    @objc private func sidebarPageChanged(_ sender: NSButton) {
        guard let page = AppPage(rawValue: sender.tag) else { return }
        selectedPage = page
        updateSelectedPage()
    }

    private func updateSelectedPage() {
        for page in AppPage.allCases {
            pageViews[page]?.isHidden = page != selectedPage
            guard let button = sidebarButtons.first(where: { $0.tag == page.rawValue }) else {
                continue
            }
            let selected = page == selectedPage
            button.state = selected ? .on : .off
            button.layer?.backgroundColor = selected
                ? NSColor(calibratedRed: 0.16, green: 0.26, blue: 0.34, alpha: 1).cgColor
                : NSColor.clear.cgColor
            button.contentTintColor = selected
                ? NSColor(calibratedRed: 0.40, green: 0.78, blue: 0.96, alpha: 1)
                : NSColor(calibratedRed: 0.78, green: 0.81, blue: 0.86, alpha: 1)
        }
    }

    private func makeModelPage() -> NSView {
        let page = NSView(frame: pageContainerView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 700))
        page.wantsLayer = true
        page.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor

        let title = makeLabel("모델 및 사운드", size: 24, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 24, y: 636, width: 300, height: 32)
        title.autoresizingMask = [.minYMargin]
        page.addSubview(title)

        statusLabel = makeLabel("대기 중", size: 13, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.frame = NSRect(x: 24, y: 607, width: 300, height: 22)
        statusLabel.autoresizingMask = [.minYMargin, .width]
        page.addSubview(statusLabel)

        diagnosticsLabel = makeLabel("XRuns 대기 중", size: 10, weight: .regular)
        diagnosticsLabel.textColor = NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.67, alpha: 1)
        diagnosticsLabel.lineBreakMode = .byTruncatingMiddle
        diagnosticsLabel.toolTip = "출력 underrun, 출력/분석 버퍼 drop, 엔진 재시작 횟수와 실제 캡처 프로세스를 표시합니다. 앱별 대상은 현재 tap에서 약 1초마다 조회하며, 대상 소멸이나 조회 실패도 표시합니다."
        diagnosticsLabel.frame = NSRect(x: 24, y: 586, width: 480, height: 16)
        diagnosticsLabel.autoresizingMask = [.minYMargin, .width]
        page.addSubview(diagnosticsLabel)

        let modelLabel = makeLabel("모델", size: 12, weight: .semibold)
        modelLabel.frame = NSRect(x: 24, y: 548, width: 55, height: 26)
        modelLabel.autoresizingMask = [.minYMargin]
        page.addSubview(modelLabel)

        modelSelector = NSSegmentedControl(labels: ["Clean", "Circuit", "HighExciter"],
            trackingMode: .selectOne, target: self, action: #selector(modelChanged))
        modelSelector.frame = NSRect(x: 84, y: 545, width: 300, height: 30)
        modelSelector.segmentStyle = .rounded
        let savedModelIndex = preferenceStore.integer(forKey: "selectedModel")
        modelSelector.selectedSegment = (0...2).contains(savedModelIndex) ? savedModelIndex : 1
        modelSelector.setAccessibilityLabel("사운드 모델")
        modelSelector.toolTip = "Clean은 DSP bypass, Circuit은 저역 회로 모델, HighExciter는 독립 고역 배음 모델입니다. 처리 중에도 바로 선택할 수 있습니다."
        modelSelector.autoresizingMask = [.minYMargin]
        page.addSubview(modelSelector)

        modelExplanationView = makeExplanationSection()
        page.addSubview(modelExplanationView)
        modelControlsView = makeControlSection()
        page.addSubview(modelControlsView)
        modelPresetsView = makePresetSection()
        page.addSubview(modelPresetsView)
        return page
    }

    private func makeSpatialPage() -> NSView {
        let view = NSHostingView(rootView: AnyView(
            SpatialPageView(
                spatialModel: spatialControlModel,
                onSpatialChange: { [weak self] settings in
                    self?.updateSpatialControls(from: settings, notifyProcessor: true)
                }
            )
        ))
        view.frame = pageContainerView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 700)
        return view
    }

    private func makeRoutingPage() -> NSView {
        let page = NSView(frame: pageContainerView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 700))
        page.wantsLayer = true
        page.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor

        let title = makeLabel("오디오 적용", size: 24, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 24, y: 636, width: 260, height: 32)
        title.autoresizingMask = [.minYMargin]
        page.addSubview(title)

        let description = makeLabel("전체 시스템 또는 선택한 앱의 오디오 신호를 처리합니다.", size: 12.5, weight: .regular)
        description.frame = NSRect(x: 24, y: 608, width: 500, height: 20)
        description.autoresizingMask = [.minYMargin, .width]
        page.addSubview(description)

        let stop = makeButton("중지", action: #selector(stopAudio))
        stop.frame = NSRect(x: 24, y: 555, width: 110, height: 38)
        stop.autoresizingMask = [.minYMargin]
        stop.toolTip = "처리를 멈추고 원래 소리로 되돌립니다."
        page.addSubview(stop)

        bundleField = NSTextField(frame: NSRect(x: 24, y: 500, width: 350, height: 32))
        bundleField.placeholderString = "예: com.tidal.desktop"
        bundleField.autoresizingMask = [.minYMargin, .width]
        page.addSubview(bundleField)

        routingStartAppButton = makeButton("특정 앱 적용", action: #selector(startSelectedApp))
        routingStartAppButton.frame = NSRect(x: 390, y: 496, width: 128, height: 40)
        routingStartAppButton.autoresizingMask = [.minYMargin, .minXMargin]
        routingStartAppButton.toolTip = "입력한 앱과 하위 오디오 프로세스에 적용합니다. 앱이나 helper를 재실행한 뒤 처리되지 않으면 앱에서 재생을 시작하고 이 버튼을 다시 누르세요. 기존 처리를 정상 중지한 뒤 현재 프로세스를 다시 선택합니다. 앱 목록 새로고침은 캡처 대상을 바꾸지 않습니다."
        page.addSubview(routingStartAppButton)

        let listButton = makeButton("실행 중인 앱 새로고침", action: #selector(refreshApps))
        listButton.frame = NSRect(x: 24, y: 446, width: 190, height: 34)
        listButton.autoresizingMask = [.minYMargin]
        page.addSubview(listButton)

        routingAppsScrollView = NSScrollView(frame: NSRect(x: 24, y: 24, width: 494, height: 408))
        routingAppsScrollView.borderType = .bezelBorder
        routingAppsScrollView.hasVerticalScroller = true
        routingAppsScrollView.autoresizingMask = [.width, .height]
        appsView = NSTextView(frame: routingAppsScrollView.bounds)
        appsView.isEditable = false
        appsView.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        appsView.textColor = .white
        appsView.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1)
        routingAppsScrollView.documentView = appsView
        page.addSubview(routingAppsScrollView)
        return page
    }

    private func makeSettingsPage() -> NSView {
        let page = NSView(frame: pageContainerView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 700))
        page.wantsLayer = true
        page.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor

        let title = makeLabel("설정", size: 24, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 24, y: 636, width: 220, height: 32)
        title.autoresizingMask = [.minYMargin]
        page.addSubview(title)

        let versionTitle = makeLabel("버전", size: 12, weight: .semibold)
        versionTitle.frame = NSRect(x: 24, y: 574, width: 90, height: 20)
        versionTitle.autoresizingMask = [.minYMargin]
        page.addSubview(versionTitle)

        let shortVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.2.7"
        let buildVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "9"
        let buildID =
            Bundle.main.object(forInfoDictionaryKey: "LCBuildID") as? String ?? ""
        // Show the monotonic build number (git commit count) plus the commit
        // hash and build time, so two builds with the same 0.2.x marketing
        // version are still distinguishable in Settings.
        let versionText = buildID.isEmpty
            ? "LowEnd Native Audio \(shortVersion) (build \(buildVersion))"
            : "LowEnd Native Audio \(shortVersion) (build \(buildVersion) · \(buildID))"
        let version = makeLabel(
            versionText,
            size: 12,
            weight: .semibold
        )
        version.textColor = .white
        version.frame = NSRect(x: 24, y: 544, width: 560, height: 24)
        version.autoresizingMask = [.minYMargin, .width]
        page.addSubview(version)

        let displayTitle = makeLabel("표시", size: 12, weight: .semibold)
        displayTitle.frame = NSRect(x: 24, y: 490, width: 90, height: 20)
        displayTitle.autoresizingMask = [.minYMargin]
        page.addSubview(displayTitle)

        expertModeButton = NSButton(
            checkboxWithTitle: "자세히 보기",
            target: self,
            action: #selector(expertModeChanged)
        )
        expertModeButton.frame = NSRect(x: 24, y: 454, width: 180, height: 24)
        expertModeButton.autoresizingMask = [.minYMargin]
        expertModeButton.state = expertModeEnabled ? .on : .off
        expertModeButton.toolTip = "오른쪽 위 포맷 표시에 Source, Tap, Engine, DAC 샘플레이트와 오버샘플링 정보를 자세히 보여줍니다."
        page.addSubview(expertModeButton)

        let note = makeLabel(
            "끄면 재생 음원, 출력 포맷, 적용 모델만 간결하게 표시합니다.",
            size: 12,
            weight: .regular
        )
        note.frame = NSRect(x: 24, y: 426, width: 480, height: 20)
        note.autoresizingMask = [.minYMargin, .width]
        page.addSubview(note)

        automaticRateMatchButton = NSButton(
            checkboxWithTitle: "자동 Rate Match",
            target: self,
            action: #selector(automaticRateMatchChanged)
        )
        automaticRateMatchButton.frame = NSRect(x: 24, y: 394, width: 320, height: 24)
        automaticRateMatchButton.autoresizingMask = [.minYMargin]
        automaticRateMatchButton.state = automaticRateMatchingEnabled ? .on : .off
        automaticRateMatchButton.toolTip = "감지된 Apple Music/TIDAL Source rate에 맞춰 기본 출력 DAC의 Nominal Sample Rate를 변경합니다. 전환 시 하드웨어 relock으로 약 1~2초 무음이 발생합니다. 일반적으로는 DAC rate 고정 + macOS 시스템 SRC가 무음 없이 더 부드럽게 동작합니다."
        page.addSubview(automaticRateMatchButton)

        let rateMatchNote = makeLabel(
            "트랙 전환 시 하드웨어 relock으로 약 1~2초 무음이 발생합니다.",
            size: 11,
            weight: .regular
        )
        rateMatchNote.frame = NSRect(x: 24, y: 372, width: 480, height: 18)
        rateMatchNote.autoresizingMask = [.minYMargin, .width]
        page.addSubview(rateMatchNote)
        return page
    }

    // MARK: - Output Conditioning page

    private func makeOutputConditioningPage() -> NSView {
        let page = NSView(frame: pageContainerView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 700))
        page.wantsLayer = true
        page.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor

        let title = makeLabel("출력 컨디셔닝", size: 24, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 24, y: 636, width: 320, height: 32)
        title.autoresizingMask = [.minYMargin]
        page.addSubview(title)

        let enableTitle = makeLabel("활성화", size: 12, weight: .semibold)
        enableTitle.frame = NSRect(x: 24, y: 596, width: 120, height: 20)
        enableTitle.autoresizingMask = [.minYMargin]
        page.addSubview(enableTitle)

        outputConditioningEnableButton = NSButton(
            checkboxWithTitle: "출력 컨디셔닝 사용",
            target: self,
            action: #selector(outputConditioningEnableChanged)
        )
        outputConditioningEnableButton.frame = NSRect(x: 24, y: 566, width: 320, height: 24)
        outputConditioningEnableButton.autoresizingMask = [.minYMargin]
        outputConditioningEnableButton.state = outputConditioningEnabled ? .on : .off
        outputConditioningEnableButton.toolTip = "출력 직전 신호를 처리합니다. 기본값은 꺼짐(Bypass)입니다. PCM Oversampling 2×는 출력 장치를 2배 샘플레이트로 전환하는 실험 기능입니다(44.1k→88.2k, 48k→96k). 전환 시 짧은 무음이 발생합니다. 실패하면 원래 PCM 구성을 복구하며, 복구에 실패하면 중지 미완료 상태와 재시도 안내를 표시합니다."
        page.addSubview(outputConditioningEnableButton)

        outputConditioningModePopup = makeConditioningPopup(
            titles: OutputConditioningMode.allCases.map { mode in
                mode == .pcmOversampling
                    ? "PCM Oversampling · DAC 출력 변환"
                    : mode == .experimentalDSD
                    ? "\(mode.displayName) (오프라인/테스트 전용)"
                    : mode.displayName
            },
            action: #selector(outputConditioningModeChanged),
            y: 512
        )
        page.addSubview(makeConditioningCaption("출력 모드", y: 536))
        page.addSubview(outputConditioningModePopup)
        selectConditioningPopup(outputConditioningModePopup, forRaw: outputConditioningModeRaw,
                                in: OutputConditioningMode.allCases.map { $0.rawValue })

        outputConditioningFactorPopup = makeConditioningPopup(
            titles: OutputConditioningParameters.allowedOversamplingFactors.map { factor in
                factor == 2 ? "2× (Live 가능)" : "\(factor)× (오프라인 전용)"
            },
            action: #selector(outputConditioningFactorChanged),
            y: 458
        )
        page.addSubview(makeConditioningCaption("DAC 출력 배수", y: 482))
        outputConditioningFactorPopup.toolTip = "모델·공간 처리 후 전체 PCM의 출력 레이트를 바꿉니다. HighExciter 내부 배음 생성 배율과 독립적입니다. 실시간 출력은 지원 장치의 2×만 적용됩니다."
        page.addSubview(outputConditioningFactorPopup)
        if let index = OutputConditioningParameters.allowedOversamplingFactors.firstIndex(of: outputConditioningFactor) {
            outputConditioningFactorPopup.selectItem(at: index)
        }

        outputConditioningFilterPopup = makeConditioningPopup(
            titles: ResamplingFilterMode.allCases.map { $0.displayName },
            action: #selector(outputConditioningFilterChanged),
            y: 404
        )
        page.addSubview(makeConditioningCaption("필터 모드", y: 428))
        page.addSubview(outputConditioningFilterPopup)
        selectConditioningPopup(outputConditioningFilterPopup, forRaw: outputConditioningFilterRaw,
                                in: ResamplingFilterMode.allCases.map { $0.rawValue })

        outputConditioningHeadroomCaption = makeConditioningCaption("헤드룸", y: 374)
        outputConditioningHeadroomCaption.frame.size.width = max(0, page.bounds.width - 48)
        outputConditioningHeadroomCaption.autoresizingMask = [.minYMargin, .width]
        page.addSubview(outputConditioningHeadroomCaption)
        outputConditioningHeadroomSlider = NSSlider(
            value: outputConditioningHeadroomDB,
            minValue: -12,
            maxValue: 0,
            target: self,
            action: #selector(outputConditioningHeadroomChanged)
        )
        outputConditioningHeadroomSlider.isContinuous = true
        outputConditioningHeadroomSlider.setAccessibilityLabel("2× 출력 헤드룸")
        outputConditioningHeadroomSlider.frame = NSRect(x: 24, y: 348, width: max(120, page.bounds.width - 144), height: 24)
        outputConditioningHeadroomSlider.autoresizingMask = [.minYMargin, .width]
        page.addSubview(outputConditioningHeadroomSlider)
        outputConditioningHeadroomValueLabel = makeLabel(
            formatDbText(outputConditioningHeadroomDB),
            size: 12, weight: .regular
        )
        outputConditioningHeadroomValueLabel.alignment = .right
        outputConditioningHeadroomValueLabel.frame = NSRect(x: page.bounds.width - 104, y: 348, width: 80, height: 20)
        outputConditioningHeadroomValueLabel.autoresizingMask = [.minYMargin, .minXMargin]
        page.addSubview(outputConditioningHeadroomValueLabel)

        outputConditioningDitherButton = NSButton(
            checkboxWithTitle: "디더",
            target: self,
            action: #selector(outputConditioningDitherChanged)
        )
        outputConditioningDitherButton.frame = NSRect(x: 24, y: 314, width: 160, height: 24)
        outputConditioningDitherButton.autoresizingMask = [.minYMargin]
        outputConditioningDitherButton.state = outputConditioningDither ? .on : .off
        page.addSubview(outputConditioningDitherButton)

        outputConditioningNoiseShapeButton = NSButton(
            checkboxWithTitle: "노이즈 셰이핑",
            target: self,
            action: #selector(outputConditioningNoiseShapeChanged)
        )
        outputConditioningNoiseShapeButton.frame = NSRect(x: 190, y: 314, width: 200, height: 24)
        outputConditioningNoiseShapeButton.autoresizingMask = [.minYMargin]
        outputConditioningNoiseShapeButton.state = outputConditioningNoiseShape ? .on : .off
        page.addSubview(outputConditioningNoiseShapeButton)

        page.addSubview(makeConditioningCaption("DSD 모드 (오프라인/테스트 전용 — 실시간 미지원)", y: 282))
        outputConditioningDSDPopup = makeConditioningPopup(
            titles: DSDMode.allCases.map { $0.displayName },
            action: #selector(outputConditioningDSDChanged),
            y: 258
        )
        page.addSubview(outputConditioningDSDPopup)
        selectConditioningPopup(outputConditioningDSDPopup, forRaw: outputConditioningDSDRaw,
                                in: DSDMode.allCases.map { $0.rawValue })

        let warning = makeLabel(
            "DSD/DoP는 현재 오프라인/테스트 전용이며 실시간 출력에 연결되어 있지 않습니다. 아래 carrier 표시는 DAC가 해당 rate(176.4 / 352.8 / 705.6 kHz)를 지원하는지의 참고용이며, 실제 DSD 출력으로 전환되지는 않습니다. 실시간 출력은 PCM(PCM Oversampling 2× 지원)으로만 동작합니다.",
            size: 11, weight: .regular
        )
        warning.lineBreakMode = .byWordWrapping
        warning.maximumNumberOfLines = 0
        warning.frame = NSRect(x: 24, y: 206, width: 540, height: 44)
        warning.autoresizingMask = [.minYMargin, .width]
        page.addSubview(warning)

        outputConditioningStatusLabel = makeLabel("", size: 12, weight: .regular)
        outputConditioningStatusLabel.textColor = NSColor(calibratedRed: 0.62, green: 0.68, blue: 0.75, alpha: 1)
        outputConditioningStatusLabel.lineBreakMode = .byWordWrapping
        outputConditioningStatusLabel.maximumNumberOfLines = 0
        outputConditioningStatusLabel.frame = NSRect(x: 24, y: 150, width: 540, height: 44)
        outputConditioningStatusLabel.autoresizingMask = [.minYMargin, .width]
        page.addSubview(outputConditioningStatusLabel)

        outputConditioningRuntimeLabel = makeLabel("", size: 12, weight: .semibold)
        outputConditioningRuntimeLabel.lineBreakMode = .byWordWrapping
        outputConditioningRuntimeLabel.maximumNumberOfLines = 3
        outputConditioningRuntimeLabel.frame = NSRect(x: 24, y: 78, width: max(0, page.bounds.width - 48), height: 64)
        outputConditioningRuntimeLabel.autoresizingMask = [.minYMargin, .width]
        page.addSubview(outputConditioningRuntimeLabel)

        applyOutputConditioningControlEnabledState()
        updateOutputConditioningStatus()
        return page
    }

    /// Read-only Diagnostics/Status page. Every value is sourced from existing
    /// off-callback state (NotificationCenter mirror + diagnosticsSnapshot() +
    /// ExciterOversamplingPolicy.resolve + a CoreAudio device-name query). The
    /// realtime render callback is never touched.
    private func makeDiagnosticsPage() -> NSView {
        let page = NSView(frame: pageContainerView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 700))
        page.wantsLayer = true
        page.layer?.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor

        let title = makeLabel("진단 / 상태", size: 24, weight: .bold)
        title.textColor = .white
        title.frame = NSRect(x: 24, y: 636, width: 320, height: 32)
        title.autoresizingMask = [.minYMargin]
        page.addSubview(title)

        let intro = makeLabel(
            "오디오 콜백에 영향을 주지 않고 기존 상태 스냅샷을 읽어 표시합니다. 1초마다 갱신됩니다.",
            size: 11, weight: .regular
        )
        intro.textColor = NSColor(calibratedRed: 0.55, green: 0.60, blue: 0.67, alpha: 1)
        intro.lineBreakMode = .byWordWrapping
        intro.maximumNumberOfLines = 0
        intro.frame = NSRect(x: 24, y: 614, width: 540, height: 28)
        intro.autoresizingMask = [.minYMargin, .width]
        page.addSubview(intro)

        page.addSubview(makeDiagSection("샘플레이트 · 포맷", y: 584))
        diagTapValue = addDiagRow(to: page, caption: "Tap 샘플레이트", value: "—", y: 560)
        diagEngineValue = addDiagRow(to: page, caption: "엔진(처리) 샘플레이트", value: "—", y: 536)
        diagDeviceValue = addDiagRow(to: page, caption: "출력 장치 샘플레이트", value: "—", y: 512)
        diagFormatValue = addDiagRow(to: page, caption: "출력 포맷(비트 깊이/샘플 타입)", value: "—", y: 488)

        page.addSubview(makeDiagSection("Output Conditioning", y: 452))
        diagConditioningValue = addDiagRow(to: page, caption: "상태", value: "Off", y: 428)
        diagFallbackValue = addDiagRow(to: page, caption: "폴백 사유", value: "—", y: 404)
        diagFallbackValue.lineBreakMode = .byWordWrapping
        diagFallbackValue.maximumNumberOfLines = 0
        diagFallbackValue.frame = NSRect(x: 224, y: 392, width: 360, height: 36)

        page.addSubview(makeDiagSection("HighExciter 오버샘플링", y: 372))
        diagHighExciterValue = addDiagRow(to: page, caption: "실제 적용 모드", value: "—", y: 348)

        page.addSubview(makeDiagSection("XRun 카운터", y: 312))
        diagXRunValue = addDiagRow(to: page, caption: "underrun / drop / 분석 drop", value: "0 / 0 / 0", y: 288)
        diagRestartValue = addDiagRow(to: page, caption: "엔진 재시작", value: "0", y: 264)

        page.addSubview(makeDiagSection("출력 장치", y: 224))
        diagDeviceNameValue = addDiagRow(to: page, caption: "이름 · ID", value: "—", y: 200)

        page.addSubview(makeDiagSection("캡처 대상", y: 160))
        diagCaptureValue = addDiagRow(to: page, caption: "실제 캡처 프로세스", value: "—", y: 136)
        diagAudioFlowValue = addDiagRow(to: page, caption: "오디오 데이터", value: "—", y: 108)

        refreshDiagnosticsPanel()
        refreshAudioFlowPresentation()
        return page
    }

    private func makeDiagSection(_ text: String, y: CGFloat) -> NSTextField {
        let label = makeLabel(text, size: 13, weight: .semibold)
        label.textColor = NSColor(calibratedRed: 0.55, green: 0.78, blue: 0.96, alpha: 1)
        label.frame = NSRect(x: 24, y: y, width: 540, height: 20)
        label.autoresizingMask = [.minYMargin, .width]
        return label
    }

    @discardableResult
    private func addDiagRow(to page: NSView, caption: String, value: String, y: CGFloat) -> NSTextField {
        let cap = makeLabel(caption, size: 12, weight: .regular)
        cap.textColor = NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)
        cap.frame = NSRect(x: 24, y: y, width: 200, height: 18)
        cap.autoresizingMask = [.minYMargin]
        page.addSubview(cap)
        let val = makeLabel(value, size: 12, weight: .regular)
        val.frame = NSRect(x: 224, y: y, width: 360, height: 18)
        val.autoresizingMask = [.minYMargin, .width]
        val.lineBreakMode = .byTruncatingTail
        page.addSubview(val)
        return val
    }

    /// Refresh the format / conditioning / HighExciter rows of the Diagnostics
    /// panel from main-cached state. Safe to call before the page is built and
    /// before the engine starts. Counters + device identity are filled by
    /// updateDiagnostics (1 Hz); this handles the notification-driven rows.
    private func refreshDiagnosticsPanel() {
        // The output page must refresh even when Diagnostics was never opened.
        refreshOutputConditioningHeadroomState()
        guard diagTapValue != nil else { return }
        diagTapValue.stringValue = formatDiagRate(currentTapSampleRate)
        diagEngineValue.stringValue = formatDiagRate(currentProcessingSampleRate)
        diagDeviceValue.stringValue = formatDiagRate(currentDeviceSampleRate)
        diagFormatValue.stringValue =
            currentProcessingSampleRate == nil ? "—" : currentOutputSampleFormat

        // Separate the selected offline options from the actual live state.
        let isPCM2xArmed = outputConditioningEnabled
            && OutputConditioningMode(rawValue: outputConditioningModeRaw) == .pcmOversampling
            && outputConditioningFactor == 2
        // A fallback reason only applies to the 2×-armed path; if the user has
        // since switched to a non-2× selection, drop the stale reason so it does
        // not linger on the panel.
        if !isPCM2xArmed, !currentLivePCM2xFallback.isEmpty {
            currentLivePCM2xFallback = ""
        }
        let conditioningText: String
        if currentStopFailure != nil {
            conditioningText = "중지 미완료 · 재시도 필요"
        } else if currentProcessingFailure != nil {
            conditioningText = "처리 중단 · 중지 후 다시 적용"
        } else if !outputConditioningEnabled {
            conditioningText = "Off"
        } else if currentLivePCM2xActive {
            conditioningText = "PCM 2× active"
        } else if !currentLivePCM2xFallback.isEmpty {
            conditioningText = "2× 미적용 · 상태 확인"
        } else {
            conditioningText = isPCM2xArmed ? "PCM 2× 대기" : "Bypass (선택 기능 Live 미적용)"
        }
        diagConditioningValue.stringValue = conditioningText
        let reason = currentStopFailure ?? currentProcessingFailure ?? currentLivePCM2xFallback
        let hasFallback = !reason.isEmpty
        diagFallbackValue.stringValue = hasFallback ? reason : "—"
        diagFallbackValue.textColor = hasFallback
            ? NSColor(calibratedRed: 0.95, green: 0.76, blue: 0.40, alpha: 1)
            : NSColor(calibratedRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)

        diagHighExciterValue.stringValue = highExciterDiagnosticsText()
    }

    /// HighExciter resolved oversampling mode (1× / 2× / 4× / safety-limited),
    /// computed from the cached engine sample rate + the selected oversampling
    /// mode via the same pure policy used by updateOversamplingIndicator.
    private func highExciterDiagnosticsText() -> String {
        guard selectedDSPModel() == .highExciter else { return "—" }
        guard let sampleRate = currentTapSampleRate else { return "포맷 대기 중" }
        let resolution = ExciterOversamplingPolicy.resolve(
            processingSampleRate: sampleRate,
            mode: exciterOversamplingMode
        )
        let internalText = formatDiagRate(resolution.internalSampleRate)
        if resolution.isSafetyLimited {
            return "safety-limited · 요청 \(resolution.requestedFactor)× → 적용 \(resolution.effectiveFactor)× (\(internalText))"
        }
        return "\(resolution.effectiveFactor)× (\(internalText))"
    }

    private func formatDiagRate(_ rate: Double?) -> String {
        AudioFormatStatus.rateText(rate)
    }

    /// Single source for the XRun row format (underrun / drop / analysis-drop),
    /// shared by updateDiagnostics (live) and stopAudio (zero reset) so the two
    /// cannot drift.
    private func formatXRunCounts(underrun: UInt64, drop: UInt64, vis: UInt64) -> String {
        "\(underrun) / \(drop) / \(vis)"
    }

    private func makeConditioningCaption(_ text: String, y: CGFloat) -> NSTextField {
        let label = makeLabel(text, size: 12, weight: .semibold)
        label.frame = NSRect(x: 24, y: y, width: 260, height: 20)
        label.autoresizingMask = [.minYMargin]
        return label
    }

    private func makeConditioningPopup(titles: [String], action: Selector, y: CGFloat) -> NSPopUpButton {
        let width = max(220, (pageContainerView?.bounds.width ?? 620) - 48)
        let popup = NSPopUpButton(frame: NSRect(x: 24, y: y, width: width, height: 26), pullsDown: false)
        popup.autoresizingMask = [.minYMargin, .width]
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        return popup
    }

    private func selectConditioningPopup(_ popup: NSPopUpButton, forRaw raw: UInt32, in rawValues: [UInt32]) {
        if let index = rawValues.firstIndex(of: raw) {
            popup.selectItem(at: index)
        }
    }

    private func applyOutputConditioningControlEnabledState() {
        let on = outputConditioningEnabled
        outputConditioningModePopup?.isEnabled = on
        let pcm = OutputConditioningMode(rawValue: outputConditioningModeRaw) == .pcmOversampling
        outputConditioningFactorPopup?.isEnabled = on && pcm
        outputConditioningFilterPopup?.isEnabled = on && pcm && outputConditioningFactor == 2
        refreshOutputConditioningHeadroomState()
        outputConditioningDitherButton?.isEnabled = false
        outputConditioningNoiseShapeButton?.isEnabled = false
        outputConditioningDitherButton?.toolTip = "현재 Float32 live 출력에는 적용되지 않습니다."
        outputConditioningNoiseShapeButton?.toolTip = "현재 Float32 live 출력에는 적용되지 않습니다."
        // DSD gating depends on device capability (set in updateOutputConditioningStatus).
    }

    private func refreshOutputConditioningHeadroomState() {
        guard let slider = outputConditioningHeadroomSlider else { return }
        let requests2x = outputConditioningEnabled
            && OutputConditioningMode(rawValue: outputConditioningModeRaw) == .pcmOversampling
            && outputConditioningFactor == 2
        if !requests2x { currentLivePCM2xFallback = "" }
        let failed = !currentLivePCM2xActive && !currentLivePCM2xFallback.isEmpty
        // The requested gain remains editable for the next successful run.
        // Editing an inactive route saves it without retrying a device transition.
        slider.isEnabled = outputConditioningEnabled
        let state: String
        if pendingAudioOperation != nil {
            state = "시작·중지 처리 중 · 설정 저장"
        } else if currentStopFailure != nil {
            state = "중지 미완료 · 설정 저장"
        } else if currentProcessingFailure != nil {
            state = "처리 중단 · 설정 저장"
        } else if currentLivePCM2xActive && !requests2x {
            state = "2× 해제 대기 · 미적용"
        } else if !outputConditioningEnabled {
            state = "꺼짐 · 미적용"
        } else if !requests2x {
            state = "현재 모드에서 미적용 · 설정 저장"
        } else if currentLivePCM2xActive {
            state = "2× 출력 중"
        } else if failed {
            state = "2× 미적용 · 설정 저장"
        } else {
            state = "2× 출력 대기 · 아직 미적용"
        }
        outputConditioningHeadroomCaption?.stringValue = "헤드룸 · \(state)"
        // The number is the requested setting, not a callback acknowledgement.
        let detail = "\(state). 설정 \(formatDbText(outputConditioningHeadroomDB)). 실제 2× 출력에서만 음량을 감쇠합니다. 0 dB는 감쇠 없음, −6 dB는 신호 진폭 약 절반입니다. 모델 내부의 포화·배음을 되돌리지는 않습니다."
        slider.toolTip = detail
        outputConditioningHeadroomValueLabel?.toolTip = detail
        outputConditioningHeadroomCaption?.toolTip = failed ? currentLivePCM2xFallback : detail
        let failure = currentStopFailure ?? currentProcessingFailure
        if pendingAudioOperation != nil {
            outputConditioningRuntimeLabel?.stringValue = "오디오 시작·중지 작업을 기다리는 중입니다. 설정은 저장되며, 정상 시작이 완료되면 최신 값이 적용됩니다."
            outputConditioningRuntimeLabel?.toolTip = nil
        } else if let failure {
            outputConditioningRuntimeLabel?.stringValue = "오디오 처리가 중단됐습니다. 오디오 적용에서 중지 후 다시 적용하세요. 헤드룸 값은 저장되며 현재 소리에는 적용되지 않습니다."
            outputConditioningRuntimeLabel?.toolTip = failure
        } else if failed {
            outputConditioningRuntimeLabel?.stringValue = "현재 2× 출력은 미적용입니다. 헤드룸 값은 저장되며 2× 출력이 활성화되면 적용됩니다."
            outputConditioningRuntimeLabel?.toolTip = currentLivePCM2xFallback
        } else {
            outputConditioningRuntimeLabel?.stringValue = ""
            outputConditioningRuntimeLabel?.toolTip = nil
        }
    }

    @objc private func outputConditioningEnableChanged() {
        outputConditioningEnabled = outputConditioningEnableButton.state == .on
        preferenceStore.set(outputConditioningEnabled, forKey: "outputConditioningEnabled")
        applyOutputConditioningControlEnabledState()
        updateOutputConditioningStatus()
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningModeChanged() {
        let index = outputConditioningModePopup.indexOfSelectedItem
        let mode = OutputConditioningMode.allCases[safe: index] ?? .bypass
        outputConditioningModeRaw = mode.rawValue
        preferenceStore.set(Int(mode.rawValue), forKey: "outputConditioningMode")
        updateOutputConditioningStatus()
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningFactorChanged() {
        let index = outputConditioningFactorPopup.indexOfSelectedItem
        let factor = OutputConditioningParameters.allowedOversamplingFactors[safe: index] ?? 2
        outputConditioningFactor = factor
        preferenceStore.set(factor, forKey: "outputConditioningFactor")
        updateOutputConditioningStatus()
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningFilterChanged() {
        let index = outputConditioningFilterPopup.indexOfSelectedItem
        let mode = ResamplingFilterMode.allCases[safe: index] ?? .linearPhaseShort
        outputConditioningFilterRaw = mode.rawValue
        preferenceStore.set(Int(mode.rawValue), forKey: "outputConditioningFilter")
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningHeadroomChanged() {
        outputConditioningHeadroomDB = Double(outputConditioningHeadroomSlider.doubleValue)
        pendingHeadroomEdit = true
        preferenceStore.set(outputConditioningHeadroomDB, forKey: "outputConditioningHeadroomDB")
        outputConditioningHeadroomValueLabel.stringValue = formatDbText(outputConditioningHeadroomDB)
        refreshOutputConditioningHeadroomState()
        if currentLivePCM2xActive { pushActiveHeadroomSettings() }
    }

    @objc private func outputConditioningDitherChanged() {
        outputConditioningDither = outputConditioningDitherButton.state == .on
        preferenceStore.set(outputConditioningDither, forKey: "outputConditioningDither")
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningNoiseShapeChanged() {
        outputConditioningNoiseShape = outputConditioningNoiseShapeButton.state == .on
        preferenceStore.set(outputConditioningNoiseShape, forKey: "outputConditioningNoiseShape")
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningDSDChanged() {
        let index = outputConditioningDSDPopup.indexOfSelectedItem
        let mode = DSDMode.allCases[safe: index] ?? .off
        outputConditioningDSDRaw = mode.rawValue
        preferenceStore.set(Int(mode.rawValue), forKey: "outputConditioningDSD")
        // The unsupported-mode warning depends on the selected mode, so refresh it.
        updateOutputConditioningStatus()
        pushOutputConditioningSettings()
    }

    private func currentOutputConditioningParameters() -> OutputConditioningParameters {
        var params = OutputConditioningParameters()
        params.isEnabled = outputConditioningEnabled
        params.outputMode = OutputConditioningMode(rawValue: outputConditioningModeRaw) ?? .bypass
        params.oversamplingFactor = outputConditioningFactor
        params.filterMode = ResamplingFilterMode(rawValue: outputConditioningFilterRaw) ?? .linearPhaseShort
        params.headroomDB = Float(outputConditioningHeadroomDB)
        params.ditherEnabled = outputConditioningDither
        params.noiseShapingEnabled = outputConditioningNoiseShape
        params.dsdMode = DSDMode(rawValue: outputConditioningDSDRaw) ?? .off
        return params
    }

    private func pushOutputConditioningSettings() {
        guard pendingAudioOperation == nil, currentStopFailure == nil, currentProcessingFailure == nil, let processor else { return }
        pendingHeadroomEdit = false
        processor.updateOutputConditioning(currentOutputConditioningParameters())
    }

    private func pushActiveHeadroomSettings() {
        guard pendingAudioOperation == nil, currentStopFailure == nil, currentProcessingFailure == nil, let processor else { return }
        let parameters = currentOutputConditioningParameters()
        guard parameters.isEnabled, parameters.outputMode == .pcmOversampling,
              parameters.oversamplingFactor == 2 else { return }
        pendingHeadroomEdit = false
        processor.updateActiveLivePCM2xParameters(parameters)
    }

    private func refreshOutputConditioningCapability() {
        outputConditioningCapability = OutputConditioningCapabilityQuery.queryDefaultOutput()
        if isViewLoadedConditioningPage() {
            updateOutputConditioningStatus()
        }
    }

    private func isViewLoadedConditioningPage() -> Bool {
        outputConditioningDSDPopup != nil
    }

    private func updateOutputConditioningStatus() {
        applyOutputConditioningControlEnabledState()
        guard let statusLabel = outputConditioningStatusLabel else { return }
        let capability = outputConditioningCapability
        var lines: [String] = []
        if let capability {
            // DSD/DoP is offline/test-only — these carrier figures are DAC
            // capability checks shown for reference, NOT as live output support.
            let carrierText = [DSDMode.dsd64, .dsd128, .dsd256]
                .map { "\($0.displayName) \(Self.rateText(DoPCarrier.requiredCarrierRate(for: $0))): \(capability.canAttemptDoP($0) ? "DAC 지원(참고용)" : "DAC 미지원")" }
                .joined(separator: " / ")
            lines.append("DSD/DoP (오프라인/테스트 전용, 실시간 출력 미지원): \(carrierText)")
            // Live PCM 2× (experimental, real-time) capability for the eligible rates.
            let live44 = capability.canAttemptLivePCM2x(tapRate: 44_100)
            let live48 = capability.canAttemptLivePCM2x(tapRate: 48_000)
            lines.append("Live PCM 2×(실험, 실시간 지원): 44.1k→88.2k \(live44 ? "지원" : "미지원") / 48k→96k \(live48 ? "지원" : "미지원")")
        } else {
            lines.append("DAC capability를 조회하지 못했습니다. 실시간 출력은 PCM으로만 동작합니다.")
        }
        // DSD/DoP is offline/test-only — the picker is never enabled for live
        // output; selecting a family has no effect on the real-time path.
        outputConditioningDSDPopup?.isEnabled = false

        // A selected DSD family is informational only: it does not change the
        // real-time output, which stays PCM. State that plainly instead of
        // implying a fallback from an active DSD output.
        let selectedMode = DSDMode(rawValue: outputConditioningDSDRaw) ?? .off
        if selectedMode != .off {
            lines.append("ℹ \(selectedMode.displayName)는 오프라인/테스트 전용이며 실시간 출력에 적용되지 않습니다. 현재 PCM으로 출력됩니다.")
        }

        // PCM Oversampling 2× selected but the device cannot run it → will fall
        // back to PCM bypass on activation.
        let pcmOSActive = outputConditioningEnabled
            && (OutputConditioningMode(rawValue: outputConditioningModeRaw) == .pcmOversampling)
            && outputConditioningFactor == 2
        if pcmOSActive,
           let capability,
           !(capability.canAttemptLivePCM2x(tapRate: 44_100) || capability.canAttemptLivePCM2x(tapRate: 48_000)) {
            lines.append("⚠ 이 장치가 2× 출력 샘플레이트(88.2/96kHz)를 지원하지 않아 PCM Oversampling이 PCM으로 폴백됩니다.")
        }

        statusLabel.stringValue = lines.joined(separator: "\n")
    }

    private static func rateText(_ sampleRate: Double) -> String {
        sampleRate >= 1000
            ? String(format: "%.1f kHz", sampleRate / 1000)
            : String(format: "%.0f Hz", sampleRate)
    }

    private func layoutModelPage() {
        guard let page = pageViews[.model] else { return }
        let width = page.bounds.width
        let height = page.bounds.height
        modelExplanationView.frame = NSRect(x: 24, y: height - 246, width: max(width - 48, 1), height: 78)
        modelControlsView.frame = NSRect(x: 24, y: height - 402, width: max(width - 48, 1), height: 132)
        modelPresetsView.frame = NSRect(x: 24, y: height - 458, width: max(width - 48, 1), height: 38)

        let controlsWidth = modelControlsView.bounds.width
        let sliderWidth = max(controlsWidth - 220, 120)
        for slider in [intensitySlider, bodySlider, outputSlider] {
            slider?.frame.size.width = sliderWidth
        }
        for valueLabel in [intensityValueLabel, bodyValueLabel, outputValueLabel] {
            valueLabel?.frame.origin.x = controlsWidth - 90
        }
        oversamplingModeControl?.frame.size.width = max(controlsWidth - 220, 180)

        let gap: CGFloat = 8
        let presetWidth = max((modelPresetsView.bounds.width - gap * 4) / 5, 48)
        for (index, button) in presetButtons.enumerated() {
            button.frame = NSRect(
                x: CGFloat(index) * (presetWidth + gap),
                y: 0,
                width: presetWidth,
                height: 36
            )
        }
    }

    private func layoutRoutingPage() {
        guard let page = pageViews[.routing] else { return }
        let width = page.bounds.width
        bundleField?.frame = NSRect(
            x: 24,
            y: page.bounds.height - 200,
            width: max(width - 200, 160),
            height: 32
        )
        routingStartAppButton?.frame = NSRect(
            x: max(width - 152, 184),
            y: page.bounds.height - 204,
            width: 128,
            height: 40
        )
        routingAppsScrollView?.frame = NSRect(
            x: 24,
            y: 24,
            width: max(page.bounds.width - 48, 1),
            height: max(page.bounds.height - 292, 120)
        )
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
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 78))
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
            label.frame = NSRect(x: 18, y: 48.0 - CGFloat(index) * 22.0, width: 484, height: 20)
            label.autoresizingMask = [.width]
            label.lineBreakMode = .byTruncatingTail
            view.addSubview(label)
        }

        return view
    }

    private func makeControlSection() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 132))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.17, alpha: 1).cgColor
        view.layer?.cornerRadius = 8

        intensitySlider = makeSlider(value: 55, min: 0, max: 100)
        bodySlider = makeSlider(value: 30, min: 0, max: 100)
        outputSlider = makeSlider(value: -1.5, min: -18, max: 6)

        applySliderValues(loadSliderValues(for: selectedDSPModel()))

        intensityValueLabel = makeLabel("", size: 13, weight: .semibold)
        bodyValueLabel = makeLabel("", size: 13, weight: .semibold)
        outputValueLabel = makeLabel("", size: 13, weight: .semibold)

        intensityNameLabel = addSliderRow(to: view, y: 86, title: "LowEnd", slider: intensitySlider, valueLabel: intensityValueLabel)
        bodyNameLabel = addSliderRow(to: view, y: 48, title: "Body", slider: bodySlider, valueLabel: bodyValueLabel)
        outputNameLabel = addSliderRow(to: view, y: 10, title: "Output", slider: outputSlider, valueLabel: outputValueLabel)

        oversamplingModeLabel = makeLabel("배음 품질", size: 13, weight: .semibold)
        oversamplingModeLabel.frame = NSRect(x: 16, y: 10, width: 100, height: 24)
        oversamplingModeControl = NSSegmentedControl(
            labels: ExciterOversamplingMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(oversamplingModeChanged)
        )
        oversamplingModeControl.frame = NSRect(x: 120, y: 7, width: 310, height: 28)
        oversamplingModeControl.autoresizingMask = [.width]
        oversamplingModeControl.selectedSegment = segmentIndex(for: exciterOversamplingMode)
        oversamplingModeControl.toolTip = "HighExciter 배음 생성 구간만 높은 레이트로 계산한 뒤 원래 Tap 레이트로 돌아옵니다. DAC 출력 배수와 독립적입니다. Auto는 Tap 처리율에 맞춰 선택하며, 수동 선택도 내부 처리율 384 kHz 한도에서 제한됩니다."
        view.addSubview(oversamplingModeLabel)
        view.addSubview(oversamplingModeControl)
        configureControlsForSelectedModel()
        return view
    }

    private func makePresetSection() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        presetButtons = [
            makeButton("IEM", action: #selector(applyIEMPreset)),
            makeButton("Gentle", action: #selector(applyGentlePreset)),
            makeButton("LowEnd", action: #selector(applyLowEndPreset)),
            makeButton("Deep", action: #selector(applyDeepPreset)),
            makeButton("Clear", action: #selector(applyClearPreset))
        ]

        let gap: CGFloat = 10
        let width = (520.0 - gap * 4) / 5
        for index in 0..<presetButtons.count {
            presetButtons[index].frame = NSRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: 36)
            view.addSubview(presetButtons[index])
        }
        configurePresetButtons()

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
        label.frame = NSRect(x: 18, y: y, width: 96, height: 24)
        slider.frame = NSRect(x: 120, y: y, width: 300, height: 24)
        slider.autoresizingMask = [.width]
        valueLabel.frame = NSRect(x: 430, y: y, width: 72, height: 24)
        valueLabel.autoresizingMask = [.minXMargin]
        view.addSubview(label)
        view.addSubview(slider)
        view.addSubview(valueLabel)
        return label
    }

    @objc private func sliderChanged() {
        updateSliderLabels()
        updateOversamplingIndicator()
        let model = selectedDSPModel()
        if model != .clean {
            saveSliderValues(
                SliderValues(
                    intensity: intensitySlider.doubleValue,
                    body: bodySlider.doubleValue,
                    outputDb: outputSlider.doubleValue
                ),
                for: model
            )
        }
        guard pendingAudioOperation == nil else { return }
        processor?.updateDSP(intensity: Float(intensitySlider.doubleValue),
                             body: Float(bodySlider.doubleValue),
                             outputDb: Float(outputSlider.doubleValue),
                             dspModel: model,
                             exciterOversamplingMode: exciterOversamplingMode)
    }

    @objc private func oversamplingModeChanged() {
        let modes = ExciterOversamplingMode.allCases
        let index = oversamplingModeControl.selectedSegment
        guard modes.indices.contains(index) else { return }
        exciterOversamplingMode = modes[index]
        preferenceStore.set(
            Int(exciterOversamplingMode.rawValue),
            forKey: "exciterOversamplingMode"
        )
        sliderChanged()
    }

    @objc private func automaticRateMatchChanged() {
        automaticRateMatchingEnabled = automaticRateMatchButton.state == .on
        preferenceStore.set(
            automaticRateMatchingEnabled,
            forKey: "automaticRateMatchingEnabled"
        )
        rateMatchStatusText = automaticRateMatchingEnabled ? "자동 켜짐: 소스 안정화 대기" : "자동 꺼짐"
        updateRateMatchPreview()
        if pendingAudioOperation == nil && currentStopFailure == nil {
            processor?.setAutomaticRateMatchingEnabled(automaticRateMatchingEnabled)
        }
    }

    @objc private func expertModeChanged() {
        expertModeEnabled = expertModeButton.state == .on
        preferenceStore.set(expertModeEnabled, forKey: "expertModeEnabled")
        // "자세히 보기" only toggles the detailed format header; 자동 Rate Match is
        // independent and stays available regardless of this setting.
        updateFormatHeaderMode()
        layoutApplication()
    }

    @objc private func modelChanged() {
        let model = selectedDSPModel()
        preferenceStore.set(modelSelector.selectedSegment, forKey: "selectedModel")
        applySliderValues(loadSliderValues(for: model))
        configureControlsForSelectedModel()
        sliderChanged()
        updateCompactFormatSummary()
        statusLabel.stringValue = currentProcessingFailure == nil
            ? "모델 변경: \(model.displayName)"
            : "처리 중단 · 모델 설정 저장: \(model.displayName)"
        refreshAudioOperationPresentation()
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
            intensitySlider.toolTip = "Clean 모델은 톤 DSP(회로/배음) 처리를 사용하지 않습니다."
            bodySlider.toolTip = "Clean 모델은 톤 DSP(회로/배음) 처리를 사용하지 않습니다."
            outputSlider.toolTip = "Clean 모델은 출력 게인을 적용하지 않습니다. 공간 음향은 모델과 관계없이 별도로 동작합니다."
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
            outputValueLabel.stringValue = formatDbText(outputSlider.doubleValue)
        case .highExciter:
            intensityValueLabel.stringValue = String(format: "%.2f", intensitySlider.doubleValue / 100)
            bodyValueLabel.stringValue = String(format: "%.2f", bodySlider.doubleValue / 100)
            outputValueLabel.stringValue = "Bypass"
        }
    }

    private func updateOversamplingIndicator() {
        guard oversamplingLabel != nil else { return }
        guard expertModeEnabled, selectedDSPModel() == .highExciter else {
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

        guard let sampleRate = currentTapSampleRate else {
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

    private func updateFormatHeaderMode() {
        let showExpertDetails = expertModeEnabled
        compactSourceTitleLabel?.isHidden = showExpertDetails
        compactSourceValueLabel?.isHidden = showExpertDetails
        compactOutputLabel?.isHidden = showExpertDetails
        compactModelLabel?.isHidden = showExpertDetails
        sourceFormatLabel?.isHidden = !showExpertDetails
        formatLabel?.isHidden = !showExpertDetails
        rateMatchPreviewLabel?.isHidden = !showExpertDetails
        updateOversamplingIndicator()
    }

    private func updateCompactFormatSummary() {
        guard compactSourceTitleLabel != nil else { return }

        if let playerName = currentSourcePlayerName {
            compactSourceTitleLabel.stringValue = "\(playerName) 재생 음원"
        } else {
            compactSourceTitleLabel.stringValue = "음원 재생"
        }

        if let sourceRate = currentSourceSampleRate {
            let depthText = currentSourceBitDepth.map { "\($0)-bit" } ?? "비트 깊이 미확인"
            compactSourceValueLabel.stringValue = "\(formatSampleRate(sourceRate)) / \(depthText)"
        } else {
            compactSourceValueLabel.stringValue = "재생 정보 대기 중"
        }

        if let outputRate = currentDeviceSampleRate {
            compactOutputLabel.stringValue =
                "출력  \(formatSampleRate(outputRate)) / \(currentOutputSampleFormat)"
        } else {
            compactOutputLabel.stringValue = "출력 포맷 대기 중"
        }
        compactModelLabel.stringValue = "적용 모델  \(selectedDSPModel().displayName)"
    }

    private func formatSampleRate(_ sampleRate: Double) -> String {
        sampleRate >= 1_000
            ? String(format: "%.1f kHz", sampleRate / 1_000)
            : String(format: "%.0f Hz", sampleRate)
    }

    private func spatialSettingsFromControls() -> SpatialSettings {
        spatialControlModel.settings
    }

    private func updateSpatialControls(from settings: SpatialSettings, notifyProcessor: Bool) {
        spatialControlModel.update(settings)
        if notifyProcessor, pendingAudioOperation == nil, let processor {
            lastSpatialSubmissionRevision = processor.updateSpatial(spatialControlModel.settings)
            spatialControlModel.appliedStatusText = "오디오 설정 수신 대기 (요청 \(lastSpatialSubmissionRevision))"
        } else if processor == nil {
            spatialControlModel.appliedStatusText = "재생 중지: 오디오 설정 적용 대기"
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
        refreshAudioOperationPresentation()
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
        switch modelSelector.selectedSegment {
        case 1:
            return .circuit
        case 2:
            return .highExciter
        default:
            return .clean
        }
    }

    private struct SliderValues: Codable {
        let intensity: Double
        let body: Double
        let outputDb: Double
    }

    private func defaultSliderValues(for model: Settings.DSPModel) -> SliderValues {
        switch model {
        case .clean: return SliderValues(intensity: 0, body: 0, outputDb: 0)
        case .circuit: return SliderValues(intensity: 55, body: 30, outputDb: -1.5)
        case .highExciter: return SliderValues(intensity: 12, body: 4, outputDb: 0)
        }
    }

    private func sliderValuesKey(for model: Settings.DSPModel) -> String {
        "sliders.\(model.rawValue)"
    }

    private func loadSliderValues(for model: Settings.DSPModel) -> SliderValues {
        let fallback = defaultSliderValues(for: model)
        guard let data = preferenceStore.data(forKey: sliderValuesKey(for: model)) else {
            return fallback
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(SliderValues.self, from: data)) ?? fallback
    }

    private func saveSliderValues(_ values: SliderValues, for model: Settings.DSPModel) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(values) {
            preferenceStore.set(data, forKey: sliderValuesKey(for: model))
        }
    }

    private func applySliderValues(_ values: SliderValues) {
        guard intensitySlider != nil,
              bodySlider != nil,
              outputSlider != nil else { return }
        intensitySlider.doubleValue = values.intensity
        bodySlider.doubleValue = values.body
        outputSlider.doubleValue = values.outputDb
    }

    private func start(_ settings: Settings) {
        guard pendingAudioOperation == nil else {
            refreshAudioOperationPresentation()
            return
        }
        let operation = PendingAudioOperation(phase: processor == nil ? .creating : .replacing)
        pendingAudioOperation = operation
        stopAnalysisPresentation()
        refreshAudioOperationPresentation()
        if let processor {
            stopOnLifecycleWorker(processor, token: operation.id, nextStart: settings)
        } else {
            clearStoppedAudioPresentation()
            createOnLifecycleWorker(settings, token: operation.id)
        }
    }

    private func createOnLifecycleWorker(_ settings: Settings, token: UUID) {
        guard pendingAudioOperation?.id == token else { return }
        if pendingAudioOperation?.stopRequested == true {
            completeAudioOperation(token: token)
            return
        }
        pendingAudioOperation?.phase = .creating
        refreshAudioOperationPresentation()
        let io = audioLifecycleIO
        audioLifecycleWorker.queue.async { [self] in
            let result = Result { try audioLifecycleWorker.make(settings, io: io) }
            DispatchQueue.main.async { [self] in
                guard pendingAudioOperation?.id == token else { return }
                switch result {
                case .failure(let error):
                    completeAudioOperation(token: token)
                    showAudioStartError(error)
                case .success(let created):
                    // Bind before Start can enqueue a format notification.
                    // The worker and this property both retain the same owner.
                    processor = created
                    if pendingAudioOperation?.stopRequested == true {
                        stopOnLifecycleWorker(created, token: token)
                    } else {
                        pendingAudioOperation?.phase = .starting
                        refreshAudioOperationPresentation()
                        let sessionID = created.notificationSessionID
                        audioLifecycleWorker.queue.async { [self] in
                            let result = Result { try io.start(created) }
                            DispatchQueue.main.async { [self] in
                                completeAudioStart(result, sessionID: sessionID, token: token)
                            }
                        }
                    }
                }
            }
        }
    }

    private func completeAudioStart(_ result: Result<Void, Error>, sessionID: String,
                                    token: UUID) {
        guard pendingAudioOperation?.id == token, let started = processor,
              started.notificationSessionID == sessionID else { return }
        switch result {
        case .failure(let error):
            if let failure = error as? AudioGraphTransitionFailure, !failure.recovered {
                // A failed cleanup is not retried by delayed completion, even
                // when a Stop/Quit was requested during the blocking call.
                pendingAudioOperation = nil
                handleAudioStartFailure(error)
                refreshAudioOperationPresentation()
                window?.makeKeyAndOrderFront(nil)
            } else {
                stopOnLifecycleWorker(started, token: token, startError: error)
            }
        case .success:
            if pendingAudioOperation?.stopRequested == true {
                stopOnLifecycleWorker(started, token: token)
                return
            }
            pendingAudioOperation = nil
            currentStopFailure = nil
            currentProcessingFailure = nil
            // UI edits were stored while Start was pending. Take the current
            // values here, never the snapshot from the earlier Apply click.
            let latest = settings(for: .all)
            started.updateDSP(intensity: latest.intensity, body: latest.body, outputDb: latest.outputDb,
                              dspModel: latest.dspModel, exciterOversamplingMode: latest.exciterOversamplingMode)
            lastSpatialSubmissionRevision = started.updateSpatial(latest.spatial)
            started.setAutomaticRateMatchingEnabled(automaticRateMatchingEnabled)
            pushOutputConditioningSettings()
            if let observation = lastSourceObservation { started.observeSourceFormats(observation.formats) }
            if let lastSourceSnapshot { updateSourceDisplay(lastSourceSnapshot) }
            let analyzer = started.makeSpectrumAnalyzer(dynamicsModel: dynamicsMeterModel, spectrumModel: spectrumModel)
            analyzer.start()
            spectrumAnalyzer = analyzer
            refreshAudioFlowPresentation()
            if lifecycleStartsDiagnosticsTimer { startDiagnosticsTimer() }
            refreshAudioOperationPresentation()
        }
    }

    private func requestStopAudio(quit: Bool = false) {
        if pendingAudioOperation != nil {
            pendingAudioOperation?.stopRequested = true
            if quit { pendingAudioOperation?.quitRequested = true }
            stopAnalysisPresentation()
            refreshAudioOperationPresentation()
            return
        }
        guard let processor else {
            clearStoppedAudioPresentation()
            return
        }
        var operation = PendingAudioOperation(phase: .stopping)
        operation.stopRequested = true
        operation.quitRequested = quit
        pendingAudioOperation = operation
        stopAnalysisPresentation()
        refreshAudioOperationPresentation()
        stopOnLifecycleWorker(processor, token: operation.id)
    }

    private func stopOnLifecycleWorker(_ stopping: SystemAudioProcessor, token: UUID,
                                       nextStart: Settings? = nil, startError: Error? = nil) {
        guard pendingAudioOperation?.id == token, processor === stopping else { return }
        pendingAudioOperation?.phase = nextStart == nil ? .stopping : .replacing
        refreshAudioOperationPresentation()
        let io = audioLifecycleIO
        let sessionID = stopping.notificationSessionID
        audioLifecycleWorker.queue.async { [self] in
            let stopped = io.stop(stopping)
            let failure = stopping.stopFailureDescription
            DispatchQueue.main.async { [self] in
                guard pendingAudioOperation?.id == token, processor?.notificationSessionID == sessionID else { return }
                if !stopped {
                    pendingAudioOperation = nil
                    showAudioStopFailure(failure)
                    refreshAudioOperationPresentation()
                    window?.makeKeyAndOrderFront(nil)
                    return
                }
                clearStoppedAudioPresentation()
                audioLifecycleWorker.retire(sessionID)
                if let nextStart, pendingAudioOperation?.stopRequested != true {
                    createOnLifecycleWorker(nextStart, token: token)
                } else {
                    completeAudioOperation(token: token)
                    if let startError { showAudioStartError(startError) }
                }
            }
        }
    }

    private func completeAudioOperation(token: UUID) {
        guard let operation = pendingAudioOperation, operation.id == token else { return }
        pendingAudioOperation = nil
        refreshAudioOperationPresentation()
        if operation.quitRequested { finishRequestedQuit() }
    }

    private func refreshAudioOperationPresentation() {
        allSystemButton?.isEnabled = pendingAudioOperation == nil
        routingStartAppButton?.isEnabled = pendingAudioOperation == nil
        if let operation = pendingAudioOperation {
            let message: String
            if operation.stopRequested && operation.phase != .stopping {
                message = "중지 요청됨 · 진행 중인 오디오 작업의 응답을 기다리는 중"
            } else if operation.phase == .stopping || operation.phase == .replacing {
                message = "오디오 중지 중 · 장치 응답 대기"
            } else {
                message = "오디오 시작 중 · 장치 응답 대기"
            }
            statusLabel?.stringValue = message
            statusLabel?.toolTip = "작업이 실제로 완료된 뒤 상태를 갱신합니다. 중지는 진행 중인 작업의 응답 후 처리됩니다."
            allSystemButton?.setAccessibilityLabel(message)
            allSystemButton?.toolTip = message
        } else {
            allSystemButton?.setAccessibilityLabel("전체 시스템 적용")
            allSystemButton?.toolTip = "전체 시스템 오디오 처리를 시작합니다."
        }
        refreshAudioFlowPresentation()
        refreshOutputConditioningHeadroomState()
    }

    /// A successful Start owns a graph, but may still be waiting for its first
    /// audio data. Poll existing atomic counters without waiting for the manager.
    /// Failure and pending lifecycle messages always take precedence.
    private func refreshAudioFlowPresentation(_ snapshot: AudioDiagnosticsSnapshot? = nil) {
        if pendingAudioOperation != nil {
            diagAudioFlowValue?.stringValue = "장치 응답 대기"
            diagAudioFlowValue?.toolTip = nil
            return
        }
        if currentStopFailure != nil || currentProcessingFailure != nil {
            diagAudioFlowValue?.stringValue = "처리 중단"
            diagAudioFlowValue?.toolTip = currentStopFailure ?? currentProcessingFailure
            return
        }
        guard let processor else {
            diagAudioFlowValue?.stringValue = "—"
            diagAudioFlowValue?.toolTip = nil
            return
        }
        let current = snapshot ?? processor.diagnosticsSnapshot()
        let flow = current.audioFlow
        let text = flow.isConfirmed ? "처리 중: \(current.captureTarget)" : flow.displayText
        if statusLabel?.stringValue != text { statusLabel?.stringValue = text }
        statusLabel?.toolTip = flow.isConfirmed ? nil : AudioFlowProgress.waitingHelp
        diagAudioFlowValue?.stringValue = flow.displayText
        diagAudioFlowValue?.toolTip = flow.isConfirmed ? nil : AudioFlowProgress.waitingHelp
    }

    private func showAudioStartError(_ error: Error) {
        statusLabel?.stringValue = "실행 실패: \(error)"
        if error is CaptureInstanceCompatibility.Conflict || error is CaptureSessionLease.Failure {
            let alert = NSAlert()
            alert.messageText = "오디오 처리를 시작할 수 없습니다."
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
    }

    private func handleAudioStartFailure(_ error: Error) {
        let startError = "실행 실패: \(error)"
        if let failure = error as? AudioGraphTransitionFailure, !failure.recovered {
            // SAP already hit a failed teardown barrier. Preserve that graph
            // and its capture lease; the explicit Stop action owns retry.
            currentStopFailure = startError
            statusLabel?.stringValue = "\(startError) · 정리 재시도 필요"
            rateMatchStatusText = startError
            currentLivePCM2xFallback = startError
            refreshDiagnosticsPanel()
            updateRateMatchPreview()
        } else {
            requestStopAudio()
            statusLabel?.stringValue = startError
        }
        spectrumAnalyzer = nil
    }

    static func runCaptureSessionChecks() throws {
        try CaptureSessionChecks.run { processor in
            let owner = NativeAppDelegate()
            owner.processor = processor
            return CaptureStartFailureCheckObserver(
                handle: { owner.handleAudioStartFailure($0) },
                retainsProcessor: { owner.processor === processor },
                hasPendingFailure: { owner.currentStopFailure != nil },
                stop: { owner.stopAndWaitForCheck() })
        }
    }

    /// Actual AppKit controls and resize/state refreshes, without starting audio,
    /// showing a window or writing the user's saved settings.
    static func runOutputConditioningPresentationChecks() throws {
        let owner = NativeAppDelegate()
        owner.outputConditioningEnabled = true
        owner.outputConditioningModeRaw = OutputConditioningMode.bypass.rawValue
        owner.outputConditioningFactor = 2
        owner.outputConditioningHeadroomDB = -6
        let page = owner.makeOutputConditioningPage()
        var assertions = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard value() else { throw AppError.message("Output conditioning UI: \(message)") }
        }
        func saveReviewImage(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["LOWEND_CONDITIONING_UI_OUTPUT"] else { return }
            // The test changes private model fields directly; synchronize the
            // pickers before rendering as a real user selection would do.
            owner.selectConditioningPopup(owner.outputConditioningModePopup,
                forRaw: owner.outputConditioningModeRaw, in: OutputConditioningMode.allCases.map { $0.rawValue })
            owner.selectConditioningPopup(owner.outputConditioningFilterPopup,
                forRaw: owner.outputConditioningFilterRaw, in: ResamplingFilterMode.allCases.map { $0.rawValue })
            owner.outputConditioningFactorPopup.selectItem(at: 0)
            page.appearance = NSAppearance(named: .darkAqua)
            page.layoutSubtreeIfNeeded()
            guard let bitmap = page.bitmapImageRepForCachingDisplay(in: page.bounds) else {
                throw AppError.message("Could not allocate conditioning UI review bitmap")
            }
            page.cacheDisplay(in: page.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw AppError.message("Could not encode conditioning UI review bitmap")
            }
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("\(name).png"))
        }
        try require(owner.outputConditioningHeadroomSlider.isEnabled, "Bypass preserves editable headroom for the next 2x run")
        try require(!owner.outputConditioningFactorPopup.isEnabled, "Bypass has no DAC factor")
        try require(owner.outputConditioningHeadroomCaption.stringValue.contains("미적용"), "Bypass explains no effect")
        try saveReviewImage("headroom-bypass")
        owner.outputConditioningModeRaw = OutputConditioningMode.pcmOversampling.rawValue
        for factor in [4, 8] {
            owner.outputConditioningFactor = factor
            owner.updateOutputConditioningStatus()
            try require(owner.outputConditioningHeadroomSlider.isEnabled, "Offline factor preserves the requested headroom setting")
            try require(owner.outputConditioningFactorPopup.isEnabled, "User can return from offline factor to 2x")
        }
        owner.outputConditioningFactor = 2
        owner.updateOutputConditioningStatus()
        try require(owner.outputConditioningHeadroomSlider.isEnabled, "2x may be configured before starting")
        try require(owner.outputConditioningHeadroomCaption.stringValue.contains("대기"), "Armed is not active")
        // Diagnostics has never been constructed: live-state updates must still
        // refresh the controls on the output page.
        owner.currentLivePCM2xActive = true
        owner.refreshDiagnosticsPanel()
        try require(owner.outputConditioningHeadroomCaption.stringValue.contains("2× 출력 중"), "Active notification reaches output page")
        try saveReviewImage("headroom-active")
        owner.outputConditioningEnabled = false
        owner.updateOutputConditioningStatus()
        try require(!owner.outputConditioningHeadroomSlider.isEnabled
                    && owner.outputConditioningHeadroomCaption.stringValue.contains("해제 대기"), "Requested off waits for actual stop")
        owner.currentLivePCM2xActive = false
        owner.refreshDiagnosticsPanel()
        try require(owner.outputConditioningHeadroomCaption.stringValue.contains("꺼짐"), "Confirmed off is explicit")
        owner.outputConditioningEnabled = true
        owner.currentLivePCM2xFallback = "장치 미지원 검사"
        owner.refreshDiagnosticsPanel()
        try require(owner.outputConditioningHeadroomSlider.isEnabled, "Failed 2x must still allow editing the requested gain")
        try require(owner.outputConditioningHeadroomCaption.toolTip == "장치 미지원 검사", "Fallback reason remains available")
        owner.outputConditioningModeRaw = OutputConditioningMode.pcmWithDither.rawValue
        owner.updateOutputConditioningStatus()
        try require(owner.outputConditioningHeadroomSlider.isEnabled, "Inactive mode preserves editable headroom without applying it")
        owner.outputConditioningModeRaw = OutputConditioningMode.pcmOversampling.rawValue
        owner.updateOutputConditioningStatus()
        try require(owner.outputConditioningHeadroomSlider.isEnabled, "Returning to 2x does not retain stale fallback")
        owner.currentStopFailure = "정리 실패 검사"
        owner.refreshDiagnosticsPanel()
        try require(owner.outputConditioningHeadroomSlider.isEnabled
                    && owner.outputConditioningHeadroomCaption.stringValue.contains("중지 미완료"), "Pending teardown preserves editable settings")
        try require(owner.outputConditioningHeadroomSlider.doubleValue == -6
                    && owner.outputConditioningHeadroomDB == -6, "State transitions preserve requested gain")
        try require(owner.outputConditioningHeadroomSlider.isContinuous, "Headroom edits are continuous")
        for width: CGFloat in [392, 515, 616, 950] {
            page.setFrameSize(NSSize(width: width, height: 700))
            let slider = owner.outputConditioningHeadroomSlider.frame
            let value = owner.outputConditioningHeadroomValueLabel.frame
            try require(slider.maxX + 15 <= value.minX, "Slider and value must not overlap at page width \(width)")
            try require(value.maxX <= width - 23 && slider.minX >= 23, "Headroom row stays within page margins")
            try require(owner.outputConditioningModePopup.frame.width >= 340
                        && owner.outputConditioningModePopup.frame.maxX <= width - 23,
                        "Output mode remains readable after resize")
        }
        print("OutputConditioningPresentationChecks: \(assertions) assertions; actual controls, live-state refresh without Diagnostics, pending/fallback/stop state, preserved gain, four page widths; no device or visible-window operation.")
    }

    /// Exercise direct model selection and gain edits against the real manager/IOProc/ring
    /// with simulated hardware. All preference writes use a disposable suite.
    static func runLiveControlEditingChecks() throws {
        let suite = "lowend.control-editing-check.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let owner = NativeAppDelegate()
        owner.preferenceStore = preferences
        owner.outputConditioningEnabled = true
        owner.outputConditioningModeRaw = OutputConditioningMode.pcmOversampling.rawValue
        owner.outputConditioningFactor = 2
        owner.outputConditioningFilterRaw = ResamplingFilterMode.linearPhaseLong.rawValue
        owner.outputConditioningHeadroomDB = 0
        let modelPage = owner.makeModelPage()
        let outputPage = owner.makeOutputConditioningPage()
        defer { withExtendedLifetime((modelPage, outputPage)) {} }
        let io = GraphCheckIO()
        let access = try SystemAudioProcessor.GraphCheckAccess(io: io)
        access.withProcessorForUICheck { owner.processor = $0 }
        NotificationCenter.default.addObserver(owner, selector: #selector(audioFormatDidChange(_:)),
            name: AudioFormatNotifications.didChange, object: nil)
        defer {
            NotificationCenter.default.removeObserver(owner)
            owner.processor = nil
            io.onPause = nil
            _ = access.stop()
        }
        var assertions = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw AppError.message("Live control editing: \(message)") }
        }
        func drainNotifications(until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(1)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            try require(condition(), "Final manager notification was not consumed")
        }
        func selectModel(_ index: Int) throws {
            try require(owner.modelSelector.isEnabled && (0..<3).allSatisfy { owner.modelSelector.isEnabled(forSegment: $0) },
                "All models remain selectable")
            owner.modelSelector.selectedSegment = index
            try require(owner.modelSelector.sendAction(owner.modelSelector.action, to: owner.modelSelector.target),
                "Direct model selection must dispatch")
            try require(owner.modelSelector.selectedSegment == index
                && preferences.integer(forKey: "selectedModel") == index,
                "Direct selection and saved model must change together")
            let names = ["Bypass", "LowEnd", "Exciter Drive"]
            try require(owner.intensityNameLabel.stringValue == names[index], "Direct selection must refresh the model controls")
        }
        func editHeadroom(_ db: Double, synchronize: Bool = true) throws {
            try require(owner.outputConditioningHeadroomSlider.isEnabled, "Headroom settings remain editable")
            owner.outputConditioningHeadroomSlider.doubleValue = db
            try require(owner.outputConditioningHeadroomSlider.sendAction(
                owner.outputConditioningHeadroomSlider.action, to: owner.outputConditioningHeadroomSlider.target),
                "Actual headroom action must dispatch")
            if synchronize { access.managerBarrier() }
            try require(preferences.double(forKey: "outputConditioningHeadroomDB") == db
                && owner.outputConditioningHeadroomValueLabel.stringValue == formatDbText(db),
                "Requested gain and visible number must be saved together")
        }
        io.onPause = {
            let state = access.state()
            io.capture(256)
            if io.outputIsRunning {
                _ = access.consumeOutput(Int(256 * state.outputRate / max(state.tapRate, 1)))
            }
        }
        try access.seed()
        for index in [1, 2, 0] { try selectModel(index) }
        access.managerBarrier()
        // Hold the manager after the initial parameter snapshot is submitted,
        // then edit twice while activation and its main-thread status are pending.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        access.stallManager(entered: entered, release: release)
        defer { release.signal() }
        try require(entered.wait(timeout: .now() + 1) == .success, "Manager must be held for the activation edit check")
        owner.pushOutputConditioningSettings()
        try editHeadroom(-6, synchronize: false)
        try editHeadroom(-12, synchronize: false)
        release.signal()
        access.managerBarrier()
        let creates = io.counts["createTap"] ?? 0
        try require(!owner.currentLivePCM2xActive && owner.pendingHeadroomEdit,
            "Edits must remain pending until the activation notification reaches the UI")
        try drainNotifications { owner.currentLivePCM2xActive }
        access.managerBarrier()
        try require(!owner.pendingHeadroomEdit, "Activation must submit the latest saved gain once")
        func verifyOutputGain(_ db: Double) throws {
            let state = access.state()
            _ = access.consumeOutput(Int((state.written - state.read) / 2), advanceRamp: false)
            io.capture(1024)
            let tail = access.consumeOutput(2048, advanceRamp: false).suffix(1024)
            let mean = tail.reduce(0.0) { $0 + Double($1) } / Double(tail.count)
            try require(abs(mean - 0.125 * pow(10, db / 20)) < 0.000001,
                "Live UI gain must reach actual output samples")
            try require(io.counts["createTap"] == creates, "Live headroom must not rebuild capture")
        }
        try verifyOutputGain(-12)
        for db: Double in [0, -6, -12, 0] {
            try editHeadroom(db)
            try verifyOutputGain(db)
        }
        access.live2x(false)
        let beforeStaleActiveEdit = io.counts
        try require(owner.currentLivePCM2xActive, "UI must still have the older active notification")
        try editHeadroom(-6)
        try require(io.counts == beforeStaleActiveEdit && !access.state().live2x,
            "An edit against stale UI state must not reactivate or rebuild a device")
        try drainNotifications { !owner.currentLivePCM2xActive }
        io.rejectRates = [96_000]
        access.live2x(true)
        try drainNotifications { !owner.currentLivePCM2xFallback.isEmpty }
        try require(access.state().started && owner.currentProcessingFailure == nil,
            "Recovered PCM fallback is still processing")
        let beforeFallbackEdit = io.counts
        try editHeadroom(-3)
        try require(io.counts == beforeFallbackEdit, "Editing inactive gain must not retry the failed rate transition")
        io.rejectRates = []
        io.onPause = {
            if io.outputIsRunning { _ = access.consumeOutput(512) }
        }
        access.live2x(true)
        try drainNotifications { owner.currentProcessingFailure != nil }
        try require(!access.state().started && !owner.currentLivePCM2xActive,
            "Failed target and rollback must remain stopped")
        try require(owner.statusLabel.stringValue.contains("처리 중단")
            && owner.outputConditioningRuntimeLabel.stringValue.contains("중단"),
            "Actual processing failure must replace stale running text")
        let beforeStoppedEdit = io.counts
        try editHeadroom(-12)
        try selectModel(2)
        access.managerBarrier()
        try require(io.counts == beforeStoppedEdit, "Settings edits must not restart or clean up the failed graph")
        try require(owner.statusLabel.stringValue.contains("처리 중단"), "Model edit must preserve stopped status")
        try require(access.stop(), "Explicit Stop must finish simulated cleanup")
        print("LiveControlEditingChecks: \(assertions) assertions; direct model selection, pending activation edits and active 2x sample gain, recovered fallback and stopped editing, actual manager notifications; simulated hardware, isolated preferences, no visible window.")
    }

    @objc private func stopAudio() {
        requestStopAudio()
    }

    /// Real delegate actions, injected graph/lease, and a gated blocking call.
    /// The main loop must remain usable until the worker is explicitly released.
    static func runGUIAudioLifecycleChecks() throws {
        var assertions = 0, cases = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard condition() else { throw AppError.message("GUI lifecycle: \(message)") }
        }
        func pump(_ label: String, until predicate: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(2)
            while !predicate() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
            try require(predicate(), label)
        }
        func heartbeat() throws {
            let seen = RuntimeSnapshotBox(false)
            DispatchQueue.main.async { seen.store(true) }
            try pump("Main event loop blocked behind lifecycle work") { seen.load() }
        }
        func runCase(_ name: String,
                     _ body: (NativeAppDelegate, GUIAudioLifecycleCheckFixture, RuntimeSnapshotBox<Int>) throws -> Void) throws {
            let suite = "lowend.gui-lifecycle-check.\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: suite)!
            let fixture = try GUIAudioLifecycleCheckFixture()
            let owner = NativeAppDelegate()
            owner.preferenceStore = preferences
            owner.lifecycleStartsDiagnosticsTimer = false
            owner.automaticRateMatchingEnabled = false
            owner.outputConditioningEnabled = false
            owner.outputConditioningModeRaw = OutputConditioningMode.bypass.rawValue
            owner.outputConditioningFactor = 2
            owner.outputConditioningHeadroomDB = 0
            owner.audioLifecycleIO = fixture.lifecycleIO
            let modelPage = owner.makeModelPage()
            let outputPage = owner.makeOutputConditioningPage()
            owner.allSystemButton = NSButton(title: "", target: owner, action: #selector(startAllAudio))
            owner.routingStartAppButton = NSButton(title: "특정 앱 적용", target: owner, action: #selector(startSelectedApp))
            owner.automaticRateMatchButton = NSButton(checkboxWithTitle: "자동", target: owner,
                                                      action: #selector(automaticRateMatchChanged))
            let quitCount = RuntimeSnapshotBox(0)
            owner.finishRequestedQuit = { quitCount.store(quitCount.load() + 1) }
            NotificationCenter.default.addObserver(owner, selector: #selector(audioFormatDidChange(_:)),
                name: AudioFormatNotifications.didChange, object: nil)
            defer {
                fixture.gate.open()
                let deadline = Date().addingTimeInterval(6)
                while owner.pendingAudioOperation != nil && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                }
                if owner.pendingAudioOperation == nil {
                    fixture.rejectStop.store(false)
                    fixture.io.failures = [:]
                    _ = owner.stopAndWaitForCheck()
                    _ = owner.audioLifecycleWorker.retainedSessionCountForCheck()
                    fixture.close()
                }
                NotificationCenter.default.removeObserver(owner)
                preferences.removePersistentDomain(forName: suite)
                withExtendedLifetime((modelPage, outputPage)) {}
            }
            try body(owner, fixture, quitCount)
            try require(fixture.journal.count("gate-timeout") == 0, "\(name): gate expired without explicit release")
            try require(fixture.journal.count("make-on-main") == 0
                && fixture.journal.count("start-on-main") == 0
                && fixture.journal.count("stop-on-main") == 0, "\(name): blocking operation ran on main")
            cases += 1
            print("GUIAudioLifecycleChecks \(name): PASS")
        }

        try runCase("audio-flow-waits-for-real-input-and-output") { owner, f, _ in
            owner.startAllAudio()
            try pump("Flow fixture did not complete Start") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            owner.diagAudioFlowValue = NSTextField(labelWithString: "")
            owner.updateDiagnostics()
            try require(f.access.state().started && f.lease.isHeld && owner.spectrumAnalyzer != nil
                && owner.statusLabel.stringValue == "오디오 데이터 대기"
                && owner.diagAudioFlowValue.stringValue == "오디오 데이터 대기",
                "No-data Start must retain its graph and show waiting, not running")
            try require(owner.statusLabel.toolTip?.contains("권한") == false
                && owner.statusLabel.toolTip?.contains("접근 요청") == true,
                "Waiting must explain conditional access requests, not assert permission denial")
            _ = f.access.consumeOutput(512)
            owner.updateDiagnostics()
            try require(f.processor.diagnosticsSnapshot().outputUnderrunSamples == 1024
                && !f.processor.diagnosticsSnapshot().audioFlow.isConfirmed
                && owner.statusLabel.stringValue == "오디오 데이터 대기",
                "Underrun padding must not count as real input/output progress")
            owner.modelSelector.selectedSegment = 1
            owner.modelChanged()
            owner.applyPreset(at: 0)
            try require(owner.statusLabel.stringValue == "오디오 데이터 대기",
                        "Model and preset edits must preserve the waiting status")
            owner.modelSelector.selectedSegment = 0
            owner.modelChanged()
            f.access.managerBarrier()
            f.io.capture(256, sample: 0)
            owner.updateDiagnostics()
            try require(owner.statusLabel.stringValue == "출력 데이터 대기"
                && f.processor.diagnosticsSnapshot().audioFlow.producedSamples == 512
                && f.processor.diagnosticsSnapshot().audioFlow.consumedSamples == 0,
                "Capture without real output consumption must remain waiting")
            let silent = f.access.consumeOutput(256, advanceRamp: false)
            owner.updateDiagnostics()
            try require(silent.count == 512 && silent.allSatisfy { $0 == 0 }
                && f.processor.diagnosticsSnapshot().audioFlow.isConfirmed
                && owner.statusLabel.stringValue.contains("처리 중:")
                && owner.diagAudioFlowValue.stringValue == "입력·출력 데이터 확인",
                "Legitimate silent PCM must confirm flow without a level threshold")
            owner.updateDiagnostics()
            try require(owner.statusLabel.toolTip == nil,
                        "Confirmed flow must remove initial waiting instructions")
        }

        try runCase("audio-flow-before-main-completion-is-preserved") { owner, f, _ in
            let base = f.lifecycleIO
            owner.audioLifecycleIO = GUIAudioLifecycleIO(make: base.make, start: { processor in
                try base.start(processor)
                f.io.capture(128)
                _ = f.access.consumeOutput(128, advanceRamp: false)
            }, stop: base.stop)
            owner.startAllAudio()
            try pump("Early data fixture did not complete") { owner.pendingAudioOperation == nil }
            try require(owner.statusLabel.stringValue.contains("처리 중:")
                && f.processor.diagnosticsSnapshot().audioFlow.producedSamples == 256
                && f.processor.diagnosticsSnapshot().audioFlow.consumedSamples == 256,
                "Main completion must not reset a baseline after real data already arrived")
        }

        try runCase("audio-flow-resets-on-graph-reconfiguration") { owner, f, _ in
            owner.startAllAudio()
            try pump("Reconfiguration flow fixture did not start") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            f.io.capture(128)
            _ = f.access.consumeOutput(128, advanceRamp: false)
            owner.updateDiagnostics()
            let previous = f.processor.diagnosticsSnapshot().audioFlow
            try require(previous.isConfirmed, "Original graph must have actual input/output")
            try f.access.reconfigureHardwareFormat(96_000)
            owner.updateDiagnostics()
            let next = f.processor.diagnosticsSnapshot().audioFlow
            try require(next.generation > previous.generation && !next.isConfirmed
                && next.producedSamples == 0 && next.consumedSamples == 0
                && f.access.state().written > 0 && owner.statusLabel.stringValue == "오디오 데이터 대기",
                "Old cumulative data must not confirm a replacement graph")
            f.io.capture(128, sample: 0)
            _ = f.access.consumeOutput(128, advanceRamp: false)
            owner.updateDiagnostics()
            try require(f.processor.diagnosticsSnapshot().audioFlow.isConfirmed
                && owner.statusLabel.stringValue.contains("처리 중:"),
                "Replacement graph did not become confirmed after its own silent PCM")
        }

        try runCase("audio-flow-waiting-stop-quit-and-old-session") { owner, f, quit in
            owner.startAllAudio()
            try pump("Waiting Stop fixture did not start") { owner.pendingAudioOperation == nil }
            try require(owner.stopAndWaitForCheck() && owner.statusLabel.stringValue == "중지됨"
                && owner.processor == nil && !f.lease.isHeld,
                "Waiting for first data must not prevent a normal Stop")
            let replacement = try GUIAudioLifecycleCheckFixture()
            defer { replacement.close() }
            owner.audioLifecycleIO = replacement.lifecycleIO
            owner.startAllAudio()
            try pump("Replacement waiting session did not start") { owner.pendingAudioOperation == nil }
            owner.audioFormatDidChange(Notification(name: AudioFormatNotifications.didChange,
                userInfo: ["processorSessionID": f.processor.notificationSessionID,
                    AudioFormatNotifications.livePCM2xActiveKey: false,
                    AudioFormatNotifications.isProcessingKey: true,
                    AudioFormatNotifications.livePCM2xFallbackKey: ""]))
            try require(owner.processor === replacement.processor
                && owner.statusLabel.stringValue == "오디오 데이터 대기",
                "A retired session's success must not confirm current flow")
            replacement.gate.arm("stop")
            try require(owner.applicationShouldTerminate(.shared) == .terminateCancel,
                        "Quit while waiting for data must await actual cleanup")
            try pump("Waiting Quit did not reach Stop") { replacement.gate.entered }
            owner.updateDiagnostics()
            try require(owner.statusLabel.stringValue.contains("중지 중") && quit.load() == 0,
                        "A diagnostics tick must not overwrite pending Stop with flow status")
            replacement.gate.open()
            try pump("Waiting Quit did not finish") { owner.pendingAudioOperation == nil }
            try require(quit.load() == 1 && owner.processor == nil && !replacement.lease.isHeld,
                        "Waiting Quit did not release its actual owner and lease")
            _ = owner.audioLifecycleWorker.retainedSessionCountForCheck()
        }

        try runCase("initialization-stop-and-duplicate-barrier") { owner, f, quit in
            f.gate.arm("make")
            owner.startAllAudio()
            try pump("Initialization did not reach the worker") { f.gate.entered }
            try heartbeat()
            let token = owner.pendingAudioOperation?.id
            owner.startAllAudio()
            try require(owner.pendingAudioOperation?.id == token && f.journal.count("make-off-main") == 1,
                        "Duplicate Apply replaced an initializing operation")
            try require(owner.processor == nil && !owner.allSystemButton.isEnabled
                && owner.allSystemButton.accessibilityLabel()?.contains("시작 중") == true,
                "Pending initialization lacks global accessible state")
            owner.stopAudio()
            try heartbeat()
            try require(f.journal.count("stop-off-main") == 0 && f.journal.count("start-off-main") == 0,
                        "Stop must not overtake an unfinished initializer")
            f.gate.open()
            try pump("Canceled initialization did not finish cleanup") { owner.pendingAudioOperation == nil }
            try require(owner.processor == nil && owner.spectrumAnalyzer == nil
                && f.journal.count("start-off-main") == 0 && f.journal.count("stop-off-main") == 1,
                "Canceled initialization must retire without starting capture")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0 && quit.load() == 0,
                        "Canceled initialization retained a worker owner or requested Quit")
            try require(owner.allSystemButton.isEnabled && owner.allSystemButton.accessibilityLabel() == "전체 시스템 적용",
                        "Finished operation did not restore the global Apply label")
        }

        try runCase("capture-start-delayed-stop-and-quit") { owner, f, quit in
            f.gate.arm("startCapture")
            owner.outputConditioningEnabled = true
            owner.outputConditioningModeRaw = OutputConditioningMode.pcmOversampling.rawValue
            owner.startAllAudio()
            try pump("Capture Start did not reach its gate") { f.gate.entered }
            try heartbeat()
            let token = owner.pendingAudioOperation?.id
            owner.startAllAudio()
            owner.stopAudio()
            try require(owner.applicationShouldTerminate(.shared) == .terminateCancel,
                        "Quit must not terminate an in-flight owner")
            try heartbeat()
            try require(owner.pendingAudioOperation?.id == token && owner.processor === f.processor
                && f.lease.isHeld && quit.load() == 0, "Pending Stop/Quit lost its token, owner or lease")
            try require(f.journal.count("stop-off-main") == 0 && f.journal.count("setOutputRate") == 0,
                        "Pending Stop/Quit ran cleanup or PCM negotiation before Start returned")
            try require(owner.allSystemButton.accessibilityLabel()?.contains("중지 요청됨") == true,
                        "Global state does not explain deferred Stop")
            f.gate.open()
            try pump("Delayed Stop/Quit did not finish") { owner.pendingAudioOperation == nil }
            try require(owner.processor == nil && owner.spectrumAnalyzer == nil && !f.lease.isHeld
                && f.journal.count("stop-off-main") == 1 && f.journal.count("setOutputRate") == 0
                && quit.load() == 1, "Delayed success must Stop once, skip PCM/analyzer, then finish Quit")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Quit completion did not retire the worker owner")
        }

        try runCase("stop-stall-keeps-main-responsive") { owner, f, _ in
            owner.startAllAudio()
            try pump("Initial Start did not complete") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            f.gate.arm("stop")
            owner.stopAudio()
            try pump("Stop did not reach its worker gate") { f.gate.entered }
            try heartbeat()
            owner.startAllAudio()
            owner.stopAudio()
            try require(owner.processor === f.processor && f.lease.isHeld
                && f.journal.count("make-off-main") == 1 && f.journal.count("stop-off-main") == 1,
                "Repeated Start/Stop replaced or duplicated a pending Stop")
            f.gate.open()
            try pump("Stop did not complete after release") { owner.pendingAudioOperation == nil }
            try require(owner.processor == nil && !f.lease.isHeld
                && owner.currentDeviceSampleRate == nil, "Confirmed Stop did not clear owner and output cache")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Successful Stop did not retire its worker owner")
        }

        try runCase("pending-edits-and-initial-notification") { owner, f, _ in
            f.gate.arm("startCapture")
            owner.startAllAudio()
            try pump("Edit fixture did not hold Start") { f.gate.entered }
            owner.modelSelector.selectedSegment = 1
            owner.modelChanged()
            owner.intensitySlider.doubleValue = 0
            owner.bodySlider.doubleValue = 0
            owner.outputSlider.doubleValue = -6
            owner.sliderChanged()
            var spatial = owner.spatialControlModel.settings
            spatial.listenerX = 1.2; spatial.amount = 71; spatial.enabled = false
            owner.updateSpatialControls(from: spatial, notifyProcessor: true)
            owner.observeSourceSnapshot(SourceFormatSnapshot(activePlayers: [], formats: []))
            owner.outputConditioningEnableButton.state = .on
            owner.outputConditioningEnableChanged()
            owner.outputConditioningModePopup.selectItem(at: 1)
            owner.outputConditioningModeChanged()
            owner.outputConditioningFilterRaw = ResamplingFilterMode.linearPhaseLong.rawValue
            owner.outputConditioningHeadroomSlider.doubleValue = -12
            owner.outputConditioningHeadroomChanged()
            try heartbeat()
            try require(owner.outputConditioningHeadroomDB == -12 && owner.pendingHeadroomEdit
                && owner.statusLabel.stringValue.contains("시작 중")
                && f.journal.count("setOutputRate") == 0 && f.journal.count("stopCapture") == 0,
                "Pending edits must be saved without starting a transition or replacing pending status")
            f.gate.open()
            try pump("Latest PCM setting did not become active after successful Start") {
                owner.pendingAudioOperation == nil && owner.currentLivePCM2xActive
            }
            f.access.managerBarrier()
            try require(owner.currentTapSampleRate == 48_000 && owner.currentDeviceSampleRate == 96_000,
                        "Bind-before-start lost matching-session format notifications")
            try require(owner.spectrumAnalyzer != nil && owner.selectedDSPModel() == .circuit
                && owner.spatialControlModel.settings.listenerX == 1.2 && !owner.pendingHeadroomEdit,
                "Successful Start lost the latest model, spatial or gain edit")
            let state = f.access.state()
            _ = f.access.consumeOutput(Int((state.written - state.read) / 2), advanceRamp: false)
            f.io.capture(4096)
            let tail = f.access.consumeOutput(8192, advanceRamp: false).suffix(1024)
            let mean = tail.reduce(0.0) { $0 + Double($1) } / Double(tail.count)
            try require(abs(mean - 0.125 * pow(10, -18.0 / 20)) < 0.00001,
                        "Latest Circuit output -6 dB and headroom -12 dB did not reach actual samples (\(mean))")
            try require(f.access.state().appliedRevision >= owner.lastSpatialSubmissionRevision,
                        "Latest Spatial submission was not consumed by the actual callback")
            try require(owner.stopAndWaitForCheck(), "Latest-setting fixture Stop failed")
            _ = owner.audioLifecycleWorker.retainedSessionCountForCheck()
            owner.audioFormatDidChange(Notification(name: AudioFormatNotifications.didChange,
                userInfo: ["processorSessionID": f.processor.notificationSessionID,
                           AudioFormatNotifications.sampleRateKey: 192_000.0]))
            try require(owner.currentDeviceSampleRate == nil && owner.processor == nil,
                        "Retired notification restored stopped output state")
        }

        try runCase("pending-automatic-edit-survives-initial-format") { owner, f, _ in
            f.gate.arm("startCapture")
            owner.startAllAudio()
            try pump("Automatic-rate fixture did not hold Start") { f.gate.entered }
            owner.automaticRateMatchButton.state = .on
            owner.automaticRateMatchChanged()
            owner.observeSourceSnapshot(SourceFormatSnapshot(activePlayers: [], formats: []))
            try heartbeat()
            f.gate.open()
            try pump("Automatic-rate fixture did not finish Start") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            // Drain the real initial false notification and the latest true
            // submission's notification, rather than inventing either event.
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try require(owner.automaticRateMatchingEnabled && owner.automaticRateMatchButton.state == .on
                && owner.preferenceStore.bool(forKey: "automaticRateMatchingEnabled"),
                "Initial stale format notification overwrote the pending automatic-rate edit")
            try require(owner.currentDeviceSampleRate == 48_000 && owner.lastSourceObservation != nil,
                        "Successful Start lost source observation or initial format")
        }

        try runCase("failed-stop-quit-retains-owner-and-retry") { owner, f, quit in
            owner.startAllAudio()
            try pump("Stop failure fixture Start failed") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            f.rejectStop.store(true)
            try require(owner.applicationShouldTerminate(.shared) == .terminateCancel, "Quit must wait for Stop")
            try pump("Injected Stop failure did not complete") { owner.pendingAudioOperation == nil }
            try require(owner.processor === f.processor && f.lease.isHeld && owner.currentStopFailure != nil
                && quit.load() == 0 && owner.audioLifecycleWorker.retainedSessionCountForCheck() == 1,
                "False Stop with default diagnostic must preserve both owners and cancel Quit")
            owner.startAllAudio()
            try pump("Replacement Stop failure did not finish") { owner.pendingAudioOperation == nil }
            try require(f.journal.count("make-off-main") == 1 && owner.processor === f.processor,
                        "Failed replacement Stop created another processor")
            f.rejectStop.store(false)
            try require(owner.stopAndWaitForCheck() && !f.lease.isHeld && quit.load() == 0,
                        "Explicit retry did not clear owner, or replayed the failed Quit intent")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Explicit retry did not retire the worker reference")
        }

        try runCase("failed-start-cleanup-requires-explicit-retry") { owner, f, _ in
            f.io.failures["startCapture"] = [1]
            f.io.failures["unregisterCapture"] = [1]
            owner.startAllAudio()
            try pump("Start cleanup failure did not complete") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            try require(f.journal.count("unregisterCapture") == 1 && f.journal.count("stop-off-main") == 0
                && owner.processor === f.processor && f.lease.isHeld && owner.currentStopFailure != nil,
                "Start completion retried a failed teardown or lost its owner")
            try require(owner.stopAndWaitForCheck() && !f.lease.isHeld,
                        "Explicit Stop did not retry failed startup cleanup")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Startup cleanup retry did not retire its worker owner")
        }

        try runCase("initialization-error") { owner, f, _ in
            f.failMake.store(true)
            owner.startAllAudio()
            try pump("Initializer error did not complete") { owner.pendingAudioOperation == nil }
            try require(owner.processor == nil && owner.spectrumAnalyzer == nil
                && owner.statusLabel.stringValue.contains("실행 실패") && owner.allSystemButton.isEnabled
                && f.journal.count("start-off-main") == 0 && f.journal.count("stop-off-main") == 0,
                "Initializer error started a graph, retained an owner or left Apply disabled")
        }

        try runCase("final-destructor-on-worker") { owner, _, _ in
            let weakOwner = GUIAudioWeakOwnerCheck()
            let journal = GUIAudioCheckJournal()
            owner.audioLifecycleIO = GUIAudioLifecycleIO(make: { settings in
                let io = GraphCheckIO()
                io.onCall = { operation in
                    if operation == "stopOutput" {
                        journal.record(Thread.isMainThread ? "stopOutput-main" : "stopOutput-worker")
                    }
                }
                let processor = try SystemAudioProcessor(settings: settings,
                    initialOutput: { (777, 48_000) }, graphIO: io)
                weakOwner.observe(processor)
                return processor
            }, start: { _ in }, stop: { $0.stop() })
            owner.startAllAudio()
            try pump("Retirement fixture did not start") { owner.pendingAudioOperation == nil }
            try require(weakOwner.isAlive && owner.audioLifecycleWorker.retainedSessionCountForCheck() == 1,
                        "Worker did not retain the live processor")
            try require(owner.stopAndWaitForCheck(), "Retirement fixture Stop failed")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Retirement table did not clear")
            try pump("Final processor reference survived worker retirement") { !weakOwner.isAlive }
            try require(journal.count("stopOutput-main") == 0 && journal.count("stopOutput-worker") >= 2,
                        "Successful Stop or final destructor entered the graph on main")
        }
        print("GUIAudioLifecycleChecks: \(cases) cases; \(assertions) assertions; actual async delegate init/start/stop, gated main-loop responsiveness, duplicate/Stop/Quit ownership, latest edits and samples, failed cleanup/retry, session routing and worker retirement; injected devices/leases, isolated preferences, no visible window.")
    }

    /// Exercise the real strong property and stop method without launching the
    /// app, building a window, observing source players or querying a device.
    static func runStopRestorationChecks() throws {
        try SystemAudioProcessor.runStopRestorationChecks { processor in
            let owner = NativeAppDelegate()
            owner.processor = processor
            return (
                attempt: { owner.stopAndWaitForCheck() },
                retainsProcessor: { owner.processor === processor }
            )
        }
    }

    /// Exercise the real diagnostics observer boundary with no graph, device
    /// lookup, app launch or timer. Identical snapshots must not invalidate the
    /// Spatial page; receipt/pending text changes must remain observable.
    static func runSpatialDiagnosticsChecks() throws {
        let owner = NativeAppDelegate()
        let processor = try SystemAudioProcessor(settings: Settings(), initialOutput: { (777, 48_000) })
        owner.processor = processor
        owner.diagnosticsLabel = NSTextField(labelWithString: "")
        var publications = 0
        var audioSubmissions = 0
        let observation = owner.spatialControlModel.objectWillChange.sink { publications += 1 }
        owner.spatialControlModel.onChange = { _ in audioSubmissions += 1 }
        defer { observation.cancel(); owner.processor = nil; _ = processor.stop() }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw AppError.message("Spatial diagnostics: \(message)") }
        }
        owner.updateDiagnostics()
        let received = owner.spatialControlModel.appliedStatusText
        try require(publications == 1 && received?.contains("수신 확인 (0)") == true,
                    "Initial actual diagnostics did not publish receipt status")
        for _ in 0..<3 { owner.updateDiagnostics() }
        try require(publications == 1, "Identical receipt status republished the observed model")
        owner.lastSpatialSubmissionRevision = 7
        owner.updateDiagnostics()
        try require(publications == 2 && owner.spatialControlModel.appliedStatusText?.contains("요청 7, 수신 0") == true,
                    "Changed pending request did not update its status")
        for _ in 0..<3 { owner.updateDiagnostics() }
        try require(publications == 2, "Identical pending status republished the observed model")
        owner.lastSpatialSubmissionRevision = 0
        owner.updateDiagnostics()
        try require(publications == 3 && owner.spatialControlModel.appliedStatusText == received,
                    "Returning to received status did not publish the change")
        try require(audioSubmissions == 0 && owner.spatialControlModel.uiEditRevision == 0
                    && !owner.spatialControlModel.hasPendingEdit && processor.appliedSpatialRevision == 0,
                    "Read-only diagnostics changed an audio edit or ACK")
        print("SpatialDiagnosticsChecks: 6 assertions; actual updateDiagnostics, identical receipt/pending status emits no model update, changed status remains observable, no audio edit. Injected unstarted processor; no window/device query.")
    }

    /// Check the actual notification consumer without posting to the global
    /// notification center. Device/engine rates must not replace the tap rate
    /// used by Spatial preview, and a retired processor cannot change the page.
    static func runSpatialFormatBridgeChecks() throws {
        let owner = NativeAppDelegate()
        let old = try SystemAudioProcessor(settings: Settings(), initialOutput: { (777, 48_000) })
        let current = try SystemAudioProcessor(settings: Settings(), initialOutput: { (777, 44_100) })
        defer { owner.processor = nil; _ = old.stop(); _ = current.stop() }
        var settings = SpatialSettings()
        settings.enabled = true; settings.listenerX = 1.2; settings.listenerZ = 0.7
        settings.speakerWidth = 2.1; settings.amount = 73
        owner.spatialControlModel.update(settings)
        var audioEdits = 0
        owner.spatialControlModel.onChange = { _ in audioEdits += 1 }
        var assertions = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw AppError.message("Spatial format bridge: \(message)") }
        }
        func deliver(_ session: String?, tap: Double, output: Double) {
            var values: [String: Any] = [
                AudioFormatNotifications.tapSampleRateKey: tap,
                AudioFormatNotifications.processingSampleRateKey: output,
                AudioFormatNotifications.sampleRateKey: output,
                AudioFormatNotifications.livePCM2xActiveKey: true
            ]
            if let session { values["processorSessionID"] = session }
            owner.audioFormatDidChange(Notification(name: AudioFormatNotifications.didChange,
                                                    object: nil, userInfo: values))
        }
        owner.processor = old
        deliver(old.notificationSessionID, tap: 48_000, output: 96_000)
        try require(owner.currentProcessingSampleRate == 96_000 && owner.currentDeviceSampleRate == 96_000,
                    "Matching session did not update engine/device rates")
        try require(owner.currentTapSampleRate == 48_000 && owner.spatialControlModel.processingSampleRate == 48_000
                    && owner.spatialControlModel.preview?.raw.sampleRate == 48_000,
                    "Spatial preview used output 2x instead of capture 1x")
        try require(owner.currentLivePCM2xActive, "Matching notification lost live 2x display state")
        deliver(nil, tap: 192_000, output: 384_000)
        try require(owner.currentTapSampleRate == 48_000 && owner.currentDeviceSampleRate == 96_000,
                    "Notification without a session changed the active state")
        owner.processor = current
        deliver(old.notificationSessionID, tap: 96_000, output: 192_000)
        try require(owner.currentTapSampleRate == 48_000 && owner.spatialControlModel.preview?.raw.sampleRate == 48_000,
                    "Retired processor notification changed preview")
        deliver(current.notificationSessionID, tap: 44_100, output: 88_200)
        try require(owner.currentTapSampleRate == 44_100 && owner.currentProcessingSampleRate == 88_200
                    && owner.currentDeviceSampleRate == 88_200,
                    "Current session did not apply its split route")
        try require(owner.spatialControlModel.processingSampleRate == 44_100
                    && owner.spatialControlModel.preview?.raw.sampleRate == 44_100,
                    "Current session preview is not precomputed at its tap rate")
        try require(SpatialControlModel.equal(owner.spatialControlModel.settings, settings)
                    && audioEdits == 0 && owner.spatialControlModel.uiEditRevision == 0
                    && !owner.spatialControlModel.hasPendingEdit,
                    "Read-only format delivery changed an audio edit")
        owner.compactSourceTitleLabel = NSTextField(labelWithString: "")
        owner.compactSourceValueLabel = NSTextField(labelWithString: "")
        owner.compactOutputLabel = NSTextField(labelWithString: "")
        owner.compactModelLabel = NSTextField(labelWithString: "")
        owner.modelSelector = NSSegmentedControl(labels: ["Clean", "Circuit", "HighExciter"],
            trackingMode: .selectOne, target: nil, action: nil)
        owner.modelSelector.selectedSegment = 0
        owner.updateCompactFormatSummary()
        try require(owner.compactOutputLabel.stringValue.contains("88.2 kHz"),
                    "Compact output must show the current session before Stop")
        try require(owner.stopAndWaitForCheck() && owner.processor == nil,
                    "Successful Stop must retire the current processor")
        try require(owner.currentDeviceSampleRate == nil && owner.currentProcessingSampleRate == nil
                    && owner.currentTapSampleRate == nil && !owner.currentLivePCM2xActive
                    && owner.compactOutputLabel.stringValue == "출력 포맷 대기 중",
                    "Stopped compact output must not retain the previous device rate")
        deliver(old.notificationSessionID, tap: 48_000, output: 96_000)
        deliver(current.notificationSessionID, tap: 44_100, output: 88_200)
        try require(owner.currentDeviceSampleRate == nil && owner.currentProcessingSampleRate == nil
                    && owner.currentTapSampleRate == nil && !owner.currentLivePCM2xActive
                    && owner.compactOutputLabel.stringValue == "출력 포맷 대기 중",
                    "Retired notifications must not restore a stopped output display")
        try require(old.stop() && current.stop(), "Unstarted fixture cleanup failed")
        print("SpatialFormatBridgeChecks: \(assertions) assertions; actual format notification consumer, tap/output separation, session routing, stopped compact output and retired notifications, unchanged audio edits; injected processors, no graph/window/device query.")
    }

    private func stopAnalysisPresentation() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        spectrumAnalyzer?.stop()
        spectrumAnalyzer = nil
        dynamicsMeterModel.reset()
        spectrumModel.reset()
    }

    private func showAudioStopFailure(_ failure: String) {
        currentStopFailure = failure
        statusLabel?.stringValue = "중지 미완료: \(failure)"
        rateMatchStatusText = failure
        currentLivePCM2xFallback = failure
        refreshDiagnosticsPanel()
        updateRateMatchPreview()
    }

    /// Only call after confirmed Stop, or when no processor has been created.
    private func clearStoppedAudioPresentation() {
        processor = nil
        currentStopFailure = nil
        currentProcessingFailure = nil
        if let lastSourceSnapshot { updateSourceDisplay(lastSourceSnapshot) }
        if statusLabel != nil {
            statusLabel.stringValue = "중지됨"
            statusLabel.toolTip = nil
        }
        if formatLabel != nil {
            formatLabel.stringValue = "처리 포맷 대기 중"
        }
        diagnosticsLabel?.stringValue = "XRuns 대기 중"
        currentProcessingSampleRate = nil
        currentTapSampleRate = nil
        currentDeviceSampleRate = nil
        currentLivePCM2xActive = false
        currentLivePCM2xFallback = ""
        diagXRunValue?.stringValue = formatXRunCounts(underrun: 0, drop: 0, vis: 0)
        diagRestartValue?.stringValue = "0"
        diagCachedDeviceID = kAudioObjectUnknown
        diagCachedDeviceName = "—"
        diagDeviceNameValue?.stringValue = "—"
        diagCaptureValue?.stringValue = "—"
        diagAudioFlowValue?.stringValue = "—"
        diagAudioFlowValue?.toolTip = nil
        refreshDiagnosticsPanel()
        updateOversamplingIndicator()
        updateCompactFormatSummary()
    }

    /// Existing fixture adapters keep their Bool contract while exercising the
    /// real asynchronous delegate path and pumping the main event loop.
    private func stopAndWaitForCheck() -> Bool {
        requestStopAudio()
        let deadline = Date().addingTimeInterval(3)
        while pendingAudioOperation != nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        return pendingAudioOperation == nil && processor == nil && currentStopFailure == nil
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
                    self.updateSourceDisplay(snapshot)
                }
            },
            onObservation: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.observeSourceSnapshot(snapshot)
                }
            }
        )
        sourceFormatTracker = tracker
        tracker.start()
    }

    private func observeSourceSnapshot(_ snapshot: SourceFormatSnapshot) {
        lastSourceObservation = snapshot
        guard pendingAudioOperation == nil else { return }
        processor?.observeSourceFormats(snapshot.formats)
    }

    private func updateSourceDisplay(_ snapshot: SourceFormatSnapshot) {
        lastSourceSnapshot = snapshot
        let scope = processor?.capturedBundleIDs
        let selected = SourceFormatSelectionPolicy.select(formats: snapshot.formats, capturedBundleIDs: scope)
        let text = selected?.indicatorText ?? (scope == nil ? snapshot.indicatorText : "Source: 선택한 캡처 대상의 재생 정보 대기 중")
        sourceFormatLabel?.stringValue = text
        sourceFormatLabel?.toolTip = text
        currentSourceSampleRate = selected?.sampleRate
        currentSourceBitDepth = selected?.bitDepth
        currentSourcePlayerName = selected?.player.displayName
        updateCompactFormatSummary()
        updateRateMatchPreview()
    }

    @objc private func updateDiagnostics() {
        guard let processor else { return }
        let snapshot = processor.diagnosticsSnapshot()
        refreshAudioFlowPresentation(snapshot)
        let applied = processor.appliedSpatialRevision
        let spatialStatus = applied >= lastSpatialSubmissionRevision
            ? "오디오 설정 수신 확인 (\(applied)); 짧은 전환 구간은 별도"
            : "오디오 설정 수신 대기 (요청 \(lastSpatialSubmissionRevision), 수신 \(applied))"
        // Publishing an unchanged status invalidates the observed Spatial page
        // and requests another stage frame even while its scene is idle.
        if spatialControlModel.appliedStatusText != spatialStatus {
            spatialControlModel.appliedStatusText = spatialStatus
        }
        diagnosticsLabel.stringValue = snapshot.displayText
        diagnosticsLabel.toolTip = snapshot.displayText

        // Diagnostics panel — counters + device identity, refreshed at the 1 Hz
        // timer cadence (these values are not notification-driven). deviceName is
        // a CoreAudio query performed only when the device changes;
        // outputDeviceID reads an off-thread-published snapshot without waiting
        // for the manager queue or the realtime audio callback.
        if diagXRunValue != nil {
            diagXRunValue.stringValue = formatXRunCounts(
                underrun: snapshot.outputUnderrunSamples,
                drop: snapshot.outputDroppedSamples,
                vis: snapshot.visualizerDroppedSamples
            )
            diagRestartValue.stringValue = "\(snapshot.engineRestartCount)"
            diagCaptureValue.stringValue = snapshot.captureTarget
            // Resolve the device name only when the device changes (it rarely
            // does mid-session) to avoid a CoreAudio IPC on the main thread every
            // tick. outputDeviceID reads the last published device snapshot.
            let devID = processor.outputDeviceID
            if devID != diagCachedDeviceID {
                diagCachedDeviceID = devID
                diagCachedDeviceName = HardwareSampleRateTracker.deviceName(for: devID)
            }
            diagDeviceNameValue.stringValue =
                "\(diagCachedDeviceName) · 0x\(String(devID, radix: 16))"
        }
        refreshDiagnosticsPanel()
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
        guard let processor,
              notification.userInfo?["processorSessionID"] as? String == processor.notificationSessionID else { return }
        let userInfo = notification.userInfo
        if let text = userInfo?[AudioFormatNotifications.indicatorTextKey] as? String {
            formatLabel?.stringValue = text
        }

        if let sampleRate = userInfo?[AudioFormatNotifications.processingSampleRateKey] as? Double {
            currentProcessingSampleRate = sampleRate
            spectrumAnalyzer?.updateSampleRate(Float(sampleRate))
        }
        if let tapRate = userInfo?[AudioFormatNotifications.tapSampleRateKey] as? Double {
            currentTapSampleRate = tapRate
            spatialControlModel.processingSampleRate = Float(tapRate)
        }
        if let deviceRate = userInfo?[AudioFormatNotifications.sampleRateKey] as? Double {
            currentDeviceSampleRate = deviceRate
        }
        if let format = userInfo?[AudioFormatNotifications.sampleFormatKey] as? String {
            currentOutputSampleFormat = format
        }
        supportedDeviceSampleRates =
            userInfo?[AudioFormatNotifications.supportedSampleRatesKey] as? [Double]
            ?? supportedDeviceSampleRates
        isDeviceSampleRateSettable =
            userInfo?[AudioFormatNotifications.isSampleRateSettableKey] as? Bool
            ?? isDeviceSampleRateSettable
        if pendingAudioOperation == nil, let enabled =
            userInfo?[AudioFormatNotifications.automaticRateMatchingEnabledKey] as? Bool {
            automaticRateMatchingEnabled = enabled
            automaticRateMatchButton?.state = enabled ? .on : .off
        }
        rateMatchStatusText =
            userInfo?[AudioFormatNotifications.rateMatchStatusKey] as? String
            ?? rateMatchStatusText

        // Live PCM 2× conditioning state is posted separately by
        // publishLivePCM2xStatus WITHOUT an indicatorTextKey, so it must be
        // consumed here regardless of whether the format indicator is present.
        if let active = userInfo?[AudioFormatNotifications.livePCM2xActiveKey] as? Bool {
            currentLivePCM2xActive = active
        }
        if let fallback = userInfo?[AudioFormatNotifications.livePCM2xFallbackKey] as? String {
            currentLivePCM2xFallback = fallback
            if let processing = userInfo?[AudioFormatNotifications.isProcessingKey] as? Bool {
                let hadFailure = currentProcessingFailure != nil
                currentProcessingFailure = !processing && !fallback.isEmpty ? fallback : nil
                if let failure = currentProcessingFailure {
                    statusLabel?.stringValue = "처리 중단 · 오디오 적용에서 중지 후 다시 적용"
                    statusLabel?.toolTip = failure
                } else if hadFailure && processing {
                    refreshAudioFlowPresentation()
                }
            }
        }

        // Activation uses an earlier parameter snapshot. Deliver edits made
        // while it was pending only after a successful, matching-session result.
        // Inactive/fallback notifications never retry a device transition.
        if currentLivePCM2xActive && pendingHeadroomEdit && outputConditioningEnabled
            && OutputConditioningMode(rawValue: outputConditioningModeRaw) == .pcmOversampling
            && outputConditioningFactor == 2 {
            pushActiveHeadroomSettings()
        }
        updateCompactFormatSummary()
        updateRateMatchPreview()
        updateOversamplingIndicator()
        refreshDiagnosticsPanel()
        refreshAudioOperationPresentation()
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
        updateCompactFormatSummary()
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

    // Native text fields depend on the application's responder-chain edit
    // commands for keyboard shortcuts such as Command-A/C/V. A Quit-only menu
    // leaves precision editing with no standard Select All command.
    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: "편집")
    for (title, action, key) in [
        ("실행 취소", "undo:", "z"),
        ("오려두기", "cut:", "x"),
        ("복사", "copy:", "c"),
        ("붙여넣기", "paste:", "v"),
        ("전체 선택", "selectAll:", "a")
    ] {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command]
        // A nil target routes the command to the current native field editor.
        editMenu.addItem(item)
    }
    let redo = NSMenuItem(title: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.insertItem(redo, at: 1)
    editMenu.insertItem(.separator(), at: 2)
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)
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
      SystemAudioProcessor --ui-self-test
      SystemAudioProcessor --benchmark-output-conditioning

    With no arguments, open the app. Diagnostics and the offline benchmark
    above do not start audio capture. Use each diagnostic flag on its own.

    Options:
      --intensity 0...100
      --body 0...100
      --output -18...6 dB
      --model clean|circuit|highexciter
      --spatial on|off
      --listener-x -3...3 meters
      --listener-z -2.8...2.8 meters
      --stage-width 0.6...3 meters
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


do {
    if CommandLine.arguments.count == 1 {
        guard #available(macOS 14.4, *) else {
            throw AppError.message("Native system audio processing requires macOS 14.4 or newer.")
        }
        launchGUI()
    }

    if CommandLine.arguments.dropFirst() == ["--benchmark-output-conditioning"] {
        runOutputConditioningBenchmark()
        exit(0)
    }
    if CommandLine.arguments.dropFirst() == ["--ui-self-test"] {
        guard #available(macOS 14.4, *) else { throw AppError.message("UI checks need macOS 14.4") }
        try runSpatialUIChecks()
        try NativeAppDelegate.runSpatialDiagnosticsChecks()
        try NativeAppDelegate.runSpatialFormatBridgeChecks()
        try NativeAppDelegate.runOutputConditioningPresentationChecks()
        try NativeAppDelegate.runLiveControlEditingChecks()
        try NativeAppDelegate.runGUIAudioLifecycleChecks()
        exit(0)
    }
    let settings = try parseArguments()

    if case .listApps = settings.mode {
        listRunningApps()
        exit(0)
    }
    if case .selfTest = settings.mode {
        try runInputValidationChecks()
        try runDSPParityChecks()
        try runOutputConditioningChecks()
        try runRuntimeChecks()
        try runSourceFormatTrackerChecks()
        try AudioSpectrumAnalyzer.runOfflineChecks()
        if #available(macOS 14.4, *) {
            try NativeAppDelegate.runStopRestorationChecks()
            try SystemAudioProcessor.runManagerResponsivenessChecks()
            try SystemAudioProcessor.runCaptureTargetRefreshChecks()
            try SystemAudioProcessor.runInputBufferLayoutChecks()
            try AudioGraphChecks.run()
            try HardwareEventChecks.run()
            try NativeAppDelegate.runCaptureSessionChecks()
        }
        exit(0)
    }

    guard #available(macOS 14.4, *) else {
        throw AppError.message("Native system audio processing requires macOS 14.4 or newer.")
    }

    let processor = try SystemAudioProcessor(settings: settings)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler {
        if processor.stop() {
            exit(0)
        }
        let reason = processor.stopFailureDescription
        fputs("중지 미완료: \(reason). SIGINT로 다시 시도할 수 있습니다.\n", stderr)
    }
    signalSource.resume()

    try processor.start()
    RunLoop.main.run()
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
