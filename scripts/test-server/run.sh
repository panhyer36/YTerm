#!/bin/bash
# Starts a throwaway Ubuntu sshd in Docker on 127.0.0.1:2223 (user tester / password testpass)
# and prints the environment variables for the integration tests.
set -euo pipefail
cd "$(dirname "$0")"
WORK="${TMPDIR:-/tmp}/yterm-test-server"
mkdir -p "$WORK"
[ -f "$WORK/client_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$WORK/client_key"
cp "$WORK/client_key.pub" authorized_keys
docker build -t yterm-test . >/dev/null
docker rm -f yterm-test >/dev/null 2>&1 || true
docker run -d --name yterm-test -p 127.0.0.1:2223:22 yterm-test >/dev/null
rm -f authorized_keys
echo "sshd 已啟動：ssh -i $WORK/client_key -p 2223 tester@127.0.0.1（密碼 testpass）"
echo
echo "整合測試："
echo "YTERM_IT_HOST=127.0.0.1 YTERM_IT_PORT=2223 YTERM_IT_USER=tester YTERM_IT_PASSWORD=testpass \\"
echo "YTERM_IT_IDENTITY=$WORK/client_key YTERM_IT_KNOWN_HOSTS=$WORK/known_hosts swift test --filter RemoteIntegrationTests"
echo
echo "停止：docker rm -f yterm-test"
