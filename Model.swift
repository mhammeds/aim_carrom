import Foundation

/// Piece kinds on the board.
enum Kind: String, Codable {
    case white, black, queen, striker
}

struct Piece: Codable {
    var kind: Kind
    var x: Double   // board units 0...1 (playing surface), x to the right
    var y: Double   // y downwards
}

/// What the broadcast extension sends to the app ~15 times per second.
struct AimResult: Codable {
    var t: Double                    // timestamp (CFAbsoluteTime)
    var boardFound: Bool
    var pieces: [Piece]
    var aiming: Bool
    var angle: Double?               // degrees, 0 = right, counter-clockwise
    var power: Double?               // 0...1
    var paths: [[Float]]             // per body: flat [x0,y0,x1,y1,...]
    var moved: [Bool]
    var pocketedBodies: [Int]        // body indices that fall in a pocket
    var pocketedPockets: [Int]       // matching pocket index 0..3 (TL,TR,BR,BL)
    var ghost: [Double]?             // striker centre at first contact
    var aimLine: [Float]?            // long straight aim line [x0,y0,x1,y1,...]
    var status: String
}

enum Link {
    /// UDP on the loopback interface: extension -> app. No App Group needed,
    /// so the app can be re-signed with any certificate / provisioning profile.
    static let port: UInt16 = 47821
}
