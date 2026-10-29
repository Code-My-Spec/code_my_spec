#!/usr/bin/env python3
'''Clone a private project after one CodeMySpec device approval.

Usage: curl -fsS SERVER/bootstrap-harness.py | python3 - SERVER [PROJECT_ID] [DEST]
'''
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

GRANT = 'urn:ietf:params:oauth:grant-type:device_code'

def request(server, path, data=None, token=None, json_body=False):
    headers = {'Accept': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if data is not None:
        if json_body:
            body = json.dumps(data).encode()
            headers['Content-Type'] = 'application/json'
        else:
            body = urllib.parse.urlencode(data).encode()
            headers['Content-Type'] = 'application/x-www-form-urlencoded'
    else:
        body = None
    req = urllib.request.Request(server + path, body, headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return json.load(error)
        except ValueError:
            raise RuntimeError('CodeMySpec request failed: HTTP ' + str(error.code)) from None

def git(args, env, cwd=None):
    subprocess.run(['git', *args], cwd=cwd, env=env, check=True)

def main():
    if len(sys.argv) < 2 or len(sys.argv) > 5:
        raise SystemExit('Usage: bootstrap-harness.py SERVER [PROJECT_ID] [DEST] [--clone-only]')
    server = sys.argv[1].rstrip('/')
    if not server.startswith(('https://', 'http://')):
        raise SystemExit('Expected an HTTP(S) CodeMySpec server URL')
    args = [arg for arg in sys.argv[2:] if arg != '--clone-only']
    clone_only = '--clone-only' in sys.argv[2:]
    project_id = args[0] or None if args else None
    destination = Path(args[1] if len(args) > 1 else 'code_my_spec').expanduser().absolute()
    if destination.exists():
        raise SystemExit('Destination already exists: ' + str(destination))

    registered = request(server, '/oauth/register', {
        'client_name': 'CodeMySpec source bootstrap',
        'grant_types': [GRANT, 'refresh_token'],
        'redirect_uris': []
    }, json_body=True)
    client_id = registered['client_id']
    client_secret = registered['client_secret']
    device = request(server, '/oauth/device/code', {
        'client_id': client_id, 'device_id': str(uuid.uuid4())
    })
    print('Approve this harness: open ' + device['verification_uri'] + ' and enter ' + device['user_code'], flush=True)
    deadline = time.monotonic() + device['expires_in']
    interval = max(1, device.get('interval', 5))
    while time.monotonic() < deadline:
        time.sleep(interval)
        credential = request(server, '/oauth/token', {
            'client_id': client_id, 'client_secret': client_secret,
            'grant_type': GRANT, 'device_code': device['device_code']
        })
        if 'access_token' in credential:
            break
        if credential.get('error') == 'slow_down':
            interval += 5
        elif credential.get('error') != 'authorization_pending':
            raise RuntimeError('Device authorization failed: ' + str(credential.get('error')))
    else:
        raise RuntimeError('Device authorization expired')

    token = credential['access_token']
    projects = request(server, '/api/projects', token=token)['projects']
    matches = [project for project in projects if project_id is None or project['id'] == project_id]
    if len(matches) != 1:
        raise RuntimeError('Specify a project ID from the CodeMySpec projects page')
    project = matches[0]
    if not project.get('code_repo') or not project.get('docs_repo'):
        raise RuntimeError('Project must have code and docs repositories')

    source = server + '/api/source/' + project['id']
    env = os.environ.copy()
    env.update({
        'GIT_TERMINAL_PROMPT': '0',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': os.devnull,
        'GIT_CONFIG_COUNT': '1',
        'GIT_CONFIG_KEY_0': 'http.' + source + '/.extraheader',
        'GIT_CONFIG_VALUE_0': 'Authorization: Bearer ' + token
    })
    git(['clone', source + '/code', str(destination)], env)
    modules = destination / '.gitmodules'
    if not modules.is_file():
        raise RuntimeError('Checkout has no docs submodule')
    original = subprocess.check_output(
        ['git', 'config', '-f', str(modules), '--get', 'submodule..code_my_spec.url'],
        env=env, text=True
    ).strip()
    def github_repository(value):
        value = value.removesuffix('.git')
        for prefix in ('https://github.com/', 'git@github.com:'):
            if value.startswith(prefix):
                return value[len(prefix):]
        return None
    if github_repository(original) != github_repository(project['docs_repo']) or not github_repository(original):
        raise RuntimeError('Docs submodule differs from the project repository setting')
    env['GIT_CONFIG_COUNT'] = '2'
    env['GIT_CONFIG_KEY_1'] = 'url.' + source + '/docs.insteadOf'
    env['GIT_CONFIG_VALUE_1'] = original
    git(['submodule', 'update', '--init', '.code_my_spec'], env, cwd=destination)

    # This is the CodeMySpec device credential, not the GitHub integration grant.
    # HarnessOAuth uses this private file for refresh and subsequent API calls.
    state = Path(os.environ.get('CMS_STATE_DIR') or Path.home() / '.codemyspec')
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    digest = hashlib.sha256(server.encode()).hexdigest()
    credential_path = state / ('harness_oauth_' + digest + '.json')
    data = {
        'client_id': client_id, 'client_secret': client_secret,
        'access_token': token, 'refresh_token': credential['refresh_token'],
        'expires_at': int(time.time()) + credential['expires_in']
    }
    fd = os.open(credential_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as file:
        json.dump(data, file)
    os.chmod(credential_path, 0o600)
    print('Cloned ' + project['name'] + ' with its docs submodule', flush=True)
    if not clone_only:
        os.environ['CMS_STATE_DIR'] = str(state)
        os.chdir(destination)
        os.execve('/bin/bash', ['/bin/bash', 'scripts/start-harness', server], os.environ.copy())

if __name__ == '__main__':
    try:
        main()
    except (KeyError, ValueError, subprocess.CalledProcessError, RuntimeError) as error:
        raise SystemExit(str(error)) from None
