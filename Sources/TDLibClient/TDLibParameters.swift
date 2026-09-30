import Foundation

/// Everything `setTdlibParameters` needs. Sent once per client, in reply to
/// `AuthState.waitTdlibParameters`.
///
/// - `apiId` / `apiHash`: this application's identity with Telegram, registered at
///   https://my.telegram.org. Never reuse another app's.
/// - `databaseDirectory`: where TDLib keeps `td.binlog` (its append-only log of everything it
///   must not lose, including the login) and `db.sqlite`. Only one process may open it.
/// - `filesDirectory`: where downloaded media goes.
/// - `databaseEncryptionKey`: 32 random bytes; TDLib encrypts `db.sqlite` with it.
public struct TDLibParameters: Sendable {
    public var apiId: Int32
    public var apiHash: String
    public var databaseDirectory: String
    public var filesDirectory: String
    public var databaseEncryptionKey: Data
    public var deviceModel = "Telegram Gateway"
    public var systemVersion = ""
    public var systemLanguageCode = "en"
    public var applicationVersion: String
    public var useMessageDatabase = true
    public var useChatInfoDatabase = true
    public var useFileDatabase = true
    public var useSecretChats = false
    public var useTestDC = false

    public init(
        apiId: Int32,
        apiHash: String,
        databaseDirectory: String,
        filesDirectory: String,
        databaseEncryptionKey: Data,
        applicationVersion: String
    ) {
        self.apiId = apiId
        self.apiHash = apiHash
        self.databaseDirectory = databaseDirectory
        self.filesDirectory = filesDirectory
        self.databaseEncryptionKey = databaseEncryptionKey
        self.applicationVersion = applicationVersion
    }

    /// The `setTdlibParameters` request. TDLib's JSON interface takes `bytes` fields as base64.
    public var request: JSONObject {
        [
            "@type": "setTdlibParameters",
            "use_test_dc": useTestDC,
            "database_directory": databaseDirectory,
            "files_directory": filesDirectory,
            "database_encryption_key": databaseEncryptionKey.base64EncodedString(),
            "use_file_database": useFileDatabase,
            "use_chat_info_database": useChatInfoDatabase,
            "use_message_database": useMessageDatabase,
            "use_secret_chats": useSecretChats,
            "api_id": Int(apiId),
            "api_hash": apiHash,
            "system_language_code": systemLanguageCode,
            "device_model": deviceModel,
            "system_version": systemVersion,
            "application_version": applicationVersion,
        ]
    }
}
