import Foundation
import simd

// 独立于 Apple 框架的参考色彩数学。测试图的像素值和所有"期望值"都用这里算，
// 这样测量的是 ImageIO / Core Image / Core Graphics 的行为，而不是拿它们自己验证自己。
// 约定：XYZ 一律是 D65 相对值（Y=1 为 SDR 参考白）；ProPhoto 的 D50 用 Bradford 适配。

typealias V3 = SIMD3<Double>
typealias M3 = simd_double3x3

func rows(_ r0: V3, _ r1: V3, _ r2: V3) -> M3 { M3(rows: [r0, r1, r2]) }

let whiteD65 = V3(0.3127 / 0.3290, 1, (1 - 0.3127 - 0.3290) / 0.3290)
let whiteD50 = V3(0.3457 / 0.3585, 1, (1 - 0.3457 - 0.3585) / 0.3585)

/// Bradford 色适应矩阵（src 白点 → dst 白点）。
func bradford(from src: V3, to dst: V3) -> M3 {
    let b = rows(V3(0.8951, 0.2664, -0.1614), V3(-0.7502, 1.7135, 0.0367), V3(0.0389, -0.0685, 1.0296))
    let s = b * src, d = b * dst
    let scale = M3(diagonal: V3(d.x / s.x, d.y / s.y, d.z / s.z))
    return b.inverse * scale * b
}

/// 由原色色度坐标和白点求 RGB→XYZ 矩阵。
func primaryMatrix(r: (Double, Double), g: (Double, Double), b: (Double, Double), white: V3) -> M3 {
    func xyz(_ p: (Double, Double)) -> V3 { V3(p.0 / p.1, 1, (1 - p.0 - p.1) / p.1) }
    let p = M3(columns: (xyz(r), xyz(g), xyz(b)))
    let s = p.inverse * white
    return p * M3(diagonal: s)
}

enum TRC {
    case linear
    case srgb
    case gamma(Double)
    /// ICC parametric type 3：X >= d 时 Y = (aX+b)^g，否则 Y = cX。Apple 的 ROMM RGB 配置文件用的就是这种。
    case parametric3(g: Double, a: Double, b: Double, c: Double, d: Double)

    /// 编码值 → 线性（对负值做镜像扩展，和 Apple 的 extended 色彩空间一致）。
    func decode(_ v: Double) -> Double {
        let s = v < 0 ? -1.0 : 1.0, x = abs(v)
        switch self {
        case .linear: return v
        case .srgb: return s * (x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
        case .gamma(let g): return s * pow(x, g)
        case let .parametric3(g, a, b, c, d): return s * (x >= d ? pow(a * x + b, g) : c * x)
        }
    }

    func encode(_ v: Double) -> Double {
        let s = v < 0 ? -1.0 : 1.0, y = abs(v)
        switch self {
        case .linear: return v
        case .srgb: return s * (y <= 0.0031308 ? y * 12.92 : 1.055 * pow(y, 1 / 2.4) - 0.055)
        case .gamma(let g): return s * pow(y, 1 / g)
        case let .parametric3(g, a, b, c, d):
            let knee = pow(a * d + b, g)
            return s * (y >= knee ? (pow(y, 1 / g) - b) / a : y / c)
        }
    }
}

struct RGBSpace {
    let id: String
    let toXYZ: M3      // 线性 RGB → XYZ(D65)
    let fromXYZ: M3
    let trc: TRC

    init(id: String, toXYZ: M3, trc: TRC) {
        self.id = id; self.toXYZ = toXYZ; self.fromXYZ = toXYZ.inverse; self.trc = trc
    }

    func linear(fromEncoded e: V3) -> V3 { V3(trc.decode(e.x), trc.decode(e.y), trc.decode(e.z)) }
    func encoded(fromLinear l: V3) -> V3 { V3(trc.encode(l.x), trc.encode(l.y), trc.encode(l.z)) }
    func xyz(fromEncoded e: V3) -> V3 { toXYZ * linear(fromEncoded: e) }
    func encoded(fromXYZ x: V3) -> V3 { encoded(fromLinear: fromXYZ * x) }
}

enum Spaces {
    static let srgbM = primaryMatrix(r: (0.64, 0.33), g: (0.30, 0.60), b: (0.15, 0.06), white: whiteD65)
    static let p3M = primaryMatrix(r: (0.680, 0.320), g: (0.265, 0.690), b: (0.150, 0.060), white: whiteD65)
    static let adobeM = primaryMatrix(r: (0.64, 0.33), g: (0.21, 0.71), b: (0.15, 0.06), white: whiteD65)
    static let rec2020M = primaryMatrix(r: (0.708, 0.292), g: (0.170, 0.797), b: (0.131, 0.046), white: whiteD65)
    static let prophotoM: M3 = {
        let d50 = primaryMatrix(r: (0.7347, 0.2653), g: (0.1596, 0.8404), b: (0.0366, 0.0001), white: whiteD50)
        return bradford(from: whiteD50, to: whiteD65) * d50
    }()

