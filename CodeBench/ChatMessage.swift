import Foundation

struct ChatMessage: Equatable, Codable {
    enum Role: String, Codable {
        case system
        case user
        case assistant
    }

    let role: Role
    var content: String
}
