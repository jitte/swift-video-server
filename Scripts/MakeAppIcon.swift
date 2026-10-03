import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Swift Video Server.app のアイコン原画 (1024x1024 の PNG) を描く。
//
// メニューバーの SF Symbol (play.rectangle.on.rectangle) と同じ
// 「重なった 2 枚の画面と再生マーク」を、macOS のアイコン枠に収める。
// 枠の寸法は Apple のテンプレートに合わせる
// (1024 の中に 824 の角丸四角、周囲 100 は影のための余白)。
//
// 使い方: swift Scripts/MakeAppIcon.swift <出力先.png>

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.png"

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: size * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

func gradient(_ top: CGColor, _ bottom: CGColor) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
}

// MARK: 土台の角丸四角

let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 影。CoreGraphics は下端が原点なので、下へ落とすには y を負にする。
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(platePath)
ctx.setFillColor(rgb(0.2, 0.2, 0.3))
ctx.fillPath()
ctx.restoreGState()

// 夜空のような藍から紫へのグラデーション。
ctx.saveGState()
ctx.addPath(platePath)
ctx.clip()
ctx.drawLinearGradient(gradient(rgb(0.36, 0.42, 0.98), rgb(0.44, 0.16, 0.66)),
                       start: CGPoint(x: 0, y: plate.maxY),
                       end: CGPoint(x: 0, y: plate.minY), options: [])
// 上半分にごく薄い光沢を重ねて平板さを消す。
ctx.drawLinearGradient(gradient(rgb(1, 1, 1, 0.14), rgb(1, 1, 1, 0)),
                       start: CGPoint(x: 0, y: plate.maxY),
                       end: CGPoint(x: 0, y: plate.midY), options: [])
ctx.restoreGState()

// MARK: 重なった 2 枚の画面

// 奥の画面 (右上へずらした半透明の枠)。
let back = CGRect(x: 318, y: 388, width: 470, height: 330)
ctx.addPath(CGPath(roundedRect: back, cornerWidth: 52, cornerHeight: 52, transform: nil))
ctx.setStrokeColor(rgb(1, 1, 1, 0.55))
ctx.setLineWidth(30)
ctx.strokePath()

// 手前の画面 (白で塗る)。影を落として奥と分ける。
let front = CGRect(x: 236, y: 306, width: 470, height: 330)
let frontPath = CGPath(roundedRect: front, cornerWidth: 52, cornerHeight: 52, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: rgb(0.1, 0, 0.3, 0.45))
ctx.addPath(frontPath)
ctx.setFillColor(rgb(1, 1, 1))
ctx.fillPath()
ctx.restoreGState()

// MARK: 再生マーク

// 見た目の重心を画面の中央に合わせるため、三角形の外接矩形より少し右へ寄せる。
let cx = front.midX + 14
let cy = front.midY
let h = 150.0
let w = h * 0.9
let tri = CGMutablePath()
tri.move(to: CGPoint(x: cx - w / 2, y: cy + h / 2))
tri.addLine(to: CGPoint(x: cx + w / 2, y: cy))
tri.addLine(to: CGPoint(x: cx - w / 2, y: cy - h / 2))
tri.closeSubpath()
// 角を丸めるため、同じ色の太い線で縁取る。
ctx.saveGState()
ctx.addPath(tri)
ctx.setLineJoin(.round)
ctx.setLineWidth(28)
ctx.replacePathWithStrokedPath()
ctx.addPath(tri)
ctx.clip()
ctx.drawLinearGradient(gradient(rgb(0.36, 0.42, 0.98), rgb(0.44, 0.16, 0.66)),
                       start: CGPoint(x: 0, y: cy + h / 2 + 14),
                       end: CGPoint(x: 0, y: cy - h / 2 - 14), options: [])
ctx.restoreGState()

// MARK: 書き出し

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: outPath) as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write("書き出しに失敗しました: \(outPath)\n".data(using: .utf8)!)
    exit(1)
}
