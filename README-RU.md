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
}
```

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

<p align="center">
  <img src="https://raw.githubusercontent.com/catppuccin/catppuccin/main/assets/footers/gray0_ctp_on_line.svg?sanitize=true" alt="catppuccin" />
</p>

<p align="center">
  <i><code>&copy; 2026 <a href="https://github.com/WhoSowSee">WhoSowSee</a></code></i>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-CBA6F7?style=for-the-badge&logoColor=cdd6f4&labelColor=302D41" alt="Лицензия MIT"></a>
</p>
