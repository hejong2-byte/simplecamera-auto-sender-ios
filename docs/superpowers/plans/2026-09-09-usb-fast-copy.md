# USB copy with optional verification

User-approved flow: CRC-checked extraction on iPhone, USB write and size checks, copy complete with original ZIP retained, optional separate SHA verification. Temporary extracted files are removed. No USB readback failure may delete a completed copy. No changes to network-download verification or receipt protocol.

1. Change existing export progress tests to reject compulsory SHA phases. Run these against the old implementation in CI and confirm assertion failures.
2. Remove the two ZIP SHA passes and compulsory destination readback from IPhoneUSBExportService. Retain bounded-memory copying, hashing the already-read copy buffers for an optional manifest without additional reads. Close writes and check sizes; persist a manifest associated with the destination volume. Preserve original ZIP and clean temporary extraction.
3. Add explicit verification of the saved manifest, with separate progress/results, no copy or deletion, and path/volume guards. Retain legacy deletion records compatibility. New copies do not prompt deletion.
4. Add a USB SHA verification button for selected stored originals. Busy state must exclude concurrent copy, deletion, folder selection, and verification. Error details retain stage, filename, Cocoa/POSIX underlying code.
5. Add tests for optional verification success, tampering, missing/wrong USB, original and USB preservation on read errors, manifest reopen, CRC failure, and temporary cleanup. Run simulator tests and IPA build; inspect generated version and QR before delivery. Do not claim a physical USB test.
