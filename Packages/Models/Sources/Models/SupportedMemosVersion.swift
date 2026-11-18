//
//  SupportedMemosVersion.swift
//
//
//  Created by Codex on 2026/2/11.
//

import Foundation

public enum SupportedMemosVersion {
    public static let minimumV0 = "0.21.0"
    public static let minimumV1 = "0.27.0"
    public static let maximumV1 = "0.31.0"
    public static let minimumCalendar = "26.10.0"
    public static let maximumCalendar = "26.11.1"

    public static func localizedSupportedVersionsMessage() -> String {
        let format = NSLocalizedString("compat.supported-versions", comment: "Supported Memos versions for Moe Memos")
        return String.localizedStringWithFormat(format, minimumV0, minimumV1, maximumV1, minimumCalendar, maximumCalendar)
    }
}

public struct SemanticVersion: Sendable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(_ raw: String) {
        var components = [Int]()
        var current = ""

        for char in raw {
            if char.isNumber {
                current.append(char)
                continue
            }
            if !current.isEmpty {
                if let value = Int(current) {
                    components.append(value)
                    if components.count == 3 {
                        break
                    }
                }
                current = ""
            }
        }

        if components.count < 3, !current.isEmpty, let value = Int(current) {
            components.append(value)
        }

        guard components.count >= 2 else {
            return nil
        }

        let major = components[0]
        let minor = components[1]
        let patch = components.count >= 3 ? components[2] : 0
        self.init(major: major, minor: minor, patch: patch)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        return lhs.patch < rhs.patch
    }
}
