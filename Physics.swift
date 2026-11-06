import Foundation

/// Carrom physics: event-driven, exact contact times (same engine as the PC tool).
/// Board units: playing surface = [0,1] x [0,1].
/// Values learned from 104 real Sawa Play shots (calibrate_physics.py on the PC tool).
struct PhysicsParams {
    var coinR = 0.0291
    var strikerR = 0.0381
    var pocketR = 0.045
    var pocketInset = 0.052
    var coinM = 1.0
    var strikerM = 1.4456
    var eCoin = 0.7793
    var eWall = 0.4036       // cushions absorb a lot in Sawa Play
    var friction = 0.547     // constant deceleration, units/s^2
    var damping = 0.0817     // exponential damping 1/s
    var wallFriction = 0.1625 // speed lost ALONG the cushion at each hit
    var coinFriction = 0.0054 // disc-disc "throw"
    var wallOffset = 0.0241  // real cushion is this far inside the drawn edge
    var maxSpeed = 2.0164    // striker speed at power 1
    var powerExp = 1.5605    // speed = maxSpeed * power^powerExp
    var stopSpeed = 0.003
    var dt = 1.0 / 240.0
    var maxTime = 8.0
    var arrowFullLen = 0.23  // green arrow length (striker centre -> tip) at 100 %

    func radius(_ k: Kind) -> Double { k == .striker ? strikerR : coinR }
    func mass(_ k: Kind) -> Double { k == .striker ? strikerM : coinM }
    var pockets: [(Double, Double)] {
        let a = pocketInset, b = 1 - pocketInset
        return [(a, a), (b, a), (b, b), (a, b)]
    }
}

struct SimResult {
    var paths: [[(Double, Double)]]
    var moved: [Bool]
    var pocketed: [Int: Int]
    var ghost: (Double, Double)?
    var firstHit: Int
}

func simulate(pieces: [Piece], striker si: Int, dir: (Double, Double), power: Double,
              P: PhysicsParams) -> SimResult {
    let n = pieces.count
    var px = pieces.map { $0.x }, py = pieces.map { $0.y }
    var vx = [Double](repeating: 0, count: n), vy = [Double](repeating: 0, count: n)
    let r = pieces.map { P.radius($0.kind) }, m = pieces.map { P.mass($0.kind) }
    var alive = [Bool](repeating: true, count: n)
    var moved = [Bool](repeating: false, count: n)
    var paths: [[(Double, Double)]] = (0..<n).map { [(px[$0], py[$0])] }
    var pocketed: [Int: Int] = [:]
    var ghost: (Double, Double)? = nil
    var firstHit = -1

    let L = max(hypot(dir.0, dir.1), 1e-9)
    let sp = P.maxSpeed * pow(min(max(power, 0), 1.5), P.powerExp)
    vx[si] = dir.0 / L * sp
    vy[si] = dir.1 / L * sp
    moved[si] = true
    let pk = P.pockets, pr = P.pocketR

    enum Ev { case hit(Int, Int), wall(Int, Int), pocket(Int, Int) }

    func earliest() -> (Double, Ev)? {
        var bt = Double.infinity
        var ev: Ev? = nil
        for i in 0..<n where alive[i] {
            let mi = vx[i] * vx[i] + vy[i] * vy[i] > 1e-14
            if i + 1 < n {
                for j in (i + 1)..<n where alive[j] {
                    let mj = vx[j] * vx[j] + vy[j] * vy[j] > 1e-14
                    if !mi && !mj { continue }
                    let dx = px[j] - px[i], dy = py[j] - py[i]
                    let dvx = vx[j] - vx[i], dvy = vy[j] - vy[i], R = r[i] + r[j]
                    let a = dvx * dvx + dvy * dvy, b = 2 * (dx * dvx + dy * dvy), c = dx * dx + dy * dy - R * R
                    if b >= 0 || a < 1e-14 { continue }
                    var tt: Double
                    if c <= 0 { tt = 0 } else {
                        let d = b * b - 4 * a * c
                        if d < 0 { continue }
                        tt = max(0, (-b - d.squareRoot()) / (2 * a))
                    }
                    if tt < bt { bt = tt; ev = .hit(i, j) }
                }
            }
            if !mi { continue }
            let a = vx[i] * vx[i] + vy[i] * vy[i]
            for q in 0..<4 {
                let dx = px[i] - pk[q].0, dy = py[i] - pk[q].1
                let b = 2 * (dx * vx[i] + dy * vy[i]), c = dx * dx + dy * dy - pr * pr
                var tt: Double
                if c <= 0 { tt = 0 } else {
                    if b >= 0 { continue }
                    let d = b * b - 4 * a * c
                    if d < 0 { continue }
                    tt = (-b - d.squareRoot()) / (2 * a)
                }
                if tt < bt { bt = tt; ev = .pocket(i, q) }
            }
            let wo = P.wallOffset
            if vx[i] < -1e-12 { let tt = max(0, (px[i] - r[i] - wo) / -vx[i]); if tt < bt { bt = tt; ev = .wall(i, 0) } }
            if vx[i] > 1e-12 { let tt = max(0, (1 - wo - r[i] - px[i]) / vx[i]); if tt < bt { bt = tt; ev = .wall(i, 2) } }
            if vy[i] < -1e-12 { let tt = max(0, (py[i] - r[i] - wo) / -vy[i]); if tt < bt { bt = tt; ev = .wall(i, 1) } }
            if vy[i] > 1e-12 { let tt = max(0, (1 - wo - r[i] - py[i]) / vy[i]); if tt < bt { bt = tt; ev = .wall(i, 3) } }
        }
        if let e = ev { return (bt, e) }
        return nil
    }

    func advance(_ h: Double) {
        for i in 0..<n where alive[i] { px[i] += vx[i] * h; py[i] += vy[i] * h }
    }

    var t = 0.0, nextRec = 1.0 / 60.0
    while t < P.maxTime {
        var any = false
        for i in 0..<n where alive[i] && vx[i] * vx[i] + vy[i] * vy[i] > P.stopSpeed * P.stopSpeed { any = true; break }
        if !any { break }
        var rem = P.dt, guardN = 0
        while rem > 1e-12 && guardN < 200 {
            guardN += 1
            guard let e = earliest(), e.0 < rem else { advance(rem); break }
            let te = e.0, ev = e.1
            advance(te); rem -= te
            switch ev {
            case .hit(let i, let j):
                var nx = px[j] - px[i], ny = py[j] - py[i]
                let d = max(hypot(nx, ny), 1e-12); nx /= d; ny /= d
                let vrel = (vx[i] - vx[j]) * nx + (vy[i] - vy[j]) * ny
                if vrel > 0 {
                    let J = (1 + P.eCoin) * vrel / (1 / m[i] + 1 / m[j])
                    vx[i] -= J / m[i] * nx; vy[i] -= J / m[i] * ny
                    vx[j] += J / m[j] * nx; vy[j] += J / m[j] * ny
                    if P.coinFriction > 0 {
                        let tx = -ny, ty = nx
                        let vt = (vx[i] - vx[j]) * tx + (vy[i] - vy[j]) * ty
                        var Jt = min(P.coinFriction * J, abs(vt) / (1 / m[i] + 1 / m[j]))
                        if vt < 0 { Jt = -Jt }
                        vx[i] -= Jt / m[i] * tx; vy[i] -= Jt / m[i] * ty
                        vx[j] += Jt / m[j] * tx; vy[j] += Jt / m[j] * ty
                    }
                }
                let ov = r[i] + r[j] - d
                if ov > 0 { px[i] -= nx * ov / 2; py[i] -= ny * ov / 2; px[j] += nx * ov / 2; py[j] += ny * ov / 2 }
                moved[i] = true; moved[j] = true
                paths[i].append((px[i], py[i])); paths[j].append((px[j], py[j]))
                if ghost == nil && (i == si || j == si) { ghost = (px[si], py[si]); firstHit = i == si ? j : i }
            case .wall(let i, let w):
                if w % 2 == 0 {
                    vx[i] = -P.eWall * vx[i]; vy[i] *= (1 - P.wallFriction)
                    px[i] = w == 0 ? r[i] + P.wallOffset : 1 - P.wallOffset - r[i]
                } else {
                    vy[i] = -P.eWall * vy[i]; vx[i] *= (1 - P.wallFriction)
                    py[i] = w == 1 ? r[i] + P.wallOffset : 1 - P.wallOffset - r[i]
                }
                paths[i].append((px[i], py[i]))
            case .pocket(let i, let q):
                paths[i].append(pk[q]); alive[i] = false; vx[i] = 0; vy[i] = 0; pocketed[i] = q
            }
        }
        if P.damping > 0 {
            let k = exp(-P.damping * P.dt)
            for i in 0..<n { vx[i] *= k; vy[i] *= k }
        }
        let dec = P.friction * P.dt
        for i in 0..<n {
            let s = hypot(vx[i], vy[i]); let k = s > dec ? (s - dec) / s : 0
            vx[i] *= k; vy[i] *= k
        }
        t += P.dt
        if t >= nextRec {
            nextRec += 1.0 / 60.0
            for i in 0..<n where alive[i] && (vx[i] != 0 || vy[i] != 0) { paths[i].append((px[i], py[i])) }
        }
    }
    for i in 0..<n where alive[i] && moved[i] { paths[i].append((px[i], py[i])) }
    return SimResult(paths: paths, moved: moved, pocketed: pocketed, ghost: ghost, firstHit: firstHit)
}


