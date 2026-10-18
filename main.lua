--- @since 26.8.15

local M = {}
local NAME = "whatchanged"
local SEARCH_DOMAIN_PATTERN = NAME:gsub("(%W)", "%%%1") .. " %d+"
local DUMMY_KIND = 8
local WRAP_MODES = { words = ui.Wrap.YES, trim = ui.Wrap.TRIM, none = ui.Wrap.NO }
local NOTICE_ANIMATION = 0.25
local PREVIEW_LIMIT = 2 * 1024 * 1024

local function url_key(url)
	return tostring(fs.clean_url(url))
end

local function is_git_search(url)
	return url.spec.is_search and url.spec.domain:match("^" .. SEARCH_DOMAIN_PATTERN .. "$") ~= nil
end

local function notify(content, level)
	ya.notify { title = NAME, content = content, level = level or "error", timeout = 5 }
end

local ModeNotice = { _id = NAME .. "-notice" }

function ModeNotice:new(area)
	return setmetatable({ _area = area }, { __index = self })
end

function ModeNotice:reflow() return {} end

function ModeNotice:redraw()
	local elements = {}
	for _, notice in ipairs(self._state.mode_notices) do
		local content = notice.content
		local title = th.notify.icon_info .. " " .. NAME
		local width = math.min(self._area.w, math.max(ui.width(content), ui.width(title)) + 2)
		local y = self._area.bottom - 4 - math.floor(notice.offset + 0.5)
		if width < 3 or y < self._area.y then
			break
		end
		local visible = math.floor(width * notice.percent / 100)
		if visible > 0 then
			local area = ui.Rect { x = self._area.right - visible, y = y, w = visible, h = 3 }
			elements[#elements + 1] = ui.Clear(area)
			elements[#elements + 1] = ui.Border(ui.Edge.ALL):area(area):style(th.notify.title_info):title(title)
			if visible > 2 then
				elements[#elements + 1] = ui.Text(content):area(area:pad(ui.Pad.xy(1, 1)))
			end
		end
	end
	return elements
end

local function new_notice(content, now, offset)
	return { content = content, percent = 0, created = now, expires = now + 5, offset = offset }
end

local function notify_mode(state, content)
	local notices = state.mode_notices
	local idle = #notices == 0
	local now = ya.time()
	if #notices == 2 then
		if not state.pending_notice then
			local oldest = notices[1]
			oldest.expires = now - NOTICE_ANIMATION * (1 - oldest.percent / 100)
		end
		state.pending_notice = content
	else
		notices[#notices + 1] = new_notice(content, now, #notices * 4)
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
	if state.pending_notice and #notices < 2 then
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
		}
		state.views[key] = view
	end
	if schedule and view.adoption == "pending" and tab.id.value == cx.active.id.value then
		view.adoption = "loading"
		ya.emit("plugin", { NAME, "adopt --tab=" .. key })
	end
	return view, restored_hidden
end

local function update_layout(state)
	local target
	if state.git_ratio and is_git_search(cx.active.current.cwd) then
		if not state.normal_ratio then
			local ratio = rt.mgr.ratio
			state.normal_ratio = { ratio[1], ratio[2], ratio[3] }
		end
		target = state.git_ratio
	elseif state.normal_ratio then
		target, state.normal_ratio = state.normal_ratio, nil
	else
		return
	end
	local ratio = rt.mgr.ratio
	if ratio[1] ~= target[1] or ratio[2] ~= target[2] or ratio[3] ~= target[3] then
		rt.mgr.ratio = { target[1], target[2], target[3] }
		-- Reflow all panes and re-peek at the new preview width.
		ya.emit("app:resize", {})
	end
end

function M:setup(opts)
	if opts then
		assert(opts.wrap == nil or WRAP_MODES[opts.wrap], 'wrap must be "words", "trim", or "none"')
		assert(opts.diff_style == nil or opts.diff_style == "unified" or opts.diff_style == "side-by-side",
			'diff_style must be "unified" or "side-by-side"')
		assert(opts.delta == nil or type(opts.delta) == "string" and opts.delta ~= "", "delta must be an executable name or path")
		if opts.git_ratio then
			local sum = 0
			assert(type(opts.git_ratio) == "table" and #opts.git_ratio == 3, "git_ratio must contain three integers")
			for i = 1, 3 do
				local value = opts.git_ratio[i]
				assert(type(value) == "number" and value >= 0 and value <= 65535 and value % 1 == 0,
					"git_ratio values must be integers between 0 and 65535")
				sum = sum + value
			end
			assert(sum > 0 and sum <= 65535, "git_ratio total must be between 1 and 65535")
		end
		self.wrap = WRAP_MODES[opts.wrap]
		self.notify = opts.notify == true
		self.show_filename = opts.show_filename == true
		self.diff_style = opts.diff_style or "unified"
		self.delta = opts.delta or "delta"
		self.git_ratio = opts.git_ratio
	end
	if self.initialized then
		return
	end
	self.initialized = true
	self.views, self.requests = {}, {}
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
		update_layout(self)
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
	state.requests[key] = (state.requests[key] or 0) + 1
	local hidden = tab.pref.show_hidden
	local view, restored_hidden = reconcile_view(state, tab, false)
	if restored_hidden ~= nil then
		hidden = restored_hidden
	end
	if action == "adopt" and (not view or not view.adoption) then
		return
	end
	if view and action == "toggle" then
		state.views[key] = nil
		restore(view)
		return
	end
	if action == "refresh" and not view then
		return
	end
	if view then
		hidden = view.hidden
	end
	local hovered
	if action == "adopt" and tab.current.hovered then
		local relative = tab.current.hovered.url:strip_prefix(tab.current.cwd)
		hovered = relative and tostring(relative)
	end
	return {
		key = key, ticket = state.requests[key], cwd = cwd,
		origin = view and view.origin or tostring(tab.current.cwd),
		hidden = hidden,
		root = view and view.root,
		hovered = hovered,
		preview_mode = view and view.preview_mode or "diff",
	}
end)

local publish = ya.sync(function(state, request, view, files, mimes)
	-- A slow git command must not take over a different tab or folder.
	local tab = cx.active
	if tostring(tab.id.value) ~= request.key or tab.current.cwd ~= Url(request.cwd)
		or state.requests[request.key] ~= request.ticket then
		return false
	end
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
		return notify("Open the git changes view first", "info")
	end
	view.preview_mode = view.preview_mode == "source" and "diff" or "source"
	ya.emit("peek", { 0, force = true })
	if state.notify then
		notify_mode(state, view.preview_mode == "source" and "Preview: file content" or "Preview: git diff")
	end
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

-- -z does not quote paths and reverses rename order: destination NUL source NUL.
local function parse_status(raw)
	local records, pos = {}, 1
	while pos <= #raw do
		local stop = raw:find("\0", pos, true)
		if not stop then
			return nil, "Incomplete git status record"
		end
		local record = raw:sub(pos, stop - 1)
		pos = stop + 1
		if #record < 4 or record:sub(3, 3) ~= " " then
			return nil, "Invalid git status record"
		end
		local item = { status = record:sub(1, 2), path = record:sub(4) }
		if item.status:find("[RC]") then
			stop = raw:find("\0", pos, true)
			if not stop then
				return nil, "Incomplete git rename record"
			end
			item.old_path, pos = raw:sub(pos, stop - 1), stop + 1
		end
		records[#records + 1] = item
	end
	return records
end

function M:entry(job)
	local action = job.args[1] or "toggle"
	if action == "preview" then
		return toggle_preview()
	end
	if action ~= "toggle" and action ~= "refresh" and action ~= "adopt" then
		return notify("Use: plugin " .. NAME .. " [toggle|refresh|preview]")
	end
	local request = begin(action, job.args.tab)
	if not request then
		return
	end
	local function fail(error)
		if action == "adopt" then
			finish_adoption(request, error)
		end
		return notify(error)
	end
	local root, err = request.root
	if not root then
		root, err = git_output(tostring(Url(request.origin).path), { "rev-parse", "--show-toplevel" })
		if not root then
			return fail(err)
		end
		root = root:gsub("\r?\n$", "")
	end
	local raw
	raw, err = git_output(root, { "status", "--porcelain=v1", "-z", "--untracked-files=all" })
	if not raw then
		return fail(err)
	end
	local records
	records, err = parse_status(raw)
	if not records then
		return fail(err)
	end
	local cwd = Url(root):into_search(NAME .. " " .. request.key)
	local view = {
		root = root, cwd = tostring(cwd), origin = request.origin,
		hidden = request.hidden, ticket = request.ticket, entries = {},
		preview_mode = request.preview_mode,
	}
	local files, mimes = {}, {}
	for _, item in ipairs(records) do
		local url = cwd:join(item.path)
		view.entries[url_key(url)] = item
		local file = fs.file(url)
		if not file then
			mimes[tostring(url)] = "text/plain"
			file = File { url = url, cha = Cha { mode = tonumber("100644", 8), kind = DUMMY_KIND } }
		end
		files[#files + 1] = file
	end
	local published = publish(request, view, files, mimes)
	if not published and action == "adopt" then
		finish_adoption(request)
	elseif published and #files == 0 then
		notify("Working tree is clean", "info")
	end
end

local function active_item(state, job)
	local tab = cx.active
	local view = state.views[tostring(tab.id.value)]
	if view and Url(view.cwd) == tab.current.cwd and is_git_search(tab.current.cwd) then
		local item = view.entries[url_key(job.file.url)]
		if item then
			return {
				root = view.root, path = item.path, old_path = item.old_path, status = item.status, ticket = view.ticket,
			}, view
		end
	end
end

local function original_previewer(job)
	for _, rule in pairs(rt.plugin.previewers:match { file = job.file, mime = job.mime }) do
		if rule.name ~= NAME then
			return rule
		end
	end
end

local preview_context = ya.sync(function(state, file, mime, width)
	local job = { file = file, mime = mime }
	local item, view = active_item(state, job)
	if item then
		if view.preview_mode == "diff" then
			item.wrap = state.wrap or rt.preview.wrap
			item.show_filename = state.show_filename
			item.diff_style = state.diff_style or "unified"
			item.delta = state.delta or "delta"
			item.light = rt.term.light() == true
			item.width = width
			item.renderer = table.concat({ item.diff_style, item.delta, tostring(item.light) }, "\0")
			local cache = view.cache
			if cache and cache.url == url_key(file.url) and cache.ticket == view.ticket
				and cache.mtime == file.cha.mtime and cache.len == file.cha.len
				and cache.renderer == item.renderer
				and (item.diff_style ~= "side-by-side" or cache.width == width) then
				item.render_style = cache.render_style
				return item, nil, cache.lines
			end
			return item
		elseif file.cha.is_dummy and item.status:find("D", 1, true) then
			return nil, nil, nil, "File deleted. Switch to git diff to view its changes"
		end
	end
	local rule = original_previewer(job)
	if rule then
		return nil, { name = rule.name, args = rule.args }
	end
end)

local cache_preview = ya.sync(function(state, url, item, mtime, len, lines)
	local view = state.views[tostring(cx.active.id.value)]
	if view and view.ticket == item.ticket and Url(view.cwd) == cx.active.current.cwd and view.entries[url_key(url)] then
		-- Refresh invalidates the cache by replacing the view.
		view.cache = { url = url_key(url), ticket = item.ticket, mtime = mtime, len = len,
			renderer = item.renderer, width = item.width, render_style = item.render_style, lines = lines }
	end
end)

function M:seek(job)
	local item, view = active_item(self, job)
	if item and view.preview_mode == "diff" then
		return require("code"):seek(job)
	end
	local rule = original_previewer(job)
	if rule then
		job.args = rule.args
		ya.emit("plugin", { rule.name, job, method = "seek", scope = rt.scope() })
	end
end

local function diff_args(item, cached)
	local args = {
		"--no-pager", "--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv",
		item.diff_style == "side-by-side" and "--color=never" or "--color=always", "--no-relative", "--submodule=short",
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
				child:wait()
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

local function collect_delta_section(item, title, cached, lines, max_bytes)
	local git, err = Command("git"):cwd(item.root):arg(diff_args(item, cached))
		:env("GIT_OPTIONAL_LOCKS", "0"):stdout(Command.PIPED):stderr(Command.NULL):spawn()
	if not git then
		return 0, false, "Could not run git: " .. tostring(err)
	end
	local delta
	delta, err = Command(item.delta):cwd(item.root):arg {
		"--no-gitconfig", "--side-by-side", "--line-numbers", "--paging=never",
		"--width=" .. math.max(1, item.width), item.light and "--light" or "--dark",
	}:stdin(git:take_stdout()):stdout(Command.PIPED):stderr(Command.NULL):spawn()
	if not delta then
		git:start_kill()
		git:wait()
		return 0, false, "Delta unavailable; install delta or check the delta option. Showing unified diff"
	end
	local output, pending, bytes, truncated = {}, "", 0, false
	while true do
		local chunk, event = delta:read(8192)
		if event == 2 then
			break
		elseif event == 0 then
			chunk = string.char(table.unpack(chunk))
			bytes = bytes + #chunk
			pending = pending .. chunk
			local stop = pending:find("\n", 1, true)
			while stop do
				output[#output + 1] = pending:sub(1, stop - 1):gsub("\r$", "")
				pending = pending:sub(stop + 1)
				stop = pending:find("\n", 1, true)
			end
			if bytes >= max_bytes then
				truncated = true
				delta:start_kill()
				git:start_kill()
				break
			end
		end
	end
	local delta_status, git_status = delta:wait(), git:wait()
	if not truncated and (not delta_status or not delta_status.success or not git_status
		or not git_status.success and not (item.status == "??" and git_status.code == 1)) then
		return bytes, false, "Delta could not render this diff. Showing unified diff"
	end
	if pending ~= "" and not truncated then
		output[#output + 1] = pending
	end
	if #output > 0 or truncated then
		if #lines > 0 then
			lines[#lines + 1] = ""
		end
		lines[#lines + 1] = "\27[1;33m" .. title .. " (old | new)\27[0m"
		for _, line in ipairs(output) do
			lines[#lines + 1] = line
		end
	end
	if truncated then
		lines[#lines + 1] = "Preview truncated at 2 MiB"
	end
	return bytes, truncated
end

local function collect_diff(item, collector)
	local lines = {}
	local bytes, truncated, err
	collector = collector or collect_diff_section
	if item.status == "??" then
		bytes, truncated, err = collector(item, "Untracked", false, lines, PREVIEW_LIMIT)
	else
		bytes, truncated, err = collector(item, "Staged", true, lines, PREVIEW_LIMIT)
		if not truncated and not err then
			bytes, truncated, err = collector(item, "Unstaged", false, lines, PREVIEW_LIMIT - bytes)
		end
	end
	if err then
		return nil, err
	end
	if #lines == 0 then
		lines[1] = "No diff content. Refresh the git changes list"
	end
	return lines
end

local function diff_peek(job, item, cached)
	local source = cached
	if not cached then
		item.render_style = item.diff_style
		if item.diff_style == "side-by-side" then
			local err
			source, err = collect_diff(item, collect_delta_section)
			if not source then
				item.render_style = "unified"
				local unified = setmetatable({ diff_style = "unified" }, { __index = item })
				source = collect_diff(unified)
				table.insert(source, 1, "")
				table.insert(source, 1, err)
			end
		else
			source = collect_diff(item)
		end
		cache_preview(Url(job.file.url), item, job.file.cha.mtime, job.file.cha.len, source)
	end
	local lines, count = {}, 0
	local limit = job.skip + job.area.h
	local opts = { ansi = true, tab_size = rt.preview.tab_size,
		wrap = item.render_style == "side-by-side" and ui.Wrap.NO or item.wrap, width = job.area.w }
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
	local item, rule, cached, message = preview_context(File { url = Url(job.file.url), cha = job.file.cha }, job.mime, job.area.w)
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
