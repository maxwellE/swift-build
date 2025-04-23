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
        return await withCheckedContinuation { continuation in
            try! bazelBuildProcess.start { uniqueTargetsHandler, startProcessHandler in
                self.buildOutputDelegate = self.delegate.buildStarted(self)
                var commandEnvironment: [String: String] = [:]
                if let passedEnvironment: [String: String] = self.environment {
                    commandEnvironment = passedEnvironment
                }
                let projectEnv: [String: String] = self.workspace.projects.reduce(into: [String: String]()) { partialResult, project in
                    project.buildConfigurations.forEach { buildConfiguration in
                        for (key, value) in buildConfiguration.buildSettings.valueAssignments {
                            partialResult[key.name] = value.expression.asLiteralString
                        }
                    }
                }
                commandEnvironment.merge(projectEnv) { lhs, rhs in
                    rhs
                }
                let targetsEnvironment: [String: String] = self.request.buildTargets.reduce(into: [String : String]()) { partialResult, buildTargetInfo in
                    guard let buildSettings = buildTargetInfo.target.getEffectiveConfiguration(
                        self.request.parameters.configuration,
                        defaultConfigurationName: buildTargetInfo.parameters.configuration ?? "Debug"
                    )?.buildSettings else { return }
                    for valueAssignment in buildSettings.valueAssignments {
                        partialResult[valueAssignment.key.name] = valueAssignment.value.expression.asLiteralString
                    }
                }
                commandEnvironment.merge(targetsEnvironment) { lhs, rhs in
                    rhs
                }
                  commandEnvironment["ACTION"] = "build"
                  commandEnvironment["RULES_XCODEPROJ_BUILD_MODE"] = "proxy"
//                commandEnvironment["XCODE_VERSION_ACTUAL"] = "1620"
                  commandEnvironment["BAZEL_CONFIG"] = "rules_xcodeproj"
                  //commandEnvironment["INTERNAL_DIR"] = self.workspace.path.dirname.str + "/rules_xcodeproj"
                  //commandEnvironment["BAZEL_INTEGRATION_DIR"] = self.workspace.path.dirname.str + "/rules_xcodeproj/bazel"
                  //commandEnvironment["BAZEL_OUTPUT_BASE"] = self.workspace.projects.first!.sourceRoot.dirname.dirname.str
                  commandEnvironment["DEVELOPER_DIR"] = self.core.developerPath.path.str
                  commandEnvironment["XCODE_PRODUCT_BUILD_VERSION"] = self.core.xcodeProductBuildVersionString
                  //commandEnvironment["PROJECT_FILE_PATH"] = self.workspace.projects.first!.xcodeprojPath.str
                  commandEnvironment["OBJROOT"] = self.workspace.projects.first!.sourceRoot.dirname.dirname.str + "/execroot/_main/bazel-out"
//                  commandEnvironment["PROJECT_TEMP_DIR"] = self.workspace.projects.first!.sourceRoot.dirname.dirname.str + "/execroot/_main"
//                commandEnvironment["BAZEL_PACKAGE_BIN_DIR"] = "rules_xcodeproj"
//                commandEnvironment["BAZEL_OUTPUTS_PRODUCT_BASENAME"] = "proxyapp.app"
                commandEnvironment["INDEX_DATA_STORE_DIR"] = "$(INDEX_DATA_STORE_DIR)"

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
                    commandEnvironment["PROJECT_DIR"]!,
                    commandEnvironment.mapValues({ value in
                        value
                            .replacingOccurrences(of: "/build_output_base/execroot/_main/build/bazel-out/", with: "/build_output_base/execroot/_main/bazel-out/")
                            .replacingOccurrences(of: "/build_output_base/execroot/_main/build/Debug-iphoneos/bazel-out/", with: "/build_output_base/execroot/_main/bazel-out/")
                    })
                )
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
                continuation.resume(returning: status ?? .failed)
            }
        }
    }
}
