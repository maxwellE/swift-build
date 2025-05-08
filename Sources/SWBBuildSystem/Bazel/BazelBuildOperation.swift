//
//  BazelBuildManager.swift
//  SwiftBuild
//
//  Created by Maxwell Elliott on 3/10/25.
//

import Foundation
package import SWBCore
package import SWBProtocol
import SWBCAS
import SWBServiceCore
import SWBTaskConstruction
import SWBUtil
package import SWBTaskExecution
private import SWBLLBuild

package final class BazelBuildOperation: BuildOperation {

    private let bazelBuildProcess: any BazelBuildProcess
    private var buildOutputDelegate: (any BuildOutputDelegate)!

    /// This regex is used to minimally remove the timestamp at the start of our messages.
    /// After that we try to parse out the execution progress
    /// (see https://github.com/bazelbuild/bazel/blob/9bea69aee3acf18b780b397c8c441ac5715d03ae/src/main/java/com/google/devtools/build/lib/buildtool/ExecutionProgressReceiver.java#L150-L157 ).
    /// Finally we throw away any " ... (8 actions running)" like messages (see https://github.com/bazelbuild/bazel/blob/4f0b710e2b935b4249e0bbf633f43628bbf93d7b/src/main/java/com/google/devtools/build/lib/runtime/UiStateTracker.java#L1158 ).
    private static let progressRegex = try! NSRegularExpression(
        pattern: #"^(?:\(\d{1,2}:\d{1,2}:\d{1,2}\) )?(?:\[(\d{1,3}(,\d{3})*) \/ (\d{1,3}(,\d{3})*)\] )?(?:(?:INFO|ERROR|WARNING): )?(.*?)(?: \.\.\. \(.*\))?$"#
    )
    private var progressStatistics: BuildOperation.ProgressStatistics

    package override init(_ request: BuildRequest, _ requestContext: BuildRequestContext, _ buildDescription: BuildDescription, environment: [String: String]? = nil, _ delegate: any BuildOperationDelegate, _ clientDelegate: any ClientDelegate, _ cachedBuildSystems: any BuildSystemCache, persistent: Bool = false, serial: Bool = false, buildOutputMap: [String:String]? = nil, nodesToBuild: [BuildDescription.BuildNodeToPrepareForIndex]? = nil, workspace: SWBCore.Workspace, core: Core, userPreferences: UserPreferences) {
        self.bazelBuildProcess = BazelClient()
        self.progressStatistics = .init(numCommandsLowerBound: 0)
        super.init(
            request,
            requestContext,
            buildDescription,
            environment: environment,
            delegate, clientDelegate,
            cachedBuildSystems,
            persistent: persistent,
            serial: serial,
            buildOutputMap: buildOutputMap,
            nodesToBuild: nodesToBuild,
            workspace: workspace,
            core: core,
            userPreferences: userPreferences
        )
    }

    package override func build() async -> BuildOperationEnded.Status {
        return await withCheckedContinuation { continuation in
            try! bazelBuildProcess.start { uniqueTargetsHandler, startProcessHandler in
                self.buildOutputDelegate = self.delegate.buildStarted(self)
                var commandEnvironment: [String: String] = [:]
                if let passedEnvironment: [String: String] = self.environment {
                    commandEnvironment = passedEnvironment
                }


                commandEnvironment["RULES_XCODEPROJ_BUILD_MODE"] = "proxy"
                commandEnvironment["DEVELOPER_DIR"] = self.core.developerPath.path.str
                commandEnvironment["XCODE_PRODUCT_BUILD_VERSION"] = self.core.xcodeProductBuildVersionString
                commandEnvironment["PROJECT_FILE_PATH"] = self.workspace.projects.first!.xcodeprojPath.str
                commandEnvironment["INTERNAL_DIR"] = self.workspace.projects.first!.xcodeprojPath.join("rules_xcodeproj").str
                commandEnvironment["BAZEL_OUTPUT_BASE"] = "$(PROJECT_DIR)/../.."

                commandEnvironment = commandEnvironment.mapValues({ value in
                    var mutatedValue: String = value
                    for key in commandEnvironment.keys {
                        if mutatedValue.contains("$(\(key))") {
                            mutatedValue = mutatedValue.replacingOccurrences(of: "$(\(key))", with: commandEnvironment[key]!)
                        }
                    }
                    return mutatedValue
                })

                let targetPatterns: [String] = self.request.buildTargets.flatMap { buildTargetInfo -> [String] in
                    guard let buildSettings = buildTargetInfo.target.getEffectiveConfiguration(
                        self.request.parameters.configuration,
                        defaultConfigurationName: "Debug"
                    )?.buildSettings else { return [] }
                    return buildSettings.valueAssignments.filter { dict in
                        dict.key.name == "BAZEL_TARGET_ID"
                    }.flatMap({ bazelTarget in
                        return [
                            "bc",
                            "bp",
                            "bi"
                        ].map { prefix in
                            bazelTarget.value.expression.stringRep.components(separatedBy: CharacterSet.whitespaces).first! + "\n" + prefix + " " + bazelTarget.value.expression.stringRep
                        }
                    })
                }

                let commandLineString = startProcessHandler(
                    targetPatterns.joined(separator: "\n"),
                    commandEnvironment["SRCROOT"]!,
                    commandEnvironment.filter({ (key: String, value: String) in
                        !(key.hasPrefix("BAZEL_OUTPUTS_") || key.hasPrefix("INDEX_DATA_STORE_DIR"))
                    }),
                    self.workspace.path.dirname.str + "/rules_xcodeproj/bazel/proxy_build.sh"
                )
            } outputHandler: { data in
                let fullMessage: String = .init(decoding: data, as: UTF8.self)
                fullMessage.components(separatedBy: .newlines).forEach{ line in
                    guard !line.isEmpty else { return }

                    let message = String(line)

                    self.delegate.updateBuildProgress(statusMessage: message, showInLog: true)

                    if
                        let match = Self.progressRegex.firstMatch(
                            in: message,
                            options: [],
                            range: NSRange(message.startIndex ..< message.endIndex, in: message)
                        ),
                        match.numberOfRanges == 6,
                        let finalMessageRange = Range(match.range(at: 5), in: message),
                        let completedActionsRange = Range(match.range(at: 1), in: message),
                        let totalActionsRange = Range(match.range(at: 3), in: message)
                    {
                        self.delegate.updateBuildProgress(statusMessage: String(message[finalMessageRange]).capitalized, showInLog: true)
                        let completedActionsString = message[completedActionsRange]
                            .replacingOccurrences(of: ",", with: "")
                        let totalActionsString = message[totalActionsRange]
                            .replacingOccurrences(of: ",", with: "")

                        if
                            let completedActions = Int(completedActionsString),
                            let totalActions = Int(totalActionsString)
                        {
                            if self.progressStatistics.numCommandsLowerBound == 0, completedActions > 0, completedActions != totalActions {
                                self.progressStatistics.numCommandsScanned = totalActions
                                self.progressStatistics.numCommandsActivelyScanning = totalActions
                                self.progressStatistics.numCommandsCompleted = completedActions
                                self.progressStatistics.numCommandsUpToDate = completedActions
                                self.progressStatistics.numCommandsStarted = completedActions
                            }
                            self.delegate.totalCommandProgressChanged(self, forTargetName: nil, statistics: self.progressStatistics)
                        }
                    } else {
                        let components: [String] = message.components(separatedBy: ":").map { str in
                            str.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        if components.count > 4 {
                            let errorType: String = components[3]
                            switch errorType {
                            case "error":
                                self.buildOutputDelegate.error(Path(components[0]), line: Int(components[1]), column: Int(components[2]), components[4])
                            case "warning":
                                self.buildOutputDelegate.warning(Path(components[0]), line: Int(components[1]), column: Int(components[2]), components[4])
                            case "note":
                                self.buildOutputDelegate.note(Path(components[0]), line: Int(components[1]), column: Int(components[2]), components[4])
                            case "remark":
                                self.buildOutputDelegate.remark(Path(components[0]), line: Int(components[1]), column: Int(components[2]), components[4])
                            default:
                                break
                            }
                        }
                    }
                }
            } bepHandler: { event in
                if event.lastMessage {
                    self.progressStatistics.numCommandsCompleted = self.progressStatistics.numCommandsActivelyScanning
                    self.progressStatistics.numCommandsUpToDate = self.progressStatistics.numCommandsActivelyScanning
                    self.progressStatistics.numCommandsScanned = self.progressStatistics.numCommandsActivelyScanning
                    self.delegate.totalCommandProgressChanged(self, forTargetName: nil, statistics: self.progressStatistics)
                    self.progressStatistics.reset()
                    self.delegate.updateBuildProgress(statusMessage: "Compilation complete", showInLog: true)
                }
            } terminationHandler: { exitCode, cancelled in
                var status: BuildOperationEnded.Status?
                if cancelled {
                    status = .cancelled
                } else {
                    status = exitCode == 0 ? .succeeded : .failed
                }
                self.delegate.buildComplete(self, status: status, delegate: self.buildOutputDelegate, metrics: nil)
                continuation.resume(returning: status ?? .failed)
            }
        }
    }
}
