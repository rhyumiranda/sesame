import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Injects approved secrets into a child process's environment and execs it.
///
/// SECURITY MODEL: injection is via the environment (`execvp` after `setenv`),
/// never a temp `.env` file — so no plaintext secret ever touches disk. The
/// values are passed through `setenv`, NOT argv, so they can't leak via `ps`.
///
/// Threat model (Free MVP, stated in README): on macOS a child's environment is
/// still visible to same-user tooling (`ps -E`, a debugger). Accepted for the
/// $0 tier; Milestone 2 switches to a FIFO/named-pipe (the `op run` model) to
/// remove even that visibility.
enum Runner {
    /// Replaces the current process image with `command`, having merged
    /// `secrets` into the environment. On success this never returns (the child
    /// becomes the process, inheriting stdio + exit code = passthrough). Only
    /// returns — throwing — if the exec itself fails.
    static func exec(command: [String], secrets: [String: String]) throws -> Never {
        guard let program = command.first else {
            throw SesameError.io("no command to run")
        }

        // Inject via the current environ so execvp inherits it and still
        // searches PATH. This process immediately exec's, so the brief presence
        // of the value in our own environ is not observable to the child's peers
        // any differently than after exec.
        for (key, value) in secrets {
            setenv(key, value, 1)
        }

        // Build a NULL-terminated argv.
        var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) }
        argv.append(nil)

        execvp(program, &argv)

        // execvp only returns on failure.
        let reason = String(cString: strerror(errno))
        for pointer in argv where pointer != nil {
            free(pointer)
        }
        throw SesameError.io("could not exec '\(program)': \(reason)")
    }

    /// Spawn `command` with `secrets` merged into its environment, wait, and
    /// return its exit code. Used by `run --json`, where we must report the
    /// child's `exitCode` (and so cannot replace our own process image).
    /// Injection is still env-only (no disk, no argv) — `/usr/bin/env` searches
    /// PATH so bare command names work.
    static func spawnWait(command: [String], secrets: [String: String]) throws -> Int32 {
        guard !command.isEmpty else {
            throw SesameError.io("no command to run")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in secrets {
            environment[key] = value
        }
        process.environment = environment
        do {
            try process.run()
        } catch {
            throw SesameError.io("could not run '\(command[0])': \(error.localizedDescription)")
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
