import Foundation
import WakeUpCLI
import WakeUpCore

let environment = ProcessInfo.processInfo.environment
let cli = CLI(
    client: SocketClient(path: environment["WAKEUP_SOCKET"] ?? WakeUpPaths.socketPath),
    environment: environment,
    currentDirectory: FileManager.default.currentDirectoryPath,
    write: { FileHandle.standardOutput.write(Data($0.utf8)) },
    writeError: { FileHandle.standardError.write(Data($0.utf8)) })

exit(cli.run(Array(CommandLine.arguments.dropFirst())))
