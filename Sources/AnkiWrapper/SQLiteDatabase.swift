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
      handle = nil
      throw .database(message)
    }
    // Nothing the file's schema declares may call functions or run code
    // on our behalf.
    sqlite3_exec(handle, "PRAGMA trusted_schema = OFF", nil, nil, nil)
    // Parsing a schema row happens between the instructions the work
    // limit counts, at a cost the row chooses (2,000 columns, a partial
    // index's megabyte literal). These keep each row's cost small, so the
    // count bounds the whole load. Anki's widest table has 18 columns.
    sqlite3_limit(handle, SQLITE_LIMIT_COLUMN, 64)
    sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 1 << 16)
    sqlite3_limit(handle, SQLITE_LIMIT_EXPR_DEPTH, 100)
    // Anki's tables declare this collation, and SQLite refuses to query
    // them until something by that name is registered. No query here
    // orders by it, so a plain byte comparison, which allocates nothing,
    // does.
    sqlite3_create_collation_v2(
      handle, "unicase", SQLITE_UTF8, nil,
      { _, leftLength, left, rightLength, right in
        let shared = Int(min(leftLength, rightLength))
        let order = shared == 0 ? 0 : memcmp(left, right, shared)
        if order != 0 { return order < 0 ? -1 : 1 }
        return leftLength == rightLength ? 0 : (leftLength < rightLength ? -1 : 1)
      }, nil)
    try verifySchema()
  }

  /// Loading a schema is work the file chooses: tens of thousands of
  /// indexes cost quadratic time, and a chain of views compiled for any
  /// schema query costs exponential time. So the load runs under a work
  /// limit (a real Anki schema needs a sliver of it), and anything but
  /// plain tables and indexes is refused before any other query runs.
  private static let schemaWorkLimit: Int32 = 100
  private static let plainDefinitions = [
    "CREATE TABLE ", "CREATE INDEX ", "CREATE UNIQUE INDEX ",
  ]

  private final class WorkLimit {
    var remaining = SQLiteDatabase.schemaWorkLimit
  }

  private func verifySchema() throws(AnkiPackageError) {
    let limit = WorkLimit()
    sqlite3_progress_handler(
      handle, 1000,
      { pointer in
        guard let pointer else { return 1 }
        let limit = Unmanaged<WorkLimit>.fromOpaque(pointer).takeUnretainedValue()
        limit.remaining -= 1
        return limit.remaining < 0 ? 1 : 0
      }, Unmanaged.passUnretained(limit).toOpaque())
    defer {
      sqlite3_progress_handler(handle, 0, nil, nil)
      withExtendedLifetime(limit) {}
    }
    var unexpected: String?
    try query("SELECT type, name, sql FROM sqlite_master") { row in
      let definition = row.isNull(2) ? nil : row.string(2)
      let plain =
        ["table", "index"].contains(row.string(0))
        && (definition.map { sql in Self.plainDefinitions.contains { sql.hasPrefix($0) } } ?? true)
      if !plain, unexpected == nil { unexpected = "\(row.string(0)) \(row.string(1))" }
    }
    if let unexpected { throw .database("unexpected schema object: \(unexpected)") }
  }

  deinit {
    sqlite3_close(handle)
  }

  /// Whether `name` is an ordinary table: not a view, not a virtual table,
  /// and without generated columns. Any of those runs code the file chose
  /// when a row is read, which can be made to never finish. SQLite's own
  /// classification decides, not the schema's text, which a file can word
  /// however it likes.
  func isPlainTable(_ name: String) throws(AnkiPackageError) -> Bool {
    var type: String?
    try query("PRAGMA main.table_list('\(name)')") { row in type = row.string(2) }
    guard type == "table" else { return false }
    // A column of the table's own named like the rowid would take over
    // `ORDER BY rowid`, turning a b-tree walk back into a sort.
    let rowidNames: Set<String> = ["rowid", "_rowid_", "oid"]
    var plain = true
    try query("PRAGMA table_xinfo('\(name)')") { row in
      if row.int(6) != 0 || rowidNames.contains(row.string(1).lowercased()) { plain = false }
    }
    return plain
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

    func byteCount(_ column: Int32) -> Int {
      Int(sqlite3_column_bytes(statement, column))
    }

    func isNull(_ column: Int32) -> Bool {
      sqlite3_column_type(statement, column) == SQLITE_NULL
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
