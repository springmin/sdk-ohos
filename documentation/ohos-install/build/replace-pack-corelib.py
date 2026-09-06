import zipfile, sys, os
nupkg, newcl, out = sys.argv[1], sys.argv[2], sys.argv[3]
r2r = open(newcl, 'rb').read()
z = zipfile.ZipFile(nupkg)
target = None
for n in z.namelist():
    if n.endswith('System.Private.CoreLib.dll') and ('lib/net' in n or '/native/' in n):
        target = n; break
if not target:
    sys.exit(f'no CoreLib in {nupkg}')
tmp = out + '.tmp'
with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as zo:
    for n in z.namelist():
        zo.writestr(n, r2r if n == target else z.read(n))
os.replace(tmp, out)
print(f'replaced {target} -> {len(r2r)}B (R2R) in {out}')
