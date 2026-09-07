#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Clone rules_rs repository into hidden folder if not present
RULES_RS_DIR="$(pwd)/.rules_rs"
RULES_RS_UPSTREAM="${RULES_RS_UPSTREAM:-https://github.com/luca-della-vedova/rules_rs.git}"

if [[ ! -d "${RULES_RS_DIR}" ]]; then
  echo "=== Cloning rules_rs repository into ${RULES_RS_DIR}... ==="
  git clone "${RULES_RS_UPSTREAM}" "${RULES_RS_DIR}"
fi

if [[ "${1:-}" == "--fix" ]]; then
  TARGET_REV="${FIX_REV:-2d856b2}"
  echo "=== Testing rules_rs WITH fix (${TARGET_REV}) ==="
else
  TARGET_REV="${BROKEN_REV:-1600851}"
  echo "=== Testing rules_rs WITHOUT fix - reproducing failure (${TARGET_REV}) ==="
  echo "(Run with --fix to test with the fix)"
fi

# Fetch remote updates if target commit is not present locally
if ! git -C "${RULES_RS_DIR}" rev-parse --verify "${TARGET_REV}" >/dev/null 2>&1; then
  git -C "${RULES_RS_DIR}" fetch origin
fi

TARGET_COMMIT="$(git -C "${RULES_RS_DIR}" rev-parse "${TARGET_REV}")"
COMMIT_MSG="$(git -C "${RULES_RS_DIR}" log -1 --pretty=format:'%h ("%s")' "${TARGET_COMMIT}")"
echo "Target rules_rs commit: ${COMMIT_MSG}"

git -C "${RULES_RS_DIR}" checkout --detach "${TARGET_COMMIT}" >/dev/null 2>&1

echo "=== Querying Bazel output base ==="
OUTPUT_BASE="$(bazel info output_base)"
# In hermetic execution (e.g. RBE in CI), undeclared files from the toolchain archive are not mounted.
# On a local workstation, linux-sandbox mounts host paths unless blocked.
# Blocking the undeclared rustlib 'bin' directory simulates the hermetic RBE / container environment.
BLOCKED_PATH="${OUTPUT_BASE}/external/rules_rs++toolchains+rustc_linux_x86_64_1_93_0/lib/rustlib/x86_64-unknown-linux-gnu/bin"

# Ensure repo is fetched so the path exists before blocking
bazel fetch @rules_rs//... >/dev/null 2>&1 || true

# Invalidate previous binary output to force recompilation
rm -f bazel-bin/hello_bin

bazel build --sandbox_block_path="${BLOCKED_PATH}" //:hello_bin
