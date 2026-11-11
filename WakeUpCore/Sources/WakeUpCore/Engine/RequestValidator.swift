import Foundation

enum RequestValidator {
    /// A human-readable problem with the request, or `nil` if it is acceptable.
    static func problem(with request: WakeRequest) -> String? {
        if request.schemaVersion != WakeRequest.currentSchemaVersion {
            return "Unsupported schema version \(request.schemaVersion)."
        }
        if request.jobId.isEmpty { return "The job id is empty." }
        if request.name.isEmpty { return "The job name is empty." }
        if request.client.displayName.isEmpty { return "The client display name is empty." }
        if !request.client.path.hasPrefix("/") { return "The client path must be absolute." }
        if !(1...(7 * 24 * 60)).contains(request.estimatedDurationMinutes) {
            return "The estimate must be between 1 minute and 7 days."
        }
        if !(0...100).contains(request.expectedCpuPercent) || !(0...100).contains(request.expectedGpuPercent) {
            return "Expected CPU and GPU must be between 0 and 100."
        }
        switch request.launch {
        case .exec(let exec):
            if !exec.executable.hasPrefix("/") { return "The executable must be an absolute path." }
            if let directory = exec.workingDirectory, !directory.hasPrefix("/") {
                return "The working directory must be an absolute path."
            }
            if request.completion.reportedBy == .appQuit { return "appQuit completion only applies to app launches." }
        case .app(let app):
            if app.bundleId.isEmpty { return "The bundle id is empty." }
            if request.completion.reportedBy == .processExit {
                return "processExit completion only applies to exec launches."
            }
        }
        return nil
    }
}
