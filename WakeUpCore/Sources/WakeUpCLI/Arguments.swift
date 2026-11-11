import Foundation

public struct UsageError: Error, LocalizedError, Equatable {
    public var message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// A very small command line parser: `command [subcommand] --option value --flag -- passthrough`.
///
/// Options take the next argument as their value (or `--option=value`) and may repeat. A few names are
/// plain flags. Everything after a bare `--` is kept as is, for the arguments of the job being scheduled.
public struct ParsedArguments: Equatable {
    public var positionals: [String] = []
    public var options: [String: [String]] = [:]
    public var flags: Set<String> = []
    public var passthrough: [String] = []

    public static let defaultFlags: Set<String> = ["help", "json"]

    public init() {}

    public static func parse(_ arguments: [String], flags knownFlags: Set<String> = defaultFlags) throws -> ParsedArguments {
        var result = ParsedArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                result.passthrough = Array(arguments[(index + 1)...])
                break
            }
            if argument.hasPrefix("--") {
                var name = String(argument.dropFirst(2))
                var inlineValue: String?
                if let equals = name.firstIndex(of: "=") {
                    inlineValue = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if knownFlags.contains(name) {
                    result.flags.insert(name)
                } else if let inlineValue {
                    result.options[name, default: []].append(inlineValue)
                } else {
                    index += 1
                    guard index < arguments.count else { throw UsageError("--\(name) needs a value.") }
                    result.options[name, default: []].append(arguments[index])
                }
            } else {
                result.positionals.append(argument)
            }
            index += 1
        }
        return result
    }

    public func value(_ name: String) -> String? { options[name]?.last }

    public func values(_ name: String) -> [String] { options[name] ?? [] }

    public func required(_ name: String) throws -> String {
        guard let value = value(name) else { throw UsageError("--\(name) is required.") }
        return value
    }

    public func integer(_ name: String) throws -> Int? {
        guard let text = value(name) else { return nil }
        guard let number = Int(text) else { throw UsageError("--\(name) must be a whole number, not \"\(text)\".") }
        return number
    }
}
