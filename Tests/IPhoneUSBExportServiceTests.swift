import CryptoKit
import Foundation
import XCTest
import ZIPFoundation
@testable import SimpleCameraAutoSender

final class IPhoneUSBExportServiceTests: XCTestCase {
    func testNestedArchiveAndSDCardWrappersAreRemovedFromUSBRoot() async throws {
        let context = try makeContext()
        let fixture = temporaryDirectory()
        let archiveName = "싼타페_V11_전체본_SD카드용"
        let map = fixture
            .appendingPathComponent(archiveName)
            .appendingPathComponent("SD_CARD_ROOT")
            .appendingPathComponent("MAP")
        try FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        try Data("navigation".utf8).write(to: map.appendingPathComponent("data.bin"))
        let zip = context.sourceDirectory.appendingPathComponent("fixture.zip")
        try FileManager.default.zipItem(at: fixture, to: zip, shouldKeepParent: false)
        let file = try makeStoredFile(
            name: "\(archiveName).zip",
            data: Data(contentsOf: zip),
            in: context.sourceDirectory
        )

        let result = await context.service.export([file], to: context.destination)

        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent("MAP/data.bin")),
            Data("navigation".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent(archiveName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent("SD_CARD_ROOT").path))
    }

    func testRootPackagingFolderIsRemovedButNavigationFoldersArePreserved() async throws {
        let context = try makeContext()
        let fixture = temporaryDirectory()
        let map = fixture.appendingPathComponent("ROOT/MAP")
        try FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        try Data("navigation".utf8).write(to: map.appendingPathComponent("data.bin"))
        let zip = context.sourceDirectory.appendingPathComponent("fixture.zip")
        try FileManager.default.zipItem(at: fixture, to: zip, shouldKeepParent: false)
        let file = try makeStoredFile(name: "navigation.zip", data: Data(contentsOf: zip), in: context.sourceDirectory)

        let result = await context.service.export([file], to: context.destination)

        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent("MAP/data.bin")),
            Data("navigation".utf8)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent("ROOT").path))
    }

    func testSDCardArchivePlacesActualContentsAtUSBRootWithoutEitherWrapper() async throws {
        let context = try makeContext()
        let fixture = temporaryDirectory()
        let sdRoot = fixture.appendingPathComponent("SD_CARD_ROOT")
        for name in ["_bin", "ASR_DB", "MAP", "swversion", "update_loading"] {
            let folder = sdRoot.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: folder.appendingPathComponent("data.bin"))
        }
        let zip = context.sourceDirectory.appendingPathComponent("nav.zip")
        try FileManager.default.zipItem(at: fixture, to: zip, shouldKeepParent: false)
        let file = try makeStoredFile(name: "싼타페.zip", data: Data(contentsOf: zip), in: context.sourceDirectory)
        let result = await context.service.export([file], to: context.destination)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.verified.first?.usbStoredName, "")
        for name in ["_bin", "ASR_DB", "MAP", "swversion", "update_loading"] {
            XCTAssertEqual(try Data(contentsOf: context.usbDirectory.appendingPathComponent(name).appendingPathComponent("data.bin")), Data(name.utf8))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent("싼타페").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent("SD_CARD_ROOT").path))
        let verified = await context.service.verifyCopies([file], to: context.destination)
        XCTAssertTrue(verified.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testSDCardRootIsRemovedWhenManifestFilesExistBesideIt() async throws {
        let context = try makeContext()
        let fixture = temporaryDirectory()
        let map = fixture.appendingPathComponent("SD_CARD_ROOT/MAP")
        try FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        try Data("navigation".utf8).write(to: map.appendingPathComponent("MAP.spd.000"))
        try Data("manifest".utf8).write(to: fixture.appendingPathComponent("D1_전체파일_명세.json"))
        try Data("readme".utf8).write(to: fixture.appendingPathComponent("먼저읽기_V11_D1_진단용.txt"))
        let zip = context.sourceDirectory.appendingPathComponent("mixed-root.zip")
        try FileManager.default.zipItem(at: fixture, to: zip, shouldKeepParent: false)
        let file = try makeStoredFile(name: "싼타페.zip", data: Data(contentsOf: zip), in: context.sourceDirectory)

        let result = await context.service.export([file], to: context.destination)

        XCTAssertTrue(result.failed.isEmpty, result.errorMessage ?? "mixed-root ZIP export failed")
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent("MAP/MAP.spd.000")),
            Data("navigation".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent("D1_전체파일_명세.json")),
            Data("manifest".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent("먼저읽기_V11_D1_진단용.txt")),
            Data("readme".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: context.usbDirectory.appendingPathComponent("SD_CARD_ROOT").path
            )
        )
    }

    func testRootExportConflictOverwritesFilesAndMergesExistingNavigationFolder() async throws {
        let context = try makeContext()
        let fixture = temporaryDirectory()
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("MAP"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: fixture.appendingPathComponent("MAP/data.bin"))
        let zip = context.sourceDirectory.appendingPathComponent("nav.zip")
        try FileManager.default.zipItem(at: fixture, to: zip, shouldKeepParent: false)
        let file = try makeStoredFile(name: "received.zip", data: Data(contentsOf: zip), in: context.sourceDirectory)
        try FileManager.default.createDirectory(at: context.usbDirectory.appendingPathComponent("MAP"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: context.usbDirectory.appendingPathComponent("MAP/data.bin"))
        try Data("keep".utf8).write(to: context.usbDirectory.appendingPathComponent("MAP/keep.bin"))
        let first = await context.service.export([file], to: context.destination)
        XCTAssertEqual(first.failed.map(\.error), [.overwriteConfirmationRequired])
        XCTAssertEqual(try Data(contentsOf: context.usbDirectory.appendingPathComponent("MAP/data.bin")), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: context.usbDirectory.appendingPathComponent("MAP/keep.bin")), Data("keep".utf8))

        let result = await context.service.export(
            [file],
            to: context.destination,
            overwriteExisting: true
        )
        XCTAssertTrue(result.failed.isEmpty, result.errorMessage ?? "ZIP overwrite failed")
        XCTAssertEqual(result.verified.count, 1)
        XCTAssertEqual(try Data(contentsOf: context.usbDirectory.appendingPathComponent("MAP/data.bin")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: context.usbDirectory.appendingPathComponent("MAP/keep.bin")), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent("received").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testCancelAfterUSBDisappearsReportsUnconfirmedCleanupAndPreservesSource() async throws {
        let context = try makeContext(fileManager: DisconnectDuringCopyFileManager())
        let file = try makeStoredFile(name: "keep.bin", data: Data("original".utf8), in: context.sourceDirectory)
        let task = Task { await context.service.export([file], to: context.destination) }
        let result = await task.value
        XCTAssertTrue(result.cancelled)
        XCTAssertNotNil(result.cleanupWarning, "An unavailable SD must not be reported as successfully cleaned")
        XCTAssertEqual(try Data(contentsOf: file.url), Data("original".utf8))
    }

    func testZIPCopyAfterSDDeletionCoordinatesProviderWrites() async throws {
        let provider = CoordinationRequiredFileManager()
        let context = try makeContext(fileManager: provider, coordinateWrite: { url, body in
            provider.coordinating = true
            defer { provider.coordinating = false }
            try body(url)
        })
        let archiveData = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIANJIKF03rc1dEwAAAAsAAAAPAAAAZG9jcy9yZXBvcnQudHh0KkotyC8q0U1JLEkEAAAA//8DAFBLAwQUAAAACADSSChd+/k8aREAAAAJAAAACAAAAHJvb3QudHh0KsrPL9FNSSxJBAAAAP//AwBQSwECFAAUAAAACADSSChdN63NXRMAAAALAAAADwAAAAAAAAAAAAAAAAAAAAAAZG9jcy9yZXBvcnQudHh0UEsBAhQAFAAAAAgA0kgoXfv5PGkRAAAACQAAAAgAAAAAAAAAAAAAAAAAQAAAAHJvb3QudHh0UEsFBgAAAAACAAIAcwAAAHcAAAAAAA=="))
        let file = try makeStoredFile(name: "after-delete.zip", data: archiveData, in: context.sourceDirectory)
        try Data("old".utf8).write(to: context.usbDirectory.appendingPathComponent("old.txt"))
        let cleanup = USBFolderCleanupService(volumeIdentity: { _ in "volume-1" },
            startAccessing: { _ in true }, stopAccessing: { _ in })
        let before = try await cleanup.inspect(context.destination)
        let removed = try await cleanup.deleteAllContents(of: context.destination, matching: before)
        XCTAssertEqual(removed.remainingItemCount, 0)
        let result = await context.service.export([file], to: context.destination)
        XCTAssertTrue(result.failed.isEmpty, "Provider writes must be coordinated after deleting SD contents")
        let copy = try XCTUnwrap(result.verified.first)
        XCTAssertEqual(try Data(contentsOf: context.usbDirectory.appendingPathComponent(copy.usbStoredName).appendingPathComponent("docs/report.txt")), Data("report-data".utf8))
        XCTAssertEqual(try Data(contentsOf: file.url), archiveData)
    }

    func testDeleteThenExtract474FoldersAndCopy6683Files() async throws {
        let context = try makeContext()
        let fixture = temporaryDirectory()
        for index in 0..<474 {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(String(format: "%05d", index)), withIntermediateDirectories: true)
        }
        for index in 0..<6683 {
            try autoreleasepool {
                let url = fixture.appendingPathComponent(String(format: "%05d/file-%05d.bin", index % 474, index))
                try Data(repeating: UInt8(index % 251), count: 64).write(to: url)
            }
        }
        let zip = context.sourceDirectory.appendingPathComponent("many-files.zip")
        try FileManager.default.zipItem(at: fixture, to: zip, shouldKeepParent: false)
        let file = try makeStoredFile(name: "received.zip", data: Data(contentsOf: zip), in: context.sourceDirectory)
        try Data([1]).write(to: context.usbDirectory.appendingPathComponent("old.bin"))
        let cleanup = USBFolderCleanupService(volumeIdentity: { _ in "volume-1" }, startAccessing: { _ in true }, stopAccessing: { _ in })
        let before = try await cleanup.inspect(context.destination)
        _ = try await cleanup.deleteAllContents(of: context.destination, matching: before)
        let result = await context.service.export([file], to: context.destination)
        XCTAssertTrue(result.failed.isEmpty)
        let copy = try XCTUnwrap(result.verified.first)
        XCTAssertEqual(copy.copiedFiles?.count, 6683)
        let last = context.usbDirectory.appendingPathComponent(copy.usbStoredName).appendingPathComponent(String(format: "%05d/file-%05d.bin", 6682 % 474, 6682))
        XCTAssertEqual(try Data(contentsOf: last), Data(repeating: UInt8(6682 % 251), count: 64))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path).isEmpty)
    }

    func testManualCleanupRemovesLegacyExportTempsOnlyAndCanBeRepeated() async throws {
        let context = try makeContext()
        let localTemp = context.zipWorkingDirectory.appendingPathComponent("extract-\(UUID().uuidString.lowercased())")
        let partialRoot = context.usbDirectory.appendingPathComponent(IPhoneUSBExportService.partialDirectoryName)
        let usbTemp = partialRoot.appendingPathComponent("export-\(UUID().uuidString.lowercased()).partial")
        let unrelated = partialRoot.appendingPathComponent("network-download.partial")
        let completed = context.usbDirectory.appendingPathComponent("completed.txt")
        let original = try makeStoredFile(name: "original.zip", data: Data("source".utf8), in: context.sourceDirectory)
        for folder in [localTemp, usbTemp] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("temp".utf8).write(to: folder.appendingPathComponent("piece.bin"))
        }
        try Data("network".utf8).write(to: unrelated)
        try Data("complete".utf8).write(to: completed)
        let summary = await context.service.cleanupTemporaryFiles(to: context.destination)
        XCTAssertEqual(summary.deletedCount, 2)
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertTrue(summary.usbChecked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: localTemp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: usbTemp.path))
        XCTAssertEqual(try Data(contentsOf: original.url), Data("source".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("network".utf8))
        XCTAssertEqual(try Data(contentsOf: completed), Data("complete".utf8))
        let repeated = await context.service.cleanupTemporaryFiles(to: context.destination)
        XCTAssertEqual(repeated.deletedCount, 0)
        XCTAssertTrue(repeated.failures.isEmpty)
    }

    func testManualCleanupWithoutUSBStillCleansLocalTempsAndDoesNotFollowSymlink() async throws {
        let context = try makeContext()
        let localTemp = context.zipWorkingDirectory.appendingPathComponent("extract-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: localTemp, withIntermediateDirectories: true)
        let outside = try makeStoredFile(name: "keep.zip", data: Data("keep".utf8), in: context.sourceDirectory)
        let link = context.zipWorkingDirectory.appendingPathComponent("extract-\(UUID().uuidString.lowercased())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: context.sourceDirectory)
        let summary = await context.service.cleanupTemporaryFiles(to: nil)
        XCTAssertFalse(summary.usbChecked)
        XCTAssertEqual(summary.deletedCount, 1)
        XCTAssertFalse(summary.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside.url), Data("keep".utf8))
    }
    func testCancelledExportDoesNotCopyOrOfferOriginalDeletion() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(name: "keep.bin", data: Data("keep-original".utf8), in: context.sourceDirectory)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await context.service.export([file], to: context.destination)
        }
        let summary = await task.value
        XCTAssertTrue(summary.verified.isEmpty, "Canceled copy must not complete a USB file")
        XCTAssertTrue(context.deletionStore.pending().isEmpty, "Cancel must never offer source deletion")
        XCTAssertEqual(try Data(contentsOf: file.url), Data("keep-original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent(file.name).path))
    }

    func testCancelDuringZIPCopyCleansExtractionAndUSBPartialButKeepsOriginal() async throws {
        let context = try makeContext(fileManager: CancelWhenExportPartialCreatedFileManager())
        let data = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIANJIKF03rc1dEwAAAAsAAAAPAAAAZG9jcy9yZXBvcnQudHh0KkotyC8q0U1JLEkEAAAA//8DAFBLAwQUAAAACADSSChd+/k8aREAAAAJAAAACAAAAHJvb3QudHh0KsrPL9FNSSxJBAAAAP//AwBQSwECFAAUAAAACADSSChdN63NXRMAAAALAAAADwAAAAAAAAAAAAAAAAAAAAAAZG9jcy9yZXBvcnQudHh0UEsBAhQAFAAAAAgA0kgoXfv5PGkRAAAACQAAAAgAAAAAAAAAAAAAAAAAQAAAAHJvb3QudHh0UEsFBgAAAAACAAIAcwAAAHcAAAAAAA=="))
        let file = try makeStoredFile(name: "cancel.zip", data: data, in: context.sourceDirectory)
        let existing = context.usbDirectory.appendingPathComponent("existing.txt")
        try Data("existing".utf8).write(to: existing)
        let task = Task { await context.service.export([file], to: context.destination) }
        let summary = await task.value
        XCTAssertTrue(summary.verified.isEmpty, "Cancellation during ZIP copying must stop before final rename")
        XCTAssertTrue(context.deletionStore.pending().isEmpty)
        XCTAssertEqual(try Data(contentsOf: file.url), data)
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path), [])
        let partials = context.usbDirectory.appendingPathComponent(IPhoneUSBExportService.partialDirectoryName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: partials.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent("cancel").path))
    }

    func testInterruptedSingleFileContinuesFromStableUSBPartial() async throws {
        let context = try makeContext()
        let payload = Data(repeating: 0x4d, count: 3 * 1_024 * 1_024 + 41)
        let file = try makeStoredFile(name: "resume-large.bin", data: payload, in: context.sourceDirectory)
        let modifiedAt = try XCTUnwrap(
            file.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        )
        let identifier = IPhoneUSBExportService.resumeIdentifier(
            for: file,
            destination: context.destination,
            archiveMode: .keepArchive,
            sourceSize: Int64(payload.count),
            sourceModifiedAt: modifiedAt
        )
        let partialDirectory = context.usbDirectory.appendingPathComponent(
            IPhoneUSBExportService.partialDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        let partialURL = partialDirectory.appendingPathComponent("export-\(identifier.uuidString.lowercased()).partial")
        let alreadyCopied = 1_024 * 1_024 + 19
        try payload.prefix(alreadyCopied).write(to: partialURL)
        let updates = context.progressStore.updates()

        let summary = await context.service.export(
            [file],
            to: context.destination,
            archiveMode: .keepArchive,
            preservePartialOnCancellation: true
        )
        context.progressStore.publishFailure("end-resume-test")
        var reported: [USBReceiveProgress] = []
        for await progress in updates {
            if progress.errorMessage == "end-resume-test" { break }
            reported.append(progress)
        }

        XCTAssertTrue(summary.failed.isEmpty, summary.errorMessage ?? "resume export failed without detail")
        XCTAssertEqual(summary.verified.count, 1)
        XCTAssertTrue(reported.contains {
            $0.stage == .copyingToUSB
                && $0.bytesReceived >= Int64(alreadyCopied)
                && $0.detail?.contains("이어받기") == true
        })
        let storedName = try XCTUnwrap(summary.verified.first?.usbStoredName)
        XCTAssertEqual(try Data(contentsOf: context.usbDirectory.appendingPathComponent(storedName)), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
    }

    func testInterruptedZIPUSBStageReusesExtractionAndPartialOnRetry() async throws {
        let fileManager = CancelOnlyFirstExportFileFileManager()
        let context = try makeContext(fileManager: fileManager)
        let archiveData = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAIANJIKF03rc1dEwAAAAsAAAAPAAAAZG9jcy9yZXBvcnQudHh0KkotyC8q0U1JLEkEAAAA//8DAFBLAwQUAAAACADSSChd+/k8aREAAAAJAAAACAAAAHJvb3QudHh0KsrPL9FNSSxJBAAAAP//AwBQSwECFAAUAAAACADSSChdN63NXRMAAAALAAAADwAAAAAAAAAAAAAAAAAAAAAAZG9jcy9yZXBvcnQudHh0UEsBAhQAFAAAAAgA0kgoXfv5PGkRAAAACQAAAAgAAAAAAAAAAAAAAAAAQAAAAHJvb3QudHh0UEsFBgAAAAACAAIAcwAAAHcAAAAAAA=="))
        let file = try makeStoredFile(name: "resume.zip", data: archiveData, in: context.sourceDirectory)

        let first = await Task {
            await context.service.export(
                [file],
                to: context.destination,
                preservePartialOnCancellation: true
            )
        }.value
        XCTAssertTrue(first.cancelled)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path).isEmpty)
        let partialRoot = context.usbDirectory.appendingPathComponent(IPhoneUSBExportService.partialDirectoryName)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: partialRoot.path).isEmpty)

        let updates = context.progressStore.updates()
        let second = await context.service.export(
            [file],
            to: context.destination,
            preservePartialOnCancellation: true
        )
        context.progressStore.publishFailure("end-zip-resume-test")
        var reported: [USBReceiveProgress] = []
        for await progress in updates {
            if progress.errorMessage == "end-zip-resume-test" { break }
            reported.append(progress)
        }

        XCTAssertTrue(second.failed.isEmpty, second.errorMessage ?? "ZIP resume export failed without detail")
        XCTAssertEqual(second.verified.count, 1)
        XCTAssertFalse(reported.contains { $0.stage == .extracting }, "Completed local extraction must be reused")
        XCTAssertTrue(reported.contains { $0.detail?.contains("이어받기 위치 확인 완료") == true })
        XCTAssertTrue(reported.contains { $0.detail?.contains("이어받기") == true })
        XCTAssertEqual(try Data(contentsOf: context.usbDirectory.appendingPathComponent("docs/report.txt")), Data("report-data".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path), [])
    }

    func testInterruptedZIPFinalizationResumesAfterOneRootItemWasAlreadyMoved() async throws {
        let fileManager = CancelAfterFirstRootMoveFileManager()
        let context = try makeContext(fileManager: fileManager)
        let fixture = temporaryDirectory()
        let map = fixture.appendingPathComponent("MAP", isDirectory: true)
        let binary = fixture.appendingPathComponent("_bin", isDirectory: true)
        try FileManager.default.createDirectory(at: map, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
        try Data("map".utf8).write(to: map.appendingPathComponent("map.dat"))
        try Data("binary".utf8).write(to: binary.appendingPathComponent("engine.bin"))
        let zip = context.sourceDirectory.appendingPathComponent("navigation-source.zip")
        try FileManager.default.zipItem(at: fixture, to: zip, shouldKeepParent: false)
        let file = try makeStoredFile(
            name: "navigation.zip",
            data: Data(contentsOf: zip),
            in: context.sourceDirectory
        )

        let first = await Task {
            await context.service.export(
                [file],
                to: context.destination,
                preservePartialOnCancellation: true
            )
        }.value
        XCTAssertTrue(first.cancelled)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent("MAP").path)
                || FileManager.default.fileExists(atPath: context.usbDirectory.appendingPathComponent("_bin").path)
        )

        let resumed = await context.service.export(
            [file],
            to: context.destination,
            preservePartialOnCancellation: true
        )

        XCTAssertTrue(resumed.failed.isEmpty, resumed.errorMessage ?? "finalization resume failed")
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent("MAP/map.dat")),
            Data("map".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent("_bin/engine.bin")),
            Data("binary".utf8)
        )
    }
    func testOptionalVerificationDetectsTamperingWithoutDeletingEitherCopy() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(name: "optional.bin", data: Data("original".utf8), in: context.sourceDirectory)
        let copied = await context.service.export([file], to: context.destination)
        let decision = try XCTUnwrap(copied.verified.first)
        let target = context.usbDirectory.appendingPathComponent(decision.usbStoredName)
        try await context.service.keep(decisionIDs: [decision.id])
        let checked = await context.service.verifyCopies([file], to: context.destination)
        XCTAssertEqual(checked.failed, [])
        XCTAssertEqual(checked.verified.count, 1)
        try Data("tampered".utf8).write(to: target)
        let failed = await context.service.verifyCopies([file], to: context.destination)
        XCTAssertEqual(failed.failed.map(\.error), [.shaMismatch])
        XCTAssertEqual(try Data(contentsOf: target), Data("tampered".utf8))
        XCTAssertEqual(try Data(contentsOf: file.url), Data("original".utf8))
    }

    func testOptionalVerificationReadFailureDoesNotDeleteCopiedFolderOrOriginal() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(name: "read-error.bin", data: Data("original".utf8), in: context.sourceDirectory)
        let copied = await context.service.export([file], to: context.destination)
        let decision = try XCTUnwrap(copied.verified.first)
        let target = context.usbDirectory.appendingPathComponent(decision.usbStoredName)
        // Replace with a directory: the read/type check must fail, without cleanup of user data.
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let result = await context.service.verifyCopies([file], to: context.destination)
        XCTAssertEqual(result.failed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testVerificationManifestSurvivesStoreReopenAndKeepOriginalDecision() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(name: "retained.txt", data: Data("data".utf8), in: context.sourceDirectory)
        let copied = await context.service.export([file], to: context.destination)
        let decision = try XCTUnwrap(copied.verified.first)
        try await context.service.keep(decisionIDs: [decision.id])
        let reopened = try IPhoneUSBDeletionDecisionStore(fileURL: context.sourceDirectory.deletingLastPathComponent().appendingPathComponent("decisions.json"))
        XCTAssertTrue(reopened.pending().isEmpty)
        XCTAssertEqual(reopened.copies().first?.copiedFiles?.first?.size, 4)
    }

    func testOptionalVerificationRejectsWrongUSBWithoutTouchingOriginal() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(name: "guard.txt", data: Data("data".utf8), in: context.sourceDirectory)
        _ = await context.service.export([file], to: context.destination)
        let wrong = USBBookmarkDestination(url: context.usbDirectory, volumeID: "other", displayName: "wrong", isStale: false)
        let result = await context.service.verifyCopies([file], to: wrong)
        XCTAssertEqual(result.failed.map(\.error), [.destinationChanged])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testVerifiedCompletionShowsCopiedBytesInsteadOfZeroOfZero() async throws {
        let context = try makeContext()
        let payload = Data(repeating: 0x5a, count: 2 * 1_024 * 1_024 + 17)
        let file = try makeStoredFile(
            name: "large-test.bin",
            data: payload,
            in: context.sourceDirectory
        )
        let updates = context.progressStore.updates()

        let summary = await context.service.export([file], to: context.destination)
        var latest = context.progressStore.updates().makeAsyncIterator()
        let completion = await latest.next()

        XCTAssertEqual(summary.failed, [])
        XCTAssertEqual(completion?.stage, .completed)
        XCTAssertEqual(completion?.completedCount, 1)
        XCTAssertEqual(completion?.bytesReceived, Int64(payload.count))
        XCTAssertEqual(completion?.totalBytes, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: file.url), payload)

        context.progressStore.publishFailure("end-of-test")
        var stages: [USBReceiveStage] = []
        var startTimes: Set<Date> = []
        for await progress in updates {
            if progress.errorMessage == "end-of-test" { break }
            stages.append(progress.stage)
            if let startedAt = progress.startedAt { startTimes.insert(startedAt) }
        }
        XCTAssertTrue(stages.contains(.copyingToUSB))
        XCTAssertFalse(stages.contains(.verifying), "Default copy must finish without rereading the USB for SHA")
        XCTAssertEqual(startTimes.count, 1)
    }

    func testPathBackedDestinationWithoutVolumeMetadataCanCopyAndKeepsOriginal() async throws {
        let context = try makeContext(
            volumeIdentity: { _ in nil },
            destinationVolumeID: nil
        )
        let payload = Data("original-local-file".utf8)
        let file = try makeStoredFile(
            name: "local.bin",
            data: payload,
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.failed, [])
        XCTAssertEqual(summary.verified.map(\.sourceID), [file.id])
        XCTAssertEqual(try Data(contentsOf: file.url), payload)
        if let storedName = summary.verified.first?.usbStoredName {
            XCTAssertEqual(
                try Data(contentsOf: context.usbDirectory.appendingPathComponent(storedName)),
                payload
            )
        }
    }

    func testZIPExportExtractsIntoUSBRootKeepsOriginalAndCleansWorkingFiles() async throws {
        let context = try makeContext()
        let archiveData = try XCTUnwrap(Data(base64Encoded:
            "UEsDBBQAAAAIANJIKF03rc1dEwAAAAsAAAAPAAAAZG9jcy9yZXBvcnQudHh0KkotyC8q0U1JLEkEAAAA//8DAFBLAwQUAAAACADSSChd+/k8aREAAAAJAAAACAAAAHJvb3QudHh0KsrPL9FNSSxJBAAAAP//AwBQSwECFAAUAAAACADSSChdN63NXRMAAAALAAAADwAAAAAAAAAAAAAAAAAAAAAAZG9jcy9yZXBvcnQudHh0UEsBAhQAFAAAAAgA0kgoXfv5PGkRAAAACQAAAAgAAAAAAAAAAAAAAAAAQAAAAHJvb3QudHh0UEsFBgAAAAACAAIAcwAAAHcAAAAAAA=="
        ))
        let file = try makeStoredFile(
            name: "업무자료.ZIP",
            data: archiveData,
            in: context.sourceDirectory
        )

        let progressUpdates = context.progressStore.updates()
        let summary = await context.service.export([file], to: context.destination)
        context.progressStore.publishFailure("end-zip-progress-test")
        var reported: [USBReceiveProgress] = []
        for await progress in progressUpdates {
            if progress.errorMessage == "end-zip-progress-test" { break }
            reported.append(progress)
        }
        XCTAssertTrue(reported.contains { $0.stage == .extracting && $0.totalBytes > 0 })
        XCTAssertFalse(reported.contains { $0.stage == .verifying || $0.stage == .checkingSource }, "Default ZIP export must not perform full SHA passes")
        XCTAssertEqual(reported.last(where: { $0.stage == .completed })?.bytesReceived, 20)
        XCTAssertEqual(reported.last(where: { $0.stage == .completed })?.totalBytes, 20)

        XCTAssertEqual(summary.failed, [])
        let decision = try XCTUnwrap(summary.verified.first)
        XCTAssertEqual(decision.sourceID, file.id)
        XCTAssertEqual(decision.usbStoredName, "")
        XCTAssertEqual(try Data(contentsOf: file.url), archiveData, "The received ZIP must remain unchanged")
        let exportedFolder = context.usbDirectory.appendingPathComponent(decision.usbStoredName)
        XCTAssertEqual(
            try Data(contentsOf: exportedFolder.appendingPathComponent("docs/report.txt")),
            Data("report-data".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: exportedFolder.appendingPathComponent("root.txt")),
            Data("root-data".utf8)
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path),
            [],
            "Temporary extracted files must be removed after verified USB copy"
        )
        let verification = await context.service.verifyCopies([file], to: context.destination)
        XCTAssertTrue(verification.failed.isEmpty)
        XCTAssertEqual(verification.verified.count, 1)
    }

    func testZIPExportCanKeepTheArchiveWithoutExtractingIt() async throws {
        let context = try makeContext()
        let archiveData = Data("stored-zip-byte-for-byte".utf8)
        let file = try makeStoredFile(
            name: "업무자료.zip",
            data: archiveData,
            in: context.sourceDirectory
        )

        let summary = await context.service.export(
            [file],
            to: context.destination,
            archiveMode: .keepArchive
        )

        XCTAssertEqual(summary.failed, [])
        let decision = try XCTUnwrap(summary.verified.first)
        XCTAssertEqual(decision.usbStoredName, "업무자료.zip")
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent("업무자료.zip")),
            archiveData
        )
        XCTAssertEqual(try Data(contentsOf: file.url), archiveData)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path),
            []
        )
    }

    func testUnsafeZIPPathFailsWithoutLeavingUSBOrWorkingFiles() async throws {
        let context = try makeContext()
        let archiveData = try XCTUnwrap(Data(base64Encoded:
            "UEsDBBQAAAAIANJIKF1Oa16IFQAAAA0AAAAQAAAALi4vLi4vZXNjYXBlLnR4dErJ183LL9FNLU5OLEgFAAAA//8DAFBLAQIUABQAAAAIANJIKF1Oa16IFQAAAA0AAAAQAAAAAAAAAAAAAAAAAAAAAAAuLi8uLi9lc2NhcGUudHh0UEsFBgAAAAABAAEAPgAAAEMAAAAAAA=="
        ))
        let file = try makeStoredFile(
            name: "unsafe.zip",
            data: archiveData,
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.verified, [])
        XCTAssertEqual(summary.failed.map(\.error), [.unsafeZIPArchive])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: context.zipWorkingDirectory.deletingLastPathComponent()
                .appendingPathComponent("escape.txt").path
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path), [])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: context.usbDirectory.path)
                .filter { $0 != IPhoneUSBExportService.partialDirectoryName },
            []
        )
    }

    func testCorruptZIPFailsAndCleansTemporaryFilesWithoutDeletingOriginal() async throws {
        let context = try makeContext()
        let archiveData = Data("not-a-zip".utf8)
        let file = try makeStoredFile(
            name: "damaged.zip",
            data: archiveData,
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.verified, [])
        XCTAssertEqual(summary.failed.map(\.error), [.zipExtractionFailed])
        XCTAssertEqual(try Data(contentsOf: file.url), archiveData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: context.zipWorkingDirectory.path), [])
    }

    func testMissingVolumeMetadataDoesNotAcceptDifferentSavedIdentity() async throws {
        let context = try makeContext(volumeIdentity: { _ in nil })
        let file = try makeStoredFile(
            name: "keep.txt",
            data: Data("keep-original".utf8),
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.verified, [])
        XCTAssertEqual(summary.failed.map(\.error), [.destinationChanged])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(context.deletionStore.pending(), [])
    }

    func testAccessFailureReportsTheActualReasonAndFileName() async throws {
        let context = try makeContext(canAccessSecurityScope: false)
        let file = try makeStoredFile(
            name: "cannot-copy.bin",
            data: Data("keep-original".utf8),
            in: context.sourceDirectory
        )

        let summary = await context.service.export([file], to: context.destination)
        var updates = context.progressStore.updates().makeAsyncIterator()
        let progress = await updates.next()

        XCTAssertEqual(summary.failed.map(\.error), [.destinationAccessDenied])
        XCTAssertEqual(progress?.stage, .failed)
        XCTAssertEqual(progress?.fileName, file.name)
        XCTAssertTrue(progress?.errorMessage?.contains("권한") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
    }

    func testUnexpectedFileSystemFailurePreservesDiagnosticCode() async throws {
        let context = try makeContext()
        let file = try makeStoredFile(
            name: "removed-before-copy.txt",
            data: Data("temporary-test-file".utf8),
            in: context.sourceDirectory
        )
        try FileManager.default.removeItem(at: file.url)

        let summary = await context.service.export([file], to: context.destination)
        var updates = context.progressStore.updates().makeAsyncIterator()
        let progress = await updates.next()

        XCTAssertEqual(summary.verified, [])
        XCTAssertEqual(progress?.stage, .failed)
        XCTAssertTrue(progress?.errorMessage?.contains("NSCocoaErrorDomain") == true)
        XCTAssertEqual(context.deletionStore.pending(), [])
    }

    func testExportVerifiesGoodFileRecordsPartialFailureAndLeavesSources() async throws {
        let context = try makeContext()
        let good = try makeStoredFile(
            name: "보고서.hwp",
            data: Data("verified-data".utf8),
            in: context.sourceDirectory
        )
        let bad = try makeStoredFile(
            name: "변경됨.pdf",
            data: Data("changed-data".utf8),
            in: context.sourceDirectory
        )
        try Data("changed-size-after-selection".utf8).write(to: bad.url)
        try Data("existing".utf8).write(
            to: context.usbDirectory.appendingPathComponent(good.name)
        )

        let summary = await context.service.export(
            [good, bad],
            to: context.destination
        )

        XCTAssertEqual(summary.verified.map(\.sourceID), [good.id])
        XCTAssertEqual(summary.failed.map(\.sourceID), [bad.id])
        XCTAssertEqual(context.deletionStore.pending().map(\.sourceID), [good.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: good.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.url.path))
        let storedName = try XCTUnwrap(summary.verified.first?.usbStoredName)
        XCTAssertNotEqual(storedName, good.name)
        XCTAssertEqual(
            try Data(contentsOf: context.usbDirectory.appendingPathComponent(storedName)),
            Data("verified-data".utf8)
        )

        try await context.service.keep(decisionIDs: Set(summary.verified.map(\.id)))
        var updates = context.progressStore.updates().makeAsyncIterator()
        let latest = await updates.next()
        XCTAssertEqual(latest?.stage, .failed, "Keeping good originals must not hide a failed copy")
        XCTAssertNotNil(latest?.errorMessage)
    }

    func testReportedZeroCapacityDoesNotBlockVerifiedCopyToWritableUSB() async throws {
        let fileManager = ZeroCapacityUSBFileManager()
        let context = try makeContext(fileManager: fileManager)
        let payload = Data(repeating: 0x5a, count: 1_024 * 1_024 + 31)
        let file = try makeStoredFile(
            name: "capacity-report.bin",
            data: payload,
            in: context.sourceDirectory
        )
        let reported = try fileManager.attributesOfFileSystem(forPath: context.usbDirectory.path)
        XCTAssertEqual((reported[.systemFreeSize] as? NSNumber)?.int64Value, 0)
        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: context.usbDirectory.path
        )
        let actualFree = try XCTUnwrap(attributes[.systemFreeSize] as? NSNumber)
        XCTAssertGreaterThan(actualFree.int64Value, Int64(payload.count))

        let summary = await context.service.export([file], to: context.destination)

        XCTAssertEqual(summary.failed, [])
        XCTAssertEqual(summary.verified.map(\.sourceID), [file.id])
        XCTAssertEqual(try Data(contentsOf: file.url), payload)
        if let storedName = summary.verified.first?.usbStoredName {
            XCTAssertEqual(
                try Data(contentsOf: context.usbDirectory.appendingPathComponent(storedName)),
                payload
            )
        }
    }

    func testFileSystemDiskFullErrorsStopCopyAndPreserveFiles() async throws {
        let errors = [
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.fileWriteOutOfSpace.rawValue),
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOSPC.rawValue))
        ]
        for error in errors {
            let context = try makeContext(fileManager: DiskFullUSBFileManager(error: error))
            let payload = Data(repeating: 0x3c, count: 1_024 * 1_024 + 31)
            let file = try makeStoredFile(
                name: "keep-original.bin",
                data: payload,
                in: context.sourceDirectory
            )
            let existingURL = context.usbDirectory.appendingPathComponent("existing.txt")
            let existingData = Data("do-not-touch-existing-usb-files".utf8)
            try existingData.write(to: existingURL)

            let summary = await context.service.export([file], to: context.destination)

            XCTAssertEqual(summary.verified, [])
            XCTAssertEqual(summary.failed.map(\.error), [.insufficientSpace], error.domain)
            XCTAssertTrue(summary.errorMessage?.contains("저장 공간") == true, error.domain)
            XCTAssertTrue(summary.errorMessage?.contains(error.domain) == true)
            XCTAssertTrue(summary.errorMessage?.contains(String(error.code)) == true)
            XCTAssertEqual(context.deletionStore.pending(), [])
            XCTAssertEqual(try Data(contentsOf: file.url), payload)
            XCTAssertEqual(try Data(contentsOf: existingURL), existingData)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: context.usbDirectory.appendingPathComponent(file.name).path
            ))
            let partialDirectory = context.usbDirectory.appendingPathComponent(
                IPhoneUSBExportService.partialDirectoryName
            )
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: partialDirectory.path), [])
        }
    }

    func testUSBRemovalStopsLaterFileAndKeepsEverySource() async throws {
        let volume = SequencedVolumeIdentity(values: ["volume-1", "removed"])
        let context = try makeContext(volumeIdentity: { _ in volume.next() })
        let first = try makeStoredFile(
            name: "first.txt",
            data: Data("first".utf8),
            in: context.sourceDirectory
        )
        let second = try makeStoredFile(
            name: "second.txt",
            data: Data("second".utf8),
            in: context.sourceDirectory
        )

        let summary = await context.service.export([first, second], to: context.destination)

        XCTAssertEqual(summary.verified.map(\.sourceID), [first.id])
        XCTAssertEqual(summary.failed.map(\.sourceID), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    func testKeepAndDeleteDecisionsRecheckSourceBeforeDeletion() async throws {
        let context = try makeContext()
        let keepFile = try makeStoredFile(
            name: "keep.txt",
            data: Data("keep".utf8),
            in: context.sourceDirectory
        )
        let deleteFile = try makeStoredFile(
            name: "delete.txt",
            data: Data("delete".utf8),
            in: context.sourceDirectory
        )
        let changedFile = try makeStoredFile(
            name: "changed.txt",
            data: Data("original".utf8),
            in: context.sourceDirectory
        )
        let summary = await context.service.export(
            [keepFile, deleteFile, changedFile],
            to: context.destination
        )
        let decisions = Dictionary(
            uniqueKeysWithValues: summary.verified.map { ($0.sourceID, $0) }
        )

        try await context.service.keep(
            decisionIDs: [try XCTUnwrap(decisions[keepFile.id]?.id)]
        )
        try Data("mutated".utf8).write(to: changedFile.url, options: .atomic)
        let deletion = await context.service.delete(decisionIDs: [
            try XCTUnwrap(decisions[deleteFile.id]?.id),
            try XCTUnwrap(decisions[changedFile.id]?.id)
        ])

        XCTAssertEqual(deletion.deletedSourceIDs, [deleteFile.id])
        XCTAssertEqual(deletion.failed.map(\.sourceID), [changedFile.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: keepFile.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleteFile.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: changedFile.url.path))
        XCTAssertEqual(context.deletionStore.pending().map(\.sourceID), [changedFile.id])
    }

    func testDeletionDecisionsSurviveStoreReopen() async throws {
        let stateURL = temporaryDirectory().appendingPathComponent("decisions.json")
        let store = try IPhoneUSBDeletionDecisionStore(fileURL: stateURL)
        let decision = IPhoneUSBDeletionDecision(
            id: UUID(),
            sourceID: "source",
            sourceURL: URL(fileURLWithPath: "/tmp/source"),
            sourceSize: 0,
            sourceSHA256: sha256(Data()),
            usbStoredName: "empty.bin",
            verifiedAt: Date(timeIntervalSince1970: 123)
        )

        try store.save(decision)
        let reopened = try IPhoneUSBDeletionDecisionStore(fileURL: stateURL)

        XCTAssertEqual(reopened.pending(), [decision])
    }

    func testLegacyDeletionStateWithoutOptionalManifestStillLoads() throws {
        let stateURL = temporaryDirectory().appendingPathComponent("legacy.json")
        let legacy = """
        {"version":1,"decisions":[{"id":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","sourceID":"old","sourceURL":"file:///tmp/old.zip","sourceSize":8,"sourceSHA256":"abc","usbStoredName":"old.zip","verifiedAt":123}]}
        """
        try Data(legacy.utf8).write(to: stateURL)
        let reopened = try IPhoneUSBDeletionDecisionStore(fileURL: stateURL)
        XCTAssertEqual(reopened.pending().count, 1)
        XCTAssertNil(reopened.pending().first?.copiedFiles)
        XCTAssertTrue(reopened.copies().isEmpty)
    }

    private func makeContext(
        fileManager: FileManager = .default,
        volumeIdentity: @escaping @Sendable (URL) throws -> String? = { _ in "volume-1" },
        destinationVolumeID: String? = "volume-1",
        canAccessSecurityScope: Bool = true,
        coordinateWrite: @escaping IPhoneUSBExportService.CoordinateWrite = IPhoneUSBExportService.coordinateWriteSystem
    ) throws -> ExportContext {
        let root = temporaryDirectory()
        let sourceDirectory = root.appendingPathComponent("received", isDirectory: true)
        let usbDirectory = root.appendingPathComponent("usb", isDirectory: true)
        let zipWorkingDirectory = root.appendingPathComponent("zip-work", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usbDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zipWorkingDirectory, withIntermediateDirectories: true)
        let deletionStore = try IPhoneUSBDeletionDecisionStore(
            fileURL: root.appendingPathComponent("decisions.json")
        )
        let progressStore = USBReceiveProgressStore()
        let service = IPhoneUSBExportService(
            deletionStore: deletionStore,
            fileManager: fileManager,
            startAccessing: { _ in canAccessSecurityScope },
            stopAccessing: { _ in },
            volumeIdentity: volumeIdentity,
            progressStore: progressStore,
            zipWorkingDirectory: zipWorkingDirectory,
            now: { Date(timeIntervalSince1970: 456) },
            coordinateWrite: coordinateWrite
        )
        return ExportContext(
            sourceDirectory: sourceDirectory,
            usbDirectory: usbDirectory,
            zipWorkingDirectory: zipWorkingDirectory,
            destination: USBBookmarkDestination(
                url: usbDirectory,
                volumeID: destinationVolumeID ?? usbDirectory.path,
                displayName: "TEST USB",
                isStale: false
            ),
            deletionStore: deletionStore,
            service: service,
            progressStore: progressStore
        )
    }

    private func makeStoredFile(
        name: String,
        data: Data,
        expectedSHA256: String? = nil,
        in directory: URL
    ) throws -> IPhoneStoredFile {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        let record = IPhoneReceivedFileRecord(
            deliveryID: UUID(),
            originalName: name,
            storedName: name,
            size: Int64(data.count),
            sha256: expectedSHA256 ?? sha256(data),
            receivedAt: Date(timeIntervalSince1970: 100)
        )
        return IPhoneStoredFile(
            id: url.standardizedFileURL.path,
            url: url,
            name: name,
            size: Int64(data.count),
            modifiedAt: Date(timeIntervalSince1970: 100),
            receivedRecord: record
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private struct ExportContext {
    let sourceDirectory: URL
    let usbDirectory: URL
    let zipWorkingDirectory: URL
    let destination: USBBookmarkDestination
    let deletionStore: IPhoneUSBDeletionDecisionStore
    let service: IPhoneUSBExportService
    let progressStore: USBReceiveProgressStore
}

private final class CancelWhenExportPartialCreatedFileManager: FileManager, @unchecked Sendable {
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        if path.contains("export-"), path.contains(".partial/") {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return created
    }
}

private final class CancelOnlyFirstExportFileFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var hasCancelled = false

    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        let shouldCancel = lock.withLock { () -> Bool in
            guard !hasCancelled, path.contains("export-"), path.contains(".partial/") else { return false }
            hasCancelled = true
            return true
        }
        if shouldCancel { withUnsafeCurrentTask { $0?.cancel() } }
        return created
    }
}

private final class CancelAfterFirstRootMoveFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var hasCancelled = false

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        let isFinalRootMove = srcURL.path.contains(".partial/")
            && dstURL.deletingLastPathComponent().lastPathComponent == "usb"
        let shouldCancel = lock.withLock { () -> Bool in
            guard isFinalRootMove, !hasCancelled else { return false }
            hasCancelled = true
            return true
        }
        try super.moveItem(at: srcURL, to: dstURL)
        if shouldCancel {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
    }
}

private final class CoordinationRequiredFileManager: FileManager, @unchecked Sendable {
    var coordinating = false
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        if url.path.contains("/usb/"), !coordinating { throw CocoaError(.fileWriteNoPermission) }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        if path.contains("/usb/"), !coordinating { return false }
        return super.createFile(atPath: path, contents: data, attributes: attr)
    }
}

private final class DisconnectDuringCopyFileManager: FileManager, @unchecked Sendable {
    override func createFile(atPath path: String, contents data: Data?, attributes attr: [FileAttributeKey: Any]? = nil) -> Bool {
        let created = super.createFile(atPath: path, contents: data, attributes: attr)
        if path.contains("/usb/"), path.hasSuffix(".partial") {
            let root = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            if root.lastPathComponent == "usb" {
                try? FileManager.default.removeItem(at: root)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        return created
    }
}

private final class ZeroCapacityUSBFileManager: FileManager, @unchecked Sendable {
    override func attributesOfFileSystem(forPath path: String) throws -> [FileAttributeKey: Any] {
        [.systemFreeSize: NSNumber(value: 0)]
    }
}

private final class DiskFullUSBFileManager: FileManager, @unchecked Sendable {
    private let writeError: NSError

    init(error: NSError) {
        self.writeError = error
        super.init()
    }

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.pathExtension == "partial" {
            throw writeError
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

private final class SequencedVolumeIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(values: [String]) { self.values = values }

    func next() -> String? {
        lock.withLock {
            guard !values.isEmpty else { return nil }
            return values.removeFirst()
        }
    }
}
