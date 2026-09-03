#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Locate or clone rules_rs repository
RULES_RS_DIR="${RULES_RS_DIR:-}"
if [[ -z "${RULES_RS_DIR}" ]]; then
  if [[ -d "../rules_rs" ]]; then
    RULES_RS_DIR="../rules_rs"
  elif [[ -d "/usr/local/google/home/lucadv/rules_rs" ]]; then
    RULES_RS_DIR="/usr/local/google/home/lucadv/rules_rs"
  else
    RULES_RS_DIR="$(pwd)/.rules_rs_repo"
    if [[ ! -d "${RULES_RS_DIR}" ]]; then
      echo "=== rules_rs repository not found locally. Cloning into ${RULES_RS_DIR}... ==="
      git clone https://github.com/luca-della-vedova/rules_rs.git "${RULES_RS_DIR}"
    fi
  fi
fi

WORKTREE_DIR="$(pwd)/.rules_rs_worktree"

if [[ "${1:-}" == "--fix" ]]; then
  TARGET_REV="${FIX_REV:-}"
  if [[ -z "${TARGET_REV}" ]]; then
    if git -C "${RULES_RS_DIR}" rev-parse --verify 6120dfc >/dev/null 2>&1; then
      TARGET_REV="6120dfc"
    else
      TARGET_REV="HEAD"
    fi
  fi
  echo "=== Testing rules_rs WITH fix (${TARGET_REV}) ==="
else
  TARGET_REV="${BROKEN_REV:-}"
  if [[ -z "${TARGET_REV}" ]]; then
    if git -C "${RULES_RS_DIR}" rev-parse --verify 1600851 >/dev/null 2>&1; then
      TARGET_REV="1600851"
    else
      TARGET_REV="HEAD~1"
    fi
  fi
  echo "=== Testing rules_rs WITHOUT fix - reproducing failure (${TARGET_REV}) ==="
  echo "(Run with --fix to test with the fix)"
fi

TARGET_COMMIT="$(git -C "${RULES_RS_DIR}" rev-parse "${TARGET_REV}")"
COMMIT_MSG="$(git -C "${RULES_RS_DIR}" log -1 --pretty=format:'%h ("%s")' "${TARGET_COMMIT}")"
echo "Target rules_rs commit: ${COMMIT_MSG}"

git -C "${RULES_RS_DIR}" worktree prune
if [[ ! -d "${WORKTREE_DIR}" ]]; then
  git -C "${RULES_RS_DIR}" worktree add --detach "${WORKTREE_DIR}" "${TARGET_COMMIT}" >/dev/null 2>&1
else
  git -C "${WORKTREE_DIR}" checkout --detach "${TARGET_COMMIT}" >/dev/null 2>&1
fi

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

