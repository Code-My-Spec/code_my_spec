#!/usr/bin/env bash
# Run from the generated Phoenix project's root. No credentials are embedded.
set -euo pipefail
command -v python3 >/dev/null || { echo 'Install Python 3 before running Codex Cloud setup.' >&2; exit 1; }
state=$(python3 - <<'PY'
import base64, json, os, pathlib
context = json.loads(base64.b64decode('__CONTEXT__'))
assets = json.loads(base64.b64decode('__RUNTIME_BUNDLE__'))
expected = {'codex_cloud.py', 'codex_cloud_boot.exs'}
if set(assets) != expected:
    raise SystemExit('Invalid CodeMySpec runtime bundle')
state = pathlib.Path(os.environ.get('CMS_CLOUD_STATE_DIR', str(pathlib.Path.home() / '.codemyspec' / 'codex-cloud' / context['device_id']))).resolve()
state.mkdir(parents=True, exist_ok=True, mode=0o700)
config = state / 'config.json'
if config.exists():
    previous = json.loads(config.read_text())
    if any(previous.get(k) != context.get(k) for k in ('server_url', 'device_id')):
        raise SystemExit('This state directory belongs to another box/project. Choose a separate CMS_CLOUD_STATE_DIR.')
    if context.get('project_id') and previous.get('project_id') != context['project_id']:
        raise SystemExit('This state directory belongs to another project.')
    context['project_id'] = context.get('project_id') or previous.get('project_id')
for name, contents in dict(assets, **{'config.json': json.dumps(context)}).items():
    destination = state / name
    destination.write_text(contents)
    destination.chmod(0o600)
print(state)
PY
)
python3 "$state/codex_cloud.py" install --root "$PWD"
