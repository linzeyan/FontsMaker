import ArgumentParser

@main
struct FontsMakerCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fontsmaker",
        abstract: "Derive new fonts from OFL TrueType fonts.",
        subcommands: [Inspect.self, Build.self, Roundtrip.self, VertMap.self, EmboldenCommand.self, EditableCommand.self]
    )
}
