import Darwin
import Foundation

/// Reads answers from the terminal during login.
enum Prompt {
    /// Prints `label` and reads one line. Throws if stdin is closed.
    static func line(_ label: String) throws -> String {
        print(label, terminator: "")
        fflush(stdout)
        guard let answer = readLine() else {
            throw CLIError("stdin closed while waiting for input")
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Like `line` but without echoing what is typed.
    static func secret(_ label: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        guard let result = readpassphrase(label, &buffer, buffer.count, RPP_ECHO_OFF) else {
            throw CLIError("could not read from the terminal")
        }
        return String(cString: result)
    }
}
