//
//  Version.swift
//  LiveSubtitles
//
//  Dotted-version comparison, kept free of AppKit so it can be compiled and exercised
//  on its own.
//

import Foundation

enum Version {
    /// True when `candidate` is strictly newer than `current`.
    /// Missing components count as zero, so "1.2" == "1.2.0" and "1.2.1" > "1.2".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(of: candidate)
        let rhs = components(of: current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func components(of version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}
