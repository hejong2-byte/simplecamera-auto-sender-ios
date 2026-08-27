import Foundation

enum IPhoneReceiveErrorMessage {
    static func message(_ error: Error) -> String {
        let value = error as NSError
        if value.domain == NSURLErrorDomain {
            return "네트워크 오류 · 인터넷 연결을 확인해 주세요. (\(value.code))"
        }
        if value.domain == NSCocoaErrorDomain,
           value.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
            return "저장 공간이 부족합니다."
        }
        switch error {
        case USBReceiveServiceError.missingRegistration,
             IPhoneLocalReceiveError.receiverNotRegistered:
            return "수신 기기를 먼저 등록해 주세요."
        case USBReceiveServiceError.missingDestination:
            return "USB 폴더를 먼저 선택해 주세요."
        case USBReceiveServiceError.staleDestination,
             IPhoneUSBExportError.staleDestination:
            return "USB 폴더 권한이 만료되었습니다. 다시 선택해 주세요."
        case USBReceiveServiceError.destinationChanged,
             IPhoneUSBExportError.destinationChanged:
            return "선택한 USB와 현재 연결된 USB가 다릅니다."
        case USBReceiveServiceError.destinationNotWritable,
             IPhoneUSBExportError.destinationAccessDenied,
             IPhoneUSBExportError.destinationNotWritable:
            return "USB에 쓸 수 없습니다. 연결과 폴더 권한을 확인해 주세요."
        case USBReceiveServiceError.insufficientSpace,
             IPhoneUSBExportError.insufficientSpace:
            return "저장 공간이 부족합니다."
        case USBReceiveServiceError.fat32FileTooLarge:
            return "FAT32 USB에는 4GiB 초과 파일을 저장할 수 없습니다. exFAT을 사용해 주세요."
        case USBReceiveServiceError.shaMismatch,
             USBReceiveServiceError.sizeMismatch,
             IPhoneLocalReceiveError.shaMismatch,
             IPhoneLocalReceiveError.sizeMismatch,
             IPhoneUSBExportError.shaMismatch,
             IPhoneUSBExportError.sizeMismatch:
            return "파일 무결성 검증에 실패했습니다. 원본은 삭제하지 않았습니다."
        case IPhoneLocalReceiveError.finalFileChanged,
             IPhoneUSBExportError.sourceChanged:
            return "원본 파일이 변경되었습니다. 삭제하거나 완료 처리하지 않았습니다."
        case IPhoneUSBExportError.copyFailed:
            return "USB 복사에 실패했습니다. 원본 파일과 USB 연결·폴더 권한을 확인해 주세요."
        case let IPhoneReceiverClientError.server(statusCode, code):
            if statusCode == 401 || statusCode == 403 {
                return "인증 오류 (HTTP \(statusCode)) · 수신 기기 등록과 인증값을 확인해 주세요."
            }
            if statusCode == 410 || code?.lowercased().contains("expired") == true {
                return "서버 보관 기한이 만료되었습니다. PC에서 다시 보내 주세요."
            }
            if statusCode == 404 {
                return "서버에서 파일을 찾을 수 없습니다. 보관 기한 만료 또는 삭제 여부를 확인해 주세요."
            }
            return "서버 오류 (HTTP \(statusCode) · \(code ?? "unknown"))"
        case IPhoneReceiverClientError.invalidResponse,
             BackgroundIPhoneReceiveError.invalidResponse:
            return "서버 응답 오류 · 올바른 수신 응답을 받지 못했습니다."
        case is CancellationError:
            return "수신이 일시정지되었습니다."
        default:
            return "수신하지 못했습니다. 네트워크와 저장 위치를 확인해 주세요."
        }
    }
}
