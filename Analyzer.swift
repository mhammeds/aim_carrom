import Foundation

/// Light-weight computer vision for Sawa Play carrom (no OpenCV - fits the 50 MB
/// memory limit of a broadcast extension). Works on an RGBA bitmap of the screen,
/// scaled to ~540 px wide.
///
/// 1. find the board from the 4 dark-brown pocket holes
/// 2. resample the board to a 320x320 grid
/// 3. colour masks (white / black / queen) -> closing -> connected blobs -> discs
///    (touching coins are split with k-means)
/// 4. green aim arrow -> PCA line fit -> direction + length (= power)
/// 5. physics simulation -> AimResult
final class Analyzer {
    let N = 320
    var P = PhysicsParams()
    private var board: (x0: Double, y0: Double, S: Double)?
    private var lastBoardT = 0.0
    private var cachedPieces: [Piece] = []
    private var aiming = false
    private var lastKey = ""
    private var lastResult: AimResult?

    // MARK: - entry point
    func analyze(rgba: [UInt8], w: Int, h: Int, now: Double) -> AimResult {
        if !aiming && (board == nil || now - lastBoardT > 0.5) {
            if let b = findBoard(rgba, w, h) { board = b }
            lastBoardT = now
        }
        guard let bd = board else {
            return AimResult(t: now, boardFound: false, pieces: [], aiming: false, angle: nil, power: nil,
                             paths: [], moved: [], pocketedBodies: [], pocketedPockets: [], ghost: nil, aimLine: nil,
                             status: "ما لقيت اللوحة")
        }
        let grid = sampleBoard(rgba, w, h, bd)
        var pieces: [Piece]
        if aiming && !cachedPieces.isEmpty {
            pieces = cachedPieces                 // nothing moves while you aim
        } else {
            pieces = detectPieces(grid)
            if pieces.contains(where: { $0.kind == .striker }) { cachedPieces = pieces }
        }
        guard let si = pieces.firstIndex(where: { $0.kind == .striker }) else {
            aiming = false
            return AimResult(t: now, boardFound: true, pieces: pieces, aiming: false, angle: nil, power: nil,
                             paths: [], moved: [], pocketedBodies: [], pocketedPockets: [], ghost: nil, aimLine: nil,
                             status: "اسحب السهم")
        }
        guard let arrow = detectArrow(grid, striker: pieces[si]) else {
            aiming = false
            return AimResult(t: now, boardFound: true, pieces: pieces, aiming: false, angle: nil, power: nil,
                             paths: [], moved: [], pocketedBodies: [], pocketedPockets: [], ghost: nil, aimLine: nil,
                             status: "اسحب السهم")
        }
        aiming = true
        let power = min(1.0, max(0.05, arrow.len / P.arrowFullLen))
        let angle = (atan2(-arrow.dir.1, arrow.dir.0) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let key = String(format: "%.2f|%.2f|%d", angle, power, pieces.count)
        if key == lastKey, var r = lastResult { r.t = now; return r }

        let sim = simulate(pieces: pieces, striker: si, dir: arrow.dir, power: power, P: P)
        var paths: [[Float]] = []
        for (b, path) in sim.paths.enumerated() {
            guard sim.moved[b] else { paths.append([]); continue }
            let stride = max(1, path.count / 60)
            var flat: [Float] = []
            for (k, p) in path.enumerated() where k % stride == 0 || k == path.count - 1 {
                flat.append(Float(p.0)); flat.append(Float(p.1))
            }
            paths.append(flat)
        }
        var pots: [String] = []
        for (b, _) in sim.pocketed where b != si {
            switch pieces[b].kind {
            case .white: pots.append("أبيض")
            case .black: pots.append("أسود")
            case .queen: pots.append("الملكة")
            default: break
            }
        }
        var status = pots.isEmpty ? (sim.firstHit < 0 ? "ما يلمس شي" : "ما يدخل شي") : "✅ يدخل: " + pots.joined(separator: "، ")
        if sim.pocketed[si] != nil { status = "⚠️ فاول: المضرب يطيح" }
        let res = AimResult(t: now, boardFound: true, pieces: pieces, aiming: true, angle: angle, power: power,
                            paths: paths, moved: sim.moved,
                            pocketedBodies: Array(sim.pocketed.keys), pocketedPockets: Array(sim.pocketed.values),
                            ghost: sim.ghost.map { [$0.0, $0.1] },
                            aimLine: aimRay(pieces: pieces, striker: si, dir: arrow.dir, P: P).flatMap { [Float($0.0), Float($0.1)] },
                            status: status)
        lastKey = key; lastResult = res
        return res
    }

    // MARK: - colour helpers
    @inline(__always) private func hsv(_ r: Int, _ g: Int, _ b: Int) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = Double(mx - mn)
        let v = Double(mx) / 255, s = mx > 0 ? d / Double(mx) : 0
        var h = 0.0
        if d > 0 {
            if mx == r { h = (60 * Double(g - b) / d).truncatingRemainder(dividingBy: 360); if h < 0 { h += 360 } }
            else if mx == g { h = 60 * Double(b - r) / d + 120 }
            else { h = 60 * Double(r - g) / d + 240 }
        }
        return (h, s, v)
    }

