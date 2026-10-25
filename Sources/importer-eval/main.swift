import Foundation
import MelaCore

let args = CommandLine.arguments
let package = try EPUBPackage(url: URL(fileURLWithPath: args[1]))
print(package.metadata)
print("check:", BookCheck.run(package))
print("spine:", package.spine.count, "toc:", package.toc.count, "pages:", package.pageList.count, "cover:", package.coverImagePath ?? "-")
let map = BlockMap(package: package)
print("blocks:", map.blocks.count, "with page:", map.blocks.filter { $0.page != nil }.count)
