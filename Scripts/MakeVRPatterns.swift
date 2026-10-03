import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// VR 表示の検証用パターンを作る。
//
// 実写の VR 素材では「上下が反転している」「左右の目が入れ替わっている」
// といった不具合に気づけないため、方向を文字で書いたパターンを用意する。
//
// 座標の約束 (vr.js のシェーダと合わせる):
//   正距円筒  u=0.5 が正面、u=0.25 が左、u=0.75 が右、u=0/1 が背面
//             v=0 が天頂、v=1 が真下
//   魚眼      中心が正面、半径 1 が正面から 90°

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// MARK: 描画の下請け

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                     bytesPerRow: w * 4, space: cs,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}

/// y は「画像の上端からの距離」で指定する。CoreGraphics は下端が原点なので変換する。
func fill(_ ctx: CGContext, x: Double, top: Double, w: Double, h: Double,
          _ color: CGColor, height: Int) {
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: x, y: Double(height) - top - h, width: w, height: h))
}

/// 中央揃えで文字を置く。top は画像の上端からの距離。
func text(_ ctx: CGContext, _ s: String, cx: Double, top: Double, size: Double,
          _ color: CGColor, height: Int, bold: Bool = true) {
    let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString,
                                    size, nil)
    // CoreText の属性キーを直接使う。NSAttributedString.Key の
    // foregroundColor は AppKit 側の定義で、CoreText だけでは参照できない。
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
    ]
    let attributed = CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    let x = cx - bounds.width / 2
    let y = Double(height) - top - size
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(line, ctx)
}

func writePNG(_ ctx: CGContext, _ name: String) {
    guard let image = ctx.makeImage() else { return }
    let url = outDir.appendingPathComponent(name)
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("  \(name)")
}

// 方角ごとの色。隣り合う向きを取り違えないよう、はっきり違う色にする。
let cFront = rgb(0.10, 0.55, 0.55)
let cRight = rgb(0.85, 0.45, 0.10)
let cBack  = rgb(0.45, 0.20, 0.60)
let cLeft  = rgb(0.20, 0.55, 0.25)
let cGrid  = rgb(1, 1, 1, 0.28)
let cLine  = rgb(1, 1, 1, 0.85)
let white  = rgb(1, 1, 1)

/// 緯線・経線を引く。
func grid(_ ctx: CGContext, w: Int, h: Int, stepX: Double, stepY: Double) {
    ctx.setStrokeColor(cGrid)
    ctx.setLineWidth(2)
    var x = 0.0
    while x <= Double(w) {
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: Double(h)))
        x += stepX
    }
    var y = 0.0
    while y <= Double(h) {
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: Double(w), y: y))
        y += stepY
    }
    ctx.strokePath()
}

/// 水平線 (地平線) を強調する。
func horizon(_ ctx: CGContext, w: Int, h: Int) {
    ctx.setStrokeColor(cLine)
    ctx.setLineWidth(4)
    ctx.move(to: CGPoint(x: 0, y: Double(h) / 2))
    ctx.addLine(to: CGPoint(x: Double(w), y: Double(h) / 2))
    ctx.strokePath()
}

// MARK: 正距円筒 360°

func equirect360(eye: String?) -> CGContext {
    let w = 2048, h = 1024
    let ctx = makeContext(w, h)
    let W = Double(w), H = Double(h)

    // 背面が左右の端に分かれる。u=0.5 が正面。
    fill(ctx, x: 0,        top: 0, w: W * 0.125, h: H, cBack,  height: h)
    fill(ctx, x: W * 0.125, top: 0, w: W * 0.25,  h: H, cLeft,  height: h)
    fill(ctx, x: W * 0.375, top: 0, w: W * 0.25,  h: H, cFront, height: h)
    fill(ctx, x: W * 0.625, top: 0, w: W * 0.25,  h: H, cRight, height: h)
    fill(ctx, x: W * 0.875, top: 0, w: W * 0.125, h: H, cBack,  height: h)

    grid(ctx, w: w, h: h, stepX: W / 24, stepY: H / 12)
    horizon(ctx, w: w, h: h)

    // 地平線上に方角を置く。
    text(ctx, "FRONT", cx: W * 0.5,  top: H * 0.5 - 64, size: 96, white, height: h)
    text(ctx, "RIGHT", cx: W * 0.75, top: H * 0.5 - 64, size: 96, white, height: h)
    text(ctx, "LEFT",  cx: W * 0.25, top: H * 0.5 - 64, size: 96, white, height: h)
    text(ctx, "BACK",  cx: W * 0.0,  top: H * 0.5 - 64, size: 96, white, height: h)
    text(ctx, "BACK",  cx: W,        top: H * 0.5 - 64, size: 96, white, height: h)

    // 天頂と真下。極は引き伸ばされるので少し内側に置く。
    text(ctx, "UP",   cx: W * 0.5, top: H * 0.10, size: 84, white, height: h)
    text(ctx, "DOWN", cx: W * 0.5, top: H * 0.86, size: 84, white, height: h)

    if let eye {
        text(ctx, eye, cx: W * 0.5, top: H * 0.30, size: 120, white, height: h)
    }
    return ctx
}

// MARK: 正距円筒 180°

