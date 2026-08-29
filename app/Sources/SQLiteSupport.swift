import Foundation
import SQLite3

/// Every failure from the storage layer surfaces as one of these.
enum StoreError: Error, LocalizedError {
    case openFailed(message: String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(sql: String, message: String)
    case migrationFailed(version: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m):             "Could not open database: \(m)"
        case .prepareFailed(let s, let m):   "Prepare failed (\(m)) for SQL: \(s)"
        case .stepFailed(let s, let m):      "Step failed (\(m)) for SQL: \(s)"
        case .migrationFailed(let v, let m): "Migration \(v) failed: \(m)"
        }
    }
}

/// The C header defines SQLITE_TRANSIENT as a function-pointer cast that
/// Swift cannot import, so we rebuild it. It tells sqlite3_bind_text to
/// COPY the string immediately instead of keeping our temporary pointer.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
