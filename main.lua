--- @since 26.8.15

local M = {}
local NAME = "whatchanged"
local SEARCH_DOMAIN_PATTERN = NAME:gsub("(%W)", "%%%1") .. " %d+"
local DUMMY_KIND = 8
local WRAP_MODES = { words = ui.Wrap.YES, trim = ui.Wrap.TRIM, none = ui.Wrap.NO }
local NOTICE_ANIMATION = 0.25
local FILTERS = { all = true, staged = true, unstaged = true }
local STATUS_FIELDS = { ["1"] = 8, ["2"] = 9, u = 10 }

local function status_flags(status)
	if status == "??" then
		return false, false, true, false
	elseif status:find("U", 1, true) or status == "AA" or status == "DD" then
		return false, false, false, true
	end
	return status:sub(1, 1) ~= " ", status:sub(2, 2) ~= " ", false, false
end

local function status_label(status)
	local staged, modified, untracked, conflict = status_flags(status)
	if conflict then return "conflict" end
	if untracked then return "new" end
	if staged and modified then return "staged+modified" end
	return staged and "staged" or "modified"
end

local function include_status(status, filter)
	if filter == "all" then return true end
	local staged, modified, untracked, conflict = status_flags(status)
	return filter == "staged" and staged or filter == "unstaged" and (modified or untracked or conflict)
end

local function branch_text(meta)
	if not meta then return "Branch status unavailable" end
	local branch = meta.head or "Unknown branch"
	if branch == "(detached)" then return "HEAD@" .. (meta.oid or "?"):sub(1, 7) .. " (detached)" end
	if meta.oid == "(initial)" then branch = branch .. " (unborn)" end
	if not meta.upstream then return branch .. " (no upstream)" end
	branch = branch .. " → " .. meta.upstream
	if meta.gone then return branch .. " (upstream gone)" end
	if meta.ahead == nil then return branch .. " (tracking unknown)" end
	return branch .. " ↓" .. meta.behind .. " ↑" .. meta.ahead
end

local function url_key(url)
	return tostring(fs.clean_url(url))
end

local function is_git_search(url)
	return url.spec.is_search and url.spec.domain:match("^" .. SEARCH_DOMAIN_PATTERN .. "$") ~= nil
end

local function view_for_tab(state, tab)
	local view = state.views[tostring(tab.id.value)]
	if view and Url(view.cwd) == tab.current.cwd then return view end
end

local notify

local ModeNotice = { _id = NAME .. "-notice" }

function ModeNotice:new(area)
	return setmetatable({ _area = area }, { __index = self })
end

function ModeNotice:reflow() return {} end

