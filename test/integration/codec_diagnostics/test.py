from pathlib import Path
import subprocess,tempfile,sys
exe=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='zidl-diagnostics-') as root:
 root=Path(root);source=root/'shapes.idl';source.write_text('module M { struct S { long double value; }; };\n')
 for lang in ['c','cpp','java','zig']:
  for split in [False,True]:
   out=root/(lang+str(split));out.mkdir();args=[str(exe),'-b',lang,'-o',str(out),str(source)]
   if split:args.insert(1,'--split-files')
   result=subprocess.run(args,capture_output=True,text=True)
   assert result.returncode and 'UnsupportedLongDoubleCdrValue' in result.stderr,(args,result.stderr)
   assert not list(out.iterdir()),(args,list(out.iterdir()))
   result=subprocess.run(args+['--no-typesupport'],capture_output=True,text=True)
   assert result.returncode==0 and list(out.iterdir()),(args,result.stderr)
 for key in ['string<4>','wstring','wstring<4>']:
  source.write_text(f'module M {{ typedef {key} Key; struct S {{ map<Key,long> values; }}; }};\n')
  for split in [False,True]:
   for decl in [False,True]:
    out=root/(key.replace('<','').replace('>','')+str(split)+str(decl));out.mkdir()
    args=[str(exe),'-b','zig','-o',str(out),str(source)]
    if split:args.insert(1,'--split-files')
    if decl:args.insert(1,'--no-typesupport')
    result=subprocess.run(args,capture_output=True,text=True)
    assert result.returncode and 'UnsupportedZigMapKey' in result.stderr,(args,result.stderr)
    assert not list(out.iterdir())
print('28 CLI diagnostics/declaration cases passed, including split output with no partial files')
