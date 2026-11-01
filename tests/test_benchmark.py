"""Exercise real curl responses; no external traffic or root privileges."""
import http.server
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'benchmark.sh'


class Handler(http.server.BaseHTTPRequestHandler):
    active_downloads = 0
    lock = threading.Lock()
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path == '/denied':
            self.send_response(403)
            self.end_headers()
            self.wfile.write(b'x')
            return
        self.send_response(200)
        self.send_header('Content-Length', str(10**10 if self.path == '/large' else 1))
        self.end_headers()
        try:
            if self.path == '/large':
                with self.lock:
                    type(self).active_downloads += 1
                while True:
                    self.wfile.write(b'x' * 65536)
                    time.sleep(.005)
            else:
                self.wfile.write(b'x')
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            if self.path == '/large':
                with self.lock:
                    type(self).active_downloads -= 1


class BenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()

    def run_benchmark(self, path):
        with tempfile.TemporaryDirectory() as root:
            url = f'http://127.0.0.1:{self.server.server_port}'
            result = subprocess.run(['bash', str(SCRIPT), '--download-url', url+path,
                '--probe-url', url+'/small', '--seconds', '5', '--parallel', '2',
                '--output', root+'/result'], text=True, capture_output=True, timeout=20)
            self.assertTrue(Path(root, 'result/probes.tsv').exists())
            return result

    def test_sustained_download_and_response_probes(self):
        result = self.run_benchmark('/large')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('Failed downloads: 0 / 2', result.stdout)
        self.assertIn('TTFB median', result.stdout)
        self.assertIn('Aggregate download rate', result.stdout)

    def test_http_denial_cannot_be_reported_as_successful_load(self):
        result = self.run_benchmark('/denied')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Failed downloads: 2 / 2', result.stdout)
        self.assertNotIn('Aggregate download rate', result.stdout)
        self.assertIn('loaded-latency result is invalid', result.stderr)

    def test_small_file_does_not_count_as_sustained_load(self):
        result = self.run_benchmark('/small')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Downloads ended too early', result.stderr)

    def test_termination_stops_background_downloads(self):
        with tempfile.TemporaryDirectory() as root:
            url = f'http://127.0.0.1:{self.server.server_port}'
            process = subprocess.Popen(['bash', str(SCRIPT), '--download-url', url+'/large',
                '--probe-url', url+'/small', '--seconds', '120', '--parallel', '2',
                '--output', root+'/result'], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic()+8
                while Handler.active_downloads < 2 and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertEqual(Handler.active_downloads, 2)
                process.terminate()
                process.communicate(timeout=5)
                self.assertNotEqual(process.returncode, 0)
                deadline = time.monotonic()+2
                while Handler.active_downloads and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertEqual(Handler.active_downloads, 0)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)


if __name__ == '__main__':
    unittest.main(verbosity=2)
