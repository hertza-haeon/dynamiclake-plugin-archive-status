// Copyright (c) 2026 Hertza Haeon
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ArchiveStatusKit
import Foundation

/// archive-status: what DynamicLake starts for the Archive Status plugin.
///
/// Started by DynamicLake, it follows the extractions made with MacPacker
/// and Archive Utility, shows them in the notch and writes what it sees to
/// the plugin's log. Run by hand it only watches and writes the log.
///
///     archive-status                 as above
///     archive-status --echo          each line of the log printed too
///     archive-status --log <file>    write the log there instead
///     archive-status --trace <file>  also write there, to the millisecond,
///                                    what each unarchiver has open whenever
///                                    that changes (for checks on a real Mac)
///     archive-status --index <archive>…
///                                    print what the index of each archive
///                                    says, and stop
///     archive-status --pictures <folder>
///                                    write the plugin's own pictures there
///                                    as PNG files, and stop
///     archive-status --messages      print the messages of one card's life,
///                                    as they go to DynamicLake, and stop
///     archive-status --stand-in-icon <file>
///                                    write a stand-in for the plugin's icon
@main
struct ArchiveStatus {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.first == "--index" {
            arguments.removeFirst()
            for path in arguments {
                print(IndexReport.text(for: path))
            }
            return
        }
        if arguments.first == "--pictures", arguments.count == 2 {
            for line in Preview.writePictures(to: arguments[1]) {
                print(line)
            }
            return
        }

        if arguments.first == "--stand-in-icon", arguments.count == 2 {
            print(Preview.writeStandInIcon(to: arguments[1]) ? "written" : "couldn't be written")
            return
        }
        if arguments == ["--messages"] {
            for line in Preview.sampleMessages() {
                print(line)
            }
            return
        }

        var echo = false
        var logPath: String?
        var tracePath: String?
        while let argument = arguments.first {
            arguments.removeFirst()
            switch argument {
            case "--echo":
                echo = true
            case "--log" where arguments.isEmpty == false:
                logPath = arguments.removeFirst()
            case "--trace" where arguments.isEmpty == false:
                tracePath = arguments.removeFirst()
            default:
                print("archive-status: unknown argument \(argument)")
                return
            }
        }

        let log = PluginLog(path: logPath ?? PluginLog.defaultPath, echo: echo)
        let trace = tracePath.map { PluginLog(path: $0) }
        let write = { (line: String) in
            log.write(line)
            trace?.write(line, precise: true)
        }

        // DynamicLake names its socket in the plugin's environment.
        var link: LakeSocket?
        if let path = ProcessInfo.processInfo.environment["DYNAMICLAKE_JSON_SOCKET"] {
            do {
                link = try LakeSocket(path: path)
            } catch {
                write("DynamicLake's socket can't be connected to: stopping")
                exit(1)
            }
        }
        write("started: " + (link == nil ? "watching only (not started by DynamicLake)" : "connected to DynamicLake"))
        var plugin = Plugin(lookout: SystemLookout(trace: trace), link: link, log: write)
        plugin.run()
    }
}
