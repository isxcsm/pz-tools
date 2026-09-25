import base64, hashlib, html, json, lzma, pathlib, re, subprocess, xml.etree.ElementTree as ET
root=pathlib.Path.cwd()
payload=b''.join(p.read_bytes() for p in sorted((root/'.i18n-transfer').glob('part-*.txt')))
raw=lzma.decompress(base64.b64decode(payload,validate=True))
assert hashlib.sha256(raw).hexdigest()=='d4e74fd23c84df71692d1f71340d8b31080bfda2734b298888e42e65ef8085da'
changes=json.loads(raw)
allowed=('src/PzTools.App/', 'src/PzTools.App.Core/', 'src/PzTools.Process.Contracts/Localization/', 'tests/PzTools.Backup.Tests/', 'scripts/check-localization.py', 'docs/localization-review.md')
for name in changes['blobs']:
 p=pathlib.PurePosixPath(name)
 assert not p.is_absolute() and '..' not in p.parts and name.startswith(allowed),name
patch=root/'.i18n-transfer/local.patch'
patch.write_text(changes['patch'],encoding='utf-8',newline='\n')
subprocess.run(['git','apply','--check',str(patch)],check=True)
subprocess.run(['git','apply',str(patch)],check=True)
for name,values in changes['resources'].items():
 assert name in changes['blobs'] and name.endswith('/Resources.resw')
 path=root/name
 text=path.read_text(encoding='utf-8')
 existing={e.get('name') for e in ET.fromstring(text).findall('data')}
 for key,value in values.items():
  escaped=html.escape(value,quote=False).replace('\n','&#10;')
  if key in existing:
   pattern=r'(<data name="'+re.escape(key)+r'"[^>]*><value>).*?(</value></data>)'
   text,n=re.subn(pattern,lambda m:m[1]+(html.escape(value,quote=False) if '\n' in m[0] else escaped)+m[2],text,flags=re.S)
   assert n==1,(name,key,n)
  else:
   text=text.replace('</root>',f'  <data name="{key}" xml:space="preserve"><value>{escaped}</value></data>\n</root>')
 path.write_text(text,encoding='utf-8',newline='\n')
for name,expected in changes['blobs'].items():
 data=(root/name).read_bytes()
 assert hashlib.sha1(f'blob {len(data)}\0'.encode()+data).hexdigest()==expected,name
subprocess.run(['git','add','--',*changes['blobs']],check=True)
actual=set(subprocess.check_output(['git','diff','--cached','--name-only'],text=True).splitlines())
assert actual==set(changes['blobs']),(actual,set(changes['blobs']))
subprocess.run(['git','diff','--cached','--check'],check=True)
print(f'Applied and verified all {len(actual)} localized source/test/doc file hashes.')
