#!/bin/bash
#
# add-appimage.sh — установка AppImage-приложений в пользовательское окружение.
#
# Переносит AppImage в ~/.local/bin, извлекает иконку и метаданные (Name,
# Comment, Categories) из самого AppImage и создаёт .desktop-ярлык в
# ~/.local/share/applications. Поддерживает ремонт иконки, удаление,
# обновление бинарника и список установленных приложений.
#
# Полная справка: add-appimage.sh --help

set -euo pipefail

# Скрипт использует ассоциативные массивы и ${var,,} — требуется bash >= 4
if (( BASH_VERSINFO[0] < 4 )); then
    echo "[ОШИБКА] Требуется bash >= 4 (текущий: $BASH_VERSION)." >&2
    exit 1
fi

# --- Константы и глобальные переменные ---
TARGET_DIR="$HOME/.local/bin"
ICON_DIR="$HOME/.local/share/icons"
DESKTOP_DIR="$HOME/.local/share/applications"

TEMP_DIR=""
ICON_PATH_FOR_DESKTOP=""
# Временные файлы атомарных cp+mv (install/--update) — чистятся в cleanup()
TMP_DEST=""
TMP_NEW=""
# Временный файл атомарной записи .desktop (write_desktop_file/desktop_sed/
# --fix-icon): функции вызываются последовательно, одной переменной достаточно
TMP_DESKTOP=""

# Результаты resolve_app_and_desktop() — объявлены глобально, чтобы функция
# могла их заполнить (bash не возвращает несколько значений иначе). local в
# самой функции использовать нельзя: вызывающий код читает эти переменные.
APP_PATH=""
DESKTOP_FILE=""
DESKTOP_MATCHED_BY_NAME=false
DISPLAY_NAME=""
OLD_ICON=""
ICON_BASENAME=""

# --- Цвета и логирование ---
if [[ -t 1 ]]; then
    C_GREEN=$'\033[32m'; C_RED=$'\033[31m'; C_YELLOW=$'\033[33m'; C_OFF=$'\033[0m'
else
    C_GREEN=""; C_RED=""; C_YELLOW=""; C_OFF=""
fi

ok()   { echo "${C_GREEN}[ГОТОВО]${C_OFF} $1"; }
warn() { echo "${C_YELLOW}[ВНИМАНИЕ]${C_OFF} $1"; }
fail() { echo "${C_RED}[ОШИБКА]${C_OFF} $1" >&2; }

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    # TMP_DEST/TMP_NEW — временные файлы атомарных cp+mv в install/--update:
    # при сигнале между cp и mv они бы остались мусором в ~50-200 МБ
    if [[ -n "$TMP_DEST" ]]; then rm -f "$TMP_DEST"; fi
    if [[ -n "$TMP_NEW" ]];  then rm -f "$TMP_NEW";  fi
    # TMP_DESKTOP — недописанный .desktop (мелкий, но мусор в автозагрузке меню)
    if [[ -n "$TMP_DESKTOP" ]]; then rm -f "$TMP_DESKTOP"; fi
    TEMP_DIR=""; TMP_DEST=""; TMP_NEW=""; TMP_DESKTOP=""
}

