import Foundation
import os

let studyDataLog = Logger(subsystem: "de.studyhelper.core", category: "StudyData")

/// Versioned JSON storage for the blob columns of the models.
///
/// Format: `{ "v": 1, "data": … }`. The bare format written before versioning
/// (the value itself, without wrapper) is still read. Decoding never falls back
/// silently: callers get a `BlobError` and must not write over the blob.
enum JSONBlob {
    static let currentVersion = 1

    enum BlobError: Error, Equatable {
        /// The bytes are not valid for the expected type.
        case undecodable(String)
        /// Written by a newer app version than this one understands.
        case newerVersion(Int)
    }

    private struct Envelope<T: Codable>: Codable {
        var v: Int
        var data: T
    }

    private struct EncodeEnvelope<U: Encodable>: Encodable {
        var v: Int
        var data: U
    }

    private struct Header: Decodable {
        var v: Int
    }

    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(EncodeEnvelope(v: currentVersion, data: value))
        } catch {
            // Encoding plain Codable values does not fail in practice; make it loud if it ever does.
            studyDataLog.fault("Encoding \(String(describing: T.self), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            assertionFailure("JSON encoding failed: \(error)")
            return Data()
        }
    }

    static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        do {
            if let header = try? decoder.decode(Header.self, from: data) {
                guard header.v <= currentVersion else { throw BlobError.newerVersion(header.v) }
                return try decoder.decode(Envelope<T>.self, from: data).data
            }
            return try decoder.decode(T.self, from: data)
        } catch let error as BlobError {
            throw error
        } catch {
            throw BlobError.undecodable(String(describing: error))
        }
    }

    /// True if `data` currently decodes (or is empty and may be initialised).
    static func isReplaceable<T: Codable>(_ data: Data?, as type: T.Type) -> Bool {
        guard let data else { return true }
        return (try? decode(type, from: data)) != nil
    }

    /// Logs a decoding failure; used by the non-throwing accessors.
    static func log(_ error: Error, what: String) {
        studyDataLog.error("Stored \(what, privacy: .public) could not be read: \(String(describing: error), privacy: .public)")
    }
}
