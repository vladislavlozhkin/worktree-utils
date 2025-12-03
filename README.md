# Git Worktree Utilities

Набор утилит для автоматизации работы с **Git Worktrees**. Упрощает создание изолированных окружений для параллельной разработки и экспериментов с AI.

## Инструменты

### 1. `scripts/wt-setup` (Environment Setup)

Скрипт настройки окружения (ранее `ai-link`).

Синхронизирует конфигурационные файлы, секреты и скрипты из **Главного worktree** в текущее рабочее дерево.

**Конфигурация:**
Скрипт читает список файлов из двух источников:
1.  **`.git/info/exclude`**: Все игнорируемые файлы автоматически линкуются (Symlink).
2.  **`.worktree-config`**: Файл в корне проекта для явной настройки.

**Синтаксис `.worktree-config`:**
Поддерживает два режима: `LINK` (ссылка) и `COPY` (копия).
```text
# По умолчанию создается симлинк
scripts
CLAUDE.md

# Явное создание симлинка
LINK .geminiignore

# Копирование файла (полезно для .env, который нужно менять локально)
COPY .env
COPY .env.local
```

### 2. `scripts/wt-new` (Quick Start)

Создает новую задачу одной командой:
1.  Создает папку `../feature-name`.
2.  Создает ветку `feature/name`.
3.  Автоматически запускает `wt-setup`.

### 3. `scripts/wt-kill` (Smart Cleanup)

Безопасно удаляет worktree.
*   `wt-kill feature/ui` — Удаляет только папку.
*   `wt-kill feature/ui -D` — Удаляет папку И ветку.

### 4. `scripts/wt-list` (Navigator)

Показывает список worktrees с полезной информацией.

## Установка

Рекомендуется создать глобальные ссылки:

```bash
mkdir -p ~/bin
REPO_PATH=$(pwd)

ln -sf "$REPO_PATH/scripts/wt-setup" ~/bin/wt-setup
ln -sf "$REPO_PATH/scripts/wt-new"   ~/bin/wt-new
ln -sf "$REPO_PATH/scripts/wt-kill"  ~/bin/wt-kill
ln -sf "$REPO_PATH/scripts/wt-list"  ~/bin/wt-list
```
*(Убедитесь, что `~/bin` есть в PATH)*

## Использование

```bash
# Начать новую задачу
wt-new feature/awesome-bot

# (Внутри папки) Если нужно обновить конфиги
wt-setup

# Завершить работу
wt-kill feature/awesome-bot -D
```