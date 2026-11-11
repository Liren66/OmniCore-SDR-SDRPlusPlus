#!/usr/bin/env bash
# Install dependencies on the Ubuntu Noble GitHub-hosted runners.
set -euo pipefail
list="$RUNNER_TEMP/omnicore-ubuntu.list"
options=(-o "Dir::Etc::sourcelist=$list" -o Dir::Etc::sourceparts=-
         -o Acquire::Retries=1 -o Acquire::https::Timeout=15)
for mirror in https://mirrors.edge.kernel.org/ubuntu https://mirror.math.princeton.edu/pub/ubuntu https://archive.ubuntu.com/ubuntu; do
    for suite in noble noble-updates noble-security; do
        echo "deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $mirror $suite main universe"
    done > "$list"
    if sudo apt-get "${options[@]}" -o APT::Update::Error-Mode=any update &&
       sudo apt-get "${options[@]}" install -y --no-install-recommends "$@"; then
        exit 0
    fi
done
echo 'Ubuntu build dependencies could not be installed' >&2
exit 1
