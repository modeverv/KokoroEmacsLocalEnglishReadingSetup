import Foundation
import SQLite3

enum KindleBookCatalog {
    private static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.amazon.Lassen/Data/Library/Protected/BookData.sqlite")
    }

    /// Return the title of the book Kindle accessed most recently.
    ///
    /// Kindle's reader window exposes its page text through Accessibility, but
    /// its painted title is not an AX element. BookData.sqlite is Kindle's
    /// local metadata database, so this remains a native, read-only lookup and
    /// does not require OCR or network access.
    static func currentTitle(databaseURL: URL = defaultDatabaseURL) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
                              nil) == SQLITE_OK,
              let database
        else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }

        let sql = """
            SELECT ZDISPLAYTITLE
            FROM ZBOOK
            WHERE ZDISPLAYTITLE IS NOT NULL
              AND trim(ZDISPLAYTITLE) <> ''
              AND COALESCE(ZRAWISDICTIONARY, 0) = 0
            ORDER BY COALESCE(ZRAWLASTACCESSTIME, 0) DESC
            LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_text(statement, 0)
        else { return nil }
        let title = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

enum KindleBookTitle {
    static func resolve(override: String?, detected: String?) -> String {
        let requested = override?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty,
           requested.caseInsensitiveCompare("Kindle.app") != .orderedSame,
           requested.caseInsensitiveCompare("Kindle") != .orderedSame {
            return requested
        }
        let automatic = detected?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let automatic, !automatic.isEmpty {
            return automatic
        }
        return "Kindle.app"
    }
}
