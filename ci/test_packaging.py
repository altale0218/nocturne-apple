"""Generated packaging fixtures only. Does not compile Swift or produce a real iPad app."""
import hashlib, json, os, plistlib, stat, tempfile, unittest, zipfile
from pathlib import Path
from package_ipa import package
from check_source import check
ROOT=Path(__file__).resolve().parents[1]

class PackagingTests(unittest.TestCase):
    def setUp(self):
        (ROOT/'.build').mkdir(exist_ok=True)
        self.temporary=tempfile.TemporaryDirectory(prefix='packaging-fixture-',dir=ROOT/'.build')
        self.root=Path(self.temporary.name); self.app=self.root/'Nocturne.app';self.app.mkdir()
        self.info={'CFBundleIdentifier':'com.nocturne.gallery','CFBundleExecutable':'Nocturne','CFBundleSupportedPlatforms':['iPhoneOS'],'CFBundleShortVersionString':'fixture','CFBundleVersion':'0'}
        self.save();(self.app/'Nocturne').write_bytes(b'\xcf\xfa\xed\xfeGENERATED-NONEXECUTABLE-FIXTURE')
        (self.app/'Nocturne').chmod(0o755);self.output=self.root/'result.ipa'
    def tearDown(self): self.temporary.cleanup()
    def save(self): (self.app/'Info.plist').write_bytes(plistlib.dumps(self.info))
    def test_expected_payload_hash_and_executable_mode(self):
        report=package(self.app,self.output)
        self.assertEqual(report['sha256'],hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertTrue(report['requiresLocalSigning']);self.assertFalse(report['signed'])
        with zipfile.ZipFile(self.output) as archive:
            self.assertEqual(set(archive.namelist()),{'Payload/Nocturne.app/Info.plist','Payload/Nocturne.app/Nocturne'})
            if os.name!='nt': self.assertTrue((archive.getinfo('Payload/Nocturne.app/Nocturne').external_attr>>16)&stat.S_IXUSR)
    def test_refuse_simulator(self):
        self.info['CFBundleSupportedPlatforms']=['iPhoneSimulator'];self.save()
        with self.assertRaises(ValueError): package(self.app,self.output)
        self.assertFalse(self.output.exists())
    def test_refuse_other_library_identity(self):
        self.info['CFBundleIdentifier']='other.app';self.save()
        with self.assertRaises(ValueError): package(self.app,self.output)
    def test_refuse_executable_traversal(self):
        self.info['CFBundleExecutable']='../secret';self.save()
        with self.assertRaises(ValueError): package(self.app,self.output)
    def test_refuse_non_native_executable(self):
        (self.app/'Nocturne').write_bytes(b'not-an-app')
        with self.assertRaises(ValueError): package(self.app,self.output)
    def test_refuse_symlink_to_unrelated_file(self):
        outside=self.root/'private-original';outside.write_text('generated fixture')
        try: (self.app/'unrelated').symlink_to(outside)
        except OSError: self.skipTest('Windows symlink privilege unavailable; must run on macOS CI')
        with self.assertRaises(ValueError): package(self.app,self.output)
        self.assertEqual(outside.read_text(),'generated fixture')
    def test_upload_boundary_rejects_data_and_signers(self):
        source=self.root/'source';source.mkdir();(source/'README.md').write_text('fixture')
        self.assertEqual(check(source),1)
        (source/'Data').mkdir();(source/'Data/library.ncv').write_bytes(b'generated-ciphertext-fixture')
        with self.assertRaises(ValueError): check(source)

if __name__=='__main__': unittest.main(verbosity=2)
