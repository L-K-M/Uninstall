import Darwin
import Foundation

enum AdministratorTrash {
    enum MoveOutcome: Equatable {
        case moved
        case cancelled
        case failed(String)
    }

    static func move(_ app: InstalledApp) throws {
        guard !app.isProtected, app.url.pathExtension.lowercased() == "app",
              AppScanner.isDirectPath(app.url), AppScanner.fileIdentity(at: app.url) == app.identity
        else {
            throw MoveError("The app could not be verified. Scan again before removing it.")
        }

        let trash = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                appropriateFor: app.url, create: true)
        guard let trashIdentity = AppScanner.fileIdentity(at: trash),
              trashIdentity.device == app.identity.device
        else {
            throw MoveError("The Trash on this volume could not be verified.")
        }

        let sourcePath = try physicalPath(for: app.url)
        let trashPath = try physicalPath(for: trash)
        let stem = app.url.deletingPathExtension().lastPathComponent
        let alternateName = alternateName(for: stem)
        let flags = RENAME_EXCL | RENAME_NOFOLLOW_ANY

        let arguments = [
            "-e", authorizationScript, "--", renameScript,
            sourcePath, trashPath, String(app.identity.device), String(app.identity.inode),
            birthTime(app.identity), String(trashIdentity.inode), birthTime(trashIdentity),
            String(getuid()), String(flags), String(EEXIST), alternateName,
        ]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch outcome(processStatus: process.terminationStatus, output: result) {
        case .moved:
            return
        case .cancelled:
            throw CocoaError(.userCancelled)
        case .failed(let message):
            throw MoveError(message)
        }
    }

    // Diagnostics can share the pipe, so a successful move is recognised by a
    // unique sentinel line rather than by exact equality on the whole output.
    static func outcome(processStatus: Int32, output: String) -> MoveOutcome {
        let lines = output.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard processStatus == 0 else {
            return .failed(failureMessage(output))
        }
        if lines.contains("UNINSTALL_MOVE_OK") { return .moved }
        if lines.contains("cancelled") { return .cancelled }
        return .failed(failureMessage(output))
    }

    private static func failureMessage(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "macOS could not complete the authorized move to Trash."
            : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Keep the fallback name within the filesystem name limit even for long stems.
    static func alternateName(for stem: String) -> String {
        let suffix = " (\(UUID().uuidString)).app"
        let base = stem.utf8.count <= 255 - suffix.utf8.count ? stem : "App"
        return base + suffix
    }

    private static func birthTime(_ identity: FileIdentity) -> String {
        String(Double(identity.createdSeconds) + Double(identity.createdNanoseconds) / 1_000_000_000)
    }

    private static func physicalPath(for url: URL) throws -> String {
        guard let path = url.withUnsafeFileSystemRepresentation({ representation -> UnsafeMutablePointer<CChar>? in
            guard let representation else { return nil }
            return realpath(representation, nil)
        }) else {
            throw MoveError("The path could not be resolved. Scan again before removing the app.")
        }
        defer { free(path) }
        return String(cString: path)
    }

    private struct MoveError: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    private static let authorizationScript = #"""
    on run arguments
        set commandLine to "/usr/bin/osascript -l JavaScript -e " & quoted form of item 1 of arguments & " --"
        repeat with argumentValue in items 2 thru -1 of arguments
            set commandLine to commandLine & " " & quoted form of (contents of argumentValue)
        end repeat
        try
            return do shell script commandLine with prompt "Uninstall needs administrator permission to move the selected app to the Trash." with administrator privileges
        on error messageText number errorNumber
            if errorNumber is -128 then return "cancelled"
            error messageText number errorNumber
        end try
    end run
    """#

    // Recheck both directory identities after authentication. The exclusive rename
    // stays on one volume, cannot overwrite a Trash item, and rejects symbolic links.
    private static let renameScript = #"""
    ObjC.import("Foundation");
    ObjC.bindFunction("renamex_np", ["int", ["char *", "char *", "unsigned int"]]);
    ObjC.bindFunction("__error", ["int *", []]);
    ObjC.bindFunction("strerror", ["char *", ["int"]]);

    function verifyDirectory(path, device, inode, birth, description) {
        const attributes = $.NSFileManager.defaultManager.attributesOfItemAtPathError($(path), null);
        if (attributes.isNil()
            || ObjC.unwrap(attributes.objectForKey($.NSFileType)) !== "NSFileTypeDirectory"
            || ObjC.unwrap(attributes.objectForKey($.NSFileSystemNumber).stringValue) !== device
            || ObjC.unwrap(attributes.objectForKey($.NSFileSystemFileNumber).stringValue) !== inode
            || Math.abs(attributes.objectForKey($.NSFileCreationDate).timeIntervalSince1970 - Number(birth)) > 0.000001) {
            throw new Error(description + " changed after the scan.");
        }
        return attributes;
    }

    function run(args) {
        const [source, trash, device, appInode, appBirth, trashInode, trashBirth, uid, flags, exists, alternate] = args;
        verifyDirectory(source, device, appInode, appBirth, "The app");
        const trashAttributes = verifyDirectory(trash, device, trashInode, trashBirth, "The Trash");
        if (ObjC.unwrap(trashAttributes.objectForKey($.NSFileOwnerAccountID).stringValue) !== uid) {
            throw new Error("The Trash does not belong to the signed-in user.");
        }

        const originalName = source.slice(source.lastIndexOf("/") + 1);
        if ($.renamex_np(source, trash + "/" + originalName, Number(flags)) === 0) {
            return "UNINSTALL_MOVE_OK";
        }
        let failure = $.__error()[0];
        if (failure === Number(exists)) {
            verifyDirectory(source, device, appInode, appBirth, "The app");
            if ($.renamex_np(source, trash + "/" + alternate, Number(flags)) === 0) {
                return "UNINSTALL_MOVE_OK";
            }
            failure = $.__error()[0];
        }
        throw new Error($.strerror(failure));
    }
    """#
}
