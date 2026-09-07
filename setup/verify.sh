#!/usr/bin/env bash
# Проверяет ФАКТИЧЕСКОЕ состояние защиты репозитория и сравнивает с ожидаемым.
#
#   verify.sh <owner/repo>
#
# Код выхода 0 — совпадает, 1 — есть расхождения (перечислены в выводе).
#
# Зачем отдельно от bootstrap: защита ветки живёт вне git (A-13). Её нет в
# диффе, она не восстанавливается из истории, и её отключение не оставляет
# следа в коде. Единственный способ узнать, что она на месте, — спросить.
set -uo pipefail

REPO="${1:-}"
[ -n "$REPO" ] || { echo "Использование: verify.sh <owner/repo>" >&2; exit 1; }

BAD=0
say () { echo "РАСХОЖДЕНИЕ: $1"; BAD=1; }
ok  () { echo "ok  $1"; }

echo "== Защита main: $REPO =="
P=$(gh api "repos/$REPO/branches/main/protection" 2>/dev/null) || {
  say "защита main вообще не настроена"
  echo
  echo "Восстановить: setup/bootstrap.sh $REPO"
  exit 1
}

check () {           # check <jq-путь> <ожидаемое> <описание>
  local got
  got=$(printf '%s' "$P" | jq -r "$1" 2>/dev/null)
  if [ "$got" = "$2" ]; then ok "$3"; else say "$3 — ожидалось '$2', фактически '$got'"; fi
}

check '.enforce_admins.enabled'                              true  "правила действуют и на владельца"
check '.required_linear_history.enabled'                     true  "линейная история"
check '.allow_force_pushes.enabled'                          false "force-push запрещён"
check '.allow_deletions.enabled'                             false "удаление ветки запрещено"
# Апрув владельца реализован МЕТКОЙ approved, а не GitHub-ревью: при одном
# человеке в организации GitHub-ревью недостижимо — свой PR апрувить нельзя,
# а fine-grained токен агента действует от имени того же человека. Требование
# ревью здесь означало бы, что не мерджится ни один PR.
check '.required_pull_request_reviews.required_approving_review_count' 0 "PR обязан идти через pull request (апрув — меткой approved)"
check '.required_status_checks.strict'                       true  "ветка обязана быть актуальной"

# Обязательная проверка ровно одна и именно verdict: если сюда добавить
# отдельные гейты, пропущенная джоба зачтётся как успешная.
CTX=$(printf '%s' "$P" | jq -r '.required_status_checks.contexts | join(",")' 2>/dev/null)
if [ "$CTX" = "gates / verdict" ]; then
  ok "обязательная проверка ровно одна: gates / verdict"
else
  say "обязательные проверки должны быть ровно ['gates / verdict'], фактически [$CTX]"
fi

# Сверка с ФАКТИЧЕСКИ приходящими именами, а не с ожидаемым текстом настройки.
# Имя check-run у reusable workflow составное, и настройка, записанная «как
# задумано», может требовать проверку, которой не существует — тогда не
# мерджится ни один PR, и об этом узнаёшь только при первом мердже.
LAST=$(gh api "repos/$REPO/commits" -q '.[0].sha' 2>/dev/null || echo "")
if [ -n "$LAST" ]; then
  NAMES=$(gh api "repos/$REPO/commits/$LAST/check-runs" -q '.check_runs[].name' 2>/dev/null || echo "")
  if [ -z "$NAMES" ]; then
    echo "(на последнем коммите нет проверок — сверить имена не с чем)"
  elif printf '%s\n' "$NAMES" | grep -qx "$CTX"; then
    ok "требуемое имя '$CTX' совпадает с фактически приходящим"
  else
    say "требуется '$CTX', а фактически приходят: $(printf '%s' "$NAMES" | tr '\n' ',' | sed 's/,$//')"
  fi
fi

echo
echo "== Права GITHUB_TOKEN =="
W=$(gh api "repos/$REPO/actions/permissions/workflow" 2>/dev/null)
DEF=$(printf '%s' "$W" | jq -r '.default_workflow_permissions' 2>/dev/null)
[ "$DEF" = "read" ] && ok "по умолчанию read" || say "GITHUB_TOKEN по умолчанию '$DEF', ожидалось 'read'"

APR=$(printf '%s' "$W" | jq -r '.can_approve_pull_request_reviews' 2>/dev/null)
[ "$APR" = "false" ] && ok "workflow не может апрувить PR" || say "workflow может апрувить PR — это обход требования ревью"

echo
echo "== Окружение production =="
if gh api "repos/$REPO/environments/production" >/dev/null 2>&1; then
  ok "окружение существует"
  R=$(gh api "repos/$REPO/environments/production" -q '[.protection_rules[]?.type] | join(",")' 2>/dev/null)
  case "$R" in
    *required_reviewers*) ok "ручной апрув деплоя включён" ;;
    *) say "у production нет обязательного ревьюера — деплой пойдёт без человека" ;;
  esac
else
  say "окружения production нет: секреты деплоя негде хранить изолированно"
fi

echo
echo "== Вызовы factory-ci по SHA =="
# Ссылка на @main означает, что правка в factory-ci немедленно меняет проверки
# во всех репозиториях, включая уже открытые PR.
FOUND=0
for f in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "$f" ] || continue
  while read -r line; do
    FOUND=1
    ref="${line##*@}"
    if printf '%s' "$ref" | grep -Eq '^[0-9a-f]{40}$'; then
      ok "$(basename "$f"): вызов по SHA"
    else
      say "$(basename "$f"): вызов factory-ci по '@$ref' вместо 40-символьного SHA"
    fi

    # Владелец в вызове обязан совпадать с владельцем репозитория. После
    # переноса между аккаунтами старый путь отвечает редиректом, но reusable
    # workflow по редиректу не резолвится — прогон падает за 0 секунд с
    # «workflow file issue». Проверка формата SHA этого не ловит.
    called_owner=$(printf '%s' "$line" | sed -E 's|.*uses:[[:space:]]*([^/]+)/factory-ci.*|\1|')
    want_owner="${REPO%%/*}"
    if [ "$called_owner" = "$want_owner" ]; then
      ok "$(basename "$f"): владелец factory-ci совпадает ($called_owner)"
    else
      say "$(basename "$f"): вызов идёт к '$called_owner/factory-ci', а репозиторий принадлежит '$want_owner'"
    fi
  done < <(grep -h "factory-ci/.github/workflows" "$f" 2>/dev/null || true)
done
[ "$FOUND" = 0 ] && echo "(в этом каталоге вызовов factory-ci не найдено — запускайте из корня продуктового репозитория)"

echo
if [ "$BAD" = 0 ]; then
  echo "ИТОГ: фактическое состояние совпадает с ожидаемым."
else
  echo "ИТОГ: есть расхождения. Восстановить: setup/bootstrap.sh $REPO"
fi
exit "$BAD"
