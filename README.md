<h1 align="center">📝 whatchanged.yazi</h1>
<p align="center">
  <b>Browse Git changes and preview diffs in <a href="https://github.com/sxyazi/yazi">Yazi</a></b><br>
</p>

<p align="center">
  <img src="assets/preview.png" width="850" alt="Git changes with staged and unstaged diff sections" />
</p>

---

> [!TIP]
> **Русская версия:** [README-RU.md](README-RU.md)

## Installation

> [!IMPORTANT]
> Requires [yazi](https://yazi-rs.github.io) v26.8.15+\
> Requires [git](https://git-scm.com) in `PATH`

```sh
ya pkg add WhoSowSee/whatchanged
```

```sh
# Manual installation

# Linux/macOS
git clone https://github.com/WhoSowSee/whatchanged.yazi.git ~/.config/yazi/plugins/whatchanged.yazi

# Windows
git clone https://github.com/WhoSowSee/whatchanged.yazi.git "$env:APPDATA\yazi\config\plugins\whatchanged.yazi"
```

## Setup

In `init.lua`:

```lua
require("whatchanged"):setup()
```

Or with optional settings:

```lua
require("whatchanged"):setup {
  notify = false, -- true - show preview-mode notifications
  wrap = "words", -- "words" - keep indentation, "trim" - trim indentation, "none" - no wrapping
  show_filename = false, -- true - show the file path above the diff
}
```

At the start of `[plugin].prepend_previewers` in `yazi.toml`:

```toml
[plugin]
prepend_previewers = [
  { url = "search://*", run = "whatchanged" },
  { url = "search://*/", run = "whatchanged" },
]
```

In `keymap.toml`:

```toml
[[mgr.prepend_keymap]]
on = [ "<A-g>", "c" ]
run = "plugin whatchanged"
desc = "Toggle git changes"

[[mgr.prepend_keymap]]
on = [ "<A-g>", "r" ]
run = "plugin whatchanged refresh"
desc = "Refresh git changes"

[[mgr.prepend_keymap]]
on = [ "<A-g>", "v" ]
run = "plugin whatchanged preview"
desc = "Toggle diff / file content"
```

<p align="center">
  <img src="https://raw.githubusercontent.com/catppuccin/catppuccin/main/assets/footers/gray0_ctp_on_line.svg?sanitize=true" alt="catppuccin" />
</p>

<p align="center">
  <i><code>&copy; 2026 <a href="https://github.com/WhoSowSee">WhoSowSee</a></code></i>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-CBA6F7?style=for-the-badge&logoColor=cdd6f4&labelColor=302D41" alt="MIT License"></a>
</p>
