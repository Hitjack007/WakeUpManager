import Foundation
import WakeUpCore

/// Turns `wakeup request` options into a `WakeRequest`.
public enum RequestBuilder {
    public static func build(from arguments: ParsedArguments, currentDirectory: String) throws -> WakeRequest {
        if let file = arguments.value("file") {
            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: file))
            } catch {
                throw UsageError("Could not read \(file): \(error.localizedDescription)")
            }
            do {
                return try WakeUpJSON.makeDecoder().decode(WakeRequest.self, from: data)
            } catch {
                throw UsageError("\(file) is not a valid request: \(error)")
            }
        }

        let name = try arguments.required("name")
        let start = try arguments.required("at")
        guard let estimate = try arguments.integer("estimate") else { throw UsageError("--estimate is required (minutes).") }

        let clientPath = arguments.value("client-path") ?? currentDirectory
        let clientName = arguments.value("client-name")
            ?? URL(fileURLWithPath: clientPath).deletingPathExtension().lastPathComponent

        let launch = try makeLaunch(from: arguments)
        var reporter: CompletionSpec.Reporter
        switch launch {
        case .exec: reporter = .processExit
        case .app: reporter = .client
        }
        if let text = arguments.value("reported-by") {
            guard let chosen = CompletionSpec.Reporter(rawValue: text) else {
                throw UsageError("--reported-by must be processExit, client or appQuit, not \"\(text)\".")
            }
            reporter = chosen
        }

        var requirements: [Requirement] = []
        for text in arguments.values("requires") {
            guard let requirement = Requirement(rawValue: text) else {
                throw UsageError("--requires must be network, not \"\(text)\".")
            }
            requirements.append(requirement)
        }

        return WakeRequest(
            client: ClientInfo(displayName: clientName, path: clientPath),
            jobId: arguments.value("job-id") ?? slug(name),
            name: name,
            schedule: Schedule(
                start: start,
                timeZone: arguments.value("tz") ?? Schedule.systemTimeZone,
                recurrence: try makeRecurrence(from: arguments)),
            estimatedDurationMinutes: estimate,
            expectedCpuPercent: try arguments.integer("cpu") ?? 10,
            expectedGpuPercent: try arguments.integer("gpu") ?? 0,
            requires: requirements,
            launch: launch,
            completion: CompletionSpec(reportedBy: reporter))
    }

    private static func makeLaunch(from arguments: ParsedArguments) throws -> Launch {
        if let executable = arguments.value("exec") {
            var environment: [String: String] = [:]
            for pair in arguments.values("env") {
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                    throw UsageError("--env needs NAME=value, not \"\(pair)\".")
                }
                environment[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            }
            return .exec(ExecLaunch(
                executable: executable, arguments: arguments.passthrough,
                workingDirectory: arguments.value("cwd"), environment: environment))
        }
        if let bundleId = arguments.value("app") {
            return .app(AppLaunch(bundleId: bundleId, arguments: arguments.passthrough, url: arguments.value("url")))
        }
        throw UsageError("Say how to start the job: --exec PATH [-- arguments] or --app BUNDLE-ID.")
    }

    private static func makeRecurrence(from arguments: ParsedArguments) throws -> Recurrence? {
        guard let text = arguments.value("repeat") else { return nil }
        guard let frequency = Recurrence.Frequency(rawValue: text) else {
            throw UsageError("--repeat must be daily or weekly, not \"\(text)\".")
        }
        var days: [Weekday]?
        if let list = arguments.value("days") {
            days = try list.split(separator: ",").map { item in
                let prefix = item.lowercased().prefix(3)
                guard let day = Weekday.allCases.first(where: { $0.rawValue.hasPrefix(prefix) }), prefix.count == 3 else {
                    throw UsageError("--days has an unknown day: \"\(item)\".")
                }
                return day
            }
        }
        return Recurrence(
            frequency: frequency, interval: try arguments.integer("every") ?? 1,
            daysOfWeek: days, until: arguments.value("until"))
    }

    static func slug(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "job" : collapsed
    }
}
