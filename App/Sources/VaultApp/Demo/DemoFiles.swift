import Foundation
import VaultFiles

/// The demo folders' files: the design's names at their sizes (a folder holds that many small files).
enum DemoFiles {
  struct File {
    var path: String
    var size: Int
    /// A folder with this many files in it.
    var items = 0
  }

  static let design: [File] = [
    File(path: "Brand", size: 0, items: 14), File(path: "Fonts", size: 0, items: 9), File(path: "Screens", size: 0, items: 48),
    File(path: "Moodboard.fig", size: 18_200_000), File(path: "Colors.json", size: 4_000),
    File(path: "App Icon 1024.png", size: 1_100_000), File(path: "App Icon Dark 1024.png", size: 1_000_000),
    File(path: "Onboarding copy.md", size: 12_000), File(path: "Brand guide.pdf", size: 9_800_000),
    File(path: "Hero Lisbon.heic", size: 4_200_000),
  ]

  static let taxes: [File] = [
    File(path: "Receipts", size: 0, items: 64), File(path: "Statements", size: 0, items: 12),
    File(path: "2025 Return.pdf", size: 2_400_000), File(path: "W-2 Atlas Inc.pdf", size: 184_000),
    File(path: "Estimated payments.numbers", size: 412_000), File(path: "Mileage log.csv", size: 36_000),
    File(path: "Donations.pdf", size: 1_100_000), File(path: "Home office.heic", size: 3_800_000),
    File(path: "Accountant notes.md", size: 8_000), File(path: "1099-INT Credit Union.pdf", size: 96_000),
    File(path: "Property tax 2026.pdf", size: 220_000),
  ]

  static let photos: [File] = [
    File(path: "Lisbon", size: 0, items: 10), File(path: "Sintra", size: 0, items: 12),
    File(path: "IMG_2201.heic", size: 2_800_000), File(path: "IMG_2214.heic", size: 3_100_000),
    File(path: "IMG_2230.heic", size: 2_600_000), File(path: "Album.json", size: 3_000),
    File(path: "Selects.txt", size: 46),
  ]

  static let contracts: [File] = [
    File(path: "Atlas MSA 2026.pdf", size: 640_000), File(path: "Studio lease.pdf", size: 1_200_000),
    File(path: "NDA Figma.pdf", size: 180_000),
  ]

  /// Bytes for a file: its name repeated, so the demo needs no randomness and stays quick.
  private static func content(_ file: File) -> Data {
    if file.path == "Selects.txt" { return Data("IMG_2201 cover\nIMG_2214 tram, cropped\nIMG_2230 night\n".utf8) }
    if file.path.hasSuffix(".md") { return Data("# \(file.path)\n\nNotes for the accountant.\n".utf8) }
    if file.path == "Brand guide.pdf" { return brandGuide(size: file.size) }
    let seed = Data((file.path + "\n").utf8)
    var data = Data(capacity: file.size)
    while data.count < file.size { data.append(seed) }
    return data.prefix(file.size)
  }

  /// A one-page PDF (a title, a hero, text lines and four swatches) written by hand, padded to `size` with comments.
  static func brandGuide(size: Int) -> Data {
    var page = "BT /F1 22 Tf 48 730 Td (Atlas brand guide) Tj ET\nBT /F1 11 Tf 48 708 Td (Version 3 \\267 October 2026) Tj ET\n"
    page += "0.45 0.75 0.93 rg 48 520 516 168 re f\n0.86 0.87 0.9 rg\n"
    for (index, width) in [516, 460, 490, 300, 500, 410, 210].enumerated() { page += "48 \(490 - index * 18) \(width) 6 re f\n" }
    for (index, color) in ["0.35 0.68 0.78", "1 0.6 0.04", "0.37 0.36 0.9", "0.56 0.56 0.58"].enumerated() {
      page += "\(color) rg \(48 + index * 132) 270 120 64 re f\n"
    }
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
      "<< /Length \(page.utf8.count) >>\nstream\n\(page)endstream",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
    ]
    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
      offsets.append(pdf.utf8.count)
      pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let line = "%" + String(repeating: "-", count: 78) + "\n"
    pdf += String(repeating: line, count: max(0, (size - pdf.utf8.count - 400) / line.utf8.count))
    let xref = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
    return Data(pdf.utf8)
  }

  static func write(_ file: File, in folder: EncryptedFolder) throws {
    if file.items > 0 {
      try folder.createDirectory(file.path)
      for index in 1...file.items {
        try folder.write(Data("\(file.path) \(index)".utf8), to: "\(file.path)/\(file.path) \(index).pdf")
      }
    } else {
      try folder.write(content(file), to: file.path)
    }
  }

  static func writePlain(_ file: File, in url: URL) throws {
    let target = url.appendingPathComponent(file.path)
    if file.items > 0 {
      try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      for index in 1...file.items {
        try Data("\(file.path) \(index)".utf8).write(to: target.appendingPathComponent("IMG_\(2300 + index).heic"))
      }
    } else {
      try content(file).write(to: target)
    }
  }
}
