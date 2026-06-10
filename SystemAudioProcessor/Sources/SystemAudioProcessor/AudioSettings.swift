import Foundation

struct SpatialSettings {
    var enabled: Bool = true
    var listenerX: Float = 0.0
    var listenerZ: Float = 0.0
    var speakerWidth: Float = 1.65
    var amount: Float = 35.0
}

enum DSPModelID {
    static let clean: UInt32 = 0
    static let circuit: UInt32 = 1
    static let highExciter: UInt32 = 2
}

struct Settings {
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
        case selfTest
    }

    enum DSPModel: String {
        case clean
        case circuit
        case highExciter = "highexciter"

        var controlID: UInt32 {
            switch self {
            case .clean: return DSPModelID.clean
            case .circuit: return DSPModelID.circuit
            case .highExciter: return DSPModelID.highExciter
            }
        }

        var displayName: String {
            switch self {
            case .clean: return "Clean"
            case .circuit: return "Circuit"
            case .highExciter: return "HighExciter"
            }
        }

        static func fromArgument(_ value: String) -> DSPModel? {
            let normalized = value
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
            switch normalized {
            case "clean": return .clean
            case "circuit": return .circuit
            case "highexciter", "exciter": return .highExciter
            default: return nil
            }
        }
    }
}
