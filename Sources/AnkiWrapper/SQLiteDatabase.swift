import Foundation
import SQLite3

/// A read-only handle on an extracted collection database.
final class SQLiteDatabase {
  private var handle: OpaquePointer?

  init(url: URL) throws(AnkiPackageError) {
    // Anki leaves its databases in WAL mode, which a read-only connection
    // can only open as immutable (no -shm or -wal to create).
    var components = URLComponents()
    components.scheme = "file"
    components.path = url.path
    components.queryItems = [URLQueryItem(name: "immutable", value: "1")]
    let uri = components.string ?? url.path
    guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
    else {
      let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
      sqlite3_close(handle)
      throw .database(message)
    }
    // Nothing the file's schema declares may call functions or run code
    // on our behalf.
    sqlite3_exec(handle, "PRAGMA trusted_schema = OFF", nil, nil, nil)
    // Anki's tables declare this collation, and SQLite refuses to query
    // them until something by that name is registered.
    sqlite3_create_collation_v2(
      handle, "unicase", SQLITE_UTF8, nil,
      { _, leftLength, left, rightLength, right in
        let lhs = String(
          decoding: UnsafeRawBufferPointer(start: left, count: Int(leftLength)), as: UTF8.self)
        let rhs = String(
          decoding: UnsafeRawBufferPointer(start: right, count: Int(rightLength)), as: UTF8.self)
        switch lhs.lowercased().compare(rhs.lowercased()) {
        case .orderedAscending: return -1
        case .orderedSame: return 0
        case .orderedDescending: return 1
        }
      }, nil)
  }

  deinit {
    sqlite3_close(handle)
  }

  /// Every table and view the file declares, by name. Reading only ever
  /// queries names that are tables: a view in a table's place could run
  /// an unbounded query.
  func objectTypes() throws(AnkiPackageError) -> [String: String] {
    var types: [String: String] = [:]
    try query("SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view')") { row in
      types[row.string(0)] = row.string(1)
    }
    return types
  }

  func query(_ sql: String, row: (Row) throws(AnkiPackageError) -> Void) throws(AnkiPackageError) {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw .database(String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    while true {
      switch sqlite3_step(statement) {
      case SQLITE_ROW: try row(Row(statement: statement))
      case SQLITE_DONE: return
      default: throw .database(String(cString: sqlite3_errmsg(handle)))
      }
    }
  }

  struct Row {
    fileprivate let statement: OpaquePointer?

    func int(_ column: Int32) -> Int64 {
      sqlite3_column_int64(statement, column)
    }

    func string(_ column: Int32) -> String {
      sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    func data(_ column: Int32) -> Data {
      let count = Int(sqlite3_column_bytes(statement, column))
      guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
      return Data(bytes: bytes, count: count)
    }
  }
}
