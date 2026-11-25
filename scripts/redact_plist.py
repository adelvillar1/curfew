import plistlib, sys, re
SECRET = re.compile(r'(secret|token|key|password|passwd|cookie|credential|auth)', re.I)
def walk(o, keypath=[]):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from walk(v, keypath+[str(k)])
    elif isinstance(o, list):
        for i, v in enumerate(o):
            yield from walk(v, keypath+[f'[{i}]'])
    else:
        yield keypath, o
for path in sys.argv[1:]:
    print(f"### {path}")
    try:
        d = plistlib.load(open(path, 'rb'))
    except Exception as e:
        print("  unreadable:", e); continue
    for kp, v in walk(d):
        joined = '.'.join(kp)
        if SECRET.search(joined):
            print(f"  {joined} = <redacted>")
        else:
            s = str(v)
            print(f"  {joined} = {s[:200]}")
