"""Execute the production SHA loops on macOS with a bounded-memory assertion.

The fixture is a private sparse zero file, never a user's received file.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = [
    "IPhoneLocalReceiveEngine.swift",
    "USBReceiveService.swift",
    "IPhoneUSBExportService.swift",
    "USBZIPReceivePipeline.swift",
]

def hash_method(name, method="hashFile"):
    source = (ROOT / "App" / "Receive" / name).read_text(encoding="utf-8")
    start = source.index("    private func " + method + "(")
    opening = source.index("{", source.index(" throws", start))
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private func " + method, "func " + method, 1)

SWIFT = r'''
import Foundation
import CryptoKit
import Darwin
enum USBReceiveServiceError: Error { case sizeMismatch }

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return UInt64(info.resident_size)
}

let size = Int64(CommandLine.arguments[1])!
let fixture = URL(fileURLWithPath: CommandLine.arguments[2])
let selected = Int(CommandLine.arguments[3])!
FileManager.default.createFile(atPath: fixture.path, contents: nil)
let output = try FileHandle(forWritingTo: fixture)
try output.truncate(atOffset: UInt64(size))
try output.close()
var reference = SHA256()
let zeroChunk = Data(repeating: 0, count: 1_024 * 1_024)
var remaining = size
while remaining > 0 {
    let count = Int(min(remaining, Int64(zeroChunk.count)))
    reference.update(data: zeroChunk.prefix(count))
    remaining -= Int64(count)
}
let expected = reference.finalize().map { String(format: "%02x", $0) }.joined()
var failures = 0
'''

CASES = [(source, "hashFile") for source in SOURCES] + [
    ("IPhoneUSBExportService.swift", "copyAndHash"),
    ("USBZIPReceivePipeline.swift", "copyAndHash"),
    ("USBReceiveService.swift", "hashPrefix"),
]
for index, (source, method) in enumerate(CASES):
    SWIFT += "\nstruct ProductionHash%d {\n" % index
    SWIFT += hash_method(source, method)
    if method == "hashPrefix":
        SWIFT += '\nfunc prefixDigest(_ url: URL, size: Int64) throws -> String { var hasher = SHA256(); try hashPrefix(of: url, length: size, into: &hasher); return Self.hex(hasher.finalize()) }\n'
    SWIFT += '\nstatic func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }\n}\n'
    call = (f"ProductionHash{index}().hashFile(fixture)" if method == "hashFile" else
            f"ProductionHash{index}().copyAndHash(source: fixture, destination: copied, progress: {{ _ in }})")
    if method == "hashPrefix":
        call = f"ProductionHash{index}().prefixDigest(fixture, size: size)"
    SWIFT += f'''
let copied{index} = fixture.appendingPathExtension("copy-{index}")
if selected == {index} {{ try autoreleasepool {{
    let copied = copied{index}
    FileManager.default.createFile(atPath: copied.path, contents: nil)
    let before = residentBytes()
    let started = Date()
    let digest = try {call}
    let after = residentBytes()
    let growth = after > before ? after - before : 0
    let checksumOK = digest == expected
    print("{source}/{method}: bytes=\\(size) memoryGrowth=\\(growth) checksumOK=\\(checksumOK) seconds=\\(Date().timeIntervalSince(started))")
    if !checksumOK || growth > 64 * 1_024 * 1_024 {{ failures += 1 }}
}} }}
'''
SWIFT += "\nexit(failures == 0 ? 0 : 1)\n"

with tempfile.TemporaryDirectory(prefix="simplecam-hash-memory-") as temporary:
    folder = pathlib.Path(temporary)
    swift = folder / "HashMemory.swift"
    swift.write_text(SWIFT, encoding="utf-8")
    binary = folder / "hash-memory"
    subprocess.run(["swiftc", "-O", str(swift), "-o", str(binary)], check=True)
    size = int(sys.argv[1]) if len(sys.argv) > 1 else 256 * 1024 * 1024 + 123
    failures = 0
    for index, (_, method) in enumerate(CASES):
        # Full-size SHA test; the copy probe writes at most 256 MiB of private data.
        case_size = min(size, 256 * 1024 * 1024 + 123) if method == "copyAndHash" else size
        completed = subprocess.run([str(binary), str(case_size), str(folder / "zeros.bin"), str(index)])
        failures += completed.returncode != 0
    sys.exit(1 if failures else 0)
