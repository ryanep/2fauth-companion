#!/usr/bin/swift

import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let sourcesRoot = root.appendingPathComponent("Sources")

func swiftFiles(in directory: URL) -> [URL] {
    guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return []
    }

    var files: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "swift" {
        files.append(url)
    }
    return files
}

func isInsideDebugBlock(lines: [String], targetLine: Int) -> Bool {
    var nesting = 0
    for index in stride(from: targetLine - 1, through: 0, by: -1) {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#endif") {
            nesting += 1
            continue
        }

        if line.hasPrefix("#if") || line.hasPrefix("#elseif") || line.hasPrefix("#else") {
            if nesting > 0 {
                if line.hasPrefix("#if") {
                    nesting -= 1
                }
                continue
            }

            if line == "#if DEBUG" {
                var localNesting = 0
                if targetLine > 0 {
                    for probe in (index + 1)..<targetLine {
                        let probeLine = lines[probe].trimmingCharacters(in: .whitespaces)
                        if probeLine.hasPrefix("#if") {
                            localNesting += 1
                        } else if probeLine.hasPrefix("#endif") {
                            localNesting = max(0, localNesting - 1)
                        } else if localNesting == 0 && (probeLine.hasPrefix("#else") || probeLine.hasPrefix("#elseif")) {
                            return false
                        }
                    }
                }
                return true
            }

            if line.hasPrefix("#else") || line.hasPrefix("#elseif") {
                return false
            }
        }
    }

    return false
}

let files = swiftFiles(in: sourcesRoot)
var violations: [String] = []

for file in files {
    guard let content = try? String(contentsOf: file, encoding: .utf8) else {
        continue
    }

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (lineNumber, line) in lines.enumerated() where line.contains("UI_TEST_") {
        if !isInsideDebugBlock(lines: lines, targetLine: lineNumber) {
            let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
            violations.append("\(relativePath):\(lineNumber + 1): \(line.trimmingCharacters(in: .whitespaces))")
        }
    }
}

if !violations.isEmpty {
    print("Release guardrail failed: UI_TEST_ hooks are reachable outside #if DEBUG blocks")
    for violation in violations {
        print("- \(violation)")
    }
    exit(1)
}

print("Release guardrail passed: UI_TEST_ hooks are debug-only.")
