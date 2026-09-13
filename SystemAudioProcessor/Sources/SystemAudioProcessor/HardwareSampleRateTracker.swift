import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// Lock-protected optional Double shared between queues during a rate change.
final class RateBox {
    private let lock = NSLock()
    private var value: Double?

    func set(_ rate: Double) {
        lock.lock()
        value = rate
        lock.unlock()
    }

    func get() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Optional control-plane boundary. Normal trackers use Core Audio directly;
/// offline checks still execute the registered listeners on their real queues.
protocol HardwareTrackerIO: AnyObject, Sendable {
    func defaultOutputDevice() throws -> AudioObjectID
    func nominalRate(_ device: AudioObjectID) throws -> Double
    func setNominalRate(_ rate: Double, device: AudioObjectID) throws
    func addListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                     queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    func removeListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                        queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus
}

final class HardwareSampleRateTracker {
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
    private let io: HardwareTrackerIO?
    private let onChange: @Sendable (AudioObjectID, Double) -> Void
    private var outputDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    private var defaultObservationToken: HardwareObservationToken?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var observationToken: HardwareObservationToken?
    private var isStarted = false

    // Core Audio's listener must run on a queue other than `queue`, because
    // `queue` (= the audio manager queue) is blocked by the transition itself
    // during `performRateTransition`. Without a separate queue the listener
    // could not fire and the transition would deadlock on the semaphore.
    private let listenerQueue = DispatchQueue(label: "lowend.hardware-tracker.listener")
    private let confirmationLock = NSLock()
    private var confirmRateChange: ((Double) -> Void)?

    init(queue: DispatchQueue, io: HardwareTrackerIO? = nil,
         onChange: @escaping @Sendable (AudioObjectID, Double) -> Void) {
        self.queue = queue
        self.io = io
        self.onChange = onChange
    }

    private func currentDefaultOutputDevice() throws -> AudioObjectID {
        if let io { return try io.defaultOutputDevice() }
        return try Self.defaultOutputDevice()
    }

    private func currentNominalRate(_ device: AudioObjectID) throws -> Double {
        if let io { return try io.nominalRate(device) }
        return try Self.nominalSampleRate(for: device)
    }

    private func addListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                             queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        if let io { return io.addListener(object, address: address, queue: queue, listener: listener) }
        var address = address
        return AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
    }

    private func removeListener(_ object: AudioObjectID, address: AudioObjectPropertyAddress,
                                queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        if let io { return io.removeListener(object, address: address, queue: queue, listener: listener) }
        var address = address
        return AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !isStarted else { return }

        let defaultToken = HardwareObservationToken()
        defaultObservationToken = defaultToken
        let defaultListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Start/Stop and default delivery share the manager queue. A saved
            // block from an earlier registration must never refresh a new one.
            guard defaultToken.isValid else { return }
            self?.handleDefaultOutputChanged()
        }
        defaultOutputListener = defaultListener

