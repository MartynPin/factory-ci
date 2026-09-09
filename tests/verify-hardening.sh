#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATES="$ROOT/.github/workflows/gates.yml"
BOOTSTRAP="$ROOT/setup/bootstrap.sh"
VERIFY="$ROOT/setup/verify.sh"

fail () {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

grep -q 'needs: \[deps-guard\]' "$GATES" || fail "install jobs do not depend on deps-guard"
grep -q 'npm ci --ignore-scripts' "$GATES" || fail "install scripts are not disabled"
! grep -q 'npm rebuild' "$GATES" || fail "head-defined install allowlist is executable"
! grep -Eq 'npm run (lint|typecheck|test:unit|build)' "$GATES" || fail "product scripts still determine gate results"
! grep -Eq 'uses:[[:space:]]+[^#[:space:]]+@v[0-9]' "$GATES" || fail "an Action is pinned to a mutable tag"
! grep -q 'execSync(`git ' "$GATES" || fail "shell-built git command remains"
grep -q 'AGENTS.md|CLAUDE.md|package.json|package-lock.json' "$GATES" || fail "critical control files are not protected"
grep -q 'run-e2e=true, но e2e-тестов нет' "$GATES" || fail "missing e2e tests do not fail closed"
grep -q 'required_approving_review_count.*1' "$BOOTSTRAP" || fail "bootstrap does not require independent review"
grep -q "required_approving_review_count' 1" "$VERIFY" || fail "verification expects a different review policy"

printf 'OK: gate hardening invariants are present\n'
