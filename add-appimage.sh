#!/bin/bash

# --- Парсинг аргументов ---
INPUT_PATH=""
CUSTOM_ICON=""
CUSTOM_NAME=""
FIX_ICON_MODE=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --icon) CUSTOM_ICON="$2"; shift ;;
        --name) CUSTOM_NAME="$2"; shift ;;
        --fix-icon) FIX_ICON_MODE=true ;;
        -*) echo "Ошибка: Неизвестный параметр $1"; exit 1 ;;
        *) INPUT_PATH="$1" ;;
    esac
    shift
done

# --- Вспомогательные функции ---

sanitize_filename() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//'
}

process_icon() {
    local SOURCE="$1"
    local DEST_BASE="$2"
    
    if [ ! -f "$SOURCE" ]; then
        echo "      [ОШИБКА] Файл иконки не найден: $SOURCE"
        return 1
    fi

    local MIME_TYPE=$(file --mime-type -b "$SOURCE")
    local REAL_EXT="png"
    
    if [[ "$MIME_TYPE" == *"svg"* ]]; then REAL_EXT="svg"
    elif [[ "$MIME_TYPE" == *"jpeg"* ]]; then REAL_EXT="jpg"
    elif [[ "$MIME_TYPE" == *"png"* ]]; then REAL_EXT="png"
    fi

    local FINAL_PATH="$ICON_DIR/$DEST_BASE.$REAL_EXT"
    cp -L "$SOURCE" "$FINAL_PATH" 2>/dev/null || cp "$SOURCE" "$FINAL_PATH"
    chmod 644 "$FINAL_PATH"
    ICON_PATH_FOR_DESKTOP="$FINAL_PATH"
    echo "      Иконка успешно обработана (формат: $REAL_EXT)"
    return 0
}

extract_icon_from_appimage() {
    local APP_PATH="$1"
    local ICON_BASE="$2"
    
    ICON_PATH_FOR_DESKTOP=""
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    "$APP_PATH" --appimage-extract .DirIcon '*.png' '*.svg' > /dev/null 2>&1
    ICON_SOURCE=$(find "$TEMP_DIR/squashfs-root" -maxdepth 1 \( -name ".DirIcon" -o -name "*.png" -o -name "*.svg" \) | head -n 1)

    if [ -n "$ICON_SOURCE" ]; then
        process_icon "$ICON_SOURCE" "$ICON_BASE"
    else
        echo "      Автоматическое извлечение не удалось."
    fi
    rm -rf "$TEMP_DIR"
}

# --- Основная логика ---

TARGET_DIR="$HOME/.local/bin"
ICON_DIR="$HOME/.local/share/icons"
DESKTOP_DIR="$HOME/.local/share/applications"
mkdir -p "$TARGET_DIR" "$ICON_DIR" "$DESKTOP_DIR"

# ==========================================
# РЕЖИМ: РЕМОНТ ИКОНКИ (--fix-icon)
# ==========================================
if [ "$FIX_ICON_MODE" = true ]; then
    if [ -z "$INPUT_PATH" ]; then
        echo "Ошибка: Укажите имя программы или путь к AppImage для ремонта иконки."
        echo "Пример: $0 --fix-icon loop-desktop"
        exit 1
    fi

    # Ищем AppImage файл
    if [ -f "$INPUT_PATH" ]; then
        APP_PATH="$INPUT_PATH"
    else
        APP_PATH=$(find "$TARGET_DIR" -maxdepth 1 -name "*$INPUT_PATH*.AppImage" | head -n 1)
    fi

    if [ -z "$APP_PATH" ] || [ ! -f "$APP_PATH" ]; then
        echo "Ошибка: AppImage по запросу '$INPUT_PATH' не найден в $TARGET_DIR"
        exit 1
    fi

    echo "Режим ремонта: Поиск ярлыка для '$(basename "$APP_PATH")'..."
    
    # УМНЫЙ ПОИСК ЯРЛЫКА: Ищем не по имени, а по содержимому (какой файл ссылается на этот AppImage)
    DESKTOP_FILE=$(grep -rl "Exec=.*$(basename "$APP_PATH")" "$DESKTOP_DIR" 2>/dev/null | head -n 1)
    
    # Если через grep не нашло (бывает редко), ищем просто по похожему имени
    if [ -z "$DESKTOP_FILE" ]; then
        BASENAME_NO_EXT=$(basename "$APP_PATH" | sed 's/\.AppImage$//')
        DESKTOP_FILE=$(find "$DESKTOP_DIR" -maxdepth 1 -iname "*$BASENAME_NO_EXT*.desktop" | head -n 1)
    fi

    if [ -z "$DESKTOP_FILE" ] || [ ! -f "$DESKTOP_FILE" ]; then
        echo "Ошибка: Ярлык для этого AppImage не найден в системе."
        exit 1
    fi

    DISPLAY_NAME=$(grep "^Name=" "$DESKTOP_FILE" | cut -d'=' -f2)
    echo "Найден ярлык: $DESKTOP_FILE ($DISPLAY_NAME)"
    echo "Попытка повторного извлечения иконки..."

    # Берем имя для иконки из имени найденного desktop-файла, чтобы не плодить дубли
    ICON_BASENAME=$(basename "$DESKTOP_FILE" .desktop)
    
    extract_icon_from_appimage "$APP_PATH" "$ICON_BASENAME"

    if [ -n "$ICON_PATH_FOR_DESKTOP" ]; then
        # Заменяем строку Icon=
        sed -i "s|^Icon=.*|Icon=$ICON_PATH_FOR_DESKTOP|" "$DESKTOP_FILE"
        gtk-update-icon-cache -f "$ICON_DIR" 2>/dev/null
        echo -e "\033[32m[ГОТОВО]\033[0m Иконка для '$DISPLAY_NAME' успешно обновлена!"
    else
        echo -e "\033[33m[ПРОВАЛ]\033[0m Не удалось извлечь иконку. Попробуйте указать вручную: $0 --icon /путь/к/иконке.png --fix-icon $INPUT_PATH"
    fi
    exit 0
