import ClipboardBridge
import FileTransferStaging
import Foundation

public enum RDPClipboardDiagnostics {
    public static func reason(for error: Error) -> String {
        switch error {
        case FileTransferStagingError.unableToCreateRemoteDropFile(_, let errno):
            return "reason=staging-create errno=\(errno)"
        case FileTransferStagingError.unableToCreateStagingDirectory:
            return "reason=staging-directory"
        case FileTransferStagingError.sourceDoesNotExist:
            return "reason=source-unavailable"
        case FileTransferStagingError.unableToReadFileSize:
            return "reason=source-metadata"
        case FileTransferStagingError.unsafeRemoteFileName:
            return "reason=unsafe-name"
        case is CancellationError:
            return "reason=cancelled"
        case RDPRemoteFileDownloadManager.ChunkError.truncated:
            return "reason=truncated"
        case RDPRemoteFileDownloadManager.ChunkError.overlong:
            return "reason=overlong"
        case RDPSessionError.bridgeRejectedOperation(let status),
             ClipboardBridgeError.bridgeRejectedOperation(let status):
            return "reason=bridge-rejected status=\(status)"
        default:
            return "reason=unknown"
        }
    }

    public static func omissionMessage(count: Int) -> String {
        "심볼릭 링크 또는 전송할 수 없는 항목 \(count)개를 제외했습니다."
    }
}
