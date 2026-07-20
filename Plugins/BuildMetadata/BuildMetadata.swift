import Foundation
import PackagePlugin

// Generates BuildMetadata.generated.swift before every build: the version
// read from the root VERSION file (the single source of truth), the short
// git hash (with a "+" suffix when the tree is dirty), and a build date.
// The About window shows the version and hash, so any installed binary can
// be traced to its exact commit.
@main
struct BuildMetadataPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let output = context.pluginWorkDirectory.appending("BuildMetadata.generated.swift")
        let srcDir = context.package.directory.string
        return [
            .prebuildCommand(
                displayName: "Generate build metadata",
                executable: Path("/bin/sh"),
                arguments: [
                    "-c",
                    """
                    HASH=$(git -C '\(srcDir)' rev-parse --short HEAD 2>/dev/null || echo "unknown")
                    DIRTY=$(git -C '\(srcDir)' diff --quiet HEAD 2>/dev/null || echo "+")
                    DATE=$(date "+%Y-%m-%d %H:%M")
                    VERSION=$(head -1 '\(srcDir)/VERSION' 2>/dev/null | tr -d '[:space:]')
                    [ -n "$VERSION" ] || VERSION="dev"
                    cat > '\(output.string)' <<SWIFT
                    enum BuildMetadata {
                        static let version = "$VERSION"
                        static let gitHash = "${HASH}${DIRTY}"
                        static let buildDate = "$DATE"
                    }
                    SWIFT
                    """,
                ],
                outputFilesDirectory: context.pluginWorkDirectory
            ),
        ]
    }
}
