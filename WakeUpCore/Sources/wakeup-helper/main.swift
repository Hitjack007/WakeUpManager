// The root helper. launchd starts it (as a LaunchDaemon inside the app) the first time something asks
// for its Mach service. It books and cancels wakes for the scheduler, and only for programs signed by
// the same team as the app.
//
//   wakeup-helper --team TEAMID [--allow-id IDENTIFIER]...

import Foundation
import WakeUpCore
import WakeUpSystem

var team: String?
var identifiers = [WakeHelperConstants.appIdentifier, WakeHelperConstants.agentIdentifier]

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--team": team = arguments.popFirst()
    case "--allow-id": if let id = arguments.popFirst() { identifiers.append(id) }
    default:
        FileHandle.standardError.write(Data("wakeup-helper: unknown option \(argument)\n".utf8))
        exit(64)
    }
}

// Never start without a signing requirement: a root helper that accepts anyone would let any program
// on the Mac book wakes.
guard let team, !team.isEmpty else {
    FileHandle.standardError.write(Data("wakeup-helper: --team is required.\n".utf8))
    exit(64)
}

let delegate = WakeHelperListenerDelegate(
    service: WakeHelperService(),
    requirement: WakeHelperConstants.requirement(identifiers: identifiers, teamIdentifier: team))
let listener = NSXPCListener(machServiceName: WakeHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
