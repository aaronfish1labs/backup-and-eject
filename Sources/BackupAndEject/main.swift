import AppKit
import BackupAndEjectCore
import Foundation
import ServiceManagement

private func runSelfTest() -> Int32 {
    do {
        let runner = SystemCommandRunner()

        let destinationsResult = try runner.run(
            AppConfiguration.tmutilPath,
            arguments: ["destinationinfo", "-X"],
            timeout: AppConfiguration.quickCommandTimeout
        )

        guard destinationsResult.exitCode == 0 else {
            fputs(
                "SELF-TEST FAILED: tmutil destinationinfo returned \(destinationsResult.exitCode)\n",
                stderr
            )
            return 1
        }

        let destinations = try TimeMachineDestinationParser.parse(
            destinationsResult.standardOutput
        )

        let statusResult = try runner.run(
            AppConfiguration.tmutilPath,
            arguments: ["status"],
            timeout: AppConfiguration.quickCommandTimeout
        )

        guard statusResult.exitCode == 0 else {
            fputs(
                "SELF-TEST FAILED: tmutil status returned \(statusResult.exitCode)\n",
                stderr
            )
            return 1
        }

        let running = TimeMachineStatusParser.isBackupRunning(
            statusResult.standardOutput
        )
        print(
            "SELF-TEST PASSED: found \(destinations.count) configured Time Machine destination(s); running = \(running)"
        )
        return 0
    } catch {
        fputs("SELF-TEST FAILED: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

if CommandLine.arguments.contains("--workflow-self-test") {
    exit(runWorkflowSelfTest())
}

if CommandLine.arguments.contains("--self-test") {
    exit(runSelfTest())
}

if CommandLine.arguments.contains("--login-item-status") {
    print(SMAppService.mainApp.status.rawValue)
    exit(0)
}

if CommandLine.arguments.contains("--enable-login-item") {
    do {
        if SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
        }
        print(SMAppService.mainApp.status.rawValue)
        exit(0)
    } catch {
        fputs(
            "LOGIN ITEM FAILED: \(error.localizedDescription)\n",
            stderr
        )
        exit(1)
    }
}

if CommandLine.arguments.contains("--refresh-login-item") {
    do {
        if SMAppService.mainApp.status == .enabled
            || SMAppService.mainApp.status == .requiresApproval
        {
            try SMAppService.mainApp.unregister()
        }
        try SMAppService.mainApp.register()
        print(SMAppService.mainApp.status.rawValue)
        exit(0)
    } catch {
        fputs(
            "LOGIN ITEM REFRESH FAILED: \(error.localizedDescription)\n",
            stderr
        )
        exit(1)
    }
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
