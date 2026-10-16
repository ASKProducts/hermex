import Foundation

/// Physical row addresses acknowledged by Hermes at message.complete.
/// An incomplete receipt still identifies surviving rows; it never names
/// the queued next prompt and does not imply that missing rows are absent.
struct HermesTurnReceipt: Equatable {
    let rowIDs: [Int]
    let complete: Bool
    let userRowID: Int?
    let finalAssistantRowID: Int?

    init(rowIDs: [Int], complete: Bool, userRowID: Int? = nil, finalAssistantRowID: Int? = nil) {
        self.rowIDs = rowIDs
        self.complete = complete
        self.userRowID = userRowID
        self.finalAssistantRowID = finalAssistantRowID
    }

    init?(messageComplete payload: BotJSON) {
        let receipt = payload["persisted_turn"]
        guard let complete = receipt["complete"].flag, let rows = receipt["row_ids"].list else { return nil }
        self.init(rowIDs: rows.compactMap(\.integer), complete: complete,
                  userRowID: receipt["user_row_id"].integer,
                  finalAssistantRowID: receipt["final_assistant_row_id"].integer)
    }
}
