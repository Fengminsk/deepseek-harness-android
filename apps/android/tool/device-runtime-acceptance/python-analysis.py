"""Analyze acceptance-owned files using only the delivered Python standard library."""

import base64
import hashlib
import json
from pathlib import Path
import platform
import sqlite3
import ssl
import subprocess
import sys
import tempfile
import zipfile


def analyze(encoded):
    payload = base64.b64decode(encoded, validate=True)
    document = json.loads(payload)
    assert len(payload) <= 4096 and len(document['files']) == 3
    with tempfile.TemporaryDirectory(prefix='dsh-python-analysis-', dir='.') as directory:
        root = Path(directory)
        source = root / 'source.json'
        source.write_bytes(payload)
        assert json.loads(source.read_text(encoding='utf-8')) == document
        rows = []
        for entry in document['files']:
            name = entry['name']
            assert Path(name).name == name and name not in ('.', '..')
            data = entry['text'].encode('utf-8')
            path = root / name
            path.write_bytes(data)
            actual = path.read_bytes()
            rows.append((name, len(actual), hashlib.sha256(actual).hexdigest(), entry['kind']))

        archive = root / 'analysis.zip'
        with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as output:
            output.write(source, 'source.json')
            for name, _, _, _ in rows:
                output.write(root / name, name)
        with zipfile.ZipFile(archive) as saved:
            assert saved.testzip() is None
            assert saved.read('source.json') == payload
            assert all(hashlib.sha256(saved.read(name)).hexdigest() == digest for name, _, digest, _ in rows)
            entries = sorted(saved.namelist())

        database = root / 'analysis.sqlite'
        connection = sqlite3.connect(database)
        try:
            connection.execute('CREATE TABLE files (name TEXT PRIMARY KEY, bytes INTEGER, sha256 TEXT, kind TEXT)')
            connection.executemany('INSERT INTO files VALUES (?, ?, ?, ?)', rows)
            connection.commit()
        finally:
            connection.close()
        connection = sqlite3.connect(database)
        try:
            assert connection.execute('PRAGMA integrity_check').fetchone() == ('ok',)
            stored = connection.execute('SELECT name, bytes, sha256, kind FROM files ORDER BY name').fetchall()
            assert stored == sorted(rows)
            groups = connection.execute('SELECT kind, count(*), sum(bytes) FROM files GROUP BY kind ORDER BY kind').fetchall()
        finally:
            connection.close()

        child_code = (
            'import hashlib,json,sys,zipfile; '
            'z=zipfile.ZipFile(sys.argv[1]); p=z.read("source.json"); '
            'd=json.loads(p); print(json.dumps({"sha256":hashlib.sha256(p).hexdigest(),'
            '"token":d["token"],"entries":sorted(z.namelist())}))'
        )
        child = subprocess.run([sys.executable, '-c', child_code, str(archive)],
                               check=True, capture_output=True, text=True, timeout=30)
        child_result = json.loads(child.stdout)
        digest = hashlib.sha256(payload).hexdigest()
        assert child_result == {'sha256': digest, 'token': document['token'], 'entries': entries}
        tls = ssl.create_default_context()
        assert tls.check_hostname and tls.verify_mode == ssl.CERT_REQUIRED
        assert tls.cert_store_stats()['x509_ca'] > 0
        return {
            'check': 'python-stdlib-file-analysis-v1',
            'token': document['token'], 'inputSha256': digest,
            'files': stored, 'groups': groups, 'zipEntries': entries,
            'subprocess': child_result,
            'pythonVersion': platform.python_version(), 'platform': sys.platform,
            'machine': platform.machine(), 'sqliteVersion': sqlite3.sqlite_version,
            'opensslVersion': ssl.OPENSSL_VERSION,
            'tls': {'checkHostname': tls.check_hostname,
                    'certificateRequired': tls.verify_mode == ssl.CERT_REQUIRED,
                    'caCount': tls.cert_store_stats()['x509_ca']},
        }


if __name__ == '__main__':
    print(json.dumps(analyze(sys.argv[1]), ensure_ascii=True, separators=(',', ':')))
