import Foundation
import UniformTypeIdentifiers

enum IPhoneStoredFileTypeFilter: String, CaseIterable, Identifiable {
    case all = "전체"
    case photos = "사진"
    case videos = "동영상"
    case documents = "문서"
    case zip = "ZIP"
    case other = "기타"

    var id: String { rawValue }

    func includes(_ name: String) -> Bool {
        self == .all || self == Self.classify(name)
    }

    private static func classify(_ name: String) -> Self {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "zip" { return .zip }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .photos }
            if type.conforms(to: .movie) { return .videos }
            if type.conforms(to: .text) || type.conforms(to: .pdf) { return .documents }
        }
        if ["hwp", "hwpx", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "csv", "txt"].contains(ext) {
            return .documents
        }
        return .other
    }
}