fi

# ==========================================
# РЕЖИМ: ОБЫЧНОЕ ДОБАВЛЕНИЕ / ОБНОВЛЕНИЕ
# ==========================================

if [ -z "$INPUT_PATH" ]; then
    echo "Ошибка: Укажите путь к AppImage файлу."
    echo "Использование: $0 [--name 'Имя'] [--icon /путь/к/иконке] /путь/к/файлу.AppImage"
    exit 1
fi

if [ ! -f "$INPUT_PATH" ]; then
    echo "Ошибка: Файл '$INPUT_PATH' не найден."
    exit 1
fi

if [[ "$INPUT_PATH" != *.AppImage ]]; then
    echo "Ошибка: Файл не имеет расширения .AppImage"
    exit 1
fi

BASENAME=$(basename "$INPUT_PATH")
APP_NAME_RAW=$(echo "$BASENAME" | sed 's/\.AppImage$//')
SAFE_FILENAME=$(sanitize_filename "$APP_NAME_RAW")

if [ -n "$CUSTOM_NAME" ]; then
    DISPLAY_NAME="$CUSTOM_NAME"
    SAFE_FILENAME=$(sanitize_filename "$CUSTOM_NAME")
else
    DISPLAY_NAME=$(echo "$APP_NAME_RAW" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
fi

DESKTOP_FILE="$DESKTOP_DIR/$SAFE_FILENAME.desktop"
DESTINATION_PATH="$TARGET_DIR/$BASENAME"
ICON_PATH_FOR_DESKTOP=""

if [ -f "$DESKTOP_FILE" ] && [ -z "$CUSTOM_ICON" ] && [ -z "$CUSTOM_NAME" ]; then
    echo -e "\033[33m[ВНИМАНИЕ]\033[0m Приложение '$DISPLAY_NAME' уже добавлено."
    echo "Для ремонта иконки используйте: $0 --fix-icon $SAFE_FILENAME"
    exit 0
fi

echo "Настройка '$DISPLAY_NAME'..."

# 1. Переносим
if [ "$(dirname "$(readlink -f "$INPUT_PATH")")" != "$(readlink -f "$TARGET_DIR")" ]; then
    mv "$INPUT_PATH" "$TARGET_DIR/"
    echo "[1/3] Файл перемещен в $TARGET_DIR"
else
    echo "[1/3] Файл уже в целевой папке"
fi
chmod +x "$DESTINATION_PATH"

# 2. Иконка
echo "[2/3] Обработка иконки..."
if [ -n "$CUSTOM_ICON" ]; then
    process_icon "$CUSTOM_ICON" "$SAFE_FILENAME"
elif [ -f "$DESKTOP_FILE" ]; then
    ICON_PATH_FOR_DESKTOP=$(grep "^Icon=" "$DESKTOP_FILE" | cut -d'=' -f2)
    echo "      Использована текущая иконка ярлыка."
else
    extract_icon_from_appimage "$DESTINATION_PATH" "$SAFE_FILENAME"
    
    if [ -z "$ICON_PATH_FOR_DESKTOP" ] && command -v zenity &> /dev/null; then
        USER_ICON=$(zenity --file-selection --title="Иконка не найдена. Выберите иконку для $DISPLAY_NAME" --file-filter="Картинки | *.png *.jpg *.jpeg *.svg *.ico" 2>/dev/null)
        if [ -n "$USER_ICON" ]; then
            process_icon "$USER_ICON" "$SAFE_FILENAME"
        fi
    fi
fi

# 3. Ярлык
echo "[3/3] Сохранение ярлыка..."
ICON_LINE="Icon=${ICON_PATH_FOR_DESKTOP:-application-x-executable}"

cat << EOF > "$DESKTOP_FILE"
[Desktop Entry]
Name=$DISPLAY_NAME
Exec="$DESTINATION_PATH"
 $ICON_LINE
Terminal=false
Type=Application
Categories=AudioVideo;Audio;Video;
StartupNotify=true
EOF

update-desktop-database "$DESKTOP_DIR" > /dev/null 2>&1
gtk-update-icon-cache -f "$ICON_DIR" 2>/dev/null

echo -e "\033[32m[ГОТОВО]\033[0m Приложение '$DISPLAY_NAME' готово к работе!"
