import Foundation
import simd
import Accelerate

extension PaperFlattener {
    /// Page surface z(x, y), camera pose, and the position of every straight line on
    /// the page, fitted to where those lines and the paper's edges appear in the photo.
    /// Each observed point has one unknown of its own (where along its line it is);
    /// those are eliminated per point (Schur complement), so only the pose, the
    /// surface and the line positions form the dense system.
    struct Solver {
        let camera: Camera
        let pw: Double, ph: Double
        /// Residuals are in units of `scale` photo pixels.
        let scale: Double
        let G = PaperFlattener.gridSize
        var C: [Double]
        enum Kind { case across(Int), down(Int), edge(Int) }
        struct Obs { var target: Pt; var kind: Kind; var local: Double }
        var obs: [Obs] = []
        var acrossY: [Double] = []
        var downX: [Double] = []
        /// Robust loss scale (residual units).
        let f = 8.0
        let smoothWeight = 10.0

        init(camera: Camera, pw: Double, ph: Double, scale: Double) {
            self.camera = camera; self.pw = pw; self.ph = ph; self.scale = scale
            C = [Double](repeating: 0, count: PaperFlattener.gridSize * PaperFlattener.gridSize)
        }
        mutating func addAcross(_ pts: [Pt], xs: [Double], y: Double) {
            let s = acrossY.count; acrossY.append(y)
            for (p, x) in zip(pts, xs) { obs.append(Obs(target: p, kind: .across(s), local: x)) }
        }
        mutating func addDown(_ pts: [Pt], ys: [Double], x: Double) {
            let v = downX.count; downX.append(x)
            for (p, y) in zip(pts, ys) { obs.append(Obs(target: p, kind: .down(v), local: y)) }
        }
        mutating func addEdge(_ p: Pt, side: Int, free: Double) { obs.append(Obs(target: p, kind: .edge(side), local: free)) }

        // MARK: Model

        /// Cubic B-spline basis: first control index and four weights.
        @inline(__always) func basis(_ t: Double) -> (Int, SIMD4<Double>) {
            let n = G
            let s = min(max(t, 0), 1) * Double(n - 3)
            let i = min(max(Int(s.rounded(.down)), 0), n - 4)
            let u = s - Double(i), u2 = u * u, u3 = u2 * u
            return (i, SIMD4((1 - u) * (1 - u) * (1 - u) / 6, (3 * u3 - 6 * u2 + 4) / 6, (-3 * u3 + 3 * u2 + 3 * u + 1) / 6, u3 / 6))
        }
        func z(_ X: Double, _ Y: Double, _ c: [Double]) -> Double {
            let (ix, bx) = basis(X / pw), (iy, by) = basis(Y / ph)
            var s = 0.0
            for a in 0..<4 { for b in 0..<4 { s += by[a] * bx[b] * c[(iy + a) * G + ix + b] } }
            return s
        }
        @inline(__always) func proj(_ X: Double, _ Y: Double, _ Z: Double, _ R: simd_double3x3, _ t: SIMD3<Double>) -> Pt {
            let p = R * SIMD3(X, Y, Z) + t
            return Pt(camera.f * p.x / p.z + camera.cx, camera.f * p.y / p.z + camera.cy)
        }
        func project(_ X: Double, _ Y: Double, pose: Pose) -> Pt { proj(X, Y, z(X, Y, C), pose.R, pose.t) }
        func point(_ o: Obs, local: Double, ay: [Double], dx: [Double]) -> (Double, Double) {
            switch o.kind {
            case .across(let s): return (local, ay[s])
            case .down(let v): return (dx[v], local)
            case .edge(let k):
                switch k { case 0: return (local, 0); case 1: return (pw, local); case 2: return (local, ph); default: return (0, local) }
            }
        }

        // MARK: Fitting

        struct Params { var pose: Pose; var c: [Double]; var ay: [Double]; var dx: [Double]; var locals: [Double] }