        try check(
            addListener(
                AudioObjectID(kAudioObjectSystemObject),
                address: Self.defaultOutputDeviceAddress(),
                queue: queue,
                listener: defaultListener
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
        defaultObservationToken?.invalidate()
        defaultObservationToken = nil
        removeSampleRateListener()

        if let defaultOutputListener {
            _ = removeListener(
                AudioObjectID(kAudioObjectSystemObject),
                address: Self.defaultOutputDeviceAddress(),
                queue: queue,
                listener: defaultOutputListener
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

    private func handleSampleRateChanged(registeredDeviceID: AudioObjectID, token: HardwareObservationToken) {
        do {
            confirmationLock.lock()
            let currentDeviceID = outputDeviceID
            let currentRegistration = observationToken === token && token.isValid
            confirmationLock.unlock()
            // Reject stale callbacks queued for the previously-registered device.
            guard currentRegistration, currentDeviceID == registeredDeviceID else { return }
            let deviceID = currentDeviceID
            guard deviceID != kAudioObjectUnknown else { return }
            let rate = try currentNominalRate(deviceID)
            confirmationLock.lock()
            // The property read can overlap Stop or a same-device restart.
            // Recheck registration identity under the same lock that protects
            // confirmation consumption; an old read cannot take a new request.
            guard observationToken === token, token.isValid, outputDeviceID == deviceID else {
                confirmationLock.unlock()
                return
            }
            let confirm = confirmRateChange
            confirmRateChange = nil
            confirmationLock.unlock()
            confirm?(rate)
            // `onChange` must run on the audio manager queue to preserve the
            // invariant that hardware state observers see consistent ordering
            // with other manager-queue work.
            let callback = onChange
            let io = io
            queue.async {
                HardwareObservationDelivery.deliver(deviceID: deviceID, token: token,
                    currentDevice: {
                        if let io { return try? io.defaultOutputDevice() }
                        return try? Self.defaultOutputDevice()
                    },
                    currentRate: {
                        if let io { return try? io.nominalRate(deviceID) }
                        return try? Self.nominalSampleRate(for: deviceID)
                    },
                    onChange: callback)
            }
        } catch {
            fputs("Sample rate change handling failed: \(error)\n", stderr)
        }
    }

    private func refreshOutputDevice(forceNotify: Bool) throws {
        let newDeviceID = try currentDefaultOutputDevice()
        confirmationLock.lock()
        let previousDeviceID = outputDeviceID
        confirmationLock.unlock()
        let deviceChanged = newDeviceID != previousDeviceID

        if deviceChanged || sampleRateListener == nil {
            removeSampleRateListener()
            confirmationLock.lock()
            outputDeviceID = newDeviceID
            confirmationLock.unlock()
            try installSampleRateListener(for: newDeviceID)
        }

        if forceNotify || deviceChanged {
            onChange(newDeviceID, try currentNominalRate(newDeviceID))
        }
    }

    private func installSampleRateListener(for deviceID: AudioObjectID) throws {
        guard deviceID != kAudioObjectUnknown else { return }

        let token = HardwareObservationToken()
        confirmationLock.lock()
        observationToken = token
        confirmationLock.unlock()
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleSampleRateChanged(registeredDeviceID: deviceID, token: token)
        }
        sampleRateListener = listener

        try check(
            addListener(deviceID, address: Self.nominalSampleRateAddress(), queue: listenerQueue, listener: listener),
            "AudioObjectAddPropertyListenerBlock NominalSampleRate"
        )
    }

    private func removeSampleRateListener() {
        confirmationLock.lock()
        observationToken?.invalidate()
        observationToken = nil
        confirmRateChange = nil
        let deviceID = outputDeviceID
        confirmationLock.unlock()
        guard deviceID != kAudioObjectUnknown, let sampleRateListener else { return }
        _ = removeListener(deviceID, address: Self.nominalSampleRateAddress(), queue: listenerQueue, listener: sampleRateListener)
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

    /// Best-effort device display name. Runs on the caller's (non-audio) thread;
    /// returns "—" when the device is unknown or the property cannot be read.
    /// Used by the read-only Diagnostics panel to label the current output device.
    static func deviceName(for deviceID: AudioObjectID) -> String {
        guard deviceID != kAudioObjectUnknown else { return "—" }
        var name: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, ptr)
        }
        return status == noErr ? (name as String) : "—"
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

    func requestRateChange(_ sampleRate: Double,
                           for deviceID: AudioObjectID,
                           onChange: @escaping (Double) -> Void) throws {
        confirmationLock.lock()
        confirmRateChange = onChange
        confirmationLock.unlock()
        do {
            if let io { try io.setNominalRate(sampleRate, device: deviceID) }
            else { try Self.setNominalSampleRate(sampleRate, for: deviceID) }
        } catch {
            cancelRateChangeConfirmation()
            throw error
        }
    }

    func cancelRateChangeConfirmation() {
        confirmationLock.lock()
        confirmRateChange = nil
        confirmationLock.unlock()
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
