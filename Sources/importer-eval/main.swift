import Foundation
import MelaCore

let args = CommandLine.arguments
let package = try EPUBPackage(url: URL(fileURLWithPath: args[1]))
print(package.metadata.title)
print("check:", BookCheck.run(package))
let map = BlockMap(package: package)
let result = RecipeFinder.find(package: package, map: map)
print("profile:", result.profile as Any)
print("recipes:", result.recipes.count, "low:", result.recipes.filter { $0.confidence == .low }.count, "sections:", result.sections.count)
for r in result.recipes { print("  [\(r.chapter ?? "-")] \(r.title) p.\(r.page ?? "-") ing:\(r.ingredientLines) steps:\(r.stepLines) photos:\(r.photos.count) uses:\(r.uses.count) \(r.confidence == .low ? "LOW" : "")") }
