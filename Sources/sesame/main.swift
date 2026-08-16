import ArgumentParser

struct Sesame: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sesame",
        abstract: "Open sesame — a fingerprint-gated vault for your agent's env secrets.",
        version: "sesame 0.1.0 (Free MVP)"
    )

    func run() throws {
        print("sesame: scaffold — commands land in a later commit")
    }
}

Sesame.main()
