#!/usr/bin/env bash
# Настраивает продуктовый репозиторий по модели прав фабрики.
#
#   bootstrap.sh <owner/repo> [--dry-run]
#
# Идемпотентен: повторный запуск приводит настройки к ожидаемому состоянию.
# Требует gh с правами администратора репозитория (токен ВЛАДЕЛЬЦА, не агента).
set -euo pipefail

REPO="${1:-}"
DRY="${2:-}"
[ -n "$REPO" ] || { echo "Использование: bootstrap.sh <owner/repo> [--dry-run]" >&2; exit 1; }

OWNER="${REPO%%/*}"
run () {
  if [ "$DRY" = "--dry-run" ]; then echo "  [dry-run] $*"; else "$@"; fi
}

echo "==> Репозиторий: $REPO"

# --- 1. Доступ к reusable workflows из приватного factory-ci ---------------
# Приватный репозиторий по умолчанию не отдаёт свои workflow другим репо.
# Без этого вызов gates.yml падает с «workflow was not found».
echo "==> 1/5  Доступ к factory-ci"
run gh api "repos/$OWNER/factory-ci/actions/permissions/access" \
  -X PUT -f access_level=user

# --- 2. Права GITHUB_TOKEN по умолчанию ------------------------------------
# По умолчанию GitHub выдаёт токену write почти на всё. Каждая джоба обязана
# запрашивать права явно.
echo "==> 2/5  GITHUB_TOKEN → read по умолчанию"
run gh api "repos/$REPO/actions/permissions/workflow" \
  -X PUT -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=false

# --- 3. Защита main --------------------------------------------------------
# Обязательная проверка РОВНО ОДНА: verdict. GitHub засчитывает skipped как
# успех, поэтому список гейтов не выносится в настройки ветки — их собирает
# сама джоба verdict, которая запускается всегда.
echo "==> 3/5  Защита main"
run gh api "repos/$REPO/branches/main/protection" -X PUT --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["verdict"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON

# --- 4. Окружение production ----------------------------------------------
# Секреты живут здесь, а не в секретах репозитория. Джобы гейтов не объявляют
# environment — значит секретов в их окружении нет физически.
echo "==> 4/5  Окружение production"
run gh api "repos/$REPO/environments/production" -X PUT --input - <<'JSON'
{
  "wait_timer": 0,
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
JSON
echo "    Ревьюера окружения добавьте вручную: Settings → Environments →"
echo "    production → Required reviewers. Через API это требует id пользователя."

# --- 5. Метки --------------------------------------------------------------
echo "==> 5/5  Метки"
for spec in "approved:0e8a16:владелец разрешил мердж" \
            "env_fail:d93f0b:отказ окружения — попытка не засчитывается" \
            "infra:c5def5:инфраструктура фабрики"; do
  name="${spec%%:*}"; rest="${spec#*:}"
  color="${rest%%:*}"; desc="${rest#*:}"
  run gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force
done

echo
echo "Готово. Проверьте фактическое состояние: setup/verify.sh $REPO"
