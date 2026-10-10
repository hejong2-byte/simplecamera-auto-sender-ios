import Foundation

enum IPhoneStoredFileTypeFilter: String, CaseIterable, Identifiable {
    case all = "전체"
    case photos = "사진"
    case videos = "동영상"
    case documents = "문서"
    case zip = "ZIP"
    case other = "기타"

    var id: String { rawValue }
}
