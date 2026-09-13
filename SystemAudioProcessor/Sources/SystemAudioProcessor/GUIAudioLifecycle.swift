import Foundation

/// The GUI worker owns blocking lifecycle calls. Injection replaces only the
/// platform boundary for offline checks; the delegate still owns every state
/// transition, completion, cancellation intent and processor reference.
@available(macOS 14.4, *)
struct GUIAudioLifecycleIO: Sendable {
    var make: @Sendable (Settings) throws -> SystemAudioProcessor = {
        try SystemAudioProcessor(settings: $0)
    }
    var start: @Sendable (SystemAudioProcessor) throws -> Void = { try $0.start() }
    var stop: @Sendable (SystemAudioProcessor) -> Bool = { $0.stop() }
}

/// Keep the last production reference on the worker. SAP.deinit calls stop()
/// again, so retiring the main property alone must not run that destructor on
/// the event loop. This table is accessed exclusively on the serial queue.
@available(macOS 14.4, *)
final class GUIAudioLifecycleWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.codexaudiolab.lowendcircuit.gui-lifecycle")
    private var retained: [String: SystemAudioProcessor] = [:]

    func make(_ settings: Settings, io: GUIAudioLifecycleIO) throws -> SystemAudioProcessor {
        dispatchPrecondition(condition: .onQueue(queue))
        let processor = try io.make(settings)
        retained[processor.notificationSessionID] = processor
        return processor
    }

    func retire(_ sessionID: String) {
        queue.async { [self] in retained.removeValue(forKey: sessionID) }
    }

    func retainedSessionCountForCheck() -> Int { queue.sync { retained.count } }
}
