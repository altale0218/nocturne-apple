"""Native Apple build, no paid signing account or Apple credential required in CI."""
from pathlib import Path
import json, os, plistlib, re, struct, subprocess, sys, time, zlib
from package_ipa import package
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'output'

def run(args, log, env, timeout=1200):
    print(f'Running {log}', flush=True)
    try:
        with (OUT/log).open('w', encoding='utf-8') as output:
            result = subprocess.run(args, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f'{log} exceeded {timeout} seconds', flush=True)
        raise
    if result.returncode:
        lines = (OUT/log).read_text(encoding='utf-8',errors='replace').splitlines()
        errors = [line for line in lines if 'error:' in line.lower() or '** TEST FAILED **' in line or '** BUILD FAILED **' in line]
        print('\n'.join(errors[:30] or lines[-40:]))
        raise RuntimeError('Native step failed: '+log+'; download build-logs artifact')

def select_simulators(devices, sdk_version):
    sdk = tuple(map(int, sdk_version.split('.')))
    families = ('iPhone', 'iPad')
    selected = {}
    for runtime, values in devices.items():
        if 'iOS-' not in runtime:
            continue
        version = tuple(map(int, re.findall(r'\d+', runtime.rsplit('iOS-', 1)[-1])))
        if (version + (0, 0))[:3] > (sdk + (0, 0))[:3]:
            continue
        for device in values:
            if not device.get('isAvailable'):
                continue
            name = device['name']
            for family in families:
                if name.startswith(family + ' '):
                    candidate = (version, name, device['udid'])
                    if family not in selected or candidate > selected[family]:
                        selected[family] = candidate
    missing = [family for family in families if family not in selected]
    if missing:
        raise RuntimeError('Missing compatible simulators: ' + ', '.join(missing))
    return {family: selected[family][1:] for family in families}


def run_simulator_tests(family, model, udid, app, simulator_build, env, only_photos=False):
    result = {'model': model, 'passed': False, 'nativePhotosTested': False}
    run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], family + '-boot.log', env, 240)
    run(['xcrun', 'simctl', 'install', udid, str(app)], family + '-install.log', env, 120)
    app_id = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
    seed = OUT / 'synthetic-photos-seed.png'
    if not seed.exists():
        def chunk(label, payload):
            return struct.pack('>I', len(payload)) + label + payload + struct.pack('>I', zlib.crc32(label + payload))
        pixels = (b'\0' + b'\x20\x80\xb0' * 24) * 24
        seed.write_bytes(b'\x89PNG\r\n\x1a\n' +
                         chunk(b'IHDR', struct.pack('>2I5B', 24, 24, 8, 2, 0, 0, 0)) +
                         chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))
    setup = [
        ('photos-seed', ['addmedia', udid, str(seed)]),
        ('photos-launch', ['launch', udid, app_id]),
        ('photos-add-permission', ['privacy', udid, 'grant', 'photos-add', app_id]),
        ('photos-permission', ['privacy', udid, 'grant', 'photos', app_id]),
        ('photos-relaunch', ['launch', udid, app_id]),
    ]
    for step, arguments in setup:
        try:
            run(['xcrun', 'simctl', *arguments], family + '-' + step + '.log', env, 20)
        except (subprocess.TimeoutExpired, RuntimeError):
            # The integration test supplies its own data and records whether Photos actually granted access.
            result['photosFixtureWarning'] = f'Optional simulator preparation stopped at {step}'
            print(f"{family}: {result['photosFixtureWarning']}")
            break
    test = 'testSystemPhotosNativeImportAlbumReuseAndMembershipRemoval'
    args = simulator_build + [
        '-destination', 'platform=iOS Simulator,id=' + udid,
        '-destination-timeout', '120', '-parallel-testing-enabled', 'NO',
        '-resultBundlePath', str(OUT / (family + '-Tests.xcresult')),
    ]
    if only_photos:
        args.append('-only-testing:NocturneTests/NocturneTests/' + test)
    run(args + ['test-without-building'], family + '-tests.log', env, 420)
    lines = (OUT / (family + '-tests.log')).read_text(encoding='utf-8', errors='replace').splitlines()
    if any(test in line and 'passed' in line for line in lines):
        result['nativePhotosTested'] = True
    else:
        diagnostic = next((line for line in lines if test in line and 'Test skipped - Simulator Photos status' in line), None)
        if not diagnostic:
            raise RuntimeError('Native Photos test result missing on ' + family)
        result['nativePhotosSkippedReason'] = diagnostic.split('Test skipped - ', 1)[1]
        print(f"{family}: {result['nativePhotosSkippedReason']}")
    result['passed'] = True
    return result


