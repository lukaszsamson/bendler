#!/usr/bin/env bash
# LLVM's official release assets are pinned by both version and SHA-256. Bend
# emits a musttail runtime using preserve_none/preserve_most, so CI does not use
# the runner's system compiler for this ABI-sensitive code.
set -euo pipefail

: "${LLVM_ASSET:?set LLVM_ASSET}"
: "${LLVM_SHA256:?set LLVM_SHA256}"

readonly version=21.1.8
readonly destination="${RUNNER_TEMP:?RUNNER_TEMP is required}/llvm-${version}"
readonly url="https://github.com/llvm/llvm-project/releases/download/llvmorg-${version}/${LLVM_ASSET}"

case "${LLVM_ASSET}" in
  LLVM-21.1.8-Linux-X64.tar.xz)
    readonly expected_sha256=b3b7f2801d15d50736acea3c73982994d025b01c2f035b91ae3b49d1b575732b
    ;;
  LLVM-21.1.8-macOS-ARM64.tar.xz)
    readonly expected_sha256=b95bdd32a33a81ee4d40363aaeb26728a26783fcef26a4d80f65457433ea4669
    ;;
  *)
    echo "unsupported LLVM asset: ${LLVM_ASSET}" >&2
    exit 2
    ;;
esac

if [[ "${LLVM_SHA256}" != "${expected_sha256}" ]]; then
  echo "LLVM_SHA256 does not match the pinned ${version} asset digest" >&2
  exit 2
fi

curl --fail --location --retry 3 --retry-all-errors --output "${LLVM_ASSET}" "${url}"

if command -v sha256sum >/dev/null 2>&1; then
  printf '%s  %s\n' "${expected_sha256}" "${LLVM_ASSET}" | sha256sum --check --status -
else
  printf '%s  %s\n' "${expected_sha256}" "${LLVM_ASSET}" | shasum -a 256 --check --status
fi

if [[ -e "${destination}" ]]; then
  echo "refusing to reuse existing installation directory: ${destination}" >&2
  exit 2
fi
mkdir -p "${destination}"
tar -xJf "${LLVM_ASSET}" -C "${destination}" --strip-components=1

test -x "${destination}/bin/clang"
echo "${destination}/bin" >> "${GITHUB_PATH:?GITHUB_PATH is required}"
"${destination}/bin/clang" --version
