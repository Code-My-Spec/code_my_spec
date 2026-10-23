#!/usr/bin/env python3
"""Codex Cloud lifecycle. HTTP is local; credentials stay in the harness."""
import argparse
import hashlib
import fcntl
import json
import os
import pathlib
import platform
import re
import shutil
import shlex
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile


class SetupError(Exception):
    pass


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(path.suffix + '.new')
    with temporary.open('w') as output:
        os.chmod(temporary, 0o600)
        json.dump(value, output)
    temporary.replace(path)


def read(path):
    return json.loads(path.read_text())


def run(args, cwd=None, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, check=False)
    if result.returncode:
        raise SetupError(f'{args[0]} {args[1] if len(args) > 1 else ""} failed (exit {result.returncode}); fix the reported error and rerun this command')


def fingerprint(root):
    digest = hashlib.sha256()
    for name in ('mix.exs', 'mix.lock', '.tool-versions'):
        path = root / name
        digest.update(name.encode())
        digest.update(path.read_bytes() if path.exists() else b'')
    for directory in ('lib', 'config', 'priv', 'assets', 'test'):
        folder = root / directory
        if folder.exists():
            for path in sorted(folder.rglob('*')):
                if path.is_file() and not path.is_symlink() and 'node_modules' not in path.parts and '_build' not in path.parts:
                    digest.update(str(path.relative_to(root)).encode())
                    digest.update(path.read_bytes())
    settings = root / '.claude/settings.local.json'
    if settings.exists():
        digest.update(str(read(settings).get('env', {}).get('MIX_TEST_PARTITION', '')).encode())
    return digest.hexdigest()


class Cloud:
    def __init__(self, args):
        self.root = pathlib.Path(args.root).resolve()
        self.state = pathlib.Path(args.state).resolve()
        self.url = args.url.rstrip('/')
        parsed = urllib.parse.urlparse(self.url)
        if parsed.scheme != 'http' or parsed.hostname not in ('127.0.0.1', 'localhost', '::1') or parsed.username or parsed.password:
            raise SetupError('--url must name the local harness over loopback HTTP')
        self.config = read(self.state / 'config.json')
        if self.config.get('target') != 'phoenix':
            raise SetupError('Unsupported generation target; choose Phoenix in Dev boxes')
        self.tools = self.state / 'tools'
        self.env = dict(os.environ)
        self.env.update({
            'PATH': str(self.tools / 'elixir/bin') + ':' + str(self.tools / 'otp/bin') + ':' + self.env.get('PATH', ''),
            'CARGO_HOME': str(self.tools / 'cargo'), 'RUSTUP_HOME': str(self.tools / 'rustup'),
            'MIX_HOME': str(self.state / 'mix'), 'HEX_HOME': str(self.state / 'hex'),
            'ERL_FLAGS': self.env.get('ERL_FLAGS', '+S 4:4'),
            'CMS_CLOUD_STATE_DIR': str(self.state), 'CMS_CLOUD_PROJECT_ROOT': str(self.root),
            'CMS_STATE_DIR': str(self.state / 'harness'),
            'CMS_DB_PATH': str(self.state / 'harness/cli.db'),
            'CMS_HARNESS_PORT': str(parsed.port or 4004),
            'CMS_SERVER_URL': self.config['server_url'],
        })
        self.env['PATH'] = str(self.tools / 'system/usr/bin') + ':' + str(self.tools / 'cargo/bin') + ':' + self.env['PATH']
        onnx = self.tools / 'onnxruntime-linux-x64-1.19.2'
        self.env.update(ORT_LIB_LOCATION=str(onnx), ORT_PREFER_DYNAMIC_LINK='1', LD_LIBRARY_PATH=str(onnx / 'lib') + ':' + str(self.tools / 'system/usr/lib/x86_64-linux-gnu') + ':' + self.env.get('LD_LIBRARY_PATH', ''))
        # Loopback requests must never leak agent ids/session ids to a network proxy.
        self.http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, path, body=None, headers=None):
        merged = {'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream'}
        merged.update(headers or {})
        req = urllib.request.Request(self.url + path,
            data=None if body is None else json.dumps(body).encode(), headers=merged)
        try:
            with self.http.open(req, timeout=30) as response:
                data = response.read().decode()
                return data, response.headers
        except (urllib.error.URLError, TimeoutError) as error:
            raise SetupError(f'Local harness request {path} failed; run startup and inspect harness.log ({type(error).__name__})') from error

    def health(self):
        return json.loads(self.request('/health')[0])

    def validated(self):
        try:
            marker = read(self.state / 'validation.json')
            return marker.get('status') == 'passed' and marker.get('root') == str(self.root) and marker.get('fingerprint') == fingerprint(self.root)
        except (OSError, ValueError):
            return False

    def check(self):
        if not self.validated():
            raise SetupError('Target validation is missing or stale; run startup to compile, migrate and build the target before readiness')
        status = self.health()
        if status.get('device_id') != self.config['device_id']:
            raise SetupError('Running harness device identity differs from this box or release lacks Codex Cloud support; choose an unused port and install a compatible harness release')
        project = next((item for item in status.get('projects', []) if item.get('root') == str(self.root)), None)
        if not project or not all(project.get(key) is True for key in ('connected', 'watching', 'onboarded')):
            raise SetupError('Harness is not connected, watching and onboarded for this target; inspect harness.log, server URL and proxy configuration, then retry startup. MCP success alone is not readiness.')
        if project.get('terminal_refusal'):
            raise SetupError('Server refused the persistent harness connection; inspect harness.log and resolve the refusal before retrying')
        if status.get('server_url', self.config['server_url']).rstrip('/') != self.config['server_url'].rstrip('/'):
            raise SetupError('The running harness belongs to another server; use a different local port')
        return {'ready': True, 'validation': 'passed', 'connected': True, 'watching': True, 'root': str(self.root)}

    def client(self):
        thread = os.environ.get('CODEX_THREAD_ID')
        if not thread:
            raise SetupError('CODEX_THREAD_ID is required to register this conversation; run session from the Codex agent turn')
        path = self.state / 'clients' / hashlib.sha256(thread.encode()).hexdigest() / 'session.json'
        try:
            identity = read(self.root / '.cms_harness.json')
        except (OSError, ValueError) as error:
            raise SetupError('Working-copy identity is missing; run startup to onboard this target') from error
        hid = identity.get('working_copy_id') or identity.get('harness_id')
        if not hid:
            raise SetupError('Working-copy id is missing from .cms_harness.json; rerun startup')
        if identity.get('project_id') != self.config.get('project_id') or identity.get('server_url', self.config['server_url']).rstrip('/') != self.config['server_url'].rstrip('/'):
            raise SetupError('Working-copy identity does not match this dev box project/server')
        return thread, path, hid

    def rpc(self, payload, client, hid):
        headers = {'X-Harness-Id': hid, 'X-Agent-Id': client['agent_id'], 'MCP-Protocol-Version': '2025-03-26'}
        if client.get('mcp_session') and payload.get('method') != 'initialize':
            headers['Mcp-Session-Id'] = client['mcp_session']
        text, response_headers = self.request('/mcp', payload, headers)
        if response_headers.get('Mcp-Session-Id'):
            client['mcp_session'] = response_headers['Mcp-Session-Id']
        if 'id' not in payload:
            return None
        messages = [json.loads(line[6:]) for line in text.splitlines() if line.startswith('data: ')]
        if not messages:
            messages = [json.loads(text)]
        response = next((m for m in messages if m.get('id') == payload['id']), None)
        if response is None:
            raise SetupError('MCP returned no matching response; rerun session')
        if 'error' in response:
            raise SetupError('MCP refused the request: ' + str(response['error'].get('message', 'unknown error')))
        return response

    def session(self):
        self.check()
        thread, path, hid = self.client()
        registered = json.loads(self.request(f'/api/harnesses/{hid}/hooks/session-start', {
            'hook_event_name': 'SessionStart', 'session_id': thread, 'cwd': str(self.root),
            'engine': 'codex', 'source': 'startup'})[0])
        if not registered.get('agent_id'):
            raise SetupError('SessionStart did not return an agent identity; inspect harness/server logs')
        client = {'agent_id': registered['agent_id'], 'harness_id': hid}
        self.rpc({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {
            'protocolVersion': '2025-03-26', 'capabilities': {},
            'clientInfo': {'name': 'codex-cloud', 'version': '1.0'}}}, client, hid)
        self.rpc({'jsonrpc': '2.0', 'method': 'notifications/initialized'}, client, hid)
        reply = self.rpc({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list', 'params': {}}, client, hid)
        names = {tool['name'] for tool in reply.get('result', {}).get('tools', [])}
        missing = {'start_task', 'evaluate_task', 'run_script', 'tool_docs'} - names
        if missing:
            raise SetupError('MCP initialization incomplete; missing tools: ' + ', '.join(sorted(missing)))
        save(path, client)
        return {'ready': True, 'agent_id': client['agent_id'], 'tools': len(names), 'task_tools_available': True}

    def mcp(self):
        _, path, hid = self.client()
        if not path.exists():
            self.session()
        client = read(path)
        if client.get('harness_id') != hid:
            raise SetupError('Saved MCP session belongs to another checkout; rerun session')
        payload = json.load(sys.stdin)
        response = self.rpc(payload, client, hid)
        save(path, client)
        return response or {}

    def download(self, url, destination):
        if destination.exists():
            return
        destination.parent.mkdir(parents=True, exist_ok=True)
        partial = destination.with_suffix(destination.suffix + '.partial')
        run(['curl', '--proto', '=https', '--tlsv1.2', '--fail', '--location', '--retry', '3', url, '-o', str(partial)])
        partial.replace(destination)

    def extract(self, archive, destination):
        destination.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as source:
            # Python 3.12+ uses data by default only in later versions; explicit here.
            if not hasattr(tarfile, 'data_filter'):
                raise SetupError('Python 3.11.8+ is required for safe release archive extraction')
            source.extractall(destination, filter='data')

    def versions(self):
        versions = {'erlang': '28.1', 'elixir': '1.19.4-otp-28'}
        path = self.root / '.tool-versions'
        if path.exists():
            for line in path.read_text().splitlines():
                words = line.split('#', 1)[0].split()
                if words and words[0] in versions:
                    if len(words) != 2:
                        raise SetupError('.tool-versions must pin one Erlang and one Elixir version')
                    versions[words[0]] = words[1]
        if not re.fullmatch(r'\d+\.\d+(?:\.\d+)*', versions['erlang']) or not re.fullmatch(r'\d+\.\d+\.\d+(?:-otp-\d+)?', versions['elixir']):
            raise SetupError('Pin numeric Erlang/Elixir versions in .tool-versions; floating versions are not reproducible')
        otp = versions['erlang'].split('.')[0]
        elixir = versions['elixir']
        if '-otp-' not in elixir:
            elixir += '-otp-' + otp
        if elixir.rsplit('-otp-', 1)[1] != otp:
            raise SetupError('Elixir OTP suffix disagrees with the Erlang version in .tool-versions')
        return versions['erlang'], elixir

    def privilege(self):
        if os.geteuid() == 0:
            return []
        if shutil.which('sudo'):
            return ['sudo', '-n']
        raise SetupError('Install system dependencies as root or enable noninteractive sudo, then rerun setup')

    def prerequisites(self):
        required = ('curl', 'git', 'make', 'gcc', 'g++', 'pkg-config')
        missing = [name for name in required if not shutil.which(name, path=self.env['PATH'])]
        if not shutil.which('inotifywait', path=self.env['PATH']):
            if os.geteuid() != 0 and not shutil.which('sudo') and shutil.which('apt') and shutil.which('dpkg-deb'):
                cache = self.state / 'cache/system-packages'
                cache.mkdir(parents=True, exist_ok=True)
                run(['apt', 'download', 'inotify-tools', 'libinotifytools0'], cwd=cache)
                for package in cache.glob('*.deb'):
                    run(['dpkg-deb', '-x', str(package), str(self.tools / 'system')])
            else:
                missing.append('inotifywait')
        if missing:
            try:
                privilege = self.privilege()
            except SetupError as error:
                raise SetupError('Missing system tools: ' + ', '.join(missing) + '. Use a Codex image with build-essential, curl, git, pkg-config and inotify-tools installed, then rerun setup') from error
            run(privilege + ['apt-get', 'update'])
            run(privilege + ['apt-get', 'install', '-y', 'curl', 'ca-certificates', 'git', 'build-essential',
                'pkg-config', 'libssl-dev', 'libncurses-dev', 'inotify-tools'])
        if not shutil.which('docker') and not shutil.which('psql'):
            fresh = self.empty_postgres_host()
            run(self.privilege() + ['apt-get', 'update'])
            run(self.privilege() + ['apt-get', 'install', '-y', 'postgresql', 'postgresql-contrib', 'postgresql-server-dev-all'])
            if fresh:
                # Only the cluster created by this package installation belongs to setup.
                clusters = subprocess.check_output(['pg_lsclusters', '--no-header'], text=True).splitlines()
                if len(clusters) != 1:
                    raise SetupError('PostgreSQL installation did not create exactly one cluster; configure target credentials explicitly')
                version, name, port, status, owner, data, *_ = clusters[0].split()
                if port != '5432' or owner != 'postgres' or not pathlib.Path(data).is_relative_to('/var/lib/postgresql'):
                    raise SetupError('New PostgreSQL cluster has unexpected configuration; configure it explicitly')
                stat = pathlib.Path(data).stat()
                save(self.state / 'provisioned-postgres.json', {'version': version, 'name': name, 'data': data,
                     'inode': stat.st_ino, 'device': stat.st_dev, 'initialized': False})
        self.initialize_provisioned_postgres()

    @staticmethod
    def empty_postgres_host():
        # Any previous config/data (including unreadable directories) prevents credential changes.
        try:
            for directory in ('/etc/postgresql', '/var/lib/postgresql'):
                path = pathlib.Path(directory)
                if path.exists() and any(path.iterdir()):
                    return False
            with socket.create_connection(('127.0.0.1', 5432), timeout=2):
                return False
        except ConnectionRefusedError:
            return True
        except OSError:
            return False

    def initialize_provisioned_postgres(self):
        marker = self.state / 'provisioned-postgres.json'
        if not marker.exists():
            return
        cluster = read(marker)
        stat = pathlib.Path(cluster['data']).stat()
        if (stat.st_ino, stat.st_dev) != (cluster['inode'], cluster['device']):
            raise SetupError('New PostgreSQL cluster was replaced; refusing to initialize its credentials')
        clusters = [line.split() for line in subprocess.check_output(['pg_lsclusters', '--no-header'], text=True).splitlines()]
        owned = [row for row in clusters if row[:2] == [cluster['version'], cluster['name']]]
        if len(owned) != 1 or owned[0][2] != '5432' or owned[0][4:6] != ['postgres', cluster['data']]:
            raise SetupError('Provisioned PostgreSQL cluster configuration changed; refusing credential initialization')
        # A package can start its new cluster automatically; inspect it before starting again.
        status = subprocess.run(self.privilege() + ['pg_ctlcluster', cluster['version'], cluster['name'], 'status'], capture_output=True)
        if status.returncode:
            run(self.privilege() + ['pg_ctlcluster', cluster['version'], cluster['name'], 'start'])
        if cluster.get('initialized'):
            return
        run(self.privilege() + ['runuser', '-u', 'postgres', '--', 'psql', '-h', '/var/run/postgresql',
             '-p', '5432', '-d', 'postgres', '-c', "ALTER USER postgres PASSWORD 'postgres'"])
        cluster['initialized'] = True
        save(marker, cluster)

    def install(self):
        if platform.system() != 'Linux' or platform.machine() not in ('x86_64', 'amd64'):
            raise SetupError('This setup supports x86_64 Linux Codex Cloud images')
        if not (self.root / 'mix.exs').exists() or not (self.root / 'mix.lock').exists():
            raise SetupError('Run setup in a generated Phoenix project with committed mix.exs and mix.lock')
        self.tools.mkdir(parents=True, exist_ok=True)
        self.prerequisites()
        otp, elixir = self.versions()
        versions = {'otp': otp, 'elixir': elixir}
        installed = self.tools / 'versions.json'
        if not installed.exists() or read(installed) != versions:
            archive = self.state / 'cache' / f'OTP-{otp}.tar.gz'
            self.download(f'https://builds.hex.pm/builds/otp/amd64/ubuntu-22.04/OTP-{otp}.tar.gz', archive)
            with tempfile.TemporaryDirectory(dir=self.tools) as temp:
                self.extract(archive, pathlib.Path(temp))
                installer = next(pathlib.Path(temp).rglob('Install'), None)
                if installer is None:
                    raise SetupError('OTP archive has no installer; check the pinned version')
                target = self.tools / ('otp-' + otp)
                if not target.exists():
                    shutil.move(str(installer.parent), target)
                    run(['./Install', '-minimal', str(target)], cwd=target)
                self.symlink(target, self.tools / 'otp')
            archive = self.state / 'cache' / f'elixir-{elixir}.zip'
            self.download(f'https://builds.hex.pm/builds/elixir/v{elixir}.zip', archive)
            target = self.tools / ('elixir-' + elixir)
            if not target.exists():
                with zipfile.ZipFile(archive) as source:
                    for entry in source.infolist():
                        path = (target / entry.filename).resolve()
                        if not path.is_relative_to(target.resolve()):
                            raise SetupError('Unsafe path in Elixir archive')
                    source.extractall(target)
                for binary in (target / 'bin').iterdir():
                    binary.chmod(0o755)
            self.symlink(target, self.tools / 'elixir')
            save(installed, versions)
        release = str(os.environ.get('CMS_HARNESS_VERSION') or self.config['harness_version']).removeprefix('v')
        if not re.fullmatch(r'\d+\.\d+\.\d+', release):
            raise SetupError('CMS_HARNESS_VERSION must pin a published version, e.g. 2.0.355')
        harness = self.tools / ('harness-' + release)
        local_archive = os.environ.get('CMS_HARNESS_ARCHIVE')
        if local_archive:
            archive = pathlib.Path(local_archive).resolve(strict=True)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            harness = self.tools / ('harness-local-' + digest[:16])
            if not (harness / 'bin/cms_harness').exists():
                self.extract(archive, harness)
        elif not (harness / 'bin/cms_harness').exists():
            archive = self.state / 'cache' / f'cms-{release}-linux-x64.tar.gz'
            self.download(f'https://github.com/Code-My-Spec/plugins/releases/download/v{release}/cms-linux-x64.tar.gz', archive)
            self.extract(archive, harness)
        self.symlink(harness, self.tools / 'harness')
        run(['mix', 'local.hex', '--force'], cwd=self.root, env=self.env)
        run(['mix', 'local.rebar', '--force'], cwd=self.root, env=self.env)
        run(['git', 'submodule', 'update', '--init', '--recursive'], cwd=self.root)
        self.native_dependencies()
        self.validate_target()
        self.environment_file()
        return {'installed': True, 'next': 'Run the startup script to authorize the box and connect the harness'}

    def native_dependencies(self):
        lock = (self.root / 'mix.lock').read_text()
        if '"rustler"' in lock and not (self.tools / 'cargo/bin/rustc').exists():
            installer = self.state / 'cache/rustup.sh'
            self.download('https://sh.rustup.rs', installer)
            rust = os.environ.get('CMS_RUST_VERSION', '1.99.1')
            if not re.fullmatch(r'\d+\.\d+\.\d+', rust):
                raise SetupError('CMS_RUST_VERSION must pin a numeric Rust version')
            run(['sh', str(installer), '-y', '--profile', 'minimal', '--no-modify-path', '--default-toolchain', rust], env=self.env)
        if '"ortex"' in lock and not (self.tools / 'onnxruntime-linux-x64-1.19.2').exists():
            archive = self.state / 'cache/onnxruntime-1.19.2.tgz'
            self.download('https://github.com/microsoft/onnxruntime/releases/download/v1.19.2/onnxruntime-linux-x64-1.19.2.tgz', archive)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != 'eb00c64e0041f719913c4080e0fed7d9963dc3aa9b54664df6036d8308dbcd33':
                raise SetupError('ONNX archive checksum mismatch; remove the cached archive and retry')
            self.extract(archive, self.tools)
        migrations = self.root / 'priv/repo/migrations'
        needs_vector = '"pgvector"' in lock or (migrations.exists() and any('vector' in p.read_text() for p in migrations.glob('*.exs')))
        if needs_vector:
            self.database()
            if getattr(self, 'db_container', None):
                command = ['docker', 'exec', '-e', 'PGPASSWORD', self.db_container, 'psql', '-h', '127.0.0.1', '-U', self.env.get('PGUSER', 'postgres'), '-d', 'postgres', '-tAc', "SELECT count(*) FROM pg_available_extensions WHERE name = 'vector'"]
                result = subprocess.run(command, env=dict(self.env, PGPASSWORD=self.env.get('PGPASSWORD', 'postgres')), capture_output=True, text=True)
                if result.returncode or result.stdout.strip() != '1':
                    raise SetupError('Selected PostgreSQL container lacks pgvector; install it in that server or choose the supplied pinned pgvector image')
                return
            if not shutil.which('pg_config'):
                raise SetupError('Target needs pgvector; install it in the selected PostgreSQL server or use CMS_POSTGRES_MODE=docker')
            sharedir = pathlib.Path(subprocess.check_output(['pg_config', '--sharedir'], text=True).strip())
            if not (sharedir / 'extension/vector.control').exists():
                archive = self.state / 'cache/pgvector-0.8.1.tar.gz'
                self.download('https://github.com/pgvector/pgvector/archive/refs/tags/v0.8.1.tar.gz', archive)
                with tempfile.TemporaryDirectory(dir=self.tools) as temp:
                    self.extract(archive, pathlib.Path(temp))
                    source = pathlib.Path(temp) / 'pgvector-0.8.1'
                    run(['make'], cwd=source)
                    run(self.privilege() + ['make', 'install'], cwd=source)

    @staticmethod
    def symlink(target, link):
        if link.is_symlink():
            link.unlink()
        elif link.exists():
            raise SetupError(f'{link} is not a managed symlink; move it before retrying')
        link.symlink_to(target)

    def database(self):
        self.initialize_provisioned_postgres()
        mode = os.environ.get('CMS_POSTGRES_MODE', 'auto')
        if mode not in ('auto', 'existing', 'docker', 'system'):
            raise SetupError('CMS_POSTGRES_MODE must be auto, existing, docker or system')
        pg_env = dict(self.env, PGPASSWORD=self.env.get('PGPASSWORD', 'postgres'), PGCONNECT_TIMEOUT='5')
        # Verify authentication, not just a listening TCP port; never change existing credentials.
        client = ['psql', '-h', self.env.get('PGHOST', '127.0.0.1'), '-p', self.env.get('PGPORT', '5432'),
                  '-U', self.env.get('PGUSER', 'postgres'), '-d', 'postgres', '-tAc', 'SELECT 1']
        if shutil.which('psql') and mode != 'docker':
            if subprocess.run(client, env=pg_env, capture_output=True).returncode == 0:
                return
        if mode == 'existing':
            raise SetupError('Existing PostgreSQL authentication failed; provide psql and correct PGHOST/PGPORT/PGUSER/PGPASSWORD matching target config')
        if mode in ('auto', 'docker') and shutil.which('docker'):
            name = os.environ.get('CMS_POSTGRES_CONTAINER')
            if not name:
                listed = subprocess.run(['docker', 'ps', '-aq', '--filter', 'publish=5432'], capture_output=True, text=True)
                found = listed.stdout.split()
                if listed.returncode:
                    raise SetupError('Docker is unavailable; start its daemon or provide an authenticated PostgreSQL server')
                if len(found) > 1:
                    raise SetupError('Multiple PostgreSQL containers found; select CMS_POSTGRES_CONTAINER explicitly')
                name = found[0] if found else 'codemyspec-postgres-' + hashlib.sha256(self.config['device_id'].encode()).hexdigest()[:12]
            exists = subprocess.run(['docker', 'container', 'inspect', name], capture_output=True).returncode == 0
            if exists:
                run(['docker', 'start', name])
            else:
                run(['docker', 'run', '-d', '--name', name, '-e', 'POSTGRES_PASSWORD=postgres',
                     '-p', '127.0.0.1:5432:5432', '-v', name + '-data:/var/lib/postgresql/data',
                     'pgvector/pgvector@sha256:ac08538c6f8b9904c33c8224c5e5706dbe760aca29db1d096972b4052c22a75d'])
            command = ['docker', 'exec', '-e', 'PGPASSWORD', name, 'psql', '-h', '127.0.0.1',
                       '-U', self.env.get('PGUSER', 'postgres'), '-d', 'postgres', '-tAc', 'SELECT 1']
            for attempt in range(30):
                if subprocess.run(command, env=pg_env, capture_output=True).returncode == 0:
                    self.db_container = name
                    return
                time.sleep(1)
            raise SetupError('Docker PostgreSQL failed authentication/readiness; inspect docker logs and match target database credentials')
        if not shutil.which('pg_isready'):
            raise SetupError('Cannot safely initialize PostgreSQL without pg_isready; provide an authenticated server or use Docker')
        listening = subprocess.run(['pg_isready', '-h', self.env.get('PGHOST', '127.0.0.1'),
                                    '-p', self.env.get('PGPORT', '5432')], capture_output=True)
        if listening.returncode in (0, 1):
            raise SetupError('Existing PostgreSQL is listening but authentication failed; supply matching target credentials. Existing passwords are not changed')
        if self.env.get('PGHOST', '127.0.0.1') not in ('127.0.0.1', 'localhost') or self.env.get('PGPORT', '5432') != '5432':
            raise SetupError('Configured PostgreSQL is unreachable; restore it before retrying startup')
        if mode != 'system':
            raise SetupError('No authenticated database is available; use CMS_POSTGRES_MODE=docker, or explicitly select CMS_POSTGRES_MODE=system to initialize the stopped local service')
        run(self.privilege() + ['service', 'postgresql', 'start'])
        # Initialize only the previously stopped local system service; never reset a listening server.
        run(self.privilege() + ['runuser', '-u', 'postgres', '--', 'psql', '-c', "ALTER USER postgres PASSWORD 'postgres'"])
        if subprocess.run(client, env=pg_env, capture_output=True).returncode:
            raise SetupError('System PostgreSQL did not authenticate after startup; check target credentials')

    def validate_target(self):
        self.database()
        settings = self.root / '.claude/settings.local.json'
        if settings.exists():
            partition = read(settings).get('env', {}).get('MIX_TEST_PARTITION')
            if partition:
                self.env['MIX_TEST_PARTITION'] = partition
        if self.validated():
            return
        save(self.state / 'validation.json', {'root': str(self.root), 'status': 'running'})
        for environment in ('dev', 'test'):
            env = dict(self.env, MIX_ENV=environment)
            run(['mix', 'deps.get', '--check-locked'], cwd=self.root, env=env)
            run(['mix', 'compile'], cwd=self.root, env=env)
            partitions = [env.get('MIX_TEST_PARTITION', '')]
            if environment == 'test' and partitions[0]:
                partitions += [partitions[0] + 's', partitions[0] + 'a']
            for partition in partitions:
                db_env = dict(env, MIX_TEST_PARTITION=partition)
                run(['mix', 'ecto.create'], cwd=self.root, env=db_env)
                run(['mix', 'ecto.migrate'], cwd=self.root, env=db_env)
        run(['mix', 'assets.setup'], cwd=self.root, env=dict(self.env, MIX_ENV='dev'))
        run(['mix', 'assets.build'], cwd=self.root, env=dict(self.env, MIX_ENV='dev'))
        save(self.state / 'validation.json', {'root': str(self.root), 'status': 'passed', 'fingerprint': fingerprint(self.root)})

    def environment_file(self):
        names = ('PATH', 'MIX_HOME', 'HEX_HOME', 'ERL_FLAGS', 'CARGO_HOME', 'RUSTUP_HOME',
                 'ORT_LIB_LOCATION', 'ORT_PREFER_DYNAMIC_LINK', 'LD_LIBRARY_PATH', 'MIX_TEST_PARTITION')
        path = self.state / 'environment.sh'
        path.write_text('# Source this file before running target project commands.\n' +
                        ''.join('export ' + key + '=' + shlex.quote(self.env[key]) + '\n' for key in names if key in self.env))
        path.chmod(0o600)

    def project(self):
        project = os.environ.get('CMS_PROJECT_ID') or self.config.get('project_id')
        if not project and (self.root / '.cms_harness.json').exists():
            project = read(self.root / '.cms_harness.json').get('project_id')
        if not project:
            path = self.root / '.code_my_spec/config.yml'
            if path.exists():
                found = re.search(r'^project_id:\s*["\']?([a-fA-F0-9-]{36})', path.read_text(), re.M)
                if found:
                    project = found.group(1)
        if not project:
            raise SetupError('Set CMS_PROJECT_ID to this target project on the selected CodeMySpec server, then rerun startup')
        if self.config.get('project_id') and project != self.config['project_id']:
            raise SetupError('CMS_PROJECT_ID disagrees with this dev box; create a separate box for another project')
        self.config['project_id'] = project
        save(self.state / 'config.json', self.config)

    def start(self):
        self.project()
        self.validate_target()
        try:
            ready = self.check()
        except SetupError:
            ready = None
        if ready:
            self.environment_file()
            return self.session() if os.environ.get('CODEX_THREAD_ID') else ready
        executable = self.tools / 'harness/bin/cms_harness'
        if not executable.exists():
            raise SetupError('Linux harness release is missing; run setup first')
        # Never spawn a second process on an occupied port.
        try:
            status = self.health()
        except SetupError:
            status = None
        if status is not None and (status.get('device_id') != self.config['device_id'] or status.get('server_url', '').rstrip('/') != self.config['server_url'].rstrip('/') or not any(p.get('root') == str(self.root) for p in status.get('projects', []))):
            raise SetupError('Local port is occupied by another harness/server/project; set CMS_HARNESS_PORT to an unused port and rerun startup')
        process = None
        running = False
        previous = self.state / 'process.json'
        if previous.exists():
            pid = read(previous).get('pid')
            try:
                command = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes()
                running = str(self.state / 'codex_cloud_boot.exs').encode() in command
            except OSError:
                pass
        if status is None and not running:
            (self.state / 'authorization.json').unlink(missing_ok=True)
            log = self.state / 'harness.log'
            with log.open('a') as output:
                log.chmod(0o600)
                boot = str(self.state / 'codex_cloud_boot.exs')
                expression = 'Code.eval_file(' + json.dumps(boot) + ')'
                process = subprocess.Popen([str(executable), 'eval', expression], cwd=self.root,
                    env=self.env, stdin=subprocess.DEVNULL, stdout=output, stderr=output, start_new_session=True)
            save(self.state / 'process.json', {'pid': process.pid, 'root': str(self.root)})
        deadline = time.monotonic() + int(os.environ.get('CMS_CLOUD_START_TIMEOUT', '900'))
        last_grant = None
        failure = 'Harness has not connected'
        while time.monotonic() < deadline:
            auth = self.state / 'authorization.json'
            if auth.exists():
                grant = read(auth)
                if grant.get('phase') == 'pending' and grant != last_grant:
                    print(json.dumps({'authorization_required': True, **grant}), flush=True)
                    last_grant = grant
            try:
                health = self.health()
            except SetupError as error:
                failure = str(error)
            else:
                if any(p.get('root') == str(self.root) and all(p.get(k) is True for k in ('connected', 'watching', 'onboarded')) for p in health.get('projects', [])):
                    self.validate_target()
                    ready = self.check()
                    self.environment_file()
                    return self.session() if os.environ.get('CODEX_THREAD_ID') else {**ready, 'next': 'Run session inside each Codex conversation'}
                failure = 'Harness is not connected, watching and onboarded; check proxy access and device authorization'
            if process is not None and process.poll() is not None:
                raise SetupError(f'Harness exited ({process.returncode}); inspect {self.state / "harness.log"} and rerun startup')
            time.sleep(1)
        raise SetupError(f'{failure}. Startup timed out; inspect {self.state / "harness.log"} and rerun startup')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('install', 'start', 'resume', 'check', 'session', 'mcp'))
    parser.add_argument('--root', default=os.getcwd())
    parser.add_argument('--state', default=str(pathlib.Path(__file__).resolve().parent))
    parser.add_argument('--url', default='http://127.0.0.1:' + os.environ.get('CMS_HARNESS_PORT', '4004'))
    args = parser.parse_args()
    try:
        cloud = Cloud(args)
        lock = None
        if args.command in ('install', 'start', 'resume'):
            lock = (cloud.state / 'lifecycle.lock').open('a')
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SetupError('Setup or startup is already running for this box; finish its device authorization or wait for it to complete')
        result = getattr(cloud, 'start' if args.command == 'resume' else args.command)()
        print(json.dumps(result), flush=True)
    except (SetupError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'CodeMySpec Codex Cloud: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
