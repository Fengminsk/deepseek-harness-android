"""Candidate assembly preserves evidence and rejects incomplete/stale inputs."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('candidate', Path(__file__).with_name('stage-alpine-vm-candidate.py'))
candidate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(candidate)
sources = candidate.sources


class CandidateFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='dsh-linux-candidate-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in sources.PROJECT_INPUTS:
            self.write(name, ('source ' + name).encode())
        self.upstream = b'locked upstream source and license'
        self.addCleanup(patch.stopall)
        patch.object(sources, 'locked_members', return_value={'upstream/source.tar.gz': sources.sha256(self.upstream)}).start()
        boot = {}
        for name in ['bios', 'kernel']:
            path = self.write('.cache/android/linux-vm-assets/linux-vm/' + name + '.bin', name.encode())
            boot[name] = self.identity(path)
        self.locks = dict(tinyEmuGuestFixtureLock=dict(files=boot),
                          tinyEmuSourceLock=dict(sha256=sources.sha256(self.upstream)),
                          alpineGuestSourceLock=dict(version='3.22.7'))
        patch.object(candidate, 'boot_lock', return_value=self.locks).start()
        self.library = self.write('.cache/android/tinyemu-host/build-test/pocket_linux_vm.dll', b'host interpreter')
        self.build_file = self.library.with_name('build.json')
        engine = self.root / 'apps/android/android/app/src/main/cpp/linux_vm_engine.c'
        self.build = dict(format='tinyemu-windows-host-v1', library=str(self.library),
                          librarySha256=candidate.sha256(self.library), sourceArchiveSha256=sources.sha256(self.upstream),
                          inputs=[dict(name='linux_vm_engine', source=str(engine), sha256=candidate.sha256(engine))],
                          javaSources=[dict(source=name, sha256=candidate.sha256(self.root / name)) for name in [
                              'apps/android/android/app/src/main/java/com/minnnng/dsh_android/LinuxVmConsole.java',
                              'apps/android/tool/linux-vm-host/LinuxVmHost.java']],
                          patchSha256=candidate.sha256(self.root / 'apps/android/tool/patch-tinyemu.mjs'),
                          hostHeaderSha256=candidate.sha256(self.root / 'apps/android/tool/linux-vm-host/include/sys/select.h'))
        self.write_json(self.build_file, self.build)
        self.image = self.write('.cache/android/tinyemu-host/runs/alpine-test/build/extra.bin', b'tested Alpine disk')
        image_input = self.write('.cache/android/linux-image-build-assets/linux-image-build/input.tar', b'locked packages')
        command_hashes = [candidate.sha256(self.root / 'apps/android/tool/linux-vm-host' / name)
                          for name in ['build-alpine.sh', 'probe-alpine.sh']]
        command_hashes.append(sources.sha256(candidate.FILESYSTEM_COMMAND.encode()))
        self.report = dict(format='linux-vm-host-report-v2', suite='alpine', passed=True, androidDeviceVerified=False,
                           runnerSha256=candidate.sha256(self.root / 'apps/android/tool/verify-tinyemu-host.mjs'),
                           hostBuild=dict(file=str(self.build_file), sha256=candidate.sha256(self.build_file)),
                           librarySha256=self.build['librarySha256'],
                           imageManifest=dict(bios=boot['bios'], kernel=boot['kernel']),
                           reports=[dict(name=name, nativeStatus=0, exitCode=0, imagesWritten=True, truncated=False,
                                         commandSha256=command_hash, output=marker,
                                         directory=str(self.image.parent if name == 'build' else self.image.parent.parent / name))
                                    for name, command_hash, marker in zip(['build', 'probe', 'filesystem'], command_hashes,
                                                                         ['DSH_ALPINE_IMAGE_BUILT', 'DSH_ALPINE_RUNTIME_OK',
                                                                          'DSH_ALPINE_FILESYSTEM_OK'])],
                           alpineImage=dict(artifact=str(self.image), **self.identity(self.image)),
                           imageBuildInput=dict(artifact=str(image_input), **self.identity(image_input),
                                                packageLockSha256=candidate.sha256(self.root / 'apps/android/tool/alpine-packages.lock.json'),
                                                builderSha256=candidate.sha256(self.root / 'apps/android/tool/build-alpine-vm-input.py')))
        self.report_path = self.image.parent.parent / 'report.json'
        self.write_json(self.report_path, self.report)
        self.source_archive = self.root / '.cache/android/tinyemu-probe/linux-vm-corresponding-source.tar'
        self.source_manifest = self.source_archive.with_suffix('.manifest.json')
        self.bundle()

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    @staticmethod
    def write_json(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding='utf-8')

    @staticmethod
    def identity(path):
        return dict(bytes=path.stat().st_size, sha256=candidate.sha256(path))

    def bundle(self, omitted=None):
        entries = {'upstream/source.tar.gz': self.upstream, 'NOTICE.txt': b'notices'}
        entries.update({'project/' + name: (self.root / name).read_bytes() for name in sources.PROJECT_INPUTS})
        if omitted:
            del entries[omitted]
        self.source_archive.parent.mkdir(parents=True, exist_ok=True)
        records = []
        with tarfile.open(self.source_archive, 'w') as archive:
            for name, data in entries.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
                records.append(dict(name=name, bytes=len(data), sha256=sources.sha256(data)))
        self.write_json(self.source_manifest, dict(schema=2, artifact=self.source_archive.name,
                                                   **self.identity(self.source_archive), members=records))

    def stage(self):
        return Path(candidate.stage(self.report_path, self.source_manifest, self.root)['directory'])


class CandidateTests(CandidateFixture):
    def test_stages_exact_image_sources_and_host_evidence_without_overwriting_fixture(self):
        before = self.identity(self.image)
        first = self.stage()
        second = self.stage()
        self.assertNotEqual(first, second)
        self.assertEqual(before, self.identity(self.image))
        record = candidate.verify_candidate(first, self.root)
        self.assertEqual(record['systemImage']['sha256'], before['sha256'])
        self.assertFalse(record['androidDeviceVerified'])
        self.assertFalse(record['productionEnabled'])
        self.assertFalse(record['networkAvailable'])
        self.assertEqual((first / 'evidence/host-report.json').read_bytes(), self.report_path.read_bytes())

    def test_rejects_old_report_before_creating_a_candidate(self):
        self.report.pop('format')
        self.write_json(self.report_path, self.report)
        with self.assertRaisesRegex(ValueError, 'current host-only'):
            self.stage()
        self.assertFalse((self.root / '.cache/android/linux-vm-candidates').exists())

    def test_requires_all_three_successful_checks(self):
        self.report['reports'].pop()
        self.write_json(self.report_path, self.report)
        with self.assertRaisesRegex(ValueError, 'all required'):
            self.stage()

    def test_rejects_changed_disk_despite_passed_report(self):
        self.image.write_bytes(b'replaced image')
        with self.assertRaisesRegex(ValueError, 'Artifact bytes differ'):
            self.stage()

    def test_rejects_stale_console_or_native_source(self):
        engine = self.root / 'apps/android/android/app/src/main/cpp/linux_vm_engine.c'
        engine.write_bytes(b'new engine')
        with self.assertRaisesRegex(ValueError, 'Host native source changed'):
            self.stage()

    def test_rejects_a_different_package_lock(self):
        (self.root / 'apps/android/tool/alpine-packages.lock.json').write_bytes(b'changed lock')
        with self.assertRaisesRegex(ValueError, 'current package lock'):
            self.stage()

    def test_requires_guest_builder_and_console_in_source_bundle(self):
        for name in ['apps/android/tool/linux-vm-host/build-alpine.sh',
                     'apps/android/android/app/src/main/java/com/minnnng/dsh_android/LinuxVmConsole.java']:
            with self.subTest(name=name):
                self.bundle('project/' + name)
                with self.assertRaisesRegex(ValueError, 'locked source closure'):
                    self.stage()

    def test_rejects_an_archive_with_its_locked_upstream_source_removed(self):
        self.bundle('upstream/source.tar.gz')
        with self.assertRaisesRegex(ValueError, 'locked source closure'):
            self.stage()

    def test_rejects_a_stale_uncompiled_embedding_file_in_source_bundle(self):
        (self.root / 'apps/android/android/app/src/main/cpp/linux_vm_files.c').write_bytes(b'changed publisher')
        with self.assertRaisesRegex(ValueError, 'missing or stale'):
            self.stage()

    def test_rejects_tampered_candidate_bytes(self):
        directory = self.stage()
        (directory / 'assets/linux-vm/disk.bin').write_bytes(b'changed disk')
        with self.assertRaisesRegex(ValueError, 'Artifact bytes differ'):
            candidate.verify_candidate(directory, self.root)

    def test_rejects_missing_candidate_inventory_even_when_files_exist(self):
        directory = self.stage()
        record = candidate.read_json(directory / 'candidate.json')
        record['files'].pop()
        self.write_json(directory / 'candidate.json', record)
        with self.assertRaisesRegex(ValueError, 'inventory differs'):
            candidate.verify_candidate(directory, self.root)

    def test_copy_failure_retains_partial_files_without_success_record(self):
        original = candidate.shutil.copyfile
        calls = 0

        def fail_third(source, target):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError('fixture output failure')
            return original(source, target)

        with patch.object(candidate.shutil, 'copyfile', side_effect=fail_third):
            with self.assertRaisesRegex(OSError, 'fixture output failure'):
                self.stage()
        paths = list((self.root / '.cache/android/linux-vm-candidates').iterdir())
        self.assertEqual(len(paths), 1)
        self.assertFalse((paths[0] / 'candidate.json').exists())
        self.assertTrue((paths[0] / 'assets/linux-vm/bios.bin').exists())


if __name__ == '__main__':
    unittest.main()
