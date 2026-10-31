#!/usr/bin/env bash
# Install exactly the Bend release supported by Bendler. The checksums below
# are the release archives published by bendlang/bend for v2.0.39.
set -euo pipefail

: "${BEND_TARGET:?set BEND_TARGET to linux-x64 or darwin-arm64}"
: "${BEND_SHA256:?set BEND_SHA256 to the archive SHA-256}"

readonly version=2.0.39
readonly archive="bend-${version}-${BEND_TARGET}.tar.gz"
readonly url="https://github.com/bendlang/bend/releases/download/v${version}/${archive}"
readonly destination="${RUNNER_TEMP:?RUNNER_TEMP is required}/bend"

case "${BEND_TARGET}" in
  linux-x64)
    readonly expected_sha256=6cf462fd8f70b094a4950ebb709a9c4ffd8f1d1189d9cedf1fd63cd5d041c7ab
    ;;
  darwin-arm64)
    readonly expected_sha256=d4aaef68de545727429ce83b9e88ff3273bf068df599e3542e446755b5f3d83a
    ;;
  *)
    echo "unsupported Bend target: ${BEND_TARGET}" >&2
    exit 2
    ;;
esac

if [[ "${BEND_SHA256}" != "${expected_sha256}" ]]; then
  echo "BEND_SHA256 does not match the pinned ${version}/${BEND_TARGET} digest" >&2
  exit 2
fi

curl --fail --location --retry 3 --retry-all-errors --output "${archive}" "${url}"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "${expected_sha256}" "${archive}" | sha256sum --check --status -
else
  printf '%s  %s\n' "${expected_sha256}" "${archive}" | shasum -a 256 --check --status
fi

if [[ -e "${destination}" ]]; then
  echo "refusing to reuse existing installation directory: ${destination}" >&2
  exit 2
fi
mkdir -p "${destination}"
tar -xzf "${archive}" -C "${destination}" --strip-components=1

test -x "${destination}/bin/bend"
echo "${destination}/bin" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
"${destination}/bin/bend" version
