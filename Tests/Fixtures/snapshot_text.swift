import Foundation
import Vision

var snapshots: [String: String] = [:]
for path in CommandLine.arguments.dropFirst() {
    let request = VNRecognizeTextRequest()
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path))
    try handler.perform([request])
    snapshots[path] = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}
let json = try JSONEncoder().encode(snapshots)
FileHandle.standardOutput.write(json)
