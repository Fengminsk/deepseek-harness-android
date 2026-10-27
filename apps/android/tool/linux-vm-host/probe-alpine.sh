set -e
uname -srm
cat /etc/alpine-release
python3 -c 'import sys,ssl,sqlite3,subprocess,hashlib,zipfile; print(sys.version); assert subprocess.check_output(["/bin/sh","-c","printf linux-child"]) == b"linux-child"; print(hashlib.sha256(b"DSH").hexdigest()); print(sqlite3.sqlite_version); print(ssl.OPENSSL_VERSION)'
timeout 8 python3 -c 'import os,threading,time; print(os.urandom(16).hex()); t=threading.Thread(target=lambda: print(time.monotonic())); t.start(); t.join()'
git --version
curl --version | head -n 2
printf agent-file > /workspace/agent-test.txt
python3 -c 'from pathlib import Path; assert Path("/workspace/agent-test.txt").read_text()=="agent-file"; print("DSH_PYTHON_FILES_OK")'
rm -f /workspace/agent-test.txt /tmp/dsh-command.sh /tmp/dsh-command.b64
sync
printf 'DSH_ALPINE_RUNTIME_OK\n'
