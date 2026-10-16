import Foundation
import PhotoFrameCLI

// 进程级的事：信号、退出码。命令本身在 PhotoFrameCLI 里。
let environment = CLIEnvironment.standard
let signalSources = environment.interrupts.installSignalHandlers()
let status = await PhotoFrameCLI.run(Array(CommandLine.arguments.dropFirst()), environment: environment)
withExtendedLifetime(signalSources) {}
exit(status)
