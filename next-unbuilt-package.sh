#!/bin/bash

set -euxo pipefail

cd "$(dirname "$0")"

# FIXME: make a signal handler that cleans this up if we exit early.
if [ ! -d "${TEMPDIR:-}" ]; then
  TEMPDIR="$(mktemp -d)"
fi

if [[ "${TARGET-}" == "" ]]; then
  TARGET=$(rustc --version --verbose | sed -n 's/host: //p')
  export TARGET
fi

if [[ ! -f "${EXCLUDE_FILE?}" ]]; then
  exit 1
fi

POPULAR_CRATES=$(
  (./get-stats.sh && cat ./popular-crates.txt) | (
    grep -v '^#' |
      grep -v '/' |
      grep -A1000 --line-regexp "${START_AFTER_CRATE:-.*}" |
      # drop the first line (the one that matched)
      tail -n +2 ||
      # If we don't find anything (package stopped being popular?)
      # then fall back to doing a self-build.
      echo 'cargo-quickinstall'
  )
)

# see crawler policy: https://crates.io/policies
curl_slowly() {
  sleep 1 && curl --silent --show-error --user-agent "cargo-quickinstall build pipeline (alsuren@gmail.com)" "$@"
}

for CRATE in $POPULAR_CRATES; do
  if grep --line-regexp "$CRATE" "${EXCLUDE_FILE?}" >/dev/null; then
    echo "skipping $CRATE because it has failed too many times" 1>&2
    continue
  fi

  rm -rf "$TEMPDIR/crates.io-response.json"
  curl_slowly --location --fail "https://crates.io/api/v1/crates/${CRATE}" >"$TEMPDIR/crates.io-response.json"
  VERSION=$(cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].num)
  LICENSE=$(cat "$TEMPDIR/crates.io-response.json" | jq -r .versions[0].license | sed -e 's:/:", ":g' -e 's/ OR /", "/g')

  if curl_slowly --fail -I --output /dev/null "https://github.com/alsuren/cargo-quickinstall/releases/download/${CRATE}-${VERSION}-${TARGET}/${CRATE}-${VERSION}-${TARGET}.tar.gz"; then
    echo "${CRATE}-${VERSION}-${TARGET}.tar.gz already uploaded. Keep going." 1>&2
  else
    echo "${CRATE}-${VERSION}-${TARGET}.tar.gz needs building" 1>&2
    echo "::set-output name=crate_to_build::$CRATE"
    echo "::set-output name=version_to_build::$VERSION"
    echo "::set-output name=arch_to_build::$TARGET"
    exit 0
  fi
done
# If there's nothing to build, just build ourselves.
VERSION=$(curl_slowly --location --fail "https://crates.io/api/v1/crates/cargo-quickinstall" | jq -r .versions[0].num)
echo "::set-output name=crate_to_build::cargo-quickinstall"
echo "::set-output name=version_to_build::$VERSION"
echo "::set-output name=arch_to_build::$TARGET"