        func robust(_ r: Double) -> Double { let z = (r / f) * (r / f); return 2 * f * f * ((1 + z).squareRoot() - 1) }
        func smoothRows() -> [[(Int, Double)]] {
            var rows: [[(Int, Double)]] = []
            for i in 1..<(G - 1) { for j in 0..<G { rows.append([((i - 1) * G + j, 1), (i * G + j, -2), ((i + 1) * G + j, 1)]) } }
            for i in 0..<G { for j in 1..<(G - 1) { rows.append([(i * G + j - 1, 1), (i * G + j, -2), (i * G + j + 1, 1)]) } }
            for i in 0..<(G - 1) { for j in 0..<(G - 1) { rows.append([((i + 1) * G + j + 1, 1), ((i + 1) * G + j, -1), (i * G + j + 1, -1), (i * G + j, 1)]) } }
            rows.append((0..<(G * G)).map { ($0, 3.0 / Double(G * G)) })
            return rows
        }
        func cost(_ p: Params, rows: [[(Int, Double)]]) -> Double {
            let R = p.pose.R
            var total = 0.0
            for (k, o) in obs.enumerated() {
                let (X, Y) = point(o, local: p.locals[k], ay: p.ay, dx: p.dx)
                let q = proj(X, Y, z(X, Y, p.c), R, p.pose.t)
                let r = (q - o.target) / scale
                total += robust(r.x) + robust(r.y)
            }
            for row in rows { let s = smoothWeight * row.reduce(0) { $0 + $1.1 * p.c[$1.0] }; total += s * s }
            return total
        }

