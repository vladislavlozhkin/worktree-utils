# Git Worktree Utilities

Набор утилит для автоматизации работы с **Git Worktrees**. Упрощает создание изолированных окружений для параллельной разработки и экспериментов с AI.

## Единый CLI: `wt`

Все утилиты доступны через единую команду `wt`.

### Команды

| Команда | Алиасы | Описание |
| :--- | :--- | :--- |
| `wt new <name>` | `create` | Создать новую задачу (ветку + папку + setup) |
| `wt list` | `ls` | Показать список активных worktrees |
| `wt kill <name>` | `rm` | Удалить worktree (добавьте `-D` для удаления ветки) |
| `wt setup` | `init` | Настроить/обновить окружение в текущей папке |

### Конфигурация (`.worktree-config`)

Скрипт `wt setup` читает `.git/info/exclude` и `.worktree-config`.
**Синтаксис:**
```text
# Ссылки (по умолчанию)
scripts
LINK .geminiignore

# Копирование (для локальных .env)
COPY .env

# Запуск команд
RUN npm install
```

## Установка

### Быстрый старт (в текущий проект)
Чтобы добавить утилиты в конкретный проект, выполните в корне репозитория:
```bash
curl -fsSL https://raw.githubusercontent.com/vladislavlozhkin/worktree-utils/main/install.sh | bash
```
Это создаст папку `scripts/` с утилитами и файл конфигурации `.worktree-config`.

### Глобальная установка (для разработки)
Если вы клонировали этот репозиторий и хотите использовать `wt` глобально:

```bash
mkdir -p ~/bin
ln -sf "$(pwd)/scripts/wt" ~/bin/wt
```
*(Убедитесь, что `~/bin` есть в вашем PATH)*

## Пример Workflow

```bash
# 1. Начать новую задачу
wt new feature/awesome-bot

# 2. (Внутри папки) Если изменили конфиги или нужно пересобрать
wt setup

# 3. Посмотреть, где мы
wt list

# 4. Завершить работу (удалить папку и ветку)
wt rm feature/awesome-bot -D
```