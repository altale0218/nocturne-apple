"""Package a real iphoneos app only; never substitutes a simulator or fabricated executable."""
from pathlib import Path
import hashlib, os, plistlib, stat, zipfile

def package(app: Path, destination: Path) -> dict:
    app = app.resolve(strict=True)
    if app.suffix != '.app' or not app.is_dir(): raise ValueError('Expected an .app bundle')
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'com.nocturne.gallery': raise ValueError('Unexpected bundle identity')
    if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []): raise ValueError('Refuse simulator app')
    name = info.get('CFBundleExecutable')
    if not isinstance(name,str) or Path(name).name != name or name in ('', '.', '..'): raise ValueError('Invalid executable')
    executable = app / name
    with executable.open('rb') as handle: magic = handle.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'): raise ValueError('Expected device Mach-O executable')
    if os.name != 'nt' and not os.access(executable, os.X_OK): raise ValueError('Executable bit missing')
    files = sorted(app.rglob('*'))
    for file in files:
        if file.is_symlink() or not (file.is_file() or file.is_dir()): raise ValueError('Bundle contains unsafe file type')
    destination.parent.mkdir(parents=True,exist_ok=True)
    temporary = destination.with_suffix('.ipa.partial')
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for file in files:
                if file.is_file(): archive.write(file, str(Path('Payload') / app.name / file.relative_to(app)).replace('\\','/'))
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None: raise ValueError('IPA archive corruption')
            expected = 'Payload/' + app.name + '/Info.plist'
            if plistlib.loads(archive.read(expected))['CFBundleIdentifier'] != 'com.nocturne.gallery': raise ValueError('IPA identity changed')
        temporary.replace(destination)
    finally:
        if temporary.exists(): temporary.unlink()
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    return {'bundle': info['CFBundleIdentifier'], 'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'), 'sha256': digest, 'signed': False, 'requiresLocalSigning': True}
