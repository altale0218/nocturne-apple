"""Fail before building if the upload contains library data or signing secrets."""
from pathlib import Path
import json, re, sys
ROOT=Path(__file__).resolve().parents[1]

def allowed(path):
    parts=path.parts
    if not parts: return False
    name=path.name
    if parts[0]=='clients':
        if parts==('clients','android','build.ps1') or parts==('clients','android','app','libs','apksig.jar'):
            return True
        if parts[:5]==('clients','android','app','src','main') and len(parts)>5:
            return path.suffix in {'.java','.xml','.png','.txt','.js','.tsv'} or name=='public_suffix_list.dat'
        if parts==('clients','windows','build.ps1'):
            return True
        if len(parts)==4 and parts[1]=='windows' and parts[2] in {'Windows','Browser'}:
            return (path.suffix in {'.cs','.ps1','.ico','.png','.tsv','.xaml','.hlsl','.js','.manifest'}
                    or name in {'public_suffix_list.dat','LiquidGlass256.ps','LiquidImgui-LICENSE.txt'})
        return parts==('clients','windows','Windows','ThirdParty','Kyant-Backdrop.txt')
    if len(parts)==1: return name in {'README.md','LICENSE','.gitignore','THIRD_PARTY_NOTICES.md','UPLOAD-MANIFEST.json'}
    if parts[0]=='Sources': return len(parts)==2 and path.suffix=='.swift'
    if parts[0]=='Tests': return len(parts)==2 and path.suffix=='.swift'
    if parts[0]=='Resources': return path.suffix in {'.plist','.storyboard','.xcprivacy','.png','.json','.strings'}
    if parts[0]=='ci':
        return len(parts)==2 and (path.suffix=='.py' or name=='SimulatorKeychain.plist')
    if parts[0]=='docs': return len(parts)==2 and path.suffix=='.md'
    if parts[0]=='.github': return path.as_posix()=='.github/workflows/ipad-build.yml'
    if parts[0]=='Nocturne.xcodeproj': return path.as_posix()=='Nocturne.xcodeproj/project.pbxproj' or (parts[1:3]==('xcshareddata','xcschemes') and len(parts)==4 and path.suffix=='.xcscheme')
    return False

def check(root=ROOT):
    checked=0
    for file in root.rglob('*'):
        relative=file.relative_to(root)
        if relative.parts[0] in {'.git','output'} or {'.build','__pycache__'}.intersection(relative.parts): continue
        if file.is_symlink(): raise ValueError('Symlink not allowed: '+str(relative))
        if not file.is_file(): continue
        if not allowed(relative): raise ValueError('File outside reviewed source boundary: '+str(relative))
        if file.stat().st_size>4*1024*1024: raise ValueError('Unexpected large source file: '+str(relative))
        if file.suffix in {'.swift','.py','.yml','.plist','.cs','.java','.ps1','.js','.xml'}:
            data=file.read_text(encoding='utf-8-sig')
            if re.search(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',data): raise ValueError('Private key detected: '+str(relative))
        checked+=1
    return checked
if __name__=='__main__': print(json.dumps({'reviewedSourceFiles':check(),'libraryAndSignerSecretsIncluded':False}))
