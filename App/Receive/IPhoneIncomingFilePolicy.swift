import Foundation

enum IPhoneIncomingFilePolicy {
    static func needsNewDecision(
        localStage: IPhoneLocalReceiveStage?,
        usbState: USBReceiveState?,
        hasStoredRecord: Bool
    ) -> Bool {
        if hasStoredRecord { return false }
        if let localStage, localStage != .failed { return false }
        return usbState != .ackPending && usbState != .completed
    }
}
