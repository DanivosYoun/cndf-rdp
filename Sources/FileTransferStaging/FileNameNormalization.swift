import Foundation

public enum FileNameNormalization {
    public static func normalizeForTransfer(_ fileName: String) -> String {
        fileName.precomposedStringWithCanonicalMapping
    }
}