def build_device(base, env, report):
    run(base+['-configuration','Release','-sdk','iphoneos','-destination','generic/platform=iOS','-derivedDataPath','.build/Device','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=','build'],'device-build.log',env,900)
    app=ROOT/'.build/Device/Build/Products/Release-iphoneos/Nocturne.app'
    run(['xcrun','lipo',str(app/'Nocturne'),'-verify_arch','arm64'],'architecture.log',env,60)
    device_info = plistlib.loads((app / 'Info.plist').read_bytes())
    if (device_info.get('CFBundleIdentifier') != 'com.nocturne.gallery'
            or set(device_info.get('UIDeviceFamily', [])) != {1, 2}):
        raise RuntimeError('Device build must retain the shared iPhone/iPad app identity')
    extension=app/'PlugIns/NocturneTaskActivity.appex'
    extension_info=plistlib.loads((extension/'Info.plist').read_bytes())
    if (not device_info.get('NSSupportsLiveActivities')
            or extension_info.get('CFBundleIdentifier') != 'com.nocturne.gallery.TaskActivity'
            or extension_info.get('CFBundleVersion') != device_info.get('CFBundleVersion')
            or extension_info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension'):
        raise RuntimeError('Live Activity extension is missing or does not match the app')
    run(['xcrun','lipo',str(extension/extension_info['CFBundleExecutable']),'-verify_arch','arm64'],'activity-architecture.log',env,60)
    report['liveActivityEmbedded']=True
    report['ipa']=package(app,OUT/'Nocturne-unsigned.ipa');report['deviceBuildPassed']=True
    (OUT/'IPA-SHA256.txt').write_text(report['ipa']['sha256']+'  Nocturne-unsigned.ipa\n',encoding='utf-8')

def main():
    if sys.platform != 'darwin': raise RuntimeError('Requires an actual macOS runner and Apple Xcode; Windows checks are not a native build')
    OUT.mkdir(exist_ok=True)
    candidates=[]
    for app in Path('/Applications').glob('Xcode*.app'):
        info=app/'Contents/Info.plist'
        if not info.exists(): continue
        version=str(plistlib.loads(info.read_bytes()).get('CFBundleShortVersionString',''))
        if not re.fullmatch(r'\d+(?:\.\d+)*',version) or 'beta' in app.name.lower(): continue
        parts=tuple(map(int,version.split('.')))
        if parts[0]>=26: candidates.append((parts,str(app/'Contents/Developer')))
    if not candidates: raise RuntimeError('No stable Xcode26+ installed; runner image must supply the Apple SDK')
    _,developer=max(candidates)
    env=os.environ.copy();env['DEVELOPER_DIR']=developer
    report={'developerDirectory':developer,'commit':env.get('GITHUB_SHA','local'),'nativeTestsPassed':False,'deviceBuildPassed':False,'physicalIPadTested':False,'physicalIPhoneTested':False,'simulators':{},'paidSigningUsed':False}
    try:
        run(['xcodebuild','-version'],'toolchain.log',env,60)
        run(['plutil','-lint','Nocturne.xcodeproj/project.pbxproj','Resources/Info.plist','ci/SimulatorKeychain.plist'],'project.log',env,60)
        base = ['xcodebuild', '-project', 'Nocturne.xcodeproj', '-scheme', 'Nocturne']
        report['deviceOnly'] = os.environ.get('GITHUB_REF_NAME', '').startswith('nocturne-apple-ci-device-')
        if report['deviceOnly']:
            build_device(base, env, report)
            print('Device build passed; simulator tests were not run in this device-only workflow.')
            return
        devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','available','--json'],env=env,text=True))['devices']
        sdk_version=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-version'],env=env,text=True).strip()
        report['simulatorSDK'] = sdk_version
        simulators = select_simulators(devices, sdk_version)
        simulator_build = base + [
            '-configuration', 'Debug', '-sdk', 'iphonesimulator',
            '-derivedDataPath', '.build/Simulator',
        ]
        run(simulator_build + ['-destination', 'generic/platform=iOS Simulator',
                              'ENABLE_TESTABILITY=YES', 'build-for-testing'],
            'simulator-build.log', env)
        simulator_app = ROOT / '.build/Simulator/Build/Products/Debug-iphonesimulator/Nocturne.app'
        for family, (model, udid) in simulators.items():
            report['simulators'][family] = run_simulator_tests(family, model, udid, simulator_app, simulator_build, env)
        report['nativeTestsPassed']=True
        build_device(base, env, report)
        extended = env.get('NOCTURNE_EXTENDED_PHOTOS') == '1'
        report['extendedPhotosRequested'] = extended
        if extended and not all(row['nativePhotosTested'] for row in report['simulators'].values()):
            # Read/write authorization can remain undetermined on newer simulator runtimes
            # after the supported simctl grant. Test the same APIs on a pre-iOS-26 runtime.
            try:
                older = select_simulators(devices, '18.9')
            except RuntimeError as missing:
                report['olderPhotosSimulator'] = {'available': False, 'reason': str(missing)}
            else:
                report['olderPhotosSimulator'] = {'available': True}
                for family, (model, udid) in older.items():
                    report['olderPhotosSimulator'][family] = run_simulator_tests(
                        family + '-older', model, udid, simulator_app, simulator_build, env, only_photos=True)
        print('Native tests and device build passed; unsigned IPA still needs local personal-account signing.')
    finally:
        (OUT/'build-report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')

if __name__=='__main__': main()
