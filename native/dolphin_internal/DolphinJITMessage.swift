import Foundation

public struct DolphinJITMessage: Codable, Sendable {
    public let targetPID: Int32
    public let pairingData: Data

    public init(targetPID: Int32, pairingData: Data) {
        self.targetPID = targetPID
        self.pairingData = pairingData
    }

    public struct Response: Codable, Sendable {
        public let success: Bool
        public let message: String

        public init(success: Bool, message: String) {
            self.success = success
            self.message = message
        }
    }
}
