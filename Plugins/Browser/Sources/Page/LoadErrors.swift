import Foundation

/// A failed page load, named the way Chromium names it. WebKit reports a load
/// failure as an `NSError` (`NSURLErrorDomain` or `WebKitErrorDomain` and a
/// code); callers are handed Chromium's net error names (`ERR_*`) instead and
/// quote them in what they say (`failed to load <url>: ERR_CONNECTION_REFUSED`).
enum LoadErrors {
    /// The `ERR_*` name for a main-frame load failure, or nil for one that isn't
    /// a failure worth reporting: a navigation superseded by another or cancelled
    /// by a policy decision (Chromium's `ERR_ABORTED`) commits nothing.
    static func name(for error: NSError) -> String? {
        if error.domain == NSURLErrorDomain {
            if error.code == NSURLErrorCancelled { return nil }
            if let refined = refined(error) { return refined }
            return urlErrors[error.code] ?? "ERR_FAILED"
        }
        if error.domain == "WebKitErrorDomain" {
            switch error.code {
            // A navigation turned into a download, or cancelled by a policy
            // decision: "Frame load interrupted".
            case 102: return nil
            // "Not allowed to use restricted network port".
            case 103: return "ERR_UNSAFE_PORT"
            default: return "ERR_FAILED"
            }
        }
        return "ERR_FAILED"
    }

    /// What the underlying POSIX error says, where it says more than the code:
    /// a host or network that can't be reached is not a refused connection.
    private static func refined(_ error: NSError) -> String? {
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain else { return nil }
        switch Int32(underlying.code) {
        case EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN: return "ERR_ADDRESS_UNREACHABLE"
        case ETIMEDOUT: return "ERR_CONNECTION_TIMED_OUT"
        case ECONNRESET: return "ERR_CONNECTION_RESET"
        case ECONNREFUSED: return "ERR_CONNECTION_REFUSED"
        default: return nil
        }
    }

    private static let urlErrors: [Int: String] = [
        NSURLErrorBadURL: "ERR_INVALID_URL",
        NSURLErrorTimedOut: "ERR_CONNECTION_TIMED_OUT",
        NSURLErrorUnsupportedURL: "ERR_UNKNOWN_URL_SCHEME",
        NSURLErrorCannotFindHost: "ERR_NAME_NOT_RESOLVED",
        NSURLErrorCannotConnectToHost: "ERR_CONNECTION_REFUSED",
        NSURLErrorNetworkConnectionLost: "ERR_CONNECTION_RESET",
        NSURLErrorDNSLookupFailed: "ERR_NAME_NOT_RESOLVED",
        NSURLErrorHTTPTooManyRedirects: "ERR_TOO_MANY_REDIRECTS",
        NSURLErrorResourceUnavailable: "ERR_FAILED",
        NSURLErrorNotConnectedToInternet: "ERR_INTERNET_DISCONNECTED",
        NSURLErrorRedirectToNonExistentLocation: "ERR_INVALID_REDIRECT",
        NSURLErrorBadServerResponse: "ERR_INVALID_RESPONSE",
        NSURLErrorUserCancelledAuthentication: "ERR_INVALID_AUTH_CREDENTIALS",
        NSURLErrorUserAuthenticationRequired: "ERR_INVALID_AUTH_CREDENTIALS",
        NSURLErrorZeroByteResource: "ERR_EMPTY_RESPONSE",
        NSURLErrorCannotDecodeRawData: "ERR_CONTENT_DECODING_FAILED",
        NSURLErrorCannotDecodeContentData: "ERR_CONTENT_DECODING_FAILED",
        NSURLErrorCannotParseResponse: "ERR_INVALID_RESPONSE",
        NSURLErrorInternationalRoamingOff: "ERR_INTERNET_DISCONNECTED",
        NSURLErrorCallIsActive: "ERR_INTERNET_DISCONNECTED",
        NSURLErrorDataNotAllowed: "ERR_INTERNET_DISCONNECTED",
        NSURLErrorFileDoesNotExist: "ERR_FILE_NOT_FOUND",
        NSURLErrorFileIsDirectory: "ERR_FAILED",
        NSURLErrorNoPermissionsToReadFile: "ERR_ACCESS_DENIED",
        NSURLErrorDataLengthExceedsMaximum: "ERR_FILE_TOO_BIG",
        NSURLErrorSecureConnectionFailed: "ERR_SSL_PROTOCOL_ERROR",
        NSURLErrorServerCertificateHasBadDate: "ERR_CERT_DATE_INVALID",
        NSURLErrorServerCertificateUntrusted: "ERR_CERT_AUTHORITY_INVALID",
        NSURLErrorServerCertificateHasUnknownRoot: "ERR_CERT_AUTHORITY_INVALID",
        NSURLErrorServerCertificateNotYetValid: "ERR_CERT_DATE_INVALID",
        NSURLErrorClientCertificateRejected: "ERR_BAD_SSL_CLIENT_AUTH_CERT",
        NSURLErrorClientCertificateRequired: "ERR_SSL_CLIENT_AUTH_CERT_NEEDED",
        NSURLErrorCannotLoadFromNetwork: "ERR_INTERNET_DISCONNECTED",
    ]

    /// The sentence under the error page's heading, from the code
    /// (Chromium's own wording, for the codes it words).
    static func explanation(code: String, host: String) -> String {
        switch code {
        case "ERR_CONNECTION_REFUSED": "\(host) refused to connect."
        case "ERR_NAME_NOT_RESOLVED": "\(host)’s server IP address could not be found."
        case "ERR_CONNECTION_TIMED_OUT": "\(host) took too long to respond."
        case "ERR_CONNECTION_RESET": "The connection was reset."
        case "ERR_INTERNET_DISCONNECTED": "There is no internet connection."
        case "ERR_ADDRESS_UNREACHABLE": "\(host)’s server can’t be reached."
        case "ERR_UNSAFE_PORT": "The port used by \(host) is not allowed."
        case "ERR_TOO_MANY_REDIRECTS": "\(host) redirected you too many times."
        case "ERR_FILE_NOT_FOUND": "The file could not be found."
        case let code where code.hasPrefix("ERR_CERT_") || code.hasPrefix("ERR_SSL_"): "Your connection to \(host) is not private."
        default: "\(host) sent an invalid response."
        }
    }
}
