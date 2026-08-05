import Foundation
import Darwin
import PCRTCore

let exitCode: Int32
do {
    let arguments = try HelperArguments.parse()
    let runtime = try HelperRuntime(arguments: arguments)
    try runtime.run()
    exitCode = 0
} catch HelperError.cancelled {
    exitCode = 2
} catch {
    fputs("PCRTScannerHelper error: \(error.localizedDescription)\n", stderr)
    exitCode = 1
}
exit(exitCode)
