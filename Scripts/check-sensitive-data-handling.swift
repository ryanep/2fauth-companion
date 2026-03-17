#!/usr/bin/swift

import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let sourcesRoot = root.appendingPathComponent("Sources")

let sensitiveTokens = [
    "apikey",
    "api_key",
    "authorization",
    "bearer",
    "secret",
    "encryptedsecret",
    "decryptedsecret"
]

let restrictedCalls = [
    "ErrorReporter.report(",
    "logger.error(",
    "logger.warning(",
    "print(",
    "NSLog("
]

func swiftFiles(in directory: URL) -> [URL] {
    guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return []
    }

    var files: [URL] = []
    for case let url as URL in enumerator {
        if url.pathExtension == "swift" {
            files.append(url)
        }
    }
    return files
}

let files = swiftFiles(in: sourcesRoot)
var violations: [String] = []

for file in files {
    guard let content = try? String(contentsOf: file, encoding: .utf8) else {
        continue
    }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    for (index, rawLine) in lines.enumerated() {
        let line = String(rawLine)
        let lower = line.lowercased().replacingOccurrences(of: "_", with: "")

        let hasRestrictedCall = restrictedCalls.contains { line.contains($0) }
        let hasSensitiveToken = sensitiveTokens.contains { lower.contains($0) }
        let hasRawTransportLeak = line.contains("APIError.transport(error.localizedDescription)")

        if (hasRestrictedCall && hasSensitiveToken) || hasRawTransportLeak {
            let relative = file.path.replacingOccurrences(of: root.path + "/", with: "")
            violations.append("\(relative):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}

if !violations.isEmpty {
    print("Sensitive data handling violations:")
    for violation in violations {
        print("- \(violation)")
    }
    exit(1)
}

print("Sensitive data handling checks passed.")