        /// Fits everything; false when the result isn't trustworthy.
        mutating func solve(pose: inout Pose, iterations: Int) -> Bool {
            guard !obs.isEmpty else { return false }
            let nC = G * G, nA = acrossY.count, nD = downX.count
            let ng = 6 + nC + nA + nD
            let rows = smoothRows()
            var p = Params(pose: pose, c: C, ay: acrossY, dx: downX, locals: obs.map(\.local))
            var current = cost(p, rows: rows)
            var lambda = 1e-3
            let eps = 1e-6
            for _ in 0..<iterations {
                // Per-point blocks: up to `width` global unknowns each (pose, 16 surface
                // coefficients, its line), stored flat.
                let width = 23, nObs = obs.count
                var Hgg = [Double](repeating: 0, count: ng * ng)
                var bg = [Double](repeating: 0, count: ng)
                var bIdx = [Int](repeating: 0, count: nObs * width)
                var bHgl = [Double](repeating: 0, count: nObs * width)
                var bN = [Int](repeating: 0, count: nObs)
                var bHll = [Double](repeating: 0, count: nObs)
                var bBl = [Double](repeating: 0, count: nObs)
                let R0 = p.pose.R, t0 = p.pose.t
                var poses: [(simd_double3x3, SIMD3<Double>)] = []
                for k in 0..<6 {
                    var q = p.pose
                    if k < 3 { q.r[k] += eps } else { q.t[k - 3] += eps }
                    poses.append((q.R, q.t))
                }
                var idx = [Int](repeating: 0, count: width)
                var J = [Pt](repeating: .zero, count: width)
                Hgg.withUnsafeMutableBufferPointer { H in
                bg.withUnsafeMutableBufferPointer { bgp in
                for k in 0..<nObs {
                    let o = obs[k]
                    let (X, Y) = point(o, local: p.locals[k], ay: p.ay, dx: p.dx)
                    let Z = z(X, Y, p.c)
                    let q0 = proj(X, Y, Z, R0, t0)
                    let r = (q0 - o.target) / scale
                    let w = SIMD2(1 / (1 + (r.x / f) * (r.x / f)).squareRoot(), 1 / (1 + (r.y / f) * (r.y / f)).squareRoot())
                    var n = 0
                    for m in 0..<6 { idx[n] = m; J[n] = (proj(X, Y, Z, poses[m].0, poses[m].1) - q0) / eps / scale; n += 1 }
                    let dz = (proj(X, Y, Z + eps, R0, t0) - q0) / eps / scale
                    let (ix, bx) = basis(X / pw), (iy, by) = basis(Y / ph)
                    for a in 0..<4 {
                        for b in 0..<4 {
                            let weight: Double = by[a] * bx[b]
                            idx[n] = 6 + (iy + a) * G + ix + b; J[n] = dz * weight; n += 1
                        }
                    }
                    let dX = (proj(X + eps, Y, z(X + eps, Y, p.c), R0, t0) - q0) / eps / scale
                    let dY = (proj(X, Y + eps, z(X, Y + eps, p.c), R0, t0) - q0) / eps / scale
                    let Jl: Pt
                    switch o.kind {
                    case .across(let s): Jl = dX; idx[n] = 6 + nC + s; J[n] = dY; n += 1
                    case .down(let v): Jl = dY; idx[n] = 6 + nC + nA + v; J[n] = dX; n += 1
                    case .edge(let side): Jl = side == 0 || side == 2 ? dX : dY
                    }
                    for a in 0..<n {
                        let ja = J[a], ia = idx[a]
                        bgp[ia] += w.x * ja.x * r.x + w.y * ja.y * r.y
                        bIdx[k * width + a] = ia
                        bHgl[k * width + a] = w.x * ja.x * Jl.x + w.y * ja.y * Jl.y
                        for b in a..<n {
                            let jb = J[b], ib = idx[b]
                            let v = w.x * ja.x * jb.x + w.y * ja.y * jb.y
                            H[ia * ng + ib] += v
                            if a != b { H[ib * ng + ia] += v }
                        }
                    }
                    bN[k] = n
                    bHll[k] = w.x * Jl.x * Jl.x + w.y * Jl.y * Jl.y
                    bBl[k] = w.x * Jl.x * r.x + w.y * Jl.y * r.y
                }
                }
                }
                // Smoothness (linear in the surface).
                for row in rows {
                    let s = smoothWeight * row.reduce(0) { $0 + $1.1 * p.c[$1.0] }
                    for (i, ci) in row {
                        bg[6 + i] += smoothWeight * ci * s
                        for (j, cj) in row { Hgg[(6 + i) * ng + 6 + j] += smoothWeight * smoothWeight * ci * cj }
                    }
                }
                var improved = false
                for _ in 0..<8 {
                    var S = Hgg, g = bg
                    for i in 0..<ng { S[i * ng + i] += lambda * max(Hgg[i * ng + i], 1e-9) }
                    S.withUnsafeMutableBufferPointer { Sp in
                        for k in 0..<nObs {
                            let hll = bHll[k] * (1 + lambda) + 1e-12, base = k * width
                            let n = bN[k]
                            for a in 0..<n {
                                let ia = bIdx[base + a], ha = bHgl[base + a] / hll
                                g[ia] -= ha * bBl[k]
                                for b in 0..<n { Sp[ia * ng + bIdx[base + b]] -= ha * bHgl[base + b] }
                            }
                        }
                    }
                    guard let dg = Solver.cholesky(S, g.map { -$0 }, n: ng) else { lambda *= 10; continue }
                    var trial = p
                    for k in 0..<3 { trial.pose.r[k] += dg[k]; trial.pose.t[k] += dg[3 + k] }
                    for k in 0..<nC { trial.c[k] += dg[6 + k] }
                    for k in 0..<nA { trial.ay[k] += dg[6 + nC + k] }
                    for k in 0..<nD { trial.dx[k] += dg[6 + nC + nA + k] }
                    for k in 0..<nObs {
                        var v = bBl[k]
                        for a in 0..<bN[k] { v += bHgl[k * width + a] * dg[bIdx[k * width + a]] }
                        trial.locals[k] -= v / (bHll[k] * (1 + lambda) + 1e-12)
                    }
                    let c = cost(trial, rows: rows)
                    if c.isFinite && c < current {
                        let gain = (current - c) / max(current, 1e-12)
                        p = trial; current = c; lambda = max(lambda * 0.3, 1e-9); improved = true
                        if gain < 1e-6 { break }
                        break
                    }
                    lambda *= 10
                }
                if !improved { break }
            }
            pose = p.pose; C = p.c; acrossY = p.ay; downX = p.dx
            for k in obs.indices { obs[k].local = p.locals[k] }
            // Trust it only when the lines and edges actually fit.
            let R = pose.R
            var errs: [Double] = []
            for o in obs {
                let (X, Y) = point(o, local: o.local, ay: acrossY, dx: downX)
                errs.append(simd_length(proj(X, Y, z(X, Y, C), R, pose.t) - o.target) / scale)
            }
            errs.sort()
            return pose.t.z > 0 && errs[errs.count / 2] < 1.5
        }

        /// Solves A x = b for a symmetric positive definite A (n×n), with LAPACK
        /// (fast in debug builds too).
        static func cholesky(_ A: [Double], _ b: [Double], n: Int) -> [Double]? {
            var a = A, x = b
            var N = __CLPK_integer(n), nrhs = __CLPK_integer(1), lda = __CLPK_integer(n), ldb = __CLPK_integer(n), info = __CLPK_integer(0)
            var uplo = Int8(UInt8(ascii: "U"))
            dposv_(&uplo, &N, &nrhs, &a, &lda, &x, &ldb, &info)
            return info == 0 && x.allSatisfy(\.isFinite) ? x : nil
        }
    }
}
