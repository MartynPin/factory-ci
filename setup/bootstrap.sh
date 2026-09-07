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
NO_PROTECT=0
[ "$DRY" = "--no-protection" ] && { NO_PROTECT=1; DRY=""; }
[ -n "$REPO" ] || { echo "Использование: bootstrap.sh <owner/repo> [--dry-run|--no-protection]" >&2; exit 1; }

OWNER="${REPO%%/*}"
run () {
  if [ "$DRY" = "--dry-run" ]; then echo "  [dry-run] $*"; else "$@"; fi
}

echo "==> Репозиторий: $REPO"

# --- 0. Предполёт настройки ------------------------------------------------
# Тариф выясняется ДО начала, а не на третьем шаге: половина применённых
# настроек хуже, чем ни одной, потому что выглядит как работающая защита.
if [ "$DRY" != "--dry-run" ]; then
  probe_out=$(gh api "repos/$REPO/branches/main/protection" 2>&1 || true)
  if printf '%s' "$probe_out" | grep -q "Upgrade to GitHub Pro"; then
    cat <<MSG
ПРЕДПОЛЁТ КРАСНЫЙ: защита ветки недоступна на текущем тарифе.

Репозиторий $REPO приватный, а branch protection на Free доступна только для
публичных репозиториев. Без неё не работают три предохранителя из пяти: запрет
прямого push в main, обязательная проверка verdict и требование апрува.

Выходы:
  1. GitHub Pro — 4 \$/мес, всё встаёт штатно.
  2. gh repo edit $REPO --visibility public --accept-visibility-change-consequences
  3. Продолжить без защиты: bootstrap.sh $REPO --no-protection

Настройка остановлена: половина применённых правил выглядит как работающая
защита, и это опаснее, чем её явное отсутствие.
MSG
    exit 2
  fi
fi


# --- 1. Доступ к reusable workflows из приватного factory-ci ---------------
# Приватный репозиторий по умолчанию не отдаёт свои workflow другим репо.
# Без этого вызов gates.yml падает с «workflow was not found».
echo "==> 1/5  Доступ к factory-ci"
# Настройка применима только к приватным репозиториям: публичный factory-ci и
# так доступен всем, и API отвечает 422. Раньше это роняло весь скрипт на
# первом шаге — и защита ветки, снятая для правки, не возвращалась.
if [ "$DRY" = "--dry-run" ]; then
  echo "  [dry-run] gh api repos/$OWNER/factory-ci/actions/permissions/access -X PUT"
else
  FC_PRIVATE=$(gh api "repos/$OWNER/factory-ci" -q .private 2>/dev/null || echo "unknown")
  if [ "$FC_PRIVATE" = "false" ]; then
    echo "    factory-ci публичный — настройка доступа не требуется"
  elif [ "$FC_PRIVATE" = "unknown" ]; then
    echo "    ВНИМАНИЕ: не удалось определить видимость factory-ci, шаг пропущен"
  else
    gh api "repos/$OWNER/factory-ci/actions/permissions/access" -X PUT -f access_level=user >/dev/null \
      && echo "    доступ открыт для репозиториев владельца" \
      || echo "    ВНИМАНИЕ: не удалось открыть доступ к factory-ci"
  fi
fi

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
# Отказ здесь — не ошибка скрипта и не ошибка агента. Чаще всего это тариф:
# на Free branch protection недоступна для приватных репозиториев. Молчаливый
# JSON с кодом 403 в этом месте выглядит как поломка, хотя это ограничение
# среды. Называем причину прямо.
protect () {
  gh api "repos/$REPO/branches/main/protection" -X PUT --input - > /tmp/fc-protect.out 2>&1
}
if [ "$NO_PROTECT" = 1 ]; then
  echo "  ПРОПУЩЕНО по флагу --no-protection. Защиты ветки нет — единственный"
  echo "  барьер это ограниченный токен агента."
  PROTECT_FAILED=1
elif [ "$DRY" = "--dry-run" ]; then
  echo "  [dry-run] gh api repos/$REPO/branches/main/protection -X PUT --input -"
else
  if ! protect <<'JSON'
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
  then
    echo
    if grep -q "Upgrade to GitHub Pro" /tmp/fc-protect.out; then
      cat <<'MSG'
  ОГРАНИЧЕНИЕ ТАРИФА, а не ошибка скрипта.

  Branch protection недоступна для приватных репозиториев на тарифе Free.
  Без неё не работают: запрет прямого push в main, обязательная проверка
  verdict и требование апрува — то есть три предохранителя из пяти.

  Три выхода:
    1. Оплатить GitHub Pro (4 $/мес) — всё встаёт штатно, ничего менять не надо.
    2. Сделать репозиторий публичным: gh repo edit REPO --visibility public
       На публичных репозиториях защита бесплатна.
    3. Работать без защиты ветки — но тогда единственным барьером остаётся
       ограниченный токен агента, и это заметно слабее.

  Остальные шаги настройки продолжаются: они от тарифа не зависят.
MSG
      PROTECT_FAILED=1
    else
      echo "  Не удалось применить защиту main:"
      sed 's/^/    /' /tmp/fc-protect.out
      exit 1
    fi
  fi
fi

# --- 4. Окружение production ----------------------------------------------
# Секреты живут здесь, а не в секретах репозитория. Джобы гейтов не объявляют
# environment — значит секретов в их окружении нет физически.
echo "==> 4/5  Окружение production"
# Обязательный ревьюер ставится здесь же: id пользователя берётся из API.
# Окружение без ревьюера — это деплой без человека, то есть отсутствие
# предохранителя при видимости его наличия.
if [ "$DRY" = "--dry-run" ]; then
  echo "  [dry-run] gh api repos/$REPO/environments/production -X PUT (с обязательным ревьюером)"
else
  UID_OWNER=$(gh api user -q .id 2>/dev/null || echo "")
  if [ -n "$UID_OWNER" ]; then
    gh api "repos/$REPO/environments/production" -X PUT --input - > /dev/null <<JSON
{
  "wait_timer": 0,
  "reviewers": [{ "type": "User", "id": $UID_OWNER }],
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
JSON
    echo "    обязательный ревьюер: пользователь $UID_OWNER"
  else
    echo "    ВНИМАНИЕ: не удалось определить id владельца — ревьюер не задан."
    echo "    Settings → Environments → production → Required reviewers."
    gh api "repos/$REPO/environments/production" -X PUT --input - > /dev/null <<'JSON'
{
  "wait_timer": 0,
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
JSON
  fi
fi

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
if [ "${PROTECT_FAILED:-0}" = 1 ]; then
  echo "Готово частично: защита main НЕ применена (см. выше)."
else
  echo "Готово. Проверьте фактическое состояние: setup/verify.sh $REPO"
fi