    // MARK: - connected components (4-neighbour)
    struct Blob { var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, area = 0, label = 0
        var w: Int { maxX - minX + 1 }; var h: Int { maxY - minY + 1 }
        var cx: Double { Double(minX + maxX + 1) / 2 }; var cy: Double { Double(minY + maxY + 1) / 2 } }

    private func components(_ mask: [Bool], _ w: Int, _ h: Int) -> ([Int32], [Blob]) {
        var labels = [Int32](repeating: 0, count: w * h)
        var blobs: [Blob] = []
        var stack: [Int] = []
        stack.reserveCapacity(4096)
        var next: Int32 = 0
        for start in 0..<(w * h) where mask[start] && labels[start] == 0 {
            next += 1
            var b = Blob(); b.label = Int(next)
            labels[start] = next; stack.append(start)
            while let p = stack.popLast() {
                let x = p % w, y = p / w
                b.area += 1
                if x < b.minX { b.minX = x }; if x > b.maxX { b.maxX = x }
                if y < b.minY { b.minY = y }; if y > b.maxY { b.maxY = y }
                if x > 0, mask[p - 1], labels[p - 1] == 0 { labels[p - 1] = next; stack.append(p - 1) }
                if x < w - 1, mask[p + 1], labels[p + 1] == 0 { labels[p + 1] = next; stack.append(p + 1) }
                if y > 0, mask[p - w], labels[p - w] == 0 { labels[p - w] = next; stack.append(p - w) }
                if y < h - 1, mask[p + w], labels[p + w] == 0 { labels[p + w] = next; stack.append(p + w) }
            }
            blobs.append(b)
        }
        return (labels, blobs)
    }

