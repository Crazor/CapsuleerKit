import ArgumentParser

@main
struct Capsuleer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "CapsuleerKit dev CLI.")
    func run() async throws {}
}
