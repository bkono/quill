import AppKit
import CoreAudio
import Foundation

/// Observes Core Audio client metadata without opening an input device or
/// process tap. Property listeners provide the fast path; the timer is a
/// recovery sweep for listener loss and audio-service churn.
@MainActor
final class CoreAudioProcessMonitor {
    var onActivitiesChanged: (([AudioProcessActivity]) -> Void)?

    private var processListListener: AudioObjectPropertyListenerBlock?
    private var serviceRestartListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var recoveryTimer: Timer?
    private var lastActivities: [AudioProcessActivity] = []
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true
        installSystemListeners()
        refresh()

        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        removeAllProcessListeners()
        removeSystemListeners()
        lastActivities = []
    }

    private func installSystemListeners() {
        let processListBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        processListListener = processListBlock
        addSystemListener(
            selector: kAudioHardwarePropertyProcessObjectList,
            block: processListBlock
        )

        let restartBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.reinstallAfterServiceRestart() }
        }
        serviceRestartListener = restartBlock
        addSystemListener(
            selector: kAudioHardwarePropertyServiceRestarted,
            block: restartBlock
        )
    }

    private func removeSystemListeners() {
        if let processListListener {
            removeSystemListener(
                selector: kAudioHardwarePropertyProcessObjectList,
                block: processListListener
            )
        }
        if let serviceRestartListener {
            removeSystemListener(
                selector: kAudioHardwarePropertyServiceRestarted,
                block: serviceRestartListener
            )
        }
        processListListener = nil
        serviceRestartListener = nil
    }

    private func reinstallAfterServiceRestart() {
        guard isStarted else { return }
        removeAllProcessListeners()
        removeSystemListeners()
        installSystemListeners()
        refresh()
    }

    private func addSystemListener(
        selector: AudioObjectPropertySelector,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = propertyAddress(selector)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        if status != noErr {
            warn("couldn't install Core Audio system listener \(fourCC(selector)) (OSStatus \(status))")
        }
    }

    private func removeSystemListener(
        selector: AudioObjectPropertySelector,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = propertyAddress(selector)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
    }

    private func refresh() {
        guard isStarted else { return }
        let objectIDs = processObjectIDs()
        synchronizeProcessListeners(with: Set(objectIDs))

        let activities = objectIDs.compactMap(activity).sorted {
            if $0.bundleID != $1.bundleID { return $0.bundleID < $1.bundleID }
            return $0.pid < $1.pid
        }
        guard activities != lastActivities else { return }
        lastActivities = activities
        onActivitiesChanged?(activities)
    }

    private func synchronizeProcessListeners(with objectIDs: Set<AudioObjectID>) {
        for (objectID, block) in processListeners where !objectIDs.contains(objectID) {
            removeProcessListener(objectID: objectID, block: block)
        }
        for objectID in processListeners.keys where !objectIDs.contains(objectID) {
            processListeners.removeValue(forKey: objectID)
        }

        for objectID in objectIDs where processListeners[objectID] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }

            var inputAddress = propertyAddress(kAudioProcessPropertyIsRunningInput)
            let inputStatus = AudioObjectAddPropertyListenerBlock(
                objectID,
                &inputAddress,
                nil,
                block
            )
            var outputAddress = propertyAddress(kAudioProcessPropertyIsRunningOutput)
            let outputStatus = AudioObjectAddPropertyListenerBlock(
                objectID,
                &outputAddress,
                nil,
                block
            )

            if inputStatus == noErr || outputStatus == noErr {
                processListeners[objectID] = block
            }
        }
    }

    private func removeAllProcessListeners() {
        for (objectID, block) in processListeners {
            removeProcessListener(objectID: objectID, block: block)
        }
        processListeners.removeAll()
    }

    private func removeProcessListener(
        objectID: AudioObjectID,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var inputAddress = propertyAddress(kAudioProcessPropertyIsRunningInput)
        AudioObjectRemovePropertyListenerBlock(objectID, &inputAddress, nil, block)
        var outputAddress = propertyAddress(kAudioProcessPropertyIsRunningOutput)
        AudioObjectRemovePropertyListenerBlock(objectID, &outputAddress, nil, block)
    }

    private func processObjectIDs() -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](
            repeating: AudioObjectID(kAudioObjectUnknown),
            count: count
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &objectIDs
        ) == noErr else {
            return []
        }
        return objectIDs.filter { $0 != AudioObjectID(kAudioObjectUnknown) }
    }

    private func activity(_ objectID: AudioObjectID) -> AudioProcessActivity? {
        let isRunningInput = boolProperty(
            kAudioProcessPropertyIsRunningInput,
            objectID: objectID
        )
        let isRunningOutput = boolProperty(
            kAudioProcessPropertyIsRunningOutput,
            objectID: objectID
        )
        guard isRunningInput || isRunningOutput,
              let pid = pidProperty(objectID),
              pid > 0 else {
            return nil
        }

        let runningApplication = NSRunningApplication(processIdentifier: pid)
        let bundleID = stringProperty(kAudioProcessPropertyBundleID, objectID: objectID)
            ?? runningApplication?.bundleIdentifier
            ?? "pid:\(pid)"

        return AudioProcessActivity(
            pid: pid,
            bundleID: bundleID,
            appName: runningApplication?.localizedName ?? bundleID,
            isRunningInput: isRunningInput,
            isRunningOutput: isRunningOutput
        )
    }

    private func pidProperty(_ objectID: AudioObjectID) -> pid_t? {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var pid = pid_t(0)
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &pid
        ) == noErr else {
            return nil
        }
        return pid
    }

    private func stringProperty(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        // Core Audio documents this property as caller-owned.
        return value?.takeRetainedValue() as String?
    }

    private func boolProperty(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) -> Bool {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return false
        }
        return value != 0
    }

    private func propertyAddress(
        _ selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func fourCC(_ value: UInt32) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { shift in
            UInt8((value >> UInt32(shift)) & 0xff)
        }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("meeting awareness: warning: \(message)\n".utf8))
    }
}