    static let srgb = RGBSpace(id: "sRGB", toXYZ: srgbM, trc: .srgb)
    static let displayP3 = RGBSpace(id: "DisplayP3", toXYZ: p3M, trc: .srgb)
    // Apple AdobeRGB1998.icc 的 TRC 是 curv gamma = 563/256。
    static let adobeRGB = RGBSpace(id: "AdobeRGB", toXYZ: adobeM, trc: .gamma(563.0 / 256.0))
    // Apple ROMM RGB.icc 的 TRC：para type 3，g=1.8, a=1, b=0, c=1/16, d=1/512（与 ROMM 标准的线性段定义不同，见报告）。
    static let prophoto = RGBSpace(id: "ProPhoto", toXYZ: prophotoM,
                                   trc: .parametric3(g: 1.8, a: 1, b: 0, c: 0.0625, d: 0.001953125))
    static let linearSRGB = RGBSpace(id: "linear sRGB", toXYZ: srgbM, trc: .linear)
    static let linearP3 = RGBSpace(id: "linear P3", toXYZ: p3M, trc: .linear)
    static let linear2020 = RGBSpace(id: "linear Rec.2020", toXYZ: rec2020M, trc: .linear)
}

// MARK: - CIELAB / ΔE2000（D65 参考白）

func lab(fromXYZ xyz: V3) -> V3 {
    func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
    let fx = f(xyz.x / whiteD65.x), fy = f(xyz.y / whiteD65.y), fz = f(xyz.z / whiteD65.z)
    return V3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
}

func deltaE2000(_ l1: V3, _ l2: V3) -> Double {
    let (L1, a1, b1) = (l1.x, l1.y, l1.z), (L2, a2, b2) = (l2.x, l2.y, l2.z)
    let c1 = hypot(a1, b1), c2 = hypot(a2, b2), cm = (c1 + c2) / 2
    let g = 0.5 * (1 - sqrt(pow(cm, 7) / (pow(cm, 7) + pow(25, 7))))
    let a1p = (1 + g) * a1, a2p = (1 + g) * a2
    let c1p = hypot(a1p, b1), c2p = hypot(a2p, b2)
    func hue(_ b: Double, _ a: Double) -> Double {
        if a == 0 && b == 0 { return 0 }
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }
    let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
    let dLp = L2 - L1, dCp = c2p - c1p
    var dhp = 0.0
    if c1p * c2p != 0 {
        dhp = h2p - h1p
        if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
    }
    let dHp = 2 * sqrt(c1p * c2p) * sin(dhp * .pi / 360)
    let Lm = (L1 + L2) / 2, cmp = (c1p + c2p) / 2
    var hmp = h1p + h2p
    if c1p * c2p != 0 {
        if abs(h1p - h2p) > 180 { hmp += (h1p + h2p < 360) ? 360 : -360 }
        hmp /= 2
    }
    let t = 1 - 0.17 * cos((hmp - 30) * .pi / 180) + 0.24 * cos(2 * hmp * .pi / 180)
        + 0.32 * cos((3 * hmp + 6) * .pi / 180) - 0.20 * cos((4 * hmp - 63) * .pi / 180)
    let dTheta = 30 * exp(-pow((hmp - 275) / 25, 2))
    let rc = 2 * sqrt(pow(cmp, 7) / (pow(cmp, 7) + pow(25, 7)))
    let sl = 1 + 0.015 * pow(Lm - 50, 2) / sqrt(20 + pow(Lm - 50, 2))
    let sc = 1 + 0.045 * cmp, sh = 1 + 0.015 * cmp * t
    let rt = -sin(2 * dTheta * .pi / 180) * rc
    let x = dLp / sl, y = dCp / sc, z = dHp / sh
    return sqrt(x * x + y * y + z * z + rt * y * z)
}

/// 两个 sRGB 编码值（0…1）之间的 ΔE2000。
func deltaE(srgb a: V3, srgb b: V3) -> Double {
    deltaE2000(lab(fromXYZ: Spaces.srgb.xyz(fromEncoded: a)), lab(fromXYZ: Spaces.srgb.xyz(fromEncoded: b)))
}

// MARK: - PQ (SMPTE ST 2084)

enum PQ {
    static let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
    static let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
    /// 绝对亮度 nits → PQ 编码值
    static func encode(nits: Double) -> Double {
        let y = pow(max(nits, 0) / 10000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }
    static func decode(_ e: Double) -> Double {
        let p = pow(max(e, 0), 1 / m2)
        return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }
}

// MARK: - 统计

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    let idx = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
    return sorted[idx]
}

struct Stats: Codable {
    var count: Int
    var median: Double
    var p95: Double
    var max: Double
    init(_ values: [Double]) {
        let s = values.sorted()
        count = s.count; median = percentile(s, 0.5); p95 = percentile(s, 0.95); max = s.last ?? .nan
    }
}
