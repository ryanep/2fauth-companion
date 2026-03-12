#!/usr/bin/swift

import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let sourcesRoot = root.appendingPathComponent("Sources")
let stringsFile = root.appendingPathComponent("Resources/en.lproj/Localizable.strings")

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

func matchKeys(pattern: String, in input: String) -> Set<String> {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return []
    }

    let range = NSRange(input.startIndex..<input.endIndex, in: input)
    var keys: Set<String> = []
    for match in regex.matches(in: input, options: [], range: range) {
        guard match.numberOfRanges > 1,
              let keyRange = Range(match.range(at: 1), in: input) else {
            continue
        }
        keys.insert(String(input[keyRange]))
    }
    return keys
}

func referencedKeys(in source: String, knownPrefixes: Set<String>) -> Set<String> {
    let patterns = [
        #"String\(localized:\s*"([^"]+)""#,
        #"Text\(\s*"([^"]+)"\s*\)"#,
        #"Label\(\s*"([^"]+)"\s*[,\)]"#,
        #"Section\(\s*"([^"]+)"\s*\)"#,
        #"Button\(\s*"([^"]+)"\s*[,\)]"#,
        #"TextField\(\s*"([^"]+)"\s*[,\)]"#,
        #"SecureField\(\s*"([^"]+)"\s*[,\)]"#,
        #"Picker\(\s*"([^"]+)"\s*[,\)]"#,
        #"LabeledContent\(\s*"([^"]+)"\s*[,\)]"#,
        #"ContentUnavailableView\(\s*"([^"]+)"\s*[,\)]"#,
        #"\.navigationTitle\(\s*"([^"]+)"\s*\)"#,
        #"\.alert\(\s*"([^"]+)"\s*[,\)]"#
    ]

    var allLiterals: Set<String> = []
    for pattern in patterns {
        allLiterals.formUnion(matchKeys(pattern: pattern, in: source))
    }

    var keys: Set<String> = []
    for literal in allLiterals {
        guard literal.contains("."),
              let prefix = literal.split(separator: ".").first.map(String.init),
              knownPrefixes.contains(prefix) else {
            continue
        }
        keys.insert(literal)
    }
    return keys
}

func definedKeys(in stringsContent: String) -> Set<String> {
    let pattern = #"^\s*"([^"]+)"\s*=\s*".*"\s*;\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
        return []
    }

    let range = NSRange(stringsContent.startIndex..<stringsContent.endIndex, in: stringsContent)
    var keys: Set<String> = []
    for match in regex.matches(in: stringsContent, options: [], range: range) {
        guard match.numberOfRanges > 1,
              let keyRange = Range(match.range(at: 1), in: stringsContent) else {
            continue
        }
        keys.insert(String(stringsContent[keyRange]))
    }
    return keys
}

let files = swiftFiles(in: sourcesRoot)
var referenced: Set<String> = []

guard let stringsContent = try? String(contentsOf: stringsFile, encoding: .utf8) else {
    fputs("error: could not read \(stringsFile.path)\n", stderr)
    exit(1)
}

let defined = definedKeys(in: stringsContent)
let keyPrefixes = Set(defined.compactMap { $0.split(separator: ".").first.map(String.init) })

for file in files {
    guard let source = try? String(contentsOf: file, encoding: .utf8) else {
        continue
    }
    referenced.formUnion(referencedKeys(in: source, knownPrefixes: keyPrefixes))
}

let missing = referenced.subtracting(defined).sorted()
let unused = defined.subtracting(referenced).sorted()

if !missing.isEmpty {
    print("Missing localization keys:")
    for key in missing {
        print("- \(key)")
    }
}

if !unused.isEmpty {
    print("Unused localization keys:")
    for key in unused {
        print("- \(key)")
    }
}

if !missing.isEmpty || !unused.isEmpty {
    exit(1)
}

print("Localization keys are consistent.")
