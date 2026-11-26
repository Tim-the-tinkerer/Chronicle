import Foundation

enum CLI {
    static let help = """
    Chronicle — a personal time machine

    Each version stores only what changed. History lives in a vault you name.
    The watched folder is only read.

    Usage:
      Chronicle                              Launch the app

    Closing the window leaves Chronicle in the menu bar. It keeps the schedule. Quit from that menu.
      Chronicle --self-test                  Engine checks, then exit
      Chronicle snapshot --source PATH --vault PATH [--label TEXT] [--verify]
      Chronicle list --vault PATH
      Chronicle diff --vault PATH [--snapshot ID]
      Chronicle stats --vault PATH
      Chronicle restore --vault PATH --snapshot ID --dest PATH [--into-source]
      Chronicle restore-file --vault PATH --snapshot ID --path REL --dest FILE [--into-source]
      Chronicle restore-dir --vault PATH --snapshot ID --path REL --dest FOLDER [--into-source]
      Chronicle delete --vault PATH --snapshot ID
      Chronicle gc --vault PATH
      Chronicle verify --vault PATH

    A file with the same size and modification time is not read again.
    --verify reads every file. An automatic version is kept when a file, link, or directory changed. A directory's modification time alone does not count.
    verify reads every version file, then checks every stored chunk and names the versions a missing or damaged chunk affects.
    Skipped names: \(VaultConfig.defaultSkip.joined(separator: ", ")).
    Add Folder can leave out more folders, including a name that starts with a dot, before the first snapshot. That list is stored in the vault.
    """

    static func run(_ args: [String]) -> Never {
        let argv = Argv(args)
        do {
            switch argv.command {
            case "snapshot":
                let source = try argv.require("--source")
                let vault = try argv.require("--vault")
                let snap = try Vault.snapshot(
                    source: URL(fileURLWithPath: source),
                    vault: URL(fileURLWithPath: vault),
                    label: argv.opts["--label"] ?? "",
                    reason: "cli",
                    verify: argv.flags.contains("--verify")
                )
                guard let snap else {
                    print("nothing changed")
                    exit(0)
                }
                let stats = snap.stats
                print("\(snap.id)  \(stats.trackedFiles) files  \(ByteText.string(stats.logicalBytes)) in the folder  \(ByteText.string(stats.newChunkBytes)) new")
            case "list":
                let vault = try URL(fileURLWithPath: argv.require("--vault"))
                let heads = try Vault.listHeads(vault)
                if heads.isEmpty { print("no versions") }
                let shown = Vault.rowGlances(vault: vault, heads: heads)
                for head in heads {
                    let stats = head.stats
                    let label = head.label.isEmpty ? Policy.reason(head.reason) : head.label
                    let newBytes = shown[head.id]?.newBytes ?? stats.newChunkBytes
                    print("\(head.id)  \(head.created)  \(label)  \(ByteText.string(newBytes)) new  \(ByteText.string(stats.logicalBytes)) in the folder")
                }
            case "diff":
                let vault = try URL(fileURLWithPath: argv.require("--vault"))
                let id = try argv.opts["--snapshot"] ?? Vault.listHeads(vault).first?.id
                guard let id else {
                    print("no versions")
                    exit(0)
                }
                let snap = try Vault.load(vault, id)
                let basis = Vault.compared(vault: vault, to: snap)
                let names = Set((try? Vault.config(vault).skipNames) ?? VaultConfig.defaultSkip)
                let warnings = snap.warnings(skipNames: names)
                let rows = Diff.rows(
                    current: snap.files,
                    parent: basis.parent?.files,
                    comparable: basis.comparable,
                    carried: warnings.carried,
                    unread: warnings.unread
                )
                for row in rows where row.change != "same" {
                    print("\(row.change)\t\(row.path)\t\(ByteText.string(row.newBytes))")
                }
                let changed = rows.filter { $0.change != "same" }.count
                print("\(changed) paths differ from the previous version")
            case "stats":
                let vault = try URL(fileURLWithPath: argv.require("--vault"))
                let totals = try Vault.totals(vault)
                print("versions \(totals.snapshotCount)")
                print("stored \(ByteText.string(totals.storedBytes))")
                print("chunks \(ByteText.string(totals.chunkBytes))")
                print("full copies \(ByteText.string(totals.rawCopyBytes))")
                if let saved = totals.savedPercent {
                    print("saved \(saved)% against keeping every version as a full copy")
                }
            case "restore":
                let vault = try URL(fileURLWithPath: argv.require("--vault"))
                let id = try argv.require("--snapshot")
                let dest = try URL(fileURLWithPath: argv.require("--dest"))
                try Vault.restore(
                    vault: vault,
                    snapshot: id,
                    dest: dest,
                    allowInsideSource: argv.flags.contains("--into-source")
                )
                print("restored \(id) → \(dest.path)")
            case "restore-file":
                let vault = try URL(fileURLWithPath: argv.require("--vault"))
                let id = try argv.require("--snapshot")
                let path = try argv.require("--path")
                let dest = try URL(fileURLWithPath: argv.require("--dest"))
                try Vault.restoreFile(
                    vault: vault,
                    snapshot: id,
                    path: path,
                    dest: dest,
                    allowInsideSource: argv.flags.contains("--into-source")
                )
                print("restored \(path) → \(dest.path)")
            case "restore-dir":
                let vault = try URL(fileURLWithPath: argv.require("--vault"))
                let id = try argv.require("--snapshot")
                let path = try argv.require("--path")
                let dest = try URL(fileURLWithPath: argv.require("--dest"))
                try Vault.restoreDirectory(
                    vault: vault,
                    snapshot: id,
                    path: path,
                    dest: dest,
                    allowInsideSource: argv.flags.contains("--into-source")
                )
                print("restored \(path) → \(dest.path)")
            case "delete":
                let vault = try URL(fileURLWithPath: argv.require("--vault"))
                let id = try argv.require("--snapshot")
                let freed = try Vault.delete(vault: vault, id: id)
                print("deleted \(id)  freed \(ByteText.string(freed))")
            case "gc":
                let vault = try URL(fileURLWithPath: argv.require("--vault"))
                let cleaned = try Vault.clean(vault)
                if cleaned.thinning.count > 0 {
                    print(ThinText.sentence(
                        names: ThinText.names(cleaned.thinning),
                        freed: cleaned.freed,
                        complete: cleaned.thinning.complete
                    ))
                } else {
                    print("freed \(ByteText.string(cleaned.freed))")
                }
            case "verify":
                let vault = try URL(fileURLWithPath: argv.require("--vault"))
                let report = try Vault.verifyHistory(vault: vault)
                print(report.summary)
                if !report.detail.isEmpty { print(report.detail) }
                exit(report.problems.isEmpty ? 0 : 1)
            default:
                fputs(help + "\n", stderr)
                exit(argv.command == nil ? 0 : 1)
            }
            exit(0)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct Argv {
    var command: String?
    var flags = Set<String>()
    var opts: [String: String] = [:]

    init(_ args: [String]) {
        let valued: Set<String> = ["--source", "--vault", "--snapshot", "--dest", "--path", "--label"]
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("-psn_") {
                index += 1
                continue
            }
            if valued.contains(arg), index + 1 < args.count {
                opts[arg] = args[index + 1]
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                flags.insert(arg)
                index += 1
                continue
            }
            if command == nil { command = arg }
            index += 1
        }
    }

    func require(_ name: String) throws -> String {
        guard let value = opts[name], !value.isEmpty else {
            throw ChronicleError.fail("\(name) is required")
        }
        return value
    }
}
