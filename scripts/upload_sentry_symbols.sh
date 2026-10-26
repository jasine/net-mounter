#!/bin/bash
set -euo pipefail

# Upload only symbols from the build that will ship; never include source files.
if [ "$#" -ne 1 ] || [ ! -d "$1" ] || [[ "$1" != *.dSYM ]]; then
    echo "Usage: $0 /absolute/path/to/NetMounter.dSYM" >&2
    exit 1
fi
command -v sentry-cli >/dev/null || { echo "Install sentry-cli before uploading symbols." >&2; exit 1; }
: "${SENTRY_AUTH_TOKEN:?Provide a Sentry upload token through the environment, never in source control.}"
export SENTRY_ORG="context-tech-gq"
export SENTRY_PROJECT="net-mounter"
export SENTRY_URL="https://us.sentry.io/"
sentry-cli debug-files upload "$1"
