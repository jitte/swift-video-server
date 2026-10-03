// FLV の「直前のタグの長さ」欄を壊す。make-broken-samples.sh から呼ぶ。
//
// 使い方: swift Scripts/BreakFLV.swift <入力.flv> <出力.flv> first|all
//
// 実際に見つかった壊れ方に合わせ、値を 16 ビット上にずらす
// (0x0EFA が 0x0EFA0000 になる)。first は先頭のタグだけ、all は全タグ。
import Foundation

let args = CommandLine.arguments
guard args.count == 4, ["first", "all"].contains(args[3]) else {
    FileHandle.standardError.write("使い方: BreakFLV.swift <入力> <出力> first|all\n".data(using: .utf8)!)
    exit(1)
}
var d = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))
let onlyFirst = args[3] == "first"

func readUInt(_ at: Int, _ count: Int) -> UInt32 {
    d[at..<at + count].reduce(0) { $0 << 8 | UInt32($1) }
}

// ヘッダ 9 バイトと、最初の「直前のタグの長さ」(常に 0) 4 バイトの後からタグが並ぶ。
// タグは 11 バイトのヘッダ (先頭 1 バイトが種類、続く 3 バイトが本体の長さ) と本体。
var p = 13
var count = 0
while p + 11 <= d.count {
    let size = Int(readUInt(p + 1, 3))
    let q = p + 11 + size
    guard q + 4 <= d.count else { break }
    let broken = readUInt(q, 4) << 16
    for i in 0..<4 { d[q + i] = UInt8(truncatingIfNeeded: broken >> (24 - 8 * i)) }
    count += 1
    if onlyFirst { break }
    p = q + 4
}
try Data(d).write(to: URL(fileURLWithPath: args[2]))
print("  \(URL(fileURLWithPath: args[2]).lastPathComponent): \(count) 箇所を壊しました")
