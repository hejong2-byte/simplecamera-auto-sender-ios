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


if __name__ == '__main__':
    unittest.main()
