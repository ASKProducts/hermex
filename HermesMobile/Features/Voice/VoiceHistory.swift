import Foundation

extension VoiceScreenModel {
    func awaitChatWorkSettled() async { await engineSession?.awaitChatWorkSettled() }
}
