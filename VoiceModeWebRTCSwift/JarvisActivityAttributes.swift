import Foundation
import ActivityKit

struct JarvisActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var status: String
        var isMuted: Bool
    }

    var name: String
}
