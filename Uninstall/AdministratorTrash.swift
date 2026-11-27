import Darwin
import Foundation

enum AdministratorTrash {
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
        let alternateName = "\(stem.utf8.count < 190 ? stem : "App") (\(UUID().uuidString)).app"
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
        if process.terminationStatus == 0 {
            if result == "moved" { return }
            if result == "cancelled" { throw CocoaError(.userCancelled) }
        }
        throw MoveError(result.isEmpty ? "macOS could not complete the authorized move to Trash." : result)
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
            return "moved";
        }
        let failure = $.__error()[0];
        if (failure === Number(exists)) {
            verifyDirectory(source, device, appInode, appBirth, "The app");
            if ($.renamex_np(source, trash + "/" + alternate, Number(flags)) === 0) {
                return "moved";
            }
            failure = $.__error()[0];
        }
        throw new Error($.strerror(failure));
    }
    """#
}