function ModeNotice:redraw()
	local elements, layouts, slot_height = {}, {}, 4
	for _, notice in ipairs(self._state.mode_notices) do
		local level = notice.level or "info"
		local title = (th.notify["icon_" .. level] or th.notify.icon_info) .. " " .. NAME
		local width = math.min(self._area.w, math.max(ui.width(notice.content), ui.width(title)) + 2)
		if width < 3 or self._area.h < 4 then return elements end
		local lines = ui.lines(notice.content, { width = width - 2, wrap = ui.Wrap.YES, tab_size = rt.preview.tab_size })
		local height = math.min(self._area.h - 1, math.max(3, #lines + 2))
		layouts[#layouts + 1] = { notice = notice, title = title, level = level, width = width, height = height, lines = lines }
		slot_height = math.max(slot_height, height + 1)
	end
	for _, layout in ipairs(layouts) do
		local notice = layout.notice
		local y = self._area.bottom - 1 - layout.height - math.floor(notice.offset / 4 * slot_height + 0.5)
		if y < self._area.y then break end
		local visible = math.floor(layout.width * notice.percent / 100)
		if visible > 0 then
			local area = ui.Rect { x = self._area.right - visible, y = y, w = visible, h = layout.height }
			elements[#elements + 1] = ui.Clear(area)
			elements[#elements + 1] = ui.Border(ui.Edge.ALL):area(area)
				:style(th.notify["title_" .. layout.level] or th.notify.title_info):title(layout.title)
			if visible > 2 then
				elements[#elements + 1] = ui.Text(layout.lines):area(area:pad(ui.Pad.xy(1, 1)))
			end
		end
	end
	return elements
end

local function new_notice(message, now, offset)
	return { content = message.content, level = message.level, percent = 0, created = now, expires = now + 5, offset = offset }
end

local function push_notice(state, content, level)
	if not state.notify then return end
	level = level or "info"
	if not state.mode_notices or not state.notice_sender then
		return ya.notify { title = NAME, content = content, level = level, timeout = 5 }
	end
	local message = { content = content, level = level }
	local notices = state.mode_notices
	local idle = #notices == 0
	local now = ya.time()
	if #notices == 2 then
		if not state.pending_notice then
			local oldest = notices[1]
			oldest.expires = now - NOTICE_ANIMATION * (1 - oldest.percent / 100)
		end
		state.pending_notice = message
	elseif #notices == 1 and notices[1].offset > 0 then
		state.pending_notice = message
	else
		notices[#notices + 1] = new_notice(message, now, #notices * 4)
	end
	if idle then
		state.notice_sender:send(true)
	end
	ui.render()
end

local animate_notices = ya.sync(function(state)
	local now, changed = ya.time(), false
	for i = #state.mode_notices, 1, -1 do
		local notice = state.mode_notices[i]
		if now >= notice.expires + NOTICE_ANIMATION then
			table.remove(state.mode_notices, i)
			changed = true
		else
			local percent = math.floor(100 * math.min(1,
				(now - notice.created) / NOTICE_ANIMATION,
				(notice.expires + NOTICE_ANIMATION - now) / NOTICE_ANIMATION))
			if percent ~= notice.percent then
				notice.percent, changed = percent, true
			end
		end
	end
	local notices = state.mode_notices
	if #notices == 1 and notices[1].offset > 0 and not notices[1].moved then
		notices[1].from_offset, notices[1].moved = notices[1].offset, now
	end
	for _, notice in ipairs(notices) do
		if notice.moved and notice.offset > 0 then
			notice.offset = notice.from_offset * math.max(0, 1 - (now - notice.moved) / NOTICE_ANIMATION)
			changed = true
		end
	end
	-- Wait for the remaining notice to settle before filling the upper slot.
	local slot_ready = #notices == 0 or (#notices == 1 and notices[1].offset == 0)
	if state.pending_notice and slot_ready then
		notices[#notices + 1] = new_notice(state.pending_notice, now, #notices * 4)
		state.pending_notice, changed = nil, true
	end
	if changed then
		ui.render()
	end
end)

local function restore(view)
	ya.emit("cd", { Url(view.origin) })
	ya.emit("hidden", { view.hidden and "show" or "hide" })
end

-- adoption is "pending", "loading", or "failed"; ready views leave it unset.
-- Success replaces the view; canceled loads return to pending, errors require an explicit retry.
local function reconcile_view(state, tab, schedule)
	local cwd = tab.current.cwd
	local key, location = tostring(tab.id.value), tostring(cwd)
	local view = state.views[key]
	local restored_hidden
	if view and Url(view.cwd) ~= cwd then
		-- publish() registers the target before its queued cd action runs.
		if view.from_cwd and Url(view.from_cwd) == cwd then
			return
		end
		if tab.id.value ~= cx.active.id.value then
			return
		end
		restored_hidden = view.hidden
		state.views[key] = nil
		ya.emit("hidden", { view.hidden and "show" or "hide" })
		view = nil
	end
	if view then
		view.from_cwd = nil
	end
	if not is_git_search(cwd) then
		return nil, restored_hidden
	end
	if not view then
		-- tab_create --current may restore only the hovered result, so rebuild the list.
		local donor
		for _, candidate in pairs(state.views) do
			if Url(candidate.cwd) == cwd then
				donor = candidate
				break
			end
		end
		local origin = donor and donor.origin or tostring(Url(cwd.path))
		local hidden = tab.pref.show_hidden
		if restored_hidden ~= nil then
			hidden = restored_hidden
		end
		if donor then
			hidden = donor.hidden
		end
		view = {
			cwd = location, root = donor and donor.root, origin = origin,
			hidden = hidden, entries = donor and donor.entries or {}, adoption = "pending",
			preview_mode = donor and donor.preview_mode or "diff",
			filter = donor and donor.filter or "all",
			snapshot = donor and donor.snapshot,
		}
		state.views[key] = view
	end
	if schedule and view.adoption == "pending" and tab.id.value == cx.active.id.value then
		view.adoption = "loading"
		ya.emit("plugin", { NAME, "adopt --tab=" .. key })
	end
	return view, restored_hidden
end

function M:setup(opts)
	opts = opts or {}
	self.show_status = opts.show_status ~= false
	self.show_branch = opts.show_branch ~= false
	assert(opts.wrap == nil or WRAP_MODES[opts.wrap], 'wrap must be "words", "trim", or "none"')
	self.wrap = WRAP_MODES[opts.wrap]
	self.notify = opts.notify == true
	self.show_filename = opts.show_filename == true
	if self.initialized then
		return
	end
	self.initialized = true
	self.views, self.requests, self.pending = {}, {}, {}
	self.mode_notices = {}
	Modal:children_add(setmetatable({ _state = self }, { __index = ModeNotice }), 1000)
	local sender, receiver = ya.chan("mpsc")
	self.notice_sender = sender
	ya.async(function()
		while receiver:recv() do
			while #self.mode_notices > 0 do
				ya.sleep(0.05)
				animate_notices()
			end
		end
	end)
	local function reconcile_active()
		reconcile_view(self, cx.active, true)
	end
	ps.sub("tab", reconcile_active)
	ps.sub("cd", reconcile_active)
	local original = Header.flags
	Header.flags = function(header)
		local flags = original(header)
		local cwd = header._current.cwd
		if is_git_search(cwd) then
			return (flags:gsub("search: " .. SEARCH_DOMAIN_PATTERN, "search: " .. NAME, 1))
		end
		return flags
	end
	Linemode:children_add(function(line)
		if not self.show_status or not line._file.in_current then return "" end
		local view = view_for_tab(self, cx.active)
		local item = view and view.entries[url_key(line._file.url)]
		return item and ui.Line { " [", status_label(item.status), "]" } or ""
	end, 1600)
	Header:children_add(function(header)
		local view = view_for_tab(self, header._tab)
		local snapshot = view and view.snapshot
		if not self.show_branch or not snapshot then
			return ""
		end
		local counts = snapshot.counts
		local text = string.format(" [%s] %s | modified:%d staged:%d new:%d conflicts:%d ",
			view.filter, branch_text(snapshot.branch), counts.modified, counts.staged, counts.untracked, counts.conflict)
		return ui.Line(ui.truncate(text, { max = math.max(1, header._area.w - 1) }))
	end, 500, Header.RIGHT)
end

local begin = ya.sync(function(state, action, target)
	local tab = cx.active
	local key, cwd = tostring(tab.id.value), tostring(tab.current.cwd)
	if action == "adopt" and target and key ~= tostring(target) then
		local waiting = state.views[tostring(target)]
		if waiting and waiting.adoption == "loading" then
			waiting.adoption = "pending"
		end
		return
	end
	local hidden = tab.pref.show_hidden
	local view, restored_hidden = reconcile_view(state, tab, false)
	if restored_hidden ~= nil then
		hidden = restored_hidden
	end
	-- A published view may still be waiting for its queued cd action.
	if not view then
		local opening = state.views[key]
		if opening and opening.from_cwd and Url(opening.from_cwd) == tab.current.cwd then view = opening end
	end
	local pending = state.pending[key]
	if pending and pending.cwd ~= cwd then
		state.pending[key], pending = nil, nil
	end
	if action == "adopt" and (not view or not view.adoption) then
		return
	end
	if action == "refresh" and not view then
		return
	end
	if FILTERS[action] and view and not view.adoption and view.filter == action then
		return
	end
	state.requests[key] = (state.requests[key] or 0) + 1
	if action == "toggle" and (view or pending) then
		state.views[key], state.pending[key] = nil, nil
		restore(view or pending)
		return
	end
	if view then
		hidden = view.hidden
	end
	local hovered
	if view and tab.current.hovered then
		local relative = tab.current.hovered.url:strip_prefix(tab.current.cwd)
		hovered = relative and tostring(relative)
	end
	local request = {
		key = key, ticket = state.requests[key], cwd = cwd,
		origin = view and view.origin or tostring(tab.current.cwd),
		hidden = hidden,
		root = view and view.root,
		hovered = hovered,
		preview_mode = view and view.preview_mode or "diff",
		filter = FILTERS[action] and action or view and view.filter or "all",
		show_branch = state.show_branch ~= false,
		snapshot = action ~= "refresh" and view and view.snapshot or nil,
	}
	state.pending[key] = { ticket = request.ticket, cwd = cwd, origin = request.origin, hidden = hidden }
	return request
end)

local function finish_request(state, request)
	local pending = state.pending[request.key]
	if pending and pending.ticket == request.ticket then state.pending[request.key] = nil end
	local tab = cx.active
	return state.requests[request.key] == request.ticket
		and tostring(tab.id.value) == request.key and tab.current.cwd == Url(request.cwd)
end

local fail_request = ya.sync(finish_request)

local publish = ya.sync(function(state, request, view, files, mimes)
	-- A slow git command must not take over a different tab or folder.
	local tab = cx.active
	if not finish_request(state, request) then return false end
	local previous = state.views[request.key]
	if previous and Url(previous.cwd) == tab.current.cwd then
		view.preview_mode = previous.preview_mode
	end
	view.from_cwd = request.cwd
	state.views[request.key] = view
	local cwd, id = Url(view.cwd), ya.id("ft")
	ya.emit("cd", { Url(cwd) })
	ya.emit("update_files", { op = fs.op("part", { id = id, url = Url(cwd), files = {} }) })
	ya.emit("update_files", { op = fs.op("part", { id = id, url = Url(cwd), files = files }) })
	ya.emit("update_files", {
		op = fs.op("done", { id = id, file = File { url = cwd, cha = Cha { mode = tonumber("40755", 8) } } }),
	})
	-- Missing files cannot be MIME-detected, and Yazi waits for MIME before peek.
	ya.emit("update_mimes", { updates = mimes })
	ya.emit("hidden", { "show" })
	if request.hovered then
		ya.emit("reveal", { Url(view.cwd):join(request.hovered) })
	end
	ya.emit("peek", { force = true })
	return true
end)

local finish_adoption = ya.sync(function(state, request, error)
	local view = state.views[request.key]
	if view and view.adoption and state.requests[request.key] == request.ticket then
		view.adoption, view.error = error and "failed" or "pending", error
		-- The tab may become active again between publish() rejecting and this callback.
		if not error and tostring(cx.active.id.value) == request.key then
			reconcile_view(state, cx.active, true)
		end
	end
end)

local toggle_preview = ya.sync(function(state)
	local view = reconcile_view(state, cx.active, true)
	if not view then
		return push_notice(state, "Open the git changes view first", "info")
	end
	view.preview_mode = view.preview_mode == "source" and "diff" or "source"
	ya.emit("peek", { 0, force = true })
	push_notice(state, view.preview_mode == "source" and "Preview: file content" or "Preview: git diff")
end)

local function git_output(cwd, args)
	local output, err = Command("git"):cwd(cwd):arg(args):env("GIT_OPTIONAL_LOCKS", "0"):output()
	if not output then
		return nil, "Could not run git: " .. tostring(err)
	elseif not output.status.success then
		return nil, output.stderr ~= "" and output.stderr or "git exited unsuccessfully"
	end
	return output.stdout
end

-- Porcelain v2 -z keeps paths verbatim; renames have a second NUL-delimited path.
local function parse_snapshot(raw)
	local records, meta, pos = {}, {}, 1
	local counts = { staged = 0, modified = 0, untracked = 0, conflict = 0 }
	while pos <= #raw do
		local stop = raw:find("\0", pos, true)
		if not stop then
			return nil, "Incomplete git status record"
		end
		local record = raw:sub(pos, stop - 1)
		pos = stop + 1
		local kind, item = record:sub(1, 1)
		if record:sub(1, 2) == "# " then
			local name, value = record:match("^# branch%.([%w]+) (.*)$")
			if name == "head" or name == "oid" or name == "upstream" then
				meta[name] = value
			elseif name == "ab" then
				local ahead, behind = value:match("^%+(%d+) %-(%d+)$")
				meta.ahead, meta.behind = tonumber(ahead), tonumber(behind)
			end
		elseif record:sub(1, 2) == "? " and #record > 2 then
			item = { status = "??", path = record:sub(3) }
		else
			local fields, path_start = STATUS_FIELDS[kind], 1
			if not fields or record:sub(2, 2) ~= " " or record:sub(5, 5) ~= " " then
				return nil, "Invalid git status record"
			end
			for _ = 1, fields do
				local separator = record:find(" ", path_start, true)
				if not separator then return nil, "Incomplete git status fields" end
				path_start = separator + 1
			end
			if path_start > #record then return nil, "Missing git status path" end
			item = { status = record:sub(3, 4):gsub("%.", " "), path = record:sub(path_start) }
			if kind == "2" then
				stop = raw:find("\0", pos, true)
				if not stop then return nil, "Incomplete git rename record" end
				item.old_path, pos = raw:sub(pos, stop - 1), stop + 1
			end
		end
		if item then
			records[#records + 1] = item
			local staged, modified, untracked, conflict = status_flags(item.status)
			if staged then counts.staged = counts.staged + 1 end
			if modified or untracked or conflict then counts.modified = counts.modified + 1 end
			if untracked then counts.untracked = counts.untracked + 1 end
			if conflict then counts.conflict = counts.conflict + 1 end
		end
	end
	return { records = records, branch = meta, counts = counts }
end

local function read_snapshot(root, show_branch)
	local args = { "status", "--porcelain=v2", "-z", "--untracked-files=all" }
	if show_branch then
		args[#args + 1], args[#args + 2] = "--branch", "--ahead-behind"
	end
	local raw, err = git_output(root, args)
	if not raw then return nil, err end
	local snapshot, parse_error = parse_snapshot(raw)
	if not snapshot then return nil, parse_error end
	local meta = snapshot.branch
	-- A missing upstream ref has no branch.ab. Query only local refs; never fetch.
	if show_branch and meta.head and meta.head ~= "(detached)" and meta.oid ~= "(initial)" and meta.ahead == nil then
		local tracking = git_output(root, {
			"for-each-ref", "--format=%(upstream:short)%00%(upstream:track)%00", "refs/heads/" .. meta.head,
		})
		if tracking then
			local upstream, track = tracking:match("^([^\0]*)\0([^\0]*)\0")
			if upstream and upstream ~= "" then meta.upstream = upstream end
			meta.gone = track == "[gone]"
		end
	end
	return snapshot
end

function M:entry(job)
	local action = job.args[1] or "toggle"
	if action == "preview" then
		return toggle_preview()
	end
	if action ~= "toggle" and action ~= "refresh" and action ~= "adopt" and not FILTERS[action] then
		return notify("Use: plugin " .. NAME .. " [toggle|refresh|preview|all|staged|unstaged]")
	end
	local request = begin(action, job.args.tab)
	if not request then
		return
	end
	local function fail(error)
		local current = fail_request(request)
		if action == "adopt" then
			finish_adoption(request, error)
		end
		if current then return notify(error) end
	end
	local root, err = request.root
	if not root then
		root, err = git_output(tostring(Url(request.origin).path), { "rev-parse", "--show-toplevel" })
		if not root then
			return fail(err)
		end
		root = root:gsub("\r?\n$", "")
	end
	local snapshot = request.snapshot
	if not snapshot then
		snapshot, err = read_snapshot(root, request.show_branch)
	end
	if not snapshot then
		return fail(err)
	end
	local cwd = Url(root):into_search(NAME .. " " .. request.key)
	local view = {
		root = root, cwd = tostring(cwd), origin = request.origin,
		hidden = request.hidden, ticket = request.ticket, entries = {},
		preview_mode = request.preview_mode, filter = request.filter,
		snapshot = snapshot,
	}
	local files, mimes = {}, {}
	for _, item in ipairs(snapshot.records) do
		local url = cwd:join(item.path)
		if include_status(item.status, view.filter) then
			view.entries[url_key(url)] = item
			local file = fs.file(url)
			if not file then
				mimes[tostring(url)] = "text/plain"
				file = File { url = url, cha = Cha { mode = tonumber("100644", 8), kind = DUMMY_KIND } }
			end
			files[#files + 1] = file
		end
	end
	if request.hovered and not view.entries[url_key(cwd:join(request.hovered))] then
		request.hovered = nil
	end
	local published = publish(request, view, files, mimes)
	if not published and action == "adopt" then
		finish_adoption(request)
	elseif published and #files == 0 then
		notify(view.filter == "all" and "Working tree is clean" or "No " .. view.filter .. " changes", "info")
	end
end

local function active_item(state, file)
	local view = view_for_tab(state, cx.active)
	local item = view and is_git_search(cx.active.current.cwd) and view.entries[url_key(file.url)]
	return item, item and view
end

local function original_previewer(file, mime)
	for _, rule in pairs(rt.plugin.previewers:match { file = file, mime = mime }) do
		if rule.name ~= NAME then
			return rule
		end
	end
end

local preview_context = ya.sync(function(state, file, mime)
	local entry, view = active_item(state, file)
	if entry then
		if view.preview_mode == "diff" then
			local item = {
				root = view.root, path = entry.path, old_path = entry.old_path, status = entry.status,
				ticket = view.ticket, filter = view.filter, wrap = state.wrap or rt.preview.wrap,
				show_filename = state.show_filename,
			}
			local cache = view.cache
			if cache and cache.url == url_key(file.url) and cache.mtime == file.cha.mtime and cache.len == file.cha.len then
				return item, nil, cache.lines
			end
			return item
		elseif file.cha.is_dummy and entry.status:find("D", 1, true) then
			return nil, nil, nil, "File deleted. Switch to git diff to view its changes"
		end
	end
	local rule = original_previewer(file, mime)
	if rule then
		return nil, { name = rule.name, args = rule.args }
	end
end)

local cache_preview = ya.sync(function(state, url, ticket, mtime, len, lines)
	local view = view_for_tab(state, cx.active)
	if view and view.ticket == ticket and view.entries[url_key(url)] then
		-- Refresh invalidates the cache by replacing the view.
		view.cache = { url = url_key(url), mtime = mtime, len = len, lines = lines }
	end
end)

notify = ya.sync(function(state, content, level)
	return push_notice(state, content, level or "error")
end)

function M:seek(job)
	local item, view = active_item(self, job.file)
	if item and view.preview_mode == "diff" then
		return require("code"):seek(job)
	end
	local rule = original_previewer(job.file, job.mime)
	if rule then
		job.args = rule.args
		ya.emit("plugin", { rule.name, job, method = "seek", scope = rt.scope() })
	end
end

local function diff_args(item, cached)
	local args = {
		"--no-pager", "--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv",
		"--color=always", "--no-relative", "--submodule=short",
	}
	if item.status == "??" then
		args[#args + 1] = "--no-index"
	elseif cached then
		args[#args + 1] = "--cached"
	end
	args[#args + 1] = "--"
	if item.status == "??" then
		args[#args + 1] = "/dev/null"
	elseif item.old_path then
		args[#args + 1] = item.old_path
	end
	args[#args + 1] = item.path
	return args
end

local DiffFilter = {}
DiffFilter.__index = DiffFilter

function DiffFilter:new(lines, title, status)
	return setmetatable({ lines = lines, title = title, untracked = status == "??" }, self)
end

function DiffFilter:emit(line)
	local lines = self.lines
	if not self.started then
		self.started = true
		if #lines > 0 then
			lines[#lines + 1] = ""
		end
		lines[#lines + 1] = "\27[1;33m" .. self.title .. "\27[0m"
		if self.summary then
			lines[#lines + 1] = self.summary
		end
		if line then
			lines[#lines + 1] = ""
		end
	end
	if line then
		lines[#lines + 1] = line
	end
end

function DiffFilter:accept(line)
	local plain = line:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
	if plain:match("^diff %-%-") then
		self.in_hunk = false
	elseif plain:sub(1, 2) == "@@" then
		self.in_hunk = true
	elseif self.in_hunk then
		-- Start compact previews at meaningful content, trimming only leading blank
		-- context. Blank additions and deletions still carry '+' or '-' and are kept.
		if self.started or not plain:match("^ %s*$") then
			self:emit(line)
		end
	elseif plain:match("^Binary files ") then
		self:emit("Binary file changed")
	elseif plain:match("^deleted file mode ") then
		self.summary = "Deleted file"
	elseif plain:match("^new file mode ") then
		if not self.untracked then
			self.summary = "New file"
		end
	elseif plain:match("^rename from ") then
		self.summary = "Renamed file"
	elseif plain:match("^copy from ") then
		self.summary = "Copied file"
	elseif plain:match("^old mode ") or plain:match("^new mode ") then
		self.summary = "File permissions changed"
	end
end

function DiffFilter:finish()
	if not self.started and self.summary then
		self:emit()
	end
end

local function collect_diff_section(item, title, cached, lines, max_bytes)
	local child, err = Command("git"):cwd(item.root):arg(diff_args(item, cached))
		:env("GIT_OPTIONAL_LOCKS", "0"):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		lines[#lines + 1] = "git error: " .. tostring(err)
		return 0, false
	end
	local filter = DiffFilter:new(lines, title, item.status)
	local pending, stderr, bytes = "", "", 0
	while true do
		local chunk, event = child:read(8192)
		if event == 2 then
			break
		end
		chunk = string.char(table.unpack(chunk))
		if event == 1 then
			stderr = (stderr .. chunk):sub(1, 4096)
		elseif event == 0 then
			bytes = bytes + #chunk
			pending = pending .. chunk
			local stop = pending:find("\n", 1, true)
			while stop do
				local line = pending:sub(1, stop - 1):gsub("\r$", "")
				pending = pending:sub(stop + 1)
				filter:accept(line)
				stop = pending:find("\n", 1, true)
			end
			if bytes >= max_bytes then
				child:start_kill()
				lines[#lines + 1] = "Preview truncated at 2 MiB"
				return bytes, true
			end
		end
	end
	local status, wait_err = child:wait()
	if pending ~= "" then
		filter:accept(pending)
	end
	filter:finish()
	if not status or (not status.success and not (item.status == "??" and status.code == 1)) then
		lines[#lines + 1] = "git error: " .. (stderr ~= "" and stderr or tostring(wait_err or "command failed"))
	end
	return bytes, false
end

local function collect_diff(item)
	local lines = {}
	local max_bytes = 2 * 1024 * 1024
	if item.status == "??" then
		collect_diff_section(item, "Untracked", false, lines, max_bytes)
	else
		local bytes, truncated = 0, false
		if item.filter ~= "unstaged" then
			bytes, truncated = collect_diff_section(item, "Staged", true, lines, max_bytes)
		end
		if not truncated and item.filter ~= "staged" then
			collect_diff_section(item, "Unstaged", false, lines, max_bytes - bytes)
		end
	end
	if #lines == 0 then
		lines[1] = "No diff content. Refresh the git changes list"
	end
	return lines
end

local function diff_peek(job, item, cached)
	local source = cached or collect_diff(item)
	if not cached then
		cache_preview(Url(job.file.url), item.ticket, job.file.cha.mtime, job.file.cha.len, source)
	end
	local lines, count = {}, 0
	local limit = job.skip + job.area.h
	local opts = { ansi = true, tab_size = rt.preview.tab_size, wrap = item.wrap, width = job.area.w }
	local function render(line)
		local rendered = line == "" and { ui.Line("") } or ui.lines(line, opts)
		for _, wrapped in ipairs(rendered) do
			count = count + 1
			if count > job.skip and count <= limit then
				lines[#lines + 1] = wrapped
			end
		end
	end
	if item.show_filename then
		opts.ansi = false
		render(item.path)
		render("")
		opts.ansi = true
	end
	for _, line in ipairs(source) do
		render(line)
		if count >= limit then
			break
		end
	end
	if job.skip > 0 and count < limit then
		return ya.emit("peek", { math.max(0, count - job.area.h), only_if = job.file.url, upper_bound = true })
	end
	ya.preview_widget(job, { ui.Clear(job.area), ui.Text(lines):area(job.area) })
end

function M:peek(job)
	-- Transfer a matching copy; keep the preview job's original File alive.
	local item, rule, cached, message = preview_context(File { url = Url(job.file.url), cha = job.file.cha }, job.mime)
	if message then
		return require("empty").msg(job, message)
	elseif item then
		return diff_peek(job, item, cached)
	elseif not rule then
		return
	end
	-- Remove the diff's persistent Clear before the next preview draws an image.
	ya.preview_widget(job, {})
	job.args = rule.args
	local chunk, err = ya.chunk(rule.name)
	if not chunk then
		ya.err(err)
	elseif chunk.sync_peek then
		ya.emit("plugin", { rule.name, job, method = "peek", scope = rt.scope() })
	else
		require(rule.name):peek(job)
	end
end

return M
