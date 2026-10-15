import Foundation
import Darwin

guard CommandLine.arguments.count == 2, geteuid() == 0 else { exit(64) }
let arguments: [String]
switch CommandLine.arguments[1] {
case "on": arguments = ["-a", "disablesleep", "1"]
case "off": arguments = ["-a", "disablesleep", "0"]
case "display-sleep": arguments = ["displaysleepnow"]
default: exit(64)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
process.arguments = arguments
do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("電源設定の適用に失敗しました。\n".utf8))
    exit(70)
}