func equirect180(eye: String?) -> CGContext {
    let s = 2048
    let ctx = makeContext(s, s)
    let S = Double(s)

    // 横幅いっぱいで 180°。中央が正面。
    fill(ctx, x: 0,       top: 0, w: S * 0.25, h: S, cLeft,  height: s)
    fill(ctx, x: S * 0.25, top: 0, w: S * 0.5, h: S, cFront, height: s)
    fill(ctx, x: S * 0.75, top: 0, w: S * 0.25, h: S, cRight, height: s)

    grid(ctx, w: s, h: s, stepX: S / 12, stepY: S / 12)
    horizon(ctx, w: s, h: s)

    text(ctx, "FRONT", cx: S * 0.5,  top: S * 0.5 - 64, size: 110, white, height: s)
    text(ctx, "LEFT",  cx: S * 0.12, top: S * 0.5 - 64, size: 84,  white, height: s)
    text(ctx, "RIGHT", cx: S * 0.88, top: S * 0.5 - 64, size: 84,  white, height: s)
    text(ctx, "UP",    cx: S * 0.5,  top: S * 0.08, size: 84, white, height: s)
    text(ctx, "DOWN",  cx: S * 0.5,  top: S * 0.88, size: 84, white, height: s)

    if let eye {
        text(ctx, eye, cx: S * 0.5, top: S * 0.30, size: 140, white, height: s)
    }
    return ctx
}

// MARK: 魚眼 180°

func fisheye180(eye: String?) -> CGContext {
    let s = 2048
    let ctx = makeContext(s, s)
    let S = Double(s)

    // 円の外は黒。円内を 4 象限に塗り分ける。
    fill(ctx, x: 0, top: 0, w: S, h: S, rgb(0, 0, 0), height: s)

    let cx = S / 2, cy = S / 2, r = S / 2
    // 上半分と下半分で色を変え、上下の取り違えを見つけられるようにする。
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 0, y: 0, width: S, height: S))
    ctx.clip()
    fill(ctx, x: 0, top: 0,     w: S, h: S / 2, cFront, height: s)
    fill(ctx, x: 0, top: S / 2, w: S, h: S / 2, cBack,  height: s)
    fill(ctx, x: 0,     top: 0, w: S / 2, h: S, cLeft.copy(alpha: 0.45)!,  height: s)
    fill(ctx, x: S / 2, top: 0, w: S / 2, h: S, cRight.copy(alpha: 0.45)!, height: s)

    // 同心円で天頂からの角度を示す (30°/60°/90°)。
    ctx.setStrokeColor(cGrid)
    ctx.setLineWidth(3)
    for f in [1.0 / 3.0, 2.0 / 3.0] {
        ctx.addEllipse(in: CGRect(x: cx - r * f, y: cy - r * f, width: r * f * 2, height: r * f * 2))
    }
    ctx.strokePath()
    ctx.restoreGState()

    // 円周を描く。
    ctx.setStrokeColor(cLine)
    ctx.setLineWidth(5)
    ctx.addEllipse(in: CGRect(x: 2, y: 2, width: S - 4, height: S - 4))
    ctx.strokePath()

    text(ctx, "FRONT", cx: cx, top: cy - 48, size: 96, white, height: s)
    text(ctx, "UP",    cx: cx, top: S * 0.07, size: 84, white, height: s)
    text(ctx, "DOWN",  cx: cx, top: S * 0.86, size: 84, white, height: s)
    text(ctx, "LEFT",  cx: S * 0.12, top: cy - 40, size: 84, white, height: s)
    text(ctx, "RIGHT", cx: S * 0.88, top: cy - 40, size: 84, white, height: s)

    if let eye {
        text(ctx, eye, cx: cx, top: S * 0.30, size: 130, white, height: s)
    }
    return ctx
}

// MARK: 立体視の合成

/// 左右に並べる。左半分が左目 (vr.js は左半分を使う)。
func sideBySide(_ left: CGContext, _ right: CGContext) -> CGContext {
    let w = left.width * 2, h = left.height
    let ctx = makeContext(w, h)
    ctx.draw(left.makeImage()!, in: CGRect(x: 0, y: 0, width: left.width, height: h))
    ctx.draw(right.makeImage()!, in: CGRect(x: left.width, y: 0, width: right.width, height: h))
    return ctx
}

/// 上下に並べる。上半分が左目。
func topBottom(_ left: CGContext, _ right: CGContext) -> CGContext {
    let w = left.width, h = left.height * 2
    let ctx = makeContext(w, h)
    // CoreGraphics は下が原点なので、上半分は y が大きい側。
    ctx.draw(left.makeImage()!, in: CGRect(x: 0, y: left.height, width: w, height: left.height))
    ctx.draw(right.makeImage()!, in: CGRect(x: 0, y: 0, width: w, height: right.height))
    return ctx
}

// MARK: 出力

print("パターンを生成します:")
writePNG(equirect360(eye: nil), "vr-360-mono.png")
writePNG(sideBySide(equirect360(eye: "L"), equirect360(eye: "R")), "vr-360-sbs.png")
writePNG(topBottom(equirect360(eye: "L"), equirect360(eye: "R")), "vr-360-tb.png")
writePNG(equirect180(eye: nil), "vr-180-mono.png")
writePNG(sideBySide(equirect180(eye: "L"), equirect180(eye: "R")), "vr-180-sbs.png")
writePNG(fisheye180(eye: nil), "vr-fisheye180-mono.png")
writePNG(sideBySide(fisheye180(eye: "L"), fisheye180(eye: "R")), "vr-fisheye180-sbs.png")
print("完了")
