import Foundation
import Carbon.HIToolbox
import VeypaneCore

@MainActor
public final class GlobalHotkeyManager {
    fileprivate static weak var sharedInstance: GlobalHotkeyManager?

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var currentBinding: HotkeyBinding?
    public var onTrigger: (@MainActor () -> Void)?

    public init() {
        Self.sharedInstance = self
        installCarbonHandlerIfNeeded()
    }

    public func register(binding: HotkeyBinding) {
        if currentBinding == binding, hotKeyRef != nil {
            return
        }
        unregister()
        currentBinding = binding

        let hotKeyID = EventHotKeyID(signature: OSType(0x534C4352), id: 1) // 'SLCR'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers.carbonFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        }
    }

    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        currentBinding = nil
    }

    private func installCarbonHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, eventRef, _ in
            guard let eventRef else { return OSStatus(eventNotHandledErr) }
            var incomingID = EventHotKeyID()
            let err = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &incomingID
            )
            guard err == noErr, incomingID.signature == OSType(0x534C4352) else {
                return OSStatus(eventNotHandledErr)
            }
            Task { @MainActor in
                GlobalHotkeyManager.sharedInstance?.onTrigger?()
            }
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            nil,
            &handlerRef
        )
        if status == noErr {
            eventHandlerRef = handlerRef
        }
    }

    public func tearDown() {
        unregister()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
    }
}