# Графическая сессия доступна (для zenity-диалогов)
gui_available() { [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; }

# Интерактивное подтверждение. Без TTY (cron/CI, закрытый stdin) действие
# не выполняется: лучше отказ, чем зависание на read или молчаливое согласие
confirm() {
    # $1 = текст вопроса; код возврата 0 = согласие, 1 = отказ
    if [[ ! -t 0 ]]; then
        warn "Нет интерактивного терминала: действие не подтверждено (отказ)."
        return 1
    fi
    local answer
    read -r -p "$1" answer || answer=""
    [[ "${answer,,}" =~ ^(y|yes|д|да)$ ]]
}
# EXIT срабатывает при любом выходе; INT/TERM дублируются, т.к. без явного
# trap сигнал завершает shell БЕЗ выполнения EXIT-ловушки (утечка TEMP_DIR).
# kill -INT/TERM по $$ после снятия trap завершает shell тем же сигналом:
# код выхода сохраняется стандартным (130/143), что видят родительские
# процессы и CI
trap cleanup EXIT
# exit после kill: в bash >=5.1 self-signal маскируется и shell продолжил бы
# выполнение после трапа; явный exit гарантирует завершение с кодом сигнала
trap 'cleanup; trap - INT; kill -INT $$; exit 130' INT
trap 'cleanup; trap - TERM; kill -TERM $$; exit 143' TERM

# --- Справка ---
usage() {
cat <<EOF
add-appimage.sh — установка AppImage в пользовательское окружение (~/.local)

Использование:
  $0 [ОПЦИИ] /путь/к/файлу.AppImage      установка приложения
  $0 --fix-icon [--icon PATH] <имя>      ремонт иконки установленного приложения
  $0 --remove [-y] <имя>                 удаление приложения (бинарник + ярлык + иконка)
  $0 --update <имя> <файл.AppImage>      обновление бинарника с сохранением ярлыка
  $0 --list                              список установленных AppImage-приложений

Опции:
  --name NAME         Отображаемое имя приложения
  --icon PATH         Путь к иконке (png/svg/jpg/jpeg/ico)
  --categories LIST   Категории ярлыка (напр. "Development;IDE;" или "Development,IDE")
  --comment TEXT      Описание приложения (Comment=)
  --keywords LIST     Ключевые слова поиска (напр. "editor,text")
  --exec-args ARGS    Аргументы командной строки в Exec= (в --update заменяют старые)
  -y, --yes           Не спрашивать подтверждение (для --remove)
  -h, --help          Эта справка

Примеры:
  $0 ~/Downloads/Cursor.AppImage
  $0 --name "Мой Редактор" --categories "Utility;TextEditor;" app.AppImage
  $0 --fix-icon cursor
  $0 --fix-icon --icon ~/icon.png cursor
  $0 --remove cursor
  $0 --update cursor ~/Downloads/Cursor-2.0.AppImage
  $0 --list
EOF
}

# --- Парсинг аргументов ---
INPUT_PATH=""
CUSTOM_ICON=""
CUSTOM_NAME=""
CUSTOM_CATEGORIES=""
CUSTOM_COMMENT=""
CUSTOM_KEYWORDS=""
EXEC_ARGS=""
FIX_ICON_MODE=false
REMOVE_MODE=false
LIST_MODE=false
UPDATE_NAME=""
ASSUME_YES=false
SHOW_HELP=false

# Проверяет, что у опции есть значение: $1 = имя опции, $2 = число
# оставшихся аргументов ($# из цикла), $3 = значение (${2:-} из цикла).
need_value() {
    if [[ $2 -lt 2 || -z "${3:-}" ]]; then
        fail "Параметр $1 требует значение."
        exit 1
    fi
}

# Как need_value, но отклоняет значения, начинающиеся с '-' (почти всегда
# это пропущенное значение и следующий флаг). Для значений с дефисом
# (напр. --exec-args "--no-sandbox") используйте формат --opt=значение.
need_value_no_dash() {
    need_value "$@"
    if [[ "$3" == -* ]]; then
        fail "Параметр $1 требует значение (получен флаг '$3'). Если значение начинается с '-', используйте формат $1=значение."
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        # Формат --opt=значение: обязателен для значений, начинающихся с '-'
        --icon=*)       CUSTOM_ICON="${1#*=}" ;;
        --name=*)       CUSTOM_NAME="${1#*=}" ;;
        --categories=*) CUSTOM_CATEGORIES="${1#*=}" ;;
        --comment=*)    CUSTOM_COMMENT="${1#*=}" ;;
        --keywords=*)   CUSTOM_KEYWORDS="${1#*=}" ;;
        --exec-args=*)  EXEC_ARGS="${1#*=}" ;;
        --update=*)     UPDATE_NAME="${1#*=}" ;;
        --icon)       need_value_no_dash "$1" "$#" "${2:-}"; CUSTOM_ICON="$2"; shift ;;
        --name)       need_value_no_dash "$1" "$#" "${2:-}"; CUSTOM_NAME="$2"; shift ;;
        --categories) need_value_no_dash "$1" "$#" "${2:-}"; CUSTOM_CATEGORIES="$2"; shift ;;
        --comment)    need_value_no_dash "$1" "$#" "${2:-}"; CUSTOM_COMMENT="$2"; shift ;;
        --keywords)   need_value_no_dash "$1" "$#" "${2:-}"; CUSTOM_KEYWORDS="$2"; shift ;;
        # --exec-args: значение может начинаться с '-' (напр. "--no-sandbox")
        --exec-args)  need_value "$1" "$#" "${2:-}"; EXEC_ARGS="$2"; shift ;;
        --update)     need_value_no_dash "$1" "$#" "${2:-}"; UPDATE_NAME="$2"; shift ;;
        --fix-icon)   FIX_ICON_MODE=true ;;
        --remove)     REMOVE_MODE=true ;;
        --list)       LIST_MODE=true ;;
        -y|--yes)     ASSUME_YES=true ;;
        -h|--help)    SHOW_HELP=true ;;
        --)           shift
                      if [[ $# -gt 1 ]]; then
                          fail "Лишний аргумент после --: $2"
                          exit 1
                      fi
                      if [[ $# -gt 0 ]]; then INPUT_PATH="$1"; shift; fi
                      if [[ -z "$INPUT_PATH" ]]; then
                          fail "После -- не указан путь к AppImage (см. --help)."
                          exit 1
                      fi
                      break ;;
        -*)           fail "Неизвестный параметр: $1 (см. --help)"; exit 1 ;;
        *)            if [[ -n "$INPUT_PATH" ]]; then
                          fail "Лишний аргумент: $1 (путь уже задан: $INPUT_PATH)"
                          exit 1
                      fi
                      INPUT_PATH="$1" ;;
    esac
    shift
done

if $SHOW_HELP; then
    usage
    exit 0
fi

# Метаданные ярлыка не должны содержать переводы строк: значение с '\n'
# создало бы в .desktop-файле дополнительные строки-ключи
check_no_newline() {
    # $1 = значение опции, $2 = имя опции
    if [[ "$1" == *$'\n'* || "$1" == *$'\r'* ]]; then
        fail "Опция $2 не должна содержать переводы строк."
        exit 1
    fi
}
check_no_newline "$CUSTOM_NAME" "--name"
check_no_newline "$CUSTOM_COMMENT" "--comment"
check_no_newline "$CUSTOM_CATEGORIES" "--categories"
check_no_newline "$CUSTOM_KEYWORDS" "--keywords"
check_no_newline "$EXEC_ARGS" "--exec-args"

# Режимы (--fix-icon/--remove/--list/--update) взаимоисключающие
MODE_COUNT=0
if $FIX_ICON_MODE;              then MODE_COUNT=$((MODE_COUNT + 1)); fi
if $REMOVE_MODE;                then MODE_COUNT=$((MODE_COUNT + 1)); fi
if $LIST_MODE;                  then MODE_COUNT=$((MODE_COUNT + 1)); fi
if [[ -n "$UPDATE_NAME" ]];     then MODE_COUNT=$((MODE_COUNT + 1)); fi
if [[ $MODE_COUNT -gt 1 ]]; then
    fail "Укажите только один режим: --fix-icon, --remove, --list или --update."
    exit 1
fi

# Опции, неприменимые в выбранном режиме, отклоняем явно, а не молча
# игнорируем (пользователь может ошибочно считать, что они подействовали)
mode_opt_check() {
    # $1 = значение опции, $2 = имя опции, $3 = режим
    if [[ -n "$1" ]]; then
        fail "Опция $2 несовместима с режимом $3 (см. --help)."
        exit 1
    fi
}
mode_flag_check() {
    # $1 = флаг (true/false), $2 = имя опции, $3 = режим
    if $1; then
        fail "Опция $2 несовместима с режимом $3 (см. --help)."
        exit 1
    fi
}
if $LIST_MODE; then
    mode_opt_check "$CUSTOM_ICON" "--icon" "--list"
    mode_opt_check "$CUSTOM_NAME" "--name" "--list"
    mode_opt_check "$CUSTOM_CATEGORIES" "--categories" "--list"
    mode_opt_check "$CUSTOM_COMMENT" "--comment" "--list"
    mode_opt_check "$CUSTOM_KEYWORDS" "--keywords" "--list"
    mode_opt_check "$EXEC_ARGS" "--exec-args" "--list"
    mode_flag_check "$ASSUME_YES" "-y/--yes" "--list"
    mode_opt_check "$INPUT_PATH" "позиционный аргумент" "--list"
fi
if $REMOVE_MODE; then
    mode_opt_check "$CUSTOM_ICON" "--icon" "--remove"
    mode_opt_check "$CUSTOM_NAME" "--name" "--remove"
    mode_opt_check "$CUSTOM_CATEGORIES" "--categories" "--remove"
    mode_opt_check "$CUSTOM_COMMENT" "--comment" "--remove"
    mode_opt_check "$CUSTOM_KEYWORDS" "--keywords" "--remove"
    mode_opt_check "$EXEC_ARGS" "--exec-args" "--remove"
fi
if [[ -n "$UPDATE_NAME" ]]; then
    mode_opt_check "$CUSTOM_ICON" "--icon" "--update"
    mode_opt_check "$CUSTOM_NAME" "--name" "--update"
    mode_opt_check "$CUSTOM_CATEGORIES" "--categories" "--update"
    mode_opt_check "$CUSTOM_COMMENT" "--comment" "--update"
    mode_opt_check "$CUSTOM_KEYWORDS" "--keywords" "--update"
    mode_flag_check "$ASSUME_YES" "-y/--yes" "--update"
fi
if $FIX_ICON_MODE; then
    mode_opt_check "$CUSTOM_NAME" "--name" "--fix-icon"
    mode_opt_check "$CUSTOM_CATEGORIES" "--categories" "--fix-icon"
    mode_opt_check "$CUSTOM_COMMENT" "--comment" "--fix-icon"
    mode_opt_check "$CUSTOM_KEYWORDS" "--keywords" "--fix-icon"
    mode_opt_check "$EXEC_ARGS" "--exec-args" "--fix-icon"
    mode_flag_check "$ASSUME_YES" "-y/--yes" "--fix-icon"
fi
if ! $FIX_ICON_MODE && ! $REMOVE_MODE && ! $LIST_MODE && [[ -z "$UPDATE_NAME" ]]; then
    # Обычная установка: подтверждений нет, -y не нужен
    if $ASSUME_YES; then
        fail "Опция -y/--yes имеет смысл только с --remove (см. --help)."
        exit 1
    fi
fi

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    warn "Скрипт запущен от root: файлы будут установлены в /root/.local"
fi

# Каталоги создаём только в пишущих режимах: --list и --remove работают
# с уже установленными файлами и не должны иметь побочных эффектов
# (--fix-icon пишет иконку в ICON_DIR, поэтому остаётся здесь)
if ! $LIST_MODE && ! $REMOVE_MODE; then
    mkdir -p "$TARGET_DIR" "$ICON_DIR" "$DESKTOP_DIR"
fi

# --- Вспомогательные функции ---

# Значение ключа из .desktop-файла (Name=, Icon=, Exec=, ...).
# tr -d '\r': значения из встроенных .desktop сторонних AppImage могут
# содержать CR (строки CRLF) — иначе они попадут в наш ярлык
desktop_key() {
    grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true
}

# Первый токен значения Exec= (путь к исполняемому файлу) с учётом кавычек
exec_first_token() {
    local v="$1"
    if [[ "$v" == \"* ]]; then
        v="${v#\"}"
        printf '%s\n' "${v%%\"*}"
    else
        printf '%s\n' "${v%% *}"
    fi
}

# Остаток строки Exec= после первого токена (аргументы), с учётом кавычек
exec_args_remainder() {
    local v="$1"
    if [[ "$v" == \"* ]]; then
        v="${v#\"}"
        v="${v#*\"}"   # отбрасываем до закрывающей кавычки включительно
        printf '%s\n' "${v# }"
    elif [[ "$v" == *" "* ]]; then
        printf '%s\n' "${v#* }"
    else
        printf '\n'
    fi
}

# Экранирует строку для вставки внутрь кавычек в desktop-файле:
# \ -> \\, " -> \" (спецификация desktop-entry). Используется для Exec=,
# чтобы кавычка/бэкслеш в аргументах (--exec-args или унаследованных)
# не создали битую строку вроде Exec="/path/app" --opt="x".
escape_desktop_string() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s\n' "$s"
}

# Приводит имя к безопасному идентификатору: латиница в нижнем регистре,
# кириллица транслитерируется, прочие символы заменяются на "-".
# Если результат пуст — fallback на appimage-<hash>.
sanitize_filename() {
    local input="$1" result="" i ch lower
    local -A TRANSLIT=(
        [а]=a [б]=b [в]=v [г]=g [д]=d [е]=e [ё]=e [ж]=zh [з]=z [и]=i
        [й]=y [к]=k [л]=l [м]=m [н]=n [о]=o [п]=p [р]=r [с]=s [т]=t
        [у]=u [ф]=f [х]=h [ц]=c [ч]=ch [ш]=sh [щ]=sch [ъ]="" [ы]=y
        [ь]="" [э]=e [ю]=yu [я]=ya
    )
    for ((i = 0; i < ${#input}; i++)); do
        ch="${input:i:1}"
        lower="${ch,,}"
        # ${VAR+x} отличает «ключ отсутствует» от «ключ есть, но пустой»:
        # ъ/ь маппятся в пустую строку и не должны превращаться в дефис
        if [[ -n "${TRANSLIT[$lower]+x}" ]]; then
            result+="${TRANSLIT[$lower]}"
        elif [[ "$lower" =~ ^[a-z0-9]$ ]]; then
            result+="$lower"
        else
            result+="-"
        fi
    done
    result=$(printf '%s' "$result" | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')
    if [[ -z "$result" ]]; then
        result="appimage-$(printf '%s' "$input" | md5sum | cut -c1-8)"
    fi
    printf '%s\n' "$result"
}

# Канонический путь: разрешает симлинки и . / .. (readlink -f). При неудаче
# readlink (нет утилиты, несуществующие промежуточные каталоги, обрыв
# симлинка) возвращает исходный путь как есть — вызывающий код всегда
# получает пригодную для сравнения строку.
resolve_path() {
    local p
    if p=$(readlink -f -- "$1" 2>/dev/null) && [[ -n "$p" ]]; then
        printf '%s\n' "$p"
    else
        printf '%s\n' "$1"
    fi
}

# Файлы одинаковы (device:inode) — надёжнее сравнения путей при симлинках
# (напр., $HOME может быть симлинком, и readlink -f даст разные строки).
# Несуществующие файлы никогда не считаются одинаковыми.
same_file() {
    [[ -e "$1" && -e "$2" ]] || return 1
    local dev_ino1 dev_ino2
    dev_ino1=$(stat -c '%d:%i' -- "$1" 2>/dev/null) || return 1
    dev_ino2=$(stat -c '%d:%i' -- "$2" 2>/dev/null) || return 1
    [[ -n "$dev_ino1" && "$dev_ino1" == "$dev_ino2" ]]
}

# Копирует иконку в ICON_DIR, определяя реальный формат по MIME-типу
# (или по расширению, если утилита file недоступна).
# Удаляет дубликаты других форматов с тем же базовым именем.
process_icon() {
    local SOURCE="$1"
    local DEST_BASE="$2"

    if [[ ! -f "$SOURCE" ]]; then
        echo "      [ОШИБКА] Файл иконки не найден: $SOURCE"
        return 1
    fi

    local REAL_EXT=""
    if command -v file >/dev/null 2>&1; then
        local MIME_TYPE
        MIME_TYPE=$(file --mime-type -b "$SOURCE")
        if   [[ "$MIME_TYPE" == *svg* ]];   then REAL_EXT="svg"
        elif [[ "$MIME_TYPE" == *jpeg* ]];  then REAL_EXT="jpg"
        elif [[ "$MIME_TYPE" == *png* ]];   then REAL_EXT="png"
        elif [[ "$MIME_TYPE" == *icon* ]];  then REAL_EXT="ico"
        fi
        if [[ -z "$REAL_EXT" ]]; then
            # Нераспознанный MIME (напр., image/webp): пробуем расширение,
            # иначе отказ — иконка с неверным форматом не отобразится в меню
            case "${SOURCE##*.}" in
                png|PNG)    REAL_EXT="png" ;;
                svg|SVG)    REAL_EXT="svg" ;;
                jpg|jpeg|JPG|JPEG) REAL_EXT="jpg" ;;
                ico|ICO)    REAL_EXT="ico" ;;
            esac
            if [[ -z "$REAL_EXT" ]]; then
                echo "      [ОШИБКА] Неподдерживаемый формат иконки ($MIME_TYPE): $SOURCE"
                return 1
            fi
        fi
    else
        warn "Утилита file не найдена: формат иконки определяется по расширению."
        case "${SOURCE##*.}" in
            png|PNG)    REAL_EXT="png" ;;
            svg|SVG)    REAL_EXT="svg" ;;
            jpg|jpeg|JPG|JPEG) REAL_EXT="jpg" ;;
            ico|ICO)    REAL_EXT="ico" ;;
        esac
        if [[ -z "$REAL_EXT" ]]; then
            echo "      [ОШИБКА] Неизвестное расширение иконки (png/svg/jpg/jpeg/ico): $SOURCE"
            return 1
        fi
    fi

    local FINAL_PATH="$ICON_DIR/$DEST_BASE.$REAL_EXT"
    # Источник уже является целевым файлом (напр., --icon указывает в ICON_DIR):
    # cp откажется с "same file" — просто используем его как готовую иконку
    if same_file "$SOURCE" "$FINAL_PATH"; then
        ICON_PATH_FOR_DESKTOP="$FINAL_PATH"
        echo "      Иконка уже на месте (формат: $REAL_EXT)"
        return 0
    fi
    if ! cp -L "$SOURCE" "$FINAL_PATH" 2>/dev/null && ! cp "$SOURCE" "$FINAL_PATH" 2>/dev/null; then
        echo "      [ОШИБКА] Не удалось скопировать иконку: $SOURCE"
        return 1
    fi
    chmod 644 "$FINAL_PATH"

    # Удаляем дубликаты других форматов с тем же базовым именем.
    # same_file: если исходник — это сам файл в ICON_DIR с неверным
    # расширением (напр., png-данные в app.jpg), удалять его нельзя —
    # мы только что скопировали его содержимое в FINAL_PATH
    local ext
    for ext in png svg jpg jpeg ico; do
        if [[ "$ext" != "$REAL_EXT" ]] \
            && ! same_file "$SOURCE" "$ICON_DIR/$DEST_BASE.$ext"; then
            rm -f "$ICON_DIR/$DEST_BASE.$ext"
        fi
    done

    ICON_PATH_FOR_DESKTOP="$FINAL_PATH"
    echo "      Иконка обработана (формат: $REAL_EXT)"
    return 0
}

# Отбирает самый большой файл из вывода `find -printf '%s\t%p\n'` (stdin)
# и печатает его путь. Путь берём из остатка строки после первой табуляции
# (не cut -f2-: табуляция допустима в имени файла и обрезала бы такой путь).
largest_of_find() {
    local best_size=-1 best_path="" size path rest
    while IFS= read -r rest; do
        size="${rest%%$'\t'*}"
        path="${rest#*$'\t'}"
        [[ "$size" =~ ^[0-9]+$ ]] || continue
        if (( size > best_size )); then
            best_size="$size"
            best_path="$path"
        fi
    done
    printf '%s\n' "$best_path"
}

# Ищет лучшую иконку в распакованном корне: сначала по имени из Icon= встроенного
# .desktop, затем любая png/svg (по убыванию размера). Печатает путь или пусто.
# Третий аргумент RECURSIVE=true включает рекурсивный поиск по подкаталогам
# (после полной распаковки — иконка может лежать в usr/share/pixmaps и т.п.).
find_icon_in_root() {
    local root="$1" embedded_desktop="$2" recursive="${3:-false}"
    local icon_source="" embedded_icon_name
    embedded_icon_name=$(desktop_key "$embedded_desktop" "Icon" 2>/dev/null)
    if [[ -n "$embedded_icon_name" ]]; then
        icon_source=$(find "$root" -type f \
            \( -iname "$embedded_icon_name.png" -o -iname "$embedded_icon_name.svg" \
            -o -iname "$embedded_icon_name.jpg" -o -iname "$embedded_icon_name.ico" \) \
            -printf '%s\t%p\n' 2>/dev/null | largest_of_find)
    fi
    if [[ -z "$icon_source" ]]; then
        if $recursive; then
            icon_source=$(find "$root" -type f \
                \( -iname '*.png' -o -iname '*.svg' \) \
                -printf '%s\t%p\n' 2>/dev/null | largest_of_find)
        else
            # Нерекурсивный режим: шаблоны --appimage-extract помещают файлы
            # в корень squashfs-root, подкаталоги здесь не смотрим
            icon_source=$(find "$root" -maxdepth 1 -type f \
                \( -iname '*.png' -o -iname '*.svg' \) \
                -printf '%s\t%p\n' 2>/dev/null | largest_of_find)
        fi
    fi
    printf '%s\n' "$icon_source"
}

# Извлекает из AppImage иконку и метаданные встроенного .desktop-файла.
# Заполняет: ICON_PATH_FOR_DESKTOP, EMBEDDED_NAME, EMBEDDED_COMMENT,
# EMBEDDED_CATEGORIES, EMBEDDED_KEYWORDS.
extract_appimage_data() {
    local APP_PATH="$1"
    local ICON_BASE="$2"
    # SKIP_ICON=true: извлекаем только метаданные (.desktop), иконку не ищем —
    # используется, когда иконка задана явно (--icon) или сохраняется старая
    local SKIP_ICON="${3:-false}"

    ICON_PATH_FOR_DESKTOP=""
    EMBEDDED_NAME=""
    EMBEDDED_COMMENT=""
    EMBEDDED_CATEGORIES=""
    EMBEDDED_KEYWORDS=""

    TEMP_DIR=$(mktemp -d)
    local ROOT="$TEMP_DIR/squashfs-root"

    # Проход 1: .DirIcon и встроенный .desktop (быстро)
    (cd "$TEMP_DIR" && "$APP_PATH" --appimage-extract .DirIcon '*.desktop' >/dev/null 2>&1) || true

    local embedded_desktop
    embedded_desktop=$(find "$ROOT" -maxdepth 1 -name '*.desktop' 2>/dev/null | head -n 1 || true)
    if [[ -n "$embedded_desktop" ]]; then
        EMBEDDED_NAME=$(desktop_key "$embedded_desktop" "Name")
        EMBEDDED_COMMENT=$(desktop_key "$embedded_desktop" "Comment")
        EMBEDDED_CATEGORIES=$(desktop_key "$embedded_desktop" "Categories")
        EMBEDDED_KEYWORDS=$(desktop_key "$embedded_desktop" "Keywords")
    fi

    if $SKIP_ICON; then
        rm -rf "$TEMP_DIR"
        TEMP_DIR=""
        return 0
    fi

    local icon_source=""
    if [[ -e "$ROOT/.DirIcon" ]]; then
        icon_source="$ROOT/.DirIcon"
    else
        # Проход 2a: типичные места иконок (распаковывается немного)
        (cd "$TEMP_DIR" && "$APP_PATH" --appimage-extract 'usr/share/icons/*' >/dev/null 2>&1) || true
        icon_source=$(find_icon_in_root "$ROOT" "$embedded_desktop")

        if [[ -z "$icon_source" ]]; then
            # Проход 2b: полная распаковка образа (шаблоны --appimage-extract
            # не рекурсивны, поэтому вместо '*.png' распаковываем всё —
            # иконка может лежать в usr/share/pixmaps и т.п.), затем ищем
            # рекурсивно по всему дереву
            (cd "$TEMP_DIR" && "$APP_PATH" --appimage-extract >/dev/null 2>&1) || true
            icon_source=$(find_icon_in_root "$ROOT" "$embedded_desktop" true)
        fi
    fi

    if [[ -n "$icon_source" ]]; then
        process_icon "$icon_source" "$ICON_BASE" || true
    else
        echo "      Автоматическое извлечение не удалось."
    fi

    rm -rf "$TEMP_DIR"
    TEMP_DIR=""
}

# Ищет .desktop-файл, чей Exec= ссылается на указанный AppImage (по содержимому)
find_desktop_by_appimage() {
    local target_real exe exe_real f
    target_real=$(resolve_path "$1")
    while IFS= read -r f; do
        exe=$(desktop_key "$f" "Exec")
        if [[ -z "$exe" ]]; then continue; fi
        exe=$(exec_first_token "$exe")
        if [[ -z "$exe" ]]; then continue; fi
        exe_real=$(resolve_path "$exe")
        if [[ "$exe_real" == "$target_real" ]]; then
            printf '%s\n' "$f"
            return 0
        fi
    done < <(find "$DESKTOP_DIR" -maxdepth 1 -name '*.desktop' 2>/dev/null | sort)
    return 1
}

# Экранирует спецсимволы glob (\ * ? [ ]) для find -iname.
# '\' экранируется ПЕРВЫМ: иначе были бы заэкранированы собственные
# escape-символы, добавленные последующими заменами
escape_glob() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\*/\\*}
    s=${s//\?/\\?}
    s=${s//[/\\[}
    s=${s//]/\\]}
    printf '%s\n' "$s"
}

# Fallback: поиск .desktop по похожему имени
find_desktop_by_name() {
    local base_no_ext="$1" found esc
    esc=$(escape_glob "$base_no_ext")
    found=$(find "$DESKTOP_DIR" -maxdepth 1 -iname "*${esc}*.desktop" 2>/dev/null | sort | head -n 1 || true)
    if [[ -n "$found" ]]; then
        printf '%s\n' "$found"
        return 0
    fi
    return 1
}

# Поиск AppImage: точный путь (только *.AppImage) или подстрока имени
# в TARGET_DIR (без учёта регистра). Неоднозначное совпадение (несколько
# файлов) — отказ с перечислением: молчаливый выбор первого по алфавиту
# привёл бы к операциям (вплоть до удаления) не над тем файлом
find_appimage_by_query() {
    local query="$1" esc
    if [[ -f "$query" && "${query,,}" == *.appimage ]]; then
        printf '%s\n' "$query"
        return 0
    fi
    esc=$(escape_glob "$query")
    local -a matches=()
    mapfile -t matches < <(find "$TARGET_DIR" -maxdepth 1 -iname "*${esc}*.appimage" 2>/dev/null | sort)
    if [[ ${#matches[@]} -gt 1 ]]; then
        fail "Запрос '$query' неоднозначен — найдено ${#matches[@]} файлов:"
        printf '  %s\n' "${matches[@]}" >&2
        fail "Уточните запрос или укажите точный путь."
        return 1
    fi
    if [[ ${#matches[@]} -eq 1 ]]; then
        printf '%s\n' "${matches[0]}"
        return 0
    fi
    return 1
}

# Тип AppImage по magic bytes: первые 4 байта должны быть ELF-заголовком
# (\x7fELF), байты 8-10 — сигнатурой AI\x01/AI\x02. Проверка ELF обязательна:
# без неё любой файл с байтами AI\x02 по смещению 8 (напр., образ диска)
# был бы ошибочно принят за AppImage и запущен как исполняемый.
# Читаем двумя вызовами dd: bash-переменные не хранят NUL-байты (в ELF
# байт 7, EI_OSABI, обычно \x00), и одно чтение сместило бы сигнатуру.
# Печатает "1", "2" или пустую строку (не AppImage)
appimage_type() {
    local elf sig
    elf=$(dd if="$1" bs=1 count=4 2>/dev/null || true)
    if [[ "$elf" != $'\x7fELF' ]]; then
        printf '\n'
        return
    fi
    sig=$(dd if="$1" bs=1 skip=8 count=3 2>/dev/null || true)
    if   [[ "$sig" == $'AI\x01' ]]; then printf '1\n'
    elif [[ "$sig" == $'AI\x02' ]]; then printf '2\n'
    else printf '\n'
    fi
}

# Отказ с диагностикой типа AppImage, если файл не type 2
require_appimage_type2() {
    local t
    t=$(appimage_type "$1")
    if [[ "$t" == "2" ]]; then return 0; fi
    if [[ "$t" == "1" ]]; then
        fail "Файл '$1' — AppImage type 1 (устаревший формат). Поддерживается только type 2."
    else
        fail "Файл '$1' не является AppImage: не найдена сигнатура AI\\x01/AI\\x02."
    fi
    exit 1
}

# Нормализация списка категорий/ключевых слов к формату "a;b;c;"
normalize_list() {
    local v
    v=$(printf '%s' "$1" | tr ',' ';' | tr -s ';' | sed 's/^ *//; s/ *$//; s/ *; */;/g; s/^;//; s/;$//')
    if [[ -n "$v" ]]; then
        printf '%s;\n' "$v"
    else
        printf '\n'
    fi
}

update_caches() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
    fi
    # gtk-update-icon-cache не вызываем: иконки лежат плоско в $ICON_DIR
    # без иерархии hicolor/<size>/apps — утилита всё равно ничего не сделает
}

# Запись .desktop-файла: атомарно (временный файл + mv), с бэкапом .bak
# и валидацией при возможности. При ошибке исходный ярлык не повреждается.
write_desktop_file() {
    local dest="$1" name="$2" comment="$3" exec_line="$4" icon_line="$5" categories="$6" keywords="$7"
    local tmp
    tmp=$(mktemp "$DESKTOP_DIR/.desktop-write.XXXXXX")
    TMP_DESKTOP="$tmp"   # на случай сигнала — чистится в cleanup()

    {
        echo "[Desktop Entry]"
        echo "Name=$name"
        if [[ -n "$comment" ]]; then echo "Comment=$comment"; fi
        echo "Exec=$exec_line"
        echo "$icon_line"
        echo "Terminal=false"
        echo "Type=Application"
        echo "Categories=$categories"
        if [[ -n "$keywords" ]]; then echo "Keywords=$keywords"; fi
        echo "StartupNotify=true"
        # Маркер «своего» ярлыка: точная идентификация в --list/--remove/--update
        echo "X-AppImage-Installer=true"
    } > "$tmp" || { rm -f "$tmp"; return 1; }

    if command -v desktop-file-validate >/dev/null 2>&1; then
        if ! desktop-file-validate "$tmp" >/dev/null 2>&1; then
            warn "Ярлык не прошёл проверку desktop-file-validate (проверьте вручную)."
        fi
    fi

    if [[ -f "$dest" ]]; then
        cp "$dest" "$dest.bak"
    fi
    chmod 644 "$tmp"   # mktemp создаёт 0600, ярлыку нужны стандартные 0644
    mv -f "$tmp" "$dest"
    TMP_DESKTOP=""
}

# Модификация ярлыка через sed: атомарно (временный файл + mv) —
# при ошибке исходный файл не повреждается
desktop_sed() {
    local file="$1" expr="$2" tmp
    tmp=$(mktemp "$DESKTOP_DIR/.desktop-sed.XXXXXX")
    TMP_DESKTOP="$tmp"   # на случай сигнала — чистится в cleanup()
    if sed "$expr" "$file" > "$tmp"; then
        chmod 644 "$tmp"   # mktemp создаёт 0600, ярлыку нужны стандартные 0644
        mv -f "$tmp" "$file"
        TMP_DESKTOP=""
    else
        rm -f "$tmp"
        TMP_DESKTOP=""
        return 1
    fi
}

# Проверяет, создан ли ярлык этим скриптом (по маркеру X-AppImage-Installer)
is_own_desktop() {
    grep -q '^X-AppImage-Installer=true$' "$1" 2>/dev/null
}

# Общее разрешение "запрос -> AppImage + ярлык" для режимов
# --remove/--update/--fix-icon. Возвращает 1, если AppImage не найден.
# Заполняет: APP_PATH, DESKTOP_FILE (может быть пустым),
# DESKTOP_MATCHED_BY_NAME, DISPLAY_NAME, OLD_ICON, ICON_BASENAME.
resolve_app_and_desktop() {
    local query="$1"
    APP_PATH=$(find_appimage_by_query "$query") || return 1

    DESKTOP_FILE=$(find_desktop_by_appimage "$APP_PATH" || true)
    DESKTOP_MATCHED_BY_NAME=false
    if [[ -z "$DESKTOP_FILE" ]]; then
        local base_no_ext
        base_no_ext=$(basename "$APP_PATH" | sed -E 's/\.[aA]pp[iI]mage$//')
        # Установка называет ярлык через sanitize_filename(basename)
        # (My.App -> my-app.desktop): ищем сначала по нормализованному
        # имени, затем по исходному (ярлык мог быть назван вручную)
        DESKTOP_FILE=$(find_desktop_by_name "$(sanitize_filename "$base_no_ext")" || true)
        if [[ -z "$DESKTOP_FILE" ]]; then
            DESKTOP_FILE=$(find_desktop_by_name "$base_no_ext" || true)
        fi
        if [[ -n "$DESKTOP_FILE" ]]; then
            DESKTOP_MATCHED_BY_NAME=true
        fi
    fi

    DISPLAY_NAME=""
    OLD_ICON=""
    ICON_BASENAME=""
    if [[ -n "$DESKTOP_FILE" && -f "$DESKTOP_FILE" ]]; then
        DISPLAY_NAME=$(desktop_key "$DESKTOP_FILE" "Name")
        OLD_ICON=$(desktop_key "$DESKTOP_FILE" "Icon")
        ICON_BASENAME=$(basename "$DESKTOP_FILE" .desktop)
        # Чужой ярлык (не создан этим скриптом) считаем совпадением по имени:
        # не будем молча удалять/переписывать чужие файлы
        if ! is_own_desktop "$DESKTOP_FILE"; then
            DESKTOP_MATCHED_BY_NAME=true
        fi
    fi
    return 0
}

# ==========================================
# РЕЖИМ: СПИСОК (--list)
# ==========================================
if $LIST_MODE; then
    echo "Установленные AppImage-приложения:"
    echo ""
    found_any=false
    found_foreign=false
    while IFS= read -r f; do
        exe=$(desktop_key "$f" "Exec")
        if [[ -z "$exe" ]]; then continue; fi
        exe=$(exec_first_token "$exe")
        if [[ "${exe,,}" != *.appimage ]]; then continue; fi
        name=$(desktop_key "$f" "Name")
        if [[ -z "$name" ]]; then name="$(basename "$f" .desktop)"; fi
        status=""
        if [[ ! -f "$exe" ]]; then
            status=" ${C_RED}[бинарник отсутствует]${C_OFF}"
        fi
        if is_own_desktop "$f"; then
            printf '  %s%s\n     -> %s\n' "$name" "$status" "$exe"
            found_any=true
        else
            # Ярлык ссылается на AppImage, но создан не этим скриптом
            printf '  %s%s %s[внешний ярлык]%s\n     -> %s\n' \
                "$name" "$status" "$C_YELLOW" "$C_OFF" "$exe"
            found_foreign=true
        fi
    done < <(find "$DESKTOP_DIR" -maxdepth 1 -name '*.desktop' 2>/dev/null | sort)
    if ! $found_any && ! $found_foreign; then
        echo "  (ничего не найдено)"
    fi
    exit 0
fi

# ==========================================
# РЕЖИМ: УДАЛЕНИЕ (--remove)
# ==========================================
if $REMOVE_MODE; then
    if [[ -z "$INPUT_PATH" ]]; then
        fail "Укажите имя программы или путь к AppImage: $0 --remove <имя>"
        exit 1
    fi

    resolve_app_and_desktop "$INPUT_PATH" || {
        fail "AppImage по запросу '$INPUT_PATH' не найден в $TARGET_DIR"
        exit 1
    }
    DESKTOP_KEPT=false

    # find_appimage_by_query принимает любой точный путь *.AppImage:
    # файлы вне TARGET_DIR удаляем только с явного подтверждения (даже с -y)
    OUTSIDE_TARGET=false
    APP_REAL=$(resolve_path "$APP_PATH")
    TARGET_REAL=$(resolve_path "$TARGET_DIR")
    if [[ "$APP_REAL" != "$TARGET_REAL"/* ]]; then
        OUTSIDE_TARGET=true
    fi

    LABEL="${DISPLAY_NAME:-$(basename "$APP_PATH")}"

    echo "Удаление '$LABEL':"
    if $DESKTOP_MATCHED_BY_NAME && [[ -n "$DESKTOP_FILE" && -f "$DESKTOP_FILE" ]]; then
        # Ярлык найден фолбэком по имени (не по ссылке на бинарник) —
        # он может принадлежать другому приложению, подтверждаем отдельно
        if ! confirm "Ярлык найден по имени, а не по ссылке на бинарник: '$DESKTOP_FILE'. Удалить его? [y/N] "; then
            echo "Ярлык оставлен. Удаляется только бинарник."
            DESKTOP_FILE=""
            DESKTOP_KEPT=true
        fi
    fi
    if ! $ASSUME_YES || $OUTSIDE_TARGET; then
        # Путь бинарника показываем всегда: при совпадении по подстроке имени
        # пользователь обязан видеть, какой именно файл будет удалён
        CONFIRM_MSG="Удалить '$APP_PATH' (бинарник, ярлык и иконку)? [y/N] "
        if $OUTSIDE_TARGET; then
            CONFIRM_MSG="Файл '$APP_PATH' находится вне $TARGET_DIR. Всё равно удалить бинарник, ярлык и иконку? [y/N] "
        fi
        if ! confirm "$CONFIRM_MSG"; then
            # Подсказываем выход для неинтерактивного запуска (cron/CI):
            # иначе пользователь видит лишь "Отменено." без объяснения причины
            if [[ ! -t 0 ]]; then
                if $OUTSIDE_TARGET; then
                    echo "Отменено. Для файлов вне $TARGET_DIR требуется интерактивное подтверждение (-y не помогает)." >&2
                else
                    echo "Отменено. Для неинтерактивного запуска используйте -y." >&2
                fi
            else
                echo "Отменено."
            fi
            exit 0
        fi
    fi

    rm -f "$APP_PATH"
    echo "  [1/3] Бинарник удалён: $APP_PATH"

    if [[ -n "$DESKTOP_FILE" && -f "$DESKTOP_FILE" ]]; then
        rm -f "$DESKTOP_FILE" "$DESKTOP_FILE.bak"
        echo "  [2/3] Ярлык удалён: $DESKTOP_FILE"
    elif $DESKTOP_KEPT; then
        echo "  [2/3] Ярлык оставлен по выбору пользователя."
    else
        echo "  [2/3] Ярлык не найден (пропущено)."
    fi

    if ! $DESKTOP_KEPT; then
        # Удаляем только реально существующие файлы иконок и честно
        # сообщаем результат (не «удалены», если их не было)
        ICONS_REMOVED=false
        if [[ -n "$ICON_BASENAME" ]]; then
            icon_ext=""
            for icon_ext in png svg jpg jpeg ico; do
                if [[ -f "$ICON_DIR/$ICON_BASENAME.$icon_ext" ]]; then
                    rm -f "$ICON_DIR/$ICON_BASENAME.$icon_ext"
                    ICONS_REMOVED=true
                fi
            done
        fi
        if [[ -n "$OLD_ICON" && -f "$OLD_ICON" && "$(dirname "$OLD_ICON")" == "$ICON_DIR" ]]; then
            rm -f "$OLD_ICON"
            ICONS_REMOVED=true
        fi
        if $ICONS_REMOVED; then
            echo "  [3/3] Иконки удалены."
        else
            echo "  [3/3] Иконки не найдены (пропущено)."
        fi
    else
        echo "  [3/3] Иконки оставлены (ярлык сохранён)."
    fi

    update_caches
    ok "Приложение '$LABEL' удалено."
    exit 0
fi

# ==========================================
# РЕЖИМ: ОБНОВЛЕНИЕ БИНАРНИКА (--update)
# ==========================================
if [[ -n "$UPDATE_NAME" ]]; then
    if [[ -z "$INPUT_PATH" ]]; then
        fail "Укажите новый файл: $0 --update <имя> /путь/к/новому.AppImage"
        exit 1
    fi
    if [[ ! -f "$INPUT_PATH" ]]; then
        fail "Файл '$INPUT_PATH' не найден."
        exit 1
    fi
    require_appimage_type2 "$INPUT_PATH"

    resolve_app_and_desktop "$UPDATE_NAME" || {
        fail "AppImage по запросу '$UPDATE_NAME' не найден в $TARGET_DIR"
        exit 1
    }
    OLD_APP="$APP_PATH"
    if [[ -z "$DESKTOP_FILE" || ! -f "$DESKTOP_FILE" ]]; then
        fail "Ярлык для '$UPDATE_NAME' не найден. Сначала установите приложение без --update."
        exit 1
    fi
    # Чужой ярлык (не создан этим скриптом) не переписываем без подтверждения
    if $DESKTOP_MATCHED_BY_NAME && ! is_own_desktop "$DESKTOP_FILE"; then
        if ! confirm "Ярлык '$DESKTOP_FILE' найден по имени и не создан этим скриптом. Обновить его Exec=? [y/N] "; then
            echo "Отменено."
            exit 0
        fi
    fi

    echo "Обновление '${DISPLAY_NAME:-$UPDATE_NAME}'..."

    # Читаем и валидируем Exec= ДО изменения файлов: если ярлык сломан
    # (нет строки Exec=), abort не оставит полузавершённого состояния
    OLD_EXE=$(desktop_key "$DESKTOP_FILE" "Exec")
    if [[ -z "$OLD_EXE" ]]; then
        fail "В '$DESKTOP_FILE' нет строки Exec= — обновление невозможно."
        exit 1
    fi
    OLD_EXE_PATH=$(exec_first_token "$OLD_EXE")

    # Новый бинарник всегда занимает путь, на который уже ссылается ярлык
    # (или путь найденного AppImage): ярлык не трогаем, версионные имена
    # не плодим, поиск по имени продолжает работать
    if [[ -n "$OLD_EXE_PATH" && -e "$OLD_EXE_PATH" ]]; then
        TARGET_PATH="$OLD_EXE_PATH"
    else
        TARGET_PATH="$OLD_APP"
    fi

    if same_file "$INPUT_PATH" "$TARGET_PATH"; then
        # Новый файл — это тот же самый файл, что уже установлен: копировать
        # нечего. Фиксируем права и честно предупреждаем, что версия не
        # изменилась (пользователь мог случайно указать установленный файл)
        chmod +x "$TARGET_PATH"
        warn "Указанный файл совпадает с установленным ($TARGET_PATH) — бинарник не изменился."
        echo "  [1/3] Файл уже на целевом пути"
    else
        # Атомарная замена: временный файл создаётся РЯДОМ с целью (тот же
        # каталог и ФС) — mv гарантированно rename, а не копия через ФС
        TMP_NEW="$(dirname "$TARGET_PATH")/.$(basename "$TARGET_PATH").new.$$"
        if ! cp -f "$INPUT_PATH" "$TMP_NEW"; then
            fail "Не удалось скопировать '$INPUT_PATH' рядом с целью: $TARGET_PATH"
            exit 1
        fi
        chmod +x "$TMP_NEW"
        if ! mv -f "$TMP_NEW" "$TARGET_PATH"; then
            fail "Не удалось установить новый бинарник: $TARGET_PATH"
            exit 1
        fi
        TMP_NEW=""
        echo "  [1/3] Новый бинарник установлен: $TARGET_PATH"
    fi

    # Аргументы Exec=: сохраняем старые (после первого токена);
    # явный --exec-args, если задан, заменяет их
    NEW_EXEC_ARGS=$(exec_args_remainder "$OLD_EXE")
    if [[ -n "$EXEC_ARGS" ]]; then
        NEW_EXEC_ARGS="$EXEC_ARGS"
    fi
    # Экранируем аргументы: кавычка/бэкслеш внутри Exec="..." иначе
    # создали бы битую строку (desktop-entry требует \ -> \\, " -> \")
    ESC_NEW_EXEC_ARGS=$(escape_desktop_string "$NEW_EXEC_ARGS")
    EXEC_LINE="\"$TARGET_PATH\""
    if [[ -n "$NEW_EXEC_ARGS" ]]; then
        EXEC_LINE="$EXEC_LINE $ESC_NEW_EXEC_ARGS"
    fi

    # & | ~ \ — спецсимволы sed replacement: & = совпадение, | = разделитель,
    # ~ = «последний заменённый текст» (GNU sed), \ = escape
    ESCAPED_EXEC=$(printf '%s' "$EXEC_LINE" | sed 's/[&|~\\]/\\&/g')
    cp -f "$DESKTOP_FILE" "$DESKTOP_FILE.bak"
    if ! desktop_sed "$DESKTOP_FILE" "s|^Exec=.*|Exec=$ESCAPED_EXEC|"; then
        # Откат из бэкапа: не оставляем ярлык в полуобновлённом состоянии
        cp -f "$DESKTOP_FILE.bak" "$DESKTOP_FILE"
        fail "Не удалось обновить Exec= в '$DESKTOP_FILE' (ярлык восстановлен из бэкапа)."
        exit 1
    fi
    # Проверяем, что Exec= действительно указывает на целевой файл
    # (если в ярлыке не было строки Exec=, sed молча ничего не меняет).
    # Сравниваем литерально (первый токен Exec=) — путь может содержать
    # glob-символы ([ ] * ?), которые ломают сравнение с шаблоном.
    if [[ $(exec_first_token "$(desktop_key "$DESKTOP_FILE" "Exec")") != "$TARGET_PATH" ]]; then
        cp -f "$DESKTOP_FILE.bak" "$DESKTOP_FILE"
        fail "Не удалось обновить Exec= в '$DESKTOP_FILE' (строка Exec= не найдена; ярлык восстановлен из бэкапа)."
        exit 1
    fi
    echo "  [2/3] Ярлык обновлён (Exec)"

    # Старый AppImage, найденный по запросу, если он отличается от целевого
    # пути (ярлык ссылался на другой файл): удаляем устаревший бинарник
    if [[ "$OLD_APP" != "$TARGET_PATH" && -f "$OLD_APP" ]]; then
        OLD_APP_REAL=$(resolve_path "$OLD_APP")
        TARGET_REAL=$(resolve_path "$TARGET_PATH")
        if [[ "$OLD_APP_REAL" == "$TARGET_REAL" ]]; then
            echo "  [3/3] Бинарник заменён"
        elif ! $DESKTOP_MATCHED_BY_NAME && \
             [[ "$OLD_APP_REAL" == "$(resolve_path "$TARGET_DIR")"/* ]]; then
            # Ярлык достоверно ссылался на этот AppImage и файл внутри
            # TARGET_DIR — удаляем его. Файлы ВНЕ TARGET_DIR молча не
            # удаляем: find_appimage_by_query принимает любой точный путь
            # *.AppImage (защита согласована с OUTSIDE_TARGET в --remove)
            rm -f "$OLD_APP"
            echo "  [3/3] Старый бинарник удалён: $OLD_APP"
        elif ! $DESKTOP_MATCHED_BY_NAME; then
            # Достоверное совпадение, но файл вне TARGET_DIR
            if confirm "Старый бинарник '$OLD_APP' находится вне $TARGET_DIR. Удалить его? [y/N] "; then
                rm -f "$OLD_APP"
                echo "  [3/3] Старый бинарник удалён: $OLD_APP"
            else
                echo "  [3/3] Старый бинарник оставлен: $OLD_APP"
            fi
        else
            # Ярлык найден фолбэком по имени: удаляем только с явного согласия
            if confirm "Ярлык найден по имени. Удалить старый бинарник '$OLD_APP'? [y/N] "; then
                rm -f "$OLD_APP"
                echo "  [3/3] Старый бинарник удалён: $OLD_APP"
            else
                echo "  [3/3] Старый бинарник оставлен: $OLD_APP"
            fi
        fi
    else
        echo "  [3/3] Бинарник заменён"
    fi

    update_caches
    ok "'${DISPLAY_NAME:-$UPDATE_NAME}' обновлён: $(basename "$TARGET_PATH")."
    echo "Для обновления иконки из нового бинарника: $0 --fix-icon $UPDATE_NAME"
    exit 0
fi

# ==========================================
# РЕЖИМ: РЕМОНТ ИКОНКИ (--fix-icon)
# ==========================================
if $FIX_ICON_MODE; then
    if [[ -z "$INPUT_PATH" ]]; then
        fail "Укажите имя программы или путь к AppImage: $0 --fix-icon <имя|путь>"
        exit 1
    fi

    resolve_app_and_desktop "$INPUT_PATH" || {
        fail "AppImage по запросу '$INPUT_PATH' не найден в $TARGET_DIR"
        exit 1
    }
    # extract_appimage_data исполняет бинарник (--appimage-extract): файл
    # мог быть подменён после установки или передан внешним путём —
    # проверяем сигнатуру, как в установке и --update
    require_appimage_type2 "$APP_PATH"

    echo "Режим ремонта: поиск ярлыка для '$(basename "$APP_PATH")'..."

    if [[ -z "$DESKTOP_FILE" || ! -f "$DESKTOP_FILE" ]]; then
        fail "Ярлык для этого AppImage не найден в системе."
        exit 1
    fi
    # Чужой ярлык (не создан этим скриптом) не переписываем без подтверждения —
    # как и в режимах --remove/--update
    if $DESKTOP_MATCHED_BY_NAME && ! is_own_desktop "$DESKTOP_FILE"; then
        if ! confirm "Ярлык '$DESKTOP_FILE' найден по имени и не создан этим скриптом. Изменить его Icon=? [y/N] "; then
            echo "Отменено."
            exit 0
        fi
    fi

    echo "Найден ярлык: $DESKTOP_FILE ($DISPLAY_NAME)"
    echo "Попытка повторного извлечения иконки..."

    if [[ -n "$CUSTOM_ICON" ]]; then
        # Ручная иконка имеет приоритет; её сбой — это ошибка пользователя
        # (опечатка в пути, неподдерживаемый формат), а не повод для fallback
        if ! process_icon "$CUSTOM_ICON" "$ICON_BASENAME"; then
            fail "Не удалось применить указанную иконку: $CUSTOM_ICON"
            exit 1
        fi
    else
        extract_appimage_data "$APP_PATH" "$ICON_BASENAME"
        # Fallback без распаковки: ищем готовую иконку с тем же базовым
        # именем в ICON_DIR (могла остаться от прошлой установки/ручной
        # установки) — быстрее и дешевле, чем zenity-диалог
        if [[ -z "$ICON_PATH_FOR_DESKTOP" ]]; then
            for icon_ext in png svg jpg jpeg ico; do
                if [[ -f "$ICON_DIR/$ICON_BASENAME.$icon_ext" ]]; then
                    ICON_PATH_FOR_DESKTOP="$ICON_DIR/$ICON_BASENAME.$icon_ext"
                    echo "      Найдена существующая иконка: $ICON_PATH_FOR_DESKTOP"
                    break
                fi
            done
        fi
        if [[ -z "$ICON_PATH_FOR_DESKTOP" ]] && gui_available && command -v zenity >/dev/null 2>&1; then
            USER_ICON=$(zenity --file-selection --title="Иконка не найдена. Выберите иконку для $DISPLAY_NAME" --file-filter="Картинки | *.png *.jpg *.jpeg *.svg *.ico" 2>/dev/null || true)
            if [[ -n "$USER_ICON" ]]; then
                process_icon "$USER_ICON" "$ICON_BASENAME" || true
            fi
        fi
    fi

    if [[ -n "$ICON_PATH_FOR_DESKTOP" ]]; then
        cp -f "$DESKTOP_FILE" "$DESKTOP_FILE.bak"
        if grep -q '^Icon=' "$DESKTOP_FILE" 2>/dev/null; then
            # & | ~ \ — спецсимволы sed replacement (см. выше)
            ESCAPED_ICON=$(printf '%s' "$ICON_PATH_FOR_DESKTOP" | sed 's/[&|~\\]/\\&/g')
            if ! desktop_sed "$DESKTOP_FILE" "s|^Icon=.*|Icon=$ESCAPED_ICON|"; then
                cp -f "$DESKTOP_FILE.bak" "$DESKTOP_FILE"
                fail "Не удалось обновить Icon= в '$DESKTOP_FILE' (ярлык восстановлен из бэкапа)."
                exit 1
            fi
        else
            # Строки Icon= не было — добавляем сразу после [Desktop Entry].
            # Значение передаётся через окружение awk: экранирование не требуется
            ICON_TMP=$(mktemp "$DESKTOP_DIR/.desktop-icon.XXXXXX")
            TMP_DESKTOP="$ICON_TMP"   # на случай сигнала — чистится в cleanup()
            if ICON_TO_ADD="$ICON_PATH_FOR_DESKTOP" awk '
                    BEGIN { inserted = 0 }
                    !inserted && /^\[Desktop Entry\][[:space:]]*$/ {
                        print
                        print "Icon=" ENVIRON["ICON_TO_ADD"]
                        inserted = 1
                        next
                    }
                    { print }
                ' "$DESKTOP_FILE" > "$ICON_TMP"; then
                chmod 644 "$ICON_TMP"   # mktemp создаёт 0600, ярлыку нужны 0644
                mv -f "$ICON_TMP" "$DESKTOP_FILE"
                TMP_DESKTOP=""
            else
                rm -f "$ICON_TMP"
                TMP_DESKTOP=""
                fail "Не удалось добавить Icon= в '$DESKTOP_FILE'."
                exit 1
            fi
        fi
        if [[ $(desktop_key "$DESKTOP_FILE" "Icon") != "$ICON_PATH_FOR_DESKTOP" ]]; then
            cp -f "$DESKTOP_FILE.bak" "$DESKTOP_FILE"
            fail "Не удалось обновить Icon= в '$DESKTOP_FILE' (ярлык восстановлен из бэкапа)."
            exit 1
        fi
        update_caches
        ok "Иконка для '$DISPLAY_NAME' успешно обновлена!"
    else
        warn "Не удалось извлечь иконку. Попробуйте указать вручную: $0 --icon /путь/к/иконке.png --fix-icon $INPUT_PATH"
    fi
    exit 0
fi

# ==========================================
# РЕЖИМ: ОБЫЧНОЕ ДОБАВЛЕНИЕ / ОБНОВЛЕНИЕ
# ==========================================

if [[ -z "$INPUT_PATH" ]]; then
    fail "Укажите путь к AppImage файлу (см. --help)."
    exit 1
fi

if [[ ! -f "$INPUT_PATH" ]]; then
    fail "Файл '$INPUT_PATH' не найден."
    exit 1
fi

if [[ "${INPUT_PATH,,}" != *.appimage ]]; then
    fail "Файл не имеет расширения .AppImage"
    exit 1
fi

require_appimage_type2 "$INPUT_PATH"

BASENAME=$(basename "$INPUT_PATH")
APP_NAME_RAW=$(printf '%s' "$BASENAME" | sed -E 's/\.[aA]pp[iI]mage$//')

# Кавычка в имени попадёт внутрь кавычек Exec="..." и создаст битый ярлык
if [[ "$BASENAME" == *\"* ]]; then
    fail "Имя файла не должно содержать кавычку (\"): $BASENAME"
    exit 1
fi

if [[ -n "$CUSTOM_NAME" ]]; then
    SAFE_FILENAME=$(sanitize_filename "$CUSTOM_NAME")
else
    SAFE_FILENAME=$(sanitize_filename "$APP_NAME_RAW")
fi

DESKTOP_FILE="$DESKTOP_DIR/$SAFE_FILENAME.desktop"
DESTINATION_PATH="$TARGET_DIR/$BASENAME"
ICON_PATH_FOR_DESKTOP=""

# Существующие поля ярлыка (при переустановке сохраняем их как baseline)
OLD_NAME=""
OLD_COMMENT=""
OLD_CATEGORIES=""
OLD_KEYWORDS=""
if [[ -f "$DESKTOP_FILE" ]]; then
    OLD_NAME=$(desktop_key "$DESKTOP_FILE" "Name")
    OLD_COMMENT=$(desktop_key "$DESKTOP_FILE" "Comment")
    OLD_CATEGORIES=$(desktop_key "$DESKTOP_FILE" "Categories")
    OLD_KEYWORDS=$(desktop_key "$DESKTOP_FILE" "Keywords")
fi

if [[ -f "$DESKTOP_FILE" && -z "$CUSTOM_ICON" && -z "$CUSTOM_NAME" && -z "$CUSTOM_CATEGORIES" \
   && -z "$CUSTOM_COMMENT" && -z "$CUSTOM_KEYWORDS" && -z "$EXEC_ARGS" ]]; then
    warn "Приложение '${OLD_NAME:-$SAFE_FILENAME}' уже добавлено."
    echo "Для ремонта иконки: $0 --fix-icon $SAFE_FILENAME"
    echo "Для обновления:    $0 --update $SAFE_FILENAME <новый файл.AppImage>"
    exit 0
fi

# Установка под новым именем (--name): если другой ярлык уже ссылается на этот
# же бинарник, в меню появится дубликат — предлагаем удалить старый ярлык
if [[ ! -f "$DESKTOP_FILE" ]]; then
    DUP_DESKTOP=$(find_desktop_by_appimage "$DESTINATION_PATH" || true)
    if [[ -n "$DUP_DESKTOP" ]]; then
        warn "Ярлык '$DUP_DESKTOP' уже ссылается на этот бинарник."
        if confirm "Удалить старый ярлык (иначе в меню будет дубликат)? [y/N] "; then
            DUP_ICON_BASE=$(basename "$DUP_DESKTOP" .desktop)
            rm -f "$DUP_DESKTOP" "$DUP_DESKTOP.bak"
            rm -f "$ICON_DIR/$DUP_ICON_BASE".png "$ICON_DIR/$DUP_ICON_BASE".svg \
                  "$ICON_DIR/$DUP_ICON_BASE".jpg "$ICON_DIR/$DUP_ICON_BASE".jpeg \
                  "$ICON_DIR/$DUP_ICON_BASE".ico
            echo "Старый ярлык удалён: $DUP_DESKTOP"
        else
            warn "Старый ярлык оставлен: в меню приложений может появиться дубликат."
        fi
    fi
fi

# Отображаемое имя: --name > старое имя ярлыка > встроенное > капитализация
# (встроенное имя дополнительно учитывается после извлечения на шаге 2)
if [[ -n "$CUSTOM_NAME" ]]; then
    DISPLAY_NAME="$CUSTOM_NAME"
elif [[ -n "$OLD_NAME" ]]; then
    DISPLAY_NAME="$OLD_NAME"
else
    DISPLAY_NAME=""
fi

echo "Настройка '${DISPLAY_NAME:-$APP_NAME_RAW}'..."

# 1. Переносим (атомарно: временный файл на той же ФС + mv).
# cp вместо mv: исходник сохраняется, и при сбое на последующих шагах
# не образуется состояние «файл ушёл из Downloads, ярлык не создан».
INPUT_REAL=$(resolve_path "$INPUT_PATH")
if same_file "$INPUT_PATH" "$DESTINATION_PATH"; then
    # Входной файл — это и есть целевой (повторная установка с --icon/--name
    # и т.п. из TARGET_DIR). Копировать нечего: cp файла в себя усёк бы его
    # до 0 байт. Ярлык и иконка обновятся дальше.
    echo "[1/3] Файл уже на целевом пути (обновляем только ярлык/иконку)"
    chmod +x "$DESTINATION_PATH"
elif [[ "$(dirname "$INPUT_REAL")" != "$(resolve_path "$TARGET_DIR")" ]]; then
    if [[ -e "$DESTINATION_PATH" && "$INPUT_REAL" != "$(resolve_path "$DESTINATION_PATH")" ]]; then
        warn "Файл '$BASENAME' уже существует в $TARGET_DIR и будет перезаписан."
    fi
    TMP_DEST="$TARGET_DIR/.$BASENAME.tmp.$$"
    if ! cp -f "$INPUT_PATH" "$TMP_DEST"; then
        fail "Не удалось скопировать '$INPUT_PATH' в $TARGET_DIR"
        exit 1
    fi
    chmod +x "$TMP_DEST"
    if ! mv -f "$TMP_DEST" "$DESTINATION_PATH"; then
        fail "Не удалось установить файл: $DESTINATION_PATH"
        exit 1
    fi
    TMP_DEST=""
    echo "[1/3] Файл скопирован в $TARGET_DIR (оригинал сохранён)"
else
    echo "[1/3] Файл уже в целевой папке"
    chmod +x "$DESTINATION_PATH"
fi

# 2. Иконка и метаданные
echo "[2/3] Обработка иконки и метаданных..."
EMBEDDED_NAME=""
EMBEDDED_COMMENT=""
EMBEDDED_CATEGORIES=""
EMBEDDED_KEYWORDS=""

# Метаданные (Name/Comment/Categories/Keywords) извлекаем из нового бинарника
# всегда — иначе при --icon или переустановке ярлык сохранил бы устаревшие
# данные. Иконку из бинарника извлекаем только когда она нужна (нет --icon
# и нет существующего ярлыка с иконкой).
if [[ -n "$CUSTOM_ICON" ]]; then
    extract_appimage_data "$DESTINATION_PATH" "$SAFE_FILENAME" true
    if ! process_icon "$CUSTOM_ICON" "$SAFE_FILENAME"; then
        # Сбой ручной иконки (напр., опечатка в пути): не затираем
        # существующую иконку ярлыка дефолтной — используем её как fallback
        if [[ -f "$DESKTOP_FILE" ]]; then
            ICON_PATH_FOR_DESKTOP=$(desktop_key "$DESKTOP_FILE" "Icon")
        fi
    fi
elif [[ -f "$DESKTOP_FILE" ]]; then
    # Переустановка: иконку ярлыка сохраняем, метаданные обновляем
    extract_appimage_data "$DESTINATION_PATH" "$SAFE_FILENAME" true
    ICON_PATH_FOR_DESKTOP=$(desktop_key "$DESKTOP_FILE" "Icon")
    echo "      Использована текущая иконка ярлыка."
else
    extract_appimage_data "$DESTINATION_PATH" "$SAFE_FILENAME"

    if [[ -z "$ICON_PATH_FOR_DESKTOP" ]] && gui_available && command -v zenity >/dev/null 2>&1; then
        USER_ICON=$(zenity --file-selection --title="Иконка не найдена. Выберите иконку для $DISPLAY_NAME" --file-filter="Картинки | *.png *.jpg *.jpeg *.svg *.ico" 2>/dev/null || true)
        if [[ -n "$USER_ICON" ]]; then
            process_icon "$USER_ICON" "$SAFE_FILENAME" || true
        fi
    fi
fi

# 3. Ярлык
echo "[3/3] Сохранение ярлыка..."

# Имя: приоритет уже вычислен, дополняем встроенным/капитализацией
if [[ -z "$DISPLAY_NAME" ]]; then
    if [[ -n "$EMBEDDED_NAME" ]]; then
        DISPLAY_NAME="$EMBEDDED_NAME"
    else
        DISPLAY_NAME=$(printf '%s' "$APP_NAME_RAW" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
    fi
fi

# Комментарий: --comment > встроенный > старый
if [[ -n "$CUSTOM_COMMENT" ]]; then
    COMMENT="$CUSTOM_COMMENT"
elif [[ -n "$EMBEDDED_COMMENT" ]]; then
    COMMENT="$EMBEDDED_COMMENT"
else
    COMMENT="$OLD_COMMENT"
fi

# Категории: --categories > встроенные > старые > Utility;
if [[ -n "$CUSTOM_CATEGORIES" ]]; then
    CATEGORIES=$(normalize_list "$CUSTOM_CATEGORIES")
elif [[ -n "$EMBEDDED_CATEGORIES" ]]; then
    CATEGORIES=$(normalize_list "$EMBEDDED_CATEGORIES")
elif [[ -n "$OLD_CATEGORIES" ]]; then
    CATEGORIES="$OLD_CATEGORIES"
else
    CATEGORIES="Utility;"
fi

# Ключевые слова: --keywords > встроенные > старые
if [[ -n "$CUSTOM_KEYWORDS" ]]; then
    KEYWORDS=$(normalize_list "$CUSTOM_KEYWORDS")
elif [[ -n "$EMBEDDED_KEYWORDS" ]]; then
    KEYWORDS=$(normalize_list "$EMBEDDED_KEYWORDS")
else
    KEYWORDS=$(normalize_list "$OLD_KEYWORDS")
fi

ICON_LINE="Icon=${ICON_PATH_FOR_DESKTOP:-application-x-executable}"
# Экранируем аргументы: кавычка/бэкслеш внутри Exec="..." иначе
# создали бы битую строку (desktop-entry требует \ -> \\, " -> \")
ESC_EXEC_ARGS=$(escape_desktop_string "$EXEC_ARGS")
EXEC_LINE="\"$DESTINATION_PATH\""
if [[ -n "$EXEC_ARGS" ]]; then
    EXEC_LINE="$EXEC_LINE $ESC_EXEC_ARGS"
fi

if ! write_desktop_file "$DESKTOP_FILE" "$DISPLAY_NAME" "$COMMENT" "$EXEC_LINE" "$ICON_LINE" "$CATEGORIES" "$KEYWORDS"; then
    fail "Не удалось записать ярлык: $DESKTOP_FILE"
    exit 1
fi

update_caches

ok "Приложение '$DISPLAY_NAME' готово к работе!"
