import Darwin
import Foundation
import Security

/// Verifies the process on the other end of the socket is Wirelight or wgbarctl:
/// a valid code signature (checked by audit token, so a PID can't be swapped
/// mid-request), an allowed identifier, and an executable that only root can
/// replace. Admin membership is still checked separately.
enum CallerCheck {
    /// Created by scripts/install-helper.sh for source builds, whose app lives in a
    /// user-writable DerivedData folder. Root-owned, so only an admin can opt in.
    static let devModePath = "/Library/Application Support/WGBar/allow-dev-callers"

    static func isAllowedIdentifier(_ id: String) -> Bool {
        id == "io.github.boatngin.wirelight" || id == "wgbarctl" || id.hasPrefix("wgbarctl-")
    }

    /// nil when the caller is acceptable, otherwise why not.
    static func verify(_ fd: Int32) -> String? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return "no peer audit token" }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return "cannot identify the calling process" }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return "caller's code signature is invalid" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "no static code" }
        var info: CFDictionary?
        SecCodeCopySigningInformation(staticCode, [], &info)
        let id = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String ?? "?"
        guard isAllowedIdentifier(id) else { return "caller '\(id)' is not Wirelight or wgbarctl" }
        if isRootOnly(devModePath) { return nil }
        var url: CFURL?
        guard SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let path = (url as URL?)?.path else { return "no caller path" }
        guard isRootOnly(path, walkUp: true) else { return "caller at \(path) could be replaced by a non-root user" }
        return nil
    }

    /// The file and (with `walkUp`) every folder above it are owned by root and not
    /// writable by group or others, so no user can swap the binary.
    static func isRootOnly(_ path: String, walkUp: Bool = false) -> Bool {
        let adminGID = getgrnam("admin")?.pointee.gr_gid ?? 80
        var p = path
        repeat {
            var st = stat()
            guard lstat(p, &st) == 0, st.st_uid == 0, st.st_mode & S_IWOTH == 0 else { return false }
            // Group write is fine for wheel/admin (like /Applications): they can sudo anyway.
            guard st.st_mode & S_IWGRP == 0 || st.st_gid == 0 || st.st_gid == adminGID else { return false }
            if !walkUp { return true }
            p = (p as NSString).deletingLastPathComponent
        } while p != "/" && !p.isEmpty
        return true
    }
}
