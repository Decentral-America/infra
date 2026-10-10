#!/usr/bin/env python3
"""Keep each node StatefulSet's pod-template `checksum/config` annotation equal to the sha256 of the
ConfigMap it mounts (clusters/testnet/apps/nodes.yaml).

Why: the nodes read dcc.conf only at startup, and a ConfigMap change alone does not restart StatefulSet
pods. Config-only changes were applied by Flux but never reached the running nodes (found 2026-10-10
while rotating the REST API key hashes; pods kept the old config until a manual rollout restart). A
changed annotation changes the pod template, so Kubernetes rolls the pod.

  config-checksums.py --check   exit 1 if any annotation is missing or stale (CI)
  config-checksums.py --fix     rewrite the annotations in place (run after editing a node config)
"""
import hashlib, json, re, sys
import yaml

PATH = 'clusters/testnet/apps/nodes.yaml'
KEY = 'checksum/config'


def expected(docs):
    cms = {d['metadata']['name']: d.get('data', {}) for d in docs if d['kind'] == 'ConfigMap'}
    out = {}
    for d in docs:
        if d['kind'] != 'StatefulSet':
            continue
        t = d['spec']['template']
        mounted = [v['configMap']['name'] for v in t['spec'].get('volumes', []) if 'configMap' in v]
        blob = json.dumps({m: cms[m] for m in sorted(mounted)}, sort_keys=True).encode()
        out[d['metadata']['name']] = (hashlib.sha256(blob).hexdigest(), t['metadata'].get('annotations', {}).get(KEY))
    return out


def main(mode):
    text = open(PATH).read()
    docs = [d for d in yaml.safe_load_all(text) if d]
    exp = expected(docs)
    stale = {n: want for n, (want, have) in exp.items() if want != have}
    if mode == '--check':
        for n, (want, have) in exp.items():
            print(f"{'OK   ' if want == have else 'STALE'} {n}: annotation={have} expected={want}")
        if stale:
            print(f'::error::{PATH}: stale {KEY} annotation(s); run scripts/config-checksums.py --fix and commit')
        return 1 if stale else 0
    # --fix: edit the template metadata block of each StatefulSet in place (comments preserved).
    for name, want in exp.items():
        pat = re.compile(r'(  template:\n    metadata:\n)((?:      annotations:\n(?:        .*\n)*?)?)(      labels:\n        app: ' + re.escape(name) + r'\n)')
        m = pat.search(text)
        if not m:
            sys.exit(f'cannot locate the pod template of {name}')
        ann = m.group(2)
        if ann:
            ann_lines = [l for l in ann.splitlines(keepends=True)[1:] if not l.strip().startswith(KEY + ':')]
            ann = '      annotations:\n' + ''.join(ann_lines) + f'        {KEY}: "{want[0]}"\n'
        else:
            ann = f'      annotations:\n        {KEY}: "{want[0]}"\n'
        text = text[:m.start()] + m.group(1) + ann + m.group(3) + text[m.end():]
    open(PATH, 'w').write(text)
    print('annotations written:', ', '.join(exp))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else '--check'))
