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
  diff_style = "unified", -- "unified" or "side-by-side" (requires delta)
  delta = "delta", -- optional executable name or path
  -- git_ratio = { 0, 1, 4 }, -- optional: 0% parent, 20% file list, 80% preview
}
```

### Side-by-side preview and pane widths

Install [delta](https://github.com/dandavison/delta), then set `diff_style = "side-by-side"`.
Each diff section shows the old version on the left and the new version on the right.
Delta is optional: the default unified preview needs only Git. If Delta cannot start
or render a diff, the preview explains the problem and falls back to the unified diff.

Delta receives the current preview width, explicit light/dark mode, and
`--no-gitconfig`. Delta does not load your Git configuration, and neither Git nor
Delta configuration is changed.
Staged and unstaged sections, preview scrolling (`J`/`K`), and source preview
continue to work. Preview output is limited to 2 MiB.

Set `git_ratio` to three nonnegative integer weights to change pane widths only
inside this plugin's Git changes views. For example, `{ 0, 1, 4 }` hides the parent
pane and divides the remaining space 20%/80%. The normal ratio is restored when
leaving the view or switching to an ordinary tab. Omit `git_ratio` to keep your
existing layout; it works with either diff style.

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

## Verification

On Linux/macOS with Python 3, tmux, Git, Yazi, and Delta in `PATH`, run
`python3 tests/verify_preview.py`. The test uses temporary repositories and a private
tmux server; it does not use your Yazi configuration or modify an existing repository.
Use `--yazi /path/to/yazi --delta /path/to/delta` to test specific binaries.

<p align="center">
  <img src="https://raw.githubusercontent.com/catppuccin/catppuccin/main/assets/footers/gray0_ctp_on_line.svg?sanitize=true" alt="catppuccin" />
</p>

<p align="center">
  <i><code>&copy; 2026 <a href="https://github.com/WhoSowSee">WhoSowSee</a></code></i>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-CBA6F7?style=for-the-badge&logoColor=cdd6f4&labelColor=302D41" alt="MIT License"></a>
</p>
