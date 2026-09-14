import PackagePlugin

@main
struct GenerateVersionPlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let input = context.package.directoryURL
      .appending(path: "Resources/Dopa-Info.plist")
    let output = context.pluginWorkDirectoryURL
      .appending(path: "DopaVersion.generated.swift")

    return [
      .buildCommand(
        displayName: "Generate Dopa version from Dopa-Info.plist",
        executable: try context.tool(named: "VersionGenerator").url,
        arguments: [input.path(), output.path()],
        inputFiles: [input],
        outputFiles: [output])
    ]
  }
}
