#!/bin/bash
set -euo pipefail
if [ $# -ne 1 ]; then
    echo "usage: make-release.sh <version>" >&2
    exit 2
fi
VERSION="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

scripts/build-app.sh "$VERSION"
ditto -c -k --norsrc --noextattr --keepParent dist/Motas.app "dist/Motas-${VERSION}.zip"
shasum -a 256 "dist/Motas-${VERSION}.zip" | awk '{print $1}' > "dist/Motas-${VERSION}.zip.sha256"

SHA="$(cat "dist/Motas-${VERSION}.zip.sha256")"
CASK="packaging/homebrew/motas.rb"
python3 - "$CASK" "$VERSION" "$SHA" <<'EOF'
import re, sys
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(path).read()
t = re.sub(r'^\s*version ".*"$', f'  version "{version}"', t, flags=re.M)
t = re.sub(r'^\s*sha256 ".*"$', f'  sha256 "{sha}"', t, flags=re.M)
open(path, "w").write(t)
EOF
echo "release staged: dist/Motas-${VERSION}.zip (sha256 $SHA)"
echo "cask updated: $CASK"
