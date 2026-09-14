"""Local wiring checks; simulator tests exercise the Swift behavior separately."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class USBBackgroundContract(unittest.TestCase):
    maxDiff = 200
    def test_export_progress_has_disk_checkpoint_in_production(self):
        source = (ROOT / 'App/Application/USBReceiverDependencies.swift').read_text(encoding='utf-8')
        self.assertTrue('usb-export-progress.json' in source, 'Export checkpoint is not wired')

    def test_copy_has_background_budget_handler(self):
        sources = '\n'.join(p.read_text(encoding='utf-8') for p in (ROOT / 'App').rglob('*.swift'))
        self.assertTrue('beginBackgroundTask(withName: "USB copy"' in sources, 'Missing USB background task')
        self.assertTrue('expireUSBCopyBackgroundTime' in sources, 'Missing expiration handler')

    def test_cleanup_availability_does_not_toggle_for_polling(self):
        source = (ROOT / 'App/UI/USBReceiverViewModel.swift').read_text(encoding='utf-8')
        body = source.split('var canCleanTemporaryFiles: Bool {')[1].split('\n    }')[0]
        self.assertNotIn('!isPerformingReceive', body)

    def test_interrupted_copy_has_stable_resume_storage(self):
        service = (ROOT / 'App/Receive/IPhoneUSBExportService.swift').read_text(encoding='utf-8')
        dependencies = (ROOT / 'App/Application/USBReceiverDependencies.swift').read_text(encoding='utf-8')
        self.assertIn('static func resumeIdentifier(', service)
        self.assertIn('resumeBoundaryMatches(', service)
        self.assertIn('resumeAt: resumeOffset', service)
        self.assertIn('preservePartialOnCancellation: true', dependencies)

    def test_foreground_return_requests_automatic_resume(self):
        model = (ROOT / 'App/UI/USBReceiverViewModel.swift').read_text(encoding='utf-8')
        content = (ROOT / 'App/UI/ContentView.swift').read_text(encoding='utf-8')
        self.assertIn('func setAppActive(_ active: Bool)', model)
        self.assertIn('resumeInterruptedUSBExportIfPossible()', model)
        self.assertIn('receiverModel.setAppActive(active)', content)

    def test_normal_zip_commit_does_not_reread_usb_for_sha(self):
        source = (ROOT / 'App/Receive/USBZIPReceivePipeline.swift').read_text(encoding='utf-8')
        commit = source.split('private func performCommit(')[1].split('private func extract(')[0]
        self.assertNotIn('tree(at: partialURL', commit)
        self.assertNotIn('layout(at: destination', commit)
        self.assertNotIn('copyAndHash(', commit)

    def test_transfer_ui_uses_mb_and_minute_second_eta(self):
        source = (ROOT / 'App/UI/USBReceiverViewModel.swift').read_text(encoding='utf-8')
        receive_view = (ROOT / 'App/UI/USBReceiverView.swift').read_text(encoding='utf-8')
        selection = (ROOT / 'App/UI/PendingIncomingSelectionView.swift').read_text(encoding='utf-8')
        self.assertIn('megabyteText(progress.bytesReceived)', source)
        self.assertIn(r'"\(seconds / 60)분 \(seconds % 60)초"', source)
        self.assertIn('format: "%.1fMB"', receive_view)
        self.assertIn('format: "%.1fMB"', selection)


if __name__ == '__main__':
    unittest.main()