/// Long straight aim line (centre of the striker) with cushion reflections, until it touches a piece.
func aimRay(pieces: [Piece], striker si: Int, dir: (Double, Double), P: PhysicsParams,
            maxBounces: Int = 4, maxLen: Double = 4.0) -> [(Double, Double)] {
    var p = (pieces[si].x, pieces[si].y)
    let rs = P.radius(.striker)
    let L = max(hypot(dir.0, dir.1), 1e-9)
    var d = (dir.0 / L, dir.1 / L)
    var pts = [p]
    var left = maxLen
    let lo = rs + P.wallOffset, hi = 1 - P.wallOffset - rs
    for _ in 0...maxBounces {
        var tHit = Double.infinity
        for (k, q) in pieces.enumerated() where k != si {
            let wx = q.x - p.0, wy = q.y - p.1
            let proj = wx * d.0 + wy * d.1
            if proj <= 0 { continue }
            let R = rs + P.radius(q.kind)
            let perp2 = wx * wx + wy * wy - proj * proj
            if perp2 < R * R { let t = proj - (R * R - perp2).squareRoot(); if t > 1e-6 && t < tHit { tHit = t } }
        }
        let tx = d.0 > 1e-12 ? (hi - p.0) / d.0 : (d.0 < -1e-12 ? (lo - p.0) / d.0 : Double.infinity)
        let ty = d.1 > 1e-12 ? (hi - p.1) / d.1 : (d.1 < -1e-12 ? (lo - p.1) / d.1 : Double.infinity)
        let tWall = max(min(tx, ty), 0)
        let t = min(tHit, tWall, left)
        p = (p.0 + d.0 * t, p.1 + d.1 * t)
        pts.append(p)
        left -= t
        if t == tHit || left <= 1e-9 { break }
        if tx <= ty { d.0 = -d.0 } else { d.1 = -d.1 }
    }
    return pts
}
