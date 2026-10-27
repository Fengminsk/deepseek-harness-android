"""Build inputs and final APK bytes cannot silently switch to stale or demo guests."""
import importlib.util
from pathlib import Path
import struct
import unittest
from unittest.mock import patch
import zipfile

from test_linux_vm_candidate import CandidateFixture, candidate

spec = importlib.util.spec_from_file_location('release', Path(__file__).with_name('linux-vm-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(CandidateFixture):
    def setUp(self):
        super().setUp()
        patch.object(release, 'candidate', candidate).start()
        self.directory = self.stage()
        self.digest = candidate.sha256(self.directory / 'candidate.json')
        self.native = self.write('build/libpocket_linux_vm.so', self.elf())

    @staticmethod
    def elf(machine=183, suffix=b'native payload'):
        header = bytearray(64)
        header[:7] = b'\x7fELF\x02\x01\x01'
        struct.pack_into('<HH', header, 16, 3, machine)
        return bytes(header) + suffix

    def prepare(self):
        return release.prepare(self.directory, self.digest, self.root)

    def apk(self, changes=None):
        record = candidate.read_json(self.directory / 'candidate.json')
        files = {'assets/' + name: path.read_bytes()
                 for name, path in release.asset_map(self.directory, record).items()}
        files[release.NATIVE_ENTRY] = self.native.read_bytes()
        files['AndroidManifest.xml'] = b'not interpreted by this focused Linux audit'
        for name, value in (changes or {}).items():
            if value is None:
                files.pop(name)
            else:
                files[name] = value
        path = self.root / 'build/candidate.apk'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, value in files.items():
                archive.writestr(name, value)
        return path

    def verify(self, apk):
        return release.verify_apk(apk, self.directory, self.digest, self.native, self.root)

    def test_prepares_only_exact_images_and_source_records_without_touching_fixture(self):
        fixture = self.root / '.cache/android/linux-vm-assets/linux-vm/bios.bin'
        before = fixture.read_bytes()
        first = self.prepare()
        self.assertEqual(first, self.prepare())
        self.assertEqual(len(first['files']), 7)
        self.assertEqual((Path(first['assets']) / 'linux-vm/disk.bin').read_bytes(), self.image.read_bytes())
        self.assertEqual(fixture.read_bytes(), before)

    def test_selection_rejects_relative_and_demo_paths(self):
        for directory in [Path('.cache/android/linux-vm-candidates/alpine-relative'),
                          self.root / '.cache/android/linux-vm-assets']:
            with self.subTest(directory=directory), self.assertRaisesRegex(ValueError, 'absolute Alpine'):
                release.prepare(directory, self.digest, self.root)

    def test_rejects_replaced_selection_record(self):
        with self.assertRaisesRegex(ValueError, 'changed after build selection'):
            release.prepare(self.directory, '0' * 64, self.root)

    def test_rejects_source_change_after_candidate_staging(self):
        (self.root / 'apps/android/android/app/build.gradle.kts').write_bytes(b'changed build')
        with self.assertRaisesRegex(ValueError, 'missing or stale'):
            self.prepare()

    def test_rejects_unlisted_candidate_asset(self):
        (self.directory / 'assets/linux-vm/old-demo.bin').write_bytes(b'demo')
        with self.assertRaisesRegex(ValueError, 'missing, extra or linked'):
            self.prepare()

    def test_rejects_missing_candidate_disk(self):
        (self.directory / 'assets/linux-vm/disk.bin').unlink()
        with self.assertRaisesRegex(ValueError, 'missing, extra or linked'):
            self.prepare()

    def test_does_not_repair_changed_prepared_assets_silently(self):
        assets = Path(self.prepare()['assets'])
        (assets / 'linux-vm/disk.bin').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'Artifact bytes differ'):
            self.prepare()
        previous = self.directory
        self.directory = self.stage()
        fresh = Path(self.prepare()['assets'])
        self.assertNotEqual(self.directory, previous)
        self.assertNotEqual(fresh, assets)
        self.assertEqual((assets / 'linux-vm/disk.bin').read_bytes(), b'changed')

    def test_apk_audit_binds_disk_source_archive_and_compiled_library(self):
        result = self.verify(self.apk())
        self.assertTrue(result['success'])
        self.assertEqual(result['diskSha256'], candidate.sha256(self.image))
        self.assertEqual(result['correspondingSourceSha256'], candidate.sha256(self.source_archive))
        self.assertEqual(result['native']['sha256'], candidate.sha256(self.native))
        self.assertEqual(len(result['assets']), 7)
        self.assertFalse(result['androidDeviceVerified'])
        self.assertFalse(result['productionEnabled'])

    def test_apk_audit_rejects_same_size_replaced_disk(self):
        with self.assertRaisesRegex(ValueError, 'checksum differs'):
            self.verify(self.apk({'assets/linux-vm/disk.bin': b'x' * self.image.stat().st_size}))

    def test_apk_audit_rejects_missing_source_record_and_wrong_abi(self):
        for changes in [{'assets/linux-vm/corresponding-source.manifest.json': None},
                        {release.NATIVE_ENTRY: None},
                        {'lib/x86_64/libpocket_linux_vm.so': self.native.read_bytes()},
                        {'assets/linux-vm/old-demo.bin': b'demo'}]:
            with self.subTest(changes=list(changes)), self.assertRaisesRegex(ValueError, 'inventory differs'):
                self.verify(self.apk(changes))

    def test_apk_audit_rejects_library_that_differs_from_compiled_output(self):
        with self.assertRaisesRegex(ValueError, 'checksum differs'):
            self.verify(self.apk({release.NATIVE_ENTRY: self.elf(suffix=b'other payload!')}))

    def test_apk_audit_rejects_non_arm64_native_even_when_bytes_match(self):
        self.native.write_bytes(self.elf(machine=62))
        with self.assertRaisesRegex(ValueError, 'ELF64 AArch64'):
            self.verify(self.apk())


if __name__ == '__main__':
    unittest.main()
