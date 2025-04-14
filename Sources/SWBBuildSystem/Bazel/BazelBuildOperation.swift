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
package import SWBTaskExecution
private import SWBLLBuild

package final class BazelBuildOperation: BuildOperation {

    private let bazelBuildProcess: any BazelBuildProcess
    private var buildOutputDelegate: (any BuildOutputDelegate)!

    package override init(_ request: BuildRequest, _ requestContext: BuildRequestContext, _ buildDescription: BuildDescription, environment: [String: String]? = nil, _ delegate: any BuildOperationDelegate, _ clientDelegate: any ClientDelegate, _ cachedBuildSystems: any BuildSystemCache, persistent: Bool = false, serial: Bool = false, buildOutputMap: [String:String]? = nil, nodesToBuild: [BuildDescription.BuildNodeToPrepareForIndex]? = nil, workspace: SWBCore.Workspace, core: Core, userPreferences: UserPreferences) {
        self.bazelBuildProcess = BazelClient()
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

        try! bazelBuildProcess.start { uniqueTargetsHandler, startProcessHandler in
            var commandEnvironment: [String: String] = [:]
            if let passedEnvironment: [String: String] = self.environment {
                commandEnvironment = passedEnvironment
            }
            let projectEnv: [String: String] = self.workspace.projects.reduce(into: [String: String]()) { partialResult, project in
                project.buildConfigurations.forEach { buildConfiguration in
                    for (key, value) in buildConfiguration.buildSettings.valueAssignments {
                        partialResult[key.name] = value.expression.stringRep
                    }
                }
            }
            commandEnvironment.merge(projectEnv) { lhs, rhs in
                lhs
            }
            commandEnvironment["ACTION"] = "build"
            commandEnvironment["RULES_XCODEPROJ_BUILD_MODE"] = "proxy"
            commandEnvironment["XCODE_VERSION_ACTUAL"] = "1620"
            commandEnvironment["BAZEL_CONFIG"] = "rules_xcodeproj"
            commandEnvironment["INTERNAL_DIR"] = self.workspace.path.dirname.str + "/rules_xcodeproj"
            commandEnvironment["BAZEL_INTEGRATION_DIR"] = self.workspace.path.dirname.str + "/rules_xcodeproj/bazel"
            commandEnvironment["BAZEL_OUTPUT_BASE"] = self.workspace.projects.first!.sourceRoot.dirname.dirname.str
            commandEnvironment["DEVELOPER_DIR"] = self.core.developerPath.path.str
            commandEnvironment["XCODE_PRODUCT_BUILD_VERSION"] = self.core.xcodeProductBuildVersionString
            commandEnvironment["PROJECT_FILE_PATH"] = self.workspace.projects.first!.xcodeprojPath.str
            commandEnvironment["OBJROOT"] = self.workspace.projects.first!.sourceRoot.dirname.dirname.str + "/execroot/_main/build"

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

            self.buildOutputDelegate = self.delegate.buildStarted(self)
            let commandLineString = startProcessHandler(
                targetPatterns.joined(separator: "\n"),
                self.workspace.path.dirname.dirname.str,
                commandEnvironment
            )
            print(commandLineString)
        } outputHandler: { data in
            self.delegate.updateBuildProgress(statusMessage: "OutputHandler: " + String(decoding: data, as: UTF8.self), showInLog: true)
        } bepHandler: { buildEvent in
            if buildEvent.progress.isInitialized {
                buildEvent.progress.stderr.split(separator: "\n").forEach { message in
                    self.delegate.updateBuildProgress(statusMessage: String("updateBuildProgress: " + message), showInLog: true)
                }
            }
        } terminationHandler: { exitCode, cancelled in
            var status: BuildOperationEnded.Status?
            if cancelled {
                status = .cancelled
            } else {
                status = exitCode == 0 ? .succeeded : .failed
            }
            self.delegate.buildComplete(self, status: status, delegate: self.buildOutputDelegate, metrics: nil)
        }
        return .succeeded
    }
}
