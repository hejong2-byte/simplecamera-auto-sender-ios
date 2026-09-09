import Foundation

enum IPhoneIncomingFilePolicy {
    static func needsNewDecision(
        localStage: IPhoneLocalReceiveStage?,
        usbState: USBReceiveState?,
        hasStoredRecord: Bool
    ) -> Bool {
        true
    }
}
