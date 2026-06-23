import Foundation

struct AudioFormatStatus {
    let sampleRate: Double
    let tapSampleRate: Double
    let processingSampleRate: Double
    let sampleFormat: String
    let isSampleRateMatched: Bool

    var indicatorText: String {
        let tapMatchesEngine = abs(tapSampleRate - processingSampleRate) <= 0.5
        if isSampleRateMatched && tapMatchesEngine {
            return "Shared Tap/Engine/DAC \(Self.rateText(processingSampleRate)) / \(sampleFormat)"
        }
        return "Tap \(Self.rateText(tapSampleRate)) / Engine \(Self.rateText(processingSampleRate)) / DAC \(Self.rateText(sampleRate))"
    }

    static func rateText(_ sampleRate: Double) -> String {
        sampleRate >= 1000
            ? String(format: "%.1f kHz", sampleRate / 1000)
            : String(format: "%.0f Hz", sampleRate)
    }

    /// Optional convenience used by the read-only Diagnostics panel: returns
    /// "—" for nil / non-positive so unbuilt/stopped rows render cleanly.
    static func rateText(_ sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate > 0 else { return "—" }
        return rateText(sampleRate)
    }
}

enum AudioFormatNotifications {
    static let didChange = Notification.Name("LowEndAudioHardwareFormatDidChange")
    static let sampleRateKey = "sampleRate"
    static let tapSampleRateKey = "tapSampleRate"
    static let processingSampleRateKey = "processingSampleRate"
    static let sampleFormatKey = "sampleFormat"
    static let isSampleRateMatchedKey = "isSampleRateMatched"
    static let indicatorTextKey = "indicatorText"
    static let supportedSampleRatesKey = "supportedSampleRates"
    static let isSampleRateSettableKey = "isSampleRateSettable"
    static let automaticRateMatchingEnabledKey = "automaticRateMatchingEnabled"
    static let rateMatchStatusKey = "rateMatchStatus"
    static let rateMatchPhaseKey = "rateMatchPhase"
    /// Live PCM 2× oversampling activation + fallback state (Output Conditioning).
    static let livePCM2xActiveKey = "livePCM2xActive"
    static let livePCM2xFallbackKey = "livePCM2xFallback"
}
