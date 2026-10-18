<h1 align="center">📝 whatchanged.yazi</h1>
<p align="center">
  <b>Список Git-изменений и превью diff в <a href="https://github.com/sxyazi/yazi">Yazi</a></b><br>
</p>

<p align="center">
  <img src="assets/preview.png" width="850" alt="Git-изменения с отдельными секциями staged и unstaged" />
</p>

---

> [!TIP]
> **English version:** [README.md](README.md)

## Установка

> [!IMPORTANT]
> Требуются [yazi](https://yazi-rs.github.io) v26.8.15+\
> Требуется [git](https://git-scm.com) в `PATH`

```sh
ya pkg add WhoSowSee/whatchanged
```

```sh
# Ручная установка

# Linux/macOS
git clone https://github.com/WhoSowSee/whatchanged.yazi.git ~/.config/yazi/plugins/whatchanged.yazi

# Windows
git clone https://github.com/WhoSowSee/whatchanged.yazi.git "$env:APPDATA\yazi\config\plugins\whatchanged.yazi"
```

## Настройка

В `init.lua`:

```lua
require("whatchanged"):setup()
```

Или с необязательными параметрами:

```lua
require("whatchanged"):setup {
  notify = false, -- true - показывать уведомления при переключении превью
  wrap = "words", -- "words" - сохранять отступы, "trim" - удалять отступы, "none" - без переноса
  show_filename = false, -- true - показывать путь файла над diff
  diff_style = "unified", -- "unified" или "side-by-side" (требуется delta)
  delta = "delta", -- необязательное имя или путь исполняемого файла
  -- git_ratio = { 0, 1, 4 }, -- необязательно: 0% родитель, 20% список, 80% превью
}
```

### Сравнение в двух колонках и ширина панелей

Установите [delta](https://github.com/dandavison/delta) и задайте `diff_style = "side-by-side"`.
Каждая секция diff показывает старую версию слева, а новую — справа.
Delta необязательна: стандартному unified-превью достаточно Git. Если Delta не
запускается или не может отобразить diff, превью объясняет проблему и использует
обычный unified diff.

Delta получает текущую ширину превью, явный светлый/тёмный режим и
`--no-gitconfig`. Delta не загружает конфигурацию Git; конфигурации Git и Delta
не изменяются.
Секции staged и unstaged, прокрутка (`J`/`K`) и просмотр содержимого файла
продолжают работать. Размер вывода превью ограничен 2 МиБ.

Параметр `git_ratio` принимает три неотрицательных целочисленных веса и меняет
ширину панелей только в Git-представлениях этого плагина. Например, `{ 0, 1, 4 }`
скрывает родительскую панель и делит оставшееся место в отношении 20%/80%.
Исходное соотношение восстанавливается при выходе из представления или переходе
на обычную вкладку. Без `git_ratio` текущая раскладка сохраняется; параметр работает
с обоими стилями diff.

В начало `[plugin].prepend_previewers` в `yazi.toml`:

```toml
[plugin]
prepend_previewers = [
  { url = "search://*", run = "whatchanged" },
  { url = "search://*/", run = "whatchanged" },
]
```

В `keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on = [ "<A-g>", "c" ]
run = "plugin whatchanged"
desc = "Список git-изменений"

[[mgr.prepend_keymap]]
on = [ "<A-g>", "r" ]
run = "plugin whatchanged refresh"
desc = "Обновить git-изменения"

[[mgr.prepend_keymap]]
on = [ "<A-g>", "v" ]
run = "plugin whatchanged preview"
desc = "Переключить diff / содержимое"
```

## Проверка

В Linux/macOS с Python 3, tmux, Git, Yazi и Delta в `PATH` запустите
`python3 tests/verify_preview.py`. Проверка использует временные репозитории и
отдельный сервер tmux; ваша конфигурация Yazi и существующие репозитории не меняются.
Для выбора бинарных файлов используйте `--yazi /path/to/yazi --delta /path/to/delta`.

<p align="center">
  <img src="https://raw.githubusercontent.com/catppuccin/catppuccin/main/assets/footers/gray0_ctp_on_line.svg?sanitize=true" alt="catppuccin" />
</p>

<p align="center">
  <i><code>&copy; 2026 <a href="https://github.com/WhoSowSee">WhoSowSee</a></code></i>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-CBA6F7?style=for-the-badge&logoColor=cdd6f4&labelColor=302D41" alt="Лицензия MIT"></a>
</p>
