"""Exercise the shipped command hook against a real loopback HTTP receiver."""
import http.server
import json
import os
import pathlib
import subprocess
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
HOOK = ROOT / 'plugins/claude/hooks/post-hook.cjs'


class HookTests(unittest.TestCase):
    def test_port_override_and_response(self):
        received = []
        answer = b'{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"ready"}}'

        class Receiver(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                # Node streams stdin with chunked transfer encoding.
                body = b''
                while True:
                    size = int(self.rfile.readline().strip(), 16)
                    if size == 0:
                        self.rfile.readline()
                        break
                    body += self.rfile.read(size)
                    self.rfile.read(2)
                received.append((self.path, body))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(answer)

            def log_message(self, *_):
                pass

        with http.server.HTTPServer(('127.0.0.1', 0), Receiver) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                manifest = json.loads((ROOT / 'plugins/claude/hooks/hooks.json').read_text())
                for groups in manifest['hooks'].values():
                    command = groups[0]['hooks'][0]['command']
                    event = command.rsplit(' ', 1)[1]
                    payload = b'{"session_id":"cloud-probe","cwd":"/repo"}'
                    result = subprocess.run(['node', str(HOOK), event], input=payload,
                        capture_output=True, timeout=10,
                        env={**os.environ, 'CMS_HARNESS_PORT': str(server.server_port)})
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout, answer)
                    self.assertEqual(received[-1], ('/api/hooks/' + event, payload))
            finally:
                server.shutdown()
                thread.join()

    def test_invalid_port_is_reported(self):
        result = subprocess.run(['node', str(HOOK), 'session-start'], input=b'{}',
            capture_output=True, env={**os.environ, 'CMS_HARNESS_PORT': 'not-a-port'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b'Invalid CodeMySpec harness port', result.stderr)


if __name__ == '__main__':
    unittest.main()