    // MARK: - 1. board from pockets
    private func findBoard(_ px: [UInt8], _ w: Int, _ h: Int) -> (x0: Double, y0: Double, S: Double)? {
        var mask = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            let r = Int(px[i * 4]), g = Int(px[i * 4 + 1]), b = Int(px[i * 4 + 2])
            if r < 40 || r > 130 || r <= b { continue }          // quick reject
            let (hh, s, v) = hsv(r, g, b)
            mask[i] = hh <= 44 && s >= 0.55 && v >= 0.16 && v <= 0.49
        }
        let (_, blobs) = components(mask, w, h)
        let minA = pow(Double(min(w, h)) * 0.008, 2) * 3
        var holes: [(Double, Double, Double)] = []
        for b in blobs {
            let rad = Double(max(b.w, b.h)) / 2
            if Double(b.area) < minA { continue }
            if Double(b.area) / (Double.pi * rad * rad) < 0.55 { continue }
            if Double(abs(b.w - b.h)) > 0.35 * Double(max(b.w, b.h)) { continue }
            holes.append((b.cx, b.cy, rad))
        }
        var best: (Int, Double, Double, Double, Double, Double)? = nil
        for a in holes {
            for c in holes {
                let dx = c.0 - a.0, dy = c.1 - a.1
                if dx <= 0 || dy <= 0 || abs(dx - dy) > 0.04 * dx || dx < 10 * a.2 { continue }
                if abs(a.2 - c.2) > 0.3 * max(a.2, c.2) { continue }
                let tol = 0.06 * dx
                var sc = 0
                for p in [(c.0, a.1), (a.0, c.1)] where holes.contains(where: { hypot($0.0 - p.0, $0.1 - p.1) < tol }) { sc += 1 }
                if sc == 0 { continue }
                if best == nil || sc > best!.0 || (sc == best!.0 && dx > best!.1) { best = (sc, dx, a.0, a.1, c.0, c.1) }
            }
        }
        guard let bb = best else { return nil }
        let inset = P.pocketInset
        let S = ((bb.4 - bb.2) + (bb.5 - bb.3)) / 2 / (1 - 2 * inset)
        return (bb.2 - inset * S, bb.3 - inset * S, S)
    }

    // MARK: - 2. resample board
    private func sampleBoard(_ px: [UInt8], _ w: Int, _ h: Int, _ bd: (x0: Double, y0: Double, S: Double)) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: N * N * 3)
        var xs = [Int](repeating: 0, count: N)
        for i in 0..<N { xs[i] = min(w - 1, max(0, Int(bd.x0 + (Double(i) + 0.5) / Double(N) * bd.S))) }
        for j in 0..<N {
            let y = min(h - 1, max(0, Int(bd.y0 + (Double(j) + 0.5) / Double(N) * bd.S)))
            for i in 0..<N {
                let s = (y * w + xs[i]) * 4, d = (j * N + i) * 3
                out[d] = px[s]; out[d + 1] = px[s + 1]; out[d + 2] = px[s + 2]
            }
        }
        return out
    }

    private func close(_ m: [Bool]) -> [Bool] {
        func pass(_ src: [Bool], dilate: Bool) -> [Bool] {
            var tmp = src, out = src
            for y in 0..<N { for x in 0..<N {
                let i = y * N + x
                let l = x > 0 ? src[i - 1] : src[i], r = x < N - 1 ? src[i + 1] : src[i]
                tmp[i] = dilate ? (src[i] || l || r) : (src[i] && l && r)
            } }
            for y in 0..<N { for x in 0..<N {
                let i = y * N + x
                let u = y > 0 ? tmp[i - N] : tmp[i], d = y < N - 1 ? tmp[i + N] : tmp[i]
                out[i] = dilate ? (tmp[i] || u || d) : (tmp[i] && u && d)
            } }
            return out
        }
        return pass(pass(m, dilate: true), dilate: false)
    }

    // MARK: - 3. pieces
    private func detectPieces(_ g: [UInt8]) -> [Piece] {
        var white = [Bool](repeating: false, count: N * N), black = white, queen = white
        for i in 0..<(N * N) {
            let r = Int(g[i * 3]), gg = Int(g[i * 3 + 1]), b = Int(g[i * 3 + 2])
            let mx = max(r, gg, b), mn = min(r, gg, b)
            white[i] = r > 200 && gg > 190 && b > 160 && r - b < 75
            black[i] = mx < 115 && mx - mn < 32
            queen[i] = r > 140 && gg < 95 && b < 95 && r - gg > 80
        }
        let cr = P.coinR * Double(N), sr = P.strikerR * Double(N)
        var out: [(Kind, Double, Double, Double)] = []
        for (kind, raw) in [(Kind.white, white), (Kind.black, black), (Kind.queen, queen)] {
            let mask = close(raw)
            let (labels, blobs) = components(mask, N, N)
            for b in blobs {
                let rb = Double(b.w + b.h) / 4
                if Double(b.area) < cr * cr * 1.2 { continue }
                let fill = Double(b.area) / Double(b.w * b.h)
                let cx = b.cx, cy = b.cy
                if P.pockets.contains(where: { hypot(cx / Double(N) - $0.0, cy / Double(N) - $0.1) < P.pocketR }) { continue }
                let square = Double(abs(b.w - b.h))
                if kind == .white && rb >= 0.85 * sr && rb <= 1.3 * sr && fill > 0.62 && square < 0.5 * rb {
                    out.append((.striker, cx, cy, rb)); continue
                }
                if rb >= 0.75 * cr && rb <= 1.25 * cr && fill > 0.55 && square < 0.6 * rb {
                    out.append((kind, cx, cy, rb)); continue
                }
                // touching coins -> k-means split
                let k = Int((Double(b.area) / (Double.pi * cr * cr * 0.9)).rounded())
                guard k >= 2 && k <= 8 && Double(max(b.w, b.h)) < cr * 2 * Double(k) + 2 else { continue }
                var pts: [(Double, Double)] = []
                for y in b.minY...b.maxY { for x in b.minX...b.maxX where labels[y * N + x] == Int32(b.label) {
                    pts.append((Double(x) + 0.5, Double(y) + 0.5)) } }
                var cents = [pts[0]]
                while cents.count < k {
                    var bi = 0, bd = -1.0
                    for (pi, p) in pts.enumerated() {
                        let d = cents.map { hypot(p.0 - $0.0, p.1 - $0.1) }.min()!
                        if d > bd { bd = d; bi = pi }
                    }
                    cents.append(pts[bi])
                }
                for _ in 0..<8 {
                    var sx = [Double](repeating: 0, count: k), sy = sx, cnt = sx
                    for p in pts {
                        var bq = 0, bdist = Double.infinity
                        for q in 0..<k { let d = hypot(p.0 - cents[q].0, p.1 - cents[q].1); if d < bdist { bdist = d; bq = q } }
                        sx[bq] += p.0; sy[bq] += p.1; cnt[bq] += 1
                    }
                    for q in 0..<k where cnt[q] > 0 { cents[q] = (sx[q] / cnt[q], sy[q] / cnt[q]) }
                }
                for c in cents { out.append((kind, c.0, c.1, cr)) }
            }
        }
        // one striker only, nothing inside it
        let strikers = out.filter { $0.0 == .striker }.sorted { $0.3 > $1.3 }
        if let s = strikers.first {
            out = out.filter { p in
                if p.0 == .striker { return p.1 == s.1 && p.2 == s.2 }
                return hypot(p.1 - s.1, p.2 - s.2) > s.3
            }
        }
        // striker last (simulation convention doesn't matter, but keeps output stable)
        out.sort { ($0.0 == .striker ? 1 : 0) < ($1.0 == .striker ? 1 : 0) }
        return out.map { Piece(kind: $0.0, x: $0.1 / Double(N), y: $0.2 / Double(N)) }
    }

    // MARK: - 4. green arrow
    private func detectArrow(_ g: [UInt8], striker s: Piece) -> (dir: (Double, Double), len: Double)? {
        var m = [Bool](repeating: false, count: N * N)
        for i in 0..<(N * N) {
            let r = Int(g[i * 3]), gg = Int(g[i * 3 + 1]), b = Int(g[i * 3 + 2])
            m[i] = gg > 150 && gg - r > 70 && gg - b > 60
        }
        let (labels, blobs) = components(m, N, N)
        let sx = s.x * Double(N), sy = s.y * Double(N), sr = P.strikerR * Double(N)
        var best: (Int, (Double, Double), Double)? = nil
        for b in blobs where b.area >= 15 {
            var xs: [Double] = [], ys: [Double] = []
            for y in b.minY...b.maxY { for x in b.minX...b.maxX where labels[y * N + x] == Int32(b.label) {
                xs.append(Double(x) + 0.5); ys.append(Double(y) + 0.5) } }
            var dmin = Double.infinity, dmax = 0.0
            for k in 0..<xs.count { let d = hypot(xs[k] - sx, ys[k] - sy); dmin = min(dmin, d); dmax = max(dmax, d) }
            if dmin > sr * 2.5 || dmax - dmin < sr * 0.8 { continue }
            let n = Double(xs.count)
            let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
            var cxx = 0.0, cyy = 0.0, cxy = 0.0
            for k in 0..<xs.count { let dx = xs[k] - mx, dy = ys[k] - my; cxx += dx * dx; cyy += dy * dy; cxy += dx * dy }
            let ang = 0.5 * atan2(2 * cxy, cxx - cyy)
            var u = (cos(ang), sin(ang))
            var rad = (mx - sx, my - sy); let rl = max(hypot(rad.0, rad.1), 1e-6); rad = (rad.0 / rl, rad.1 / rl)
            if u.0 * rad.0 + u.1 * rad.1 < 0 { u = (-u.0, -u.1) }
            if u.0 * rad.0 + u.1 * rad.1 < 0.9 { continue }
            if best == nil || b.area > best!.0 { best = (b.area, u, dmax) }
        }
        guard let bb = best else { return nil }
        return (bb.1, bb.2 / Double(N))
    }
}
