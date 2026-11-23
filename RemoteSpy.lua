--[[
	RemoteSpy -> Supabase receiver
	Target: https://sidneyy1.github.io/RemoteSpy-Receiver/
	Table : public.remote_events

	Rows posted:
	  * RemoteSpyInit   - one row at startup: version, source hash, trace
	  * FireServer      - outgoing RemoteEvent
	  * InvokeServer    - outgoing RemoteFunction
	  * OnClientEvent   - incoming RemoteEvent
	  * OnClientInvoke  - incoming RemoteFunction

	Executor must expose request / syn.request / http_request / http.request.
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")
local CoreGui           = game:GetService("CoreGui")

local player = Players.LocalPlayer

local CFG = {
	-- receiver config, copied from sidneyy1.github.io/RemoteSpy-Receiver/app.js
	supabaseUrl = "https://tbpxzmnukhoqthdozbwj.supabase.co",
	supabaseKey = "sb_publishable_RVfnZvDuGmyu22MmuPAn9A_JoaMh11a",
	table       = "remote_events",

	-- build identity, shows in the init row
	scriptName  = "RemoteSpy",
	buildTag    = "supabase-2.1",

	-- filters
	nameFilter    = {},                                  -- only log paths containing these; empty = all
	nameBlocklist = { "Ping", "Heartbeat", "Update", "Tick" },
	hookIncoming  = true,

	-- batching
	batchSize   = 40,
	flushEvery  = 3.0,
	maxQueue    = 2000,
	dedupeWindow = 0.25,

	-- serialization limits
	maxDepth     = 6,
	maxString    = 4000,
	maxKeys      = 200,
	traceChars   = 800,

	enabled = true,
	verbose = true,
}

--------------------------------------------------------------------------------
-- HTTP transport
--------------------------------------------------------------------------------

local function getRequest()
	local env = getfenv(0)
	local candidates = {
		env.request,
		env.http_request,
		env.syn and env.syn.request,
		env.http and env.http.request,
	}
	for _, fn in ipairs(candidates) do
		if type(fn) == "function" then return fn end
	end
	return nil
end

local requestFn = getRequest()
if not requestFn then
	warn("[RemoteSpy] no HTTP request function - events will queue in memory only")
end

local function statusOf(res)
	if type(res) ~= "table" then return nil end
	return res.StatusCode or res.Status or res.status
end

local function insertRows(rows)
	if not requestFn then return false, "no_request" end
	if #rows == 0 then return true, 201 end
	local ok, res = pcall(requestFn, {
		Url = CFG.supabaseUrl .. "/rest/v1/" .. CFG.table,
		Method = "POST",
		Headers = {
			["apikey"]        = CFG.supabaseKey,
			["Authorization"] = "Bearer " .. CFG.supabaseKey,
			["Content-Type"]  = "application/json",
			["Prefer"]        = "return=minimal",
		},
		Body = HttpService:JSONEncode(rows),
	})
	if not ok then return false, tostring(res) end
	local code = statusOf(res)
	if code and code >= 200 and code < 300 then
		return true, code
	end
	return false, ("HTTP %s: %s"):format(tostring(code), tostring(res.Body or res.body or ""):sub(1, 300))
end

--------------------------------------------------------------------------------
-- serialization
--------------------------------------------------------------------------------

local function shortStr(s)
	if #s > CFG.maxString then
		return s:sub(1, CFG.maxString) .. ("...[%d]"):format(#s)
	end
	return s
end

local function ser(v, depth)
	depth = depth or 0
	if depth > CFG.maxDepth then return "...[depth]" end
	local t = typeof(v)
	if t == "nil" then return nil end
	if t == "string" then return shortStr(v) end
	if t == "number" or t == "boolean" then return v end
	if t == "EnumItem" then return ("Enum.%s.%s"):format(v.EnumType, v.Name) end
	if t == "Instance" then
		local ok, path = pcall(function() return v:GetFullName() end)
		return { __instance = ok and path or "?", className = v.ClassName }
	end
	if t == "Vector3" or t == "Vector2" then return { __vec = tostring(v) } end
	if t == "CFrame" then return { __cframe = tostring(v) } end
	if t == "Color3" then return { __color = tostring(v) } end
	if t == "UDim2" or t == "UDim" then return { __udim = tostring(v) } end
	if t == "RBXScriptSignal" then return "[Signal]" end
	if t == "function" then return "[Function]" end
	if t == "thread" then return "[Thread]" end
	if t == "table" then
		local out, n = {}, 0
		for k, val in pairs(v) do
			n += 1
			if n > CFG.maxKeys then
				out["..."] = ("[%d+ keys]"):format(n)
				break
			end
			local key = (type(k) == "string" or type(k) == "number") and k or tostring(k)
			out[key] = ser(val, depth + 1)
		end
		return out
	end
	return ("[%s]"):format(t)
end

local function serArgs(args, n)
	local out = {}
	for i = 1, n or select("#", table.unpack(args)) do
		out[i] = ser(args[i])
	end
	return out
end

--------------------------------------------------------------------------------
-- path + filters + caller
--------------------------------------------------------------------------------

local function fullPath(obj)
	local ok, p = pcall(function() return obj:GetFullName() end)
	return ok and p or obj.Name
end

local function shouldLog(path)
	for _, bad in ipairs(CFG.nameBlocklist) do
		if path:find(bad, 1, true) then return false end
	end
	if #CFG.nameFilter == 0 then return true end
	for _, want in ipairs(CFG.nameFilter) do
		if path:find(want, 1, true) then return true end
	end
	return false
end

local callerTag
do
	local name = player and player.Name or "?"
	local executor = "unknown"
	for _, probe in ipairs({ "syn", "fluxus", "krnl", "wave", "scriptware" }) do
		if rawget(getfenv(0), probe) then executor = probe; break end
	end
	callerTag = ("%s@%s"):format(name, executor)
end

--------------------------------------------------------------------------------
-- queue + dedupe + flush
--------------------------------------------------------------------------------

local queue = {}
local dedupe = {}
local stats = { sent = 0, dropped = 0, lastError = "-", lastCode = "-" }

local function enqueue(method, direction, path, argsTable)
	if not CFG.enabled then return end
	if not shouldLog(path) then return end

	local sig = method .. "|" .. path .. "|" .. HttpService:JSONEncode(argsTable)
	local now = os.clock()
	if dedupe[sig] and (now - dedupe[sig]) < CFG.dedupeWindow then return end
	dedupe[sig] = now

	if #queue >= CFG.maxQueue then
		table.remove(queue, 1)
		stats.dropped += 1
	end
	queue[#queue + 1] = {
		method = method,
		direction = direction,
		remote_path = path,
		caller = callerTag,
		args = argsTable,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	if CFG.verbose then
		print(("[RemoteSpy] queued %s %s (%d)"):format(method, path, #queue))
	end
end

local function flush()
	if not requestFn then return false, "no_request" end
	if #queue == 0 then return true, 204 end
	local batch = {}
	for _ = 1, math.min(#queue, CFG.batchSize) do
		batch[#batch + 1] = table.remove(queue, 1)
	end
	local ok, code = insertRows(batch)
	if ok then
		stats.sent += #batch
		stats.lastCode = tostring(code)
		return true, code
	end
	stats.lastError = tostring(code)
	for i = #batch, 1, -1 do
		if #queue < CFG.maxQueue then table.insert(queue, 1, batch[i]) end
	end
	return false, code
end

task.spawn(function()
	while true do
		task.wait(CFG.flushEvery)
		pcall(flush)
		local now = os.clock()
		for k, t in pairs(dedupe) do
			if (now - t) > 60 then dedupe[k] = nil end
		end
	end
end)

--------------------------------------------------------------------------------
-- hooks
--------------------------------------------------------------------------------

local hooked = {}
local hookedOK = 0

-- Outgoing capture uses __namecall: assigning re.FireServer directly does
-- NOT work (Instance methods are not assignable), so that approach failed
-- silently inside safeHook's pcall and logged nothing outgoing.
local outgoingMode = "none"

local function wrap(fn)
	if type(newcclosure) == "function" then
		local ok, wrapped = pcall(newcclosure, fn)
		if ok then return wrapped end
	end
	return fn
end

local function tryNamecallHook()
	if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
		return false, "no hookmetamethod"
	end
	local ok, err = pcall(function()
		local oldNamecall
		oldNamecall = hookmetamethod(game, "__namecall", wrap(function(self, ...)
			local method = getnamecallmethod()
			if (method == "FireServer" or method == "InvokeServer")
				and typeof(self) == "Instance"
				and (self:IsA("RemoteEvent") or self:IsA("RemoteFunction")) then
				local pack = table.pack(...)
				if CFG.enabled then
					enqueue(method, "outgoing", fullPath(self), serArgs(pack, pack.n))
				end
			end
			return oldNamecall(self, ...)
		end))
	end)
	if ok then return true end
	return false, tostring(err)
end

local ncOK, ncErr = tryNamecallHook()
outgoingMode = ncOK and "namecall" or ("FAILED: " .. tostring(ncErr))

local function safeHook(re, fn)
	local ok, err = pcall(fn, re)
	if not ok and CFG.verbose then
		warn(("[RemoteSpy] hook failed on %s: %s"):format(fullPath(re), tostring(err)))
	end
end

-- Incoming hooks only (Connect / OnClientInvoke assignment are valid Roblox).
-- Outgoing is handled by __namecall above; legacy per-remote FireServer
-- assignment is only attempted when __namecall is unavailable.
local function hookRemoteEvent(re)
	if hooked[re] then return end
	hooked[re] = true

	if CFG.hookIncoming then
		local ok = pcall(function()
			re.OnClientEvent:Connect(function(...)
				local pack = table.pack(...)
				enqueue("OnClientEvent", "incoming", fullPath(re), serArgs(pack, pack.n))
			end)
		end)
		if ok then hookedOK += 1 end
	end

	if outgoingMode:sub(1, 6) == "FAILED" then
		pcall(function()
			local oldFire = re.FireServer
			re.FireServer = wrap(function(self, ...)
				local pack = table.pack(...)
				if CFG.enabled then
					enqueue("FireServer", "outgoing", fullPath(self), serArgs(pack, pack.n))
				end
				return oldFire(self, table.unpack(pack, 1, pack.n))
			end)
			outgoingMode = "legacy"
		end)
	end
end

local function hookRemoteFunction(rf)
	if hooked[rf] then return end
	hooked[rf] = true

	if CFG.hookIncoming then
		local oldOnClient = rf.OnClientInvoke
		if oldOnClient then
			local ok = pcall(function()
				rf.OnClientInvoke = function(...)
					local pack = table.pack(...)
					enqueue("OnClientInvoke", "incoming", fullPath(rf), serArgs(pack, pack.n))
					return oldOnClient(table.unpack(pack, 1, pack.n))
				end
			end)
			if ok then hookedOK += 1 end
		end
	end

	if outgoingMode:sub(1, 6) == "FAILED" then
		pcall(function()
			local oldInvoke = rf.InvokeServer
			rf.InvokeServer = wrap(function(self, ...)
				local pack = table.pack(...)
				if CFG.enabled then
					enqueue("InvokeServer", "outgoing", fullPath(self), serArgs(pack, pack.n))
				end
				return oldInvoke(self, table.unpack(pack, 1, pack.n))
			end)
			outgoingMode = "legacy"
		end)
	end
end

local function walk(root)
	local stack = { root }
	while #stack > 0 do
		local cur = table.remove(stack)
		if cur then
			if cur:IsA("RemoteEvent") then
				safeHook(cur, hookRemoteEvent)
			elseif cur:IsA("RemoteFunction") then
				safeHook(cur, hookRemoteFunction)
			end
			for _, child in ipairs(cur:GetChildren()) do
				stack[#stack + 1] = child
			end
		end
	end
end

walk(ReplicatedStorage)
ReplicatedStorage.DescendantAdded:Connect(function(d)
	if d:IsA("RemoteEvent") then safeHook(d, hookRemoteEvent) end
	if d:IsA("RemoteFunction") then safeHook(d, hookRemoteFunction) end
end)

--------------------------------------------------------------------------------
-- init row — "the code" fingerprint + trace
--------------------------------------------------------------------------------

local function initRow()
	local trace = debug.traceback("", 2):sub(1, CFG.traceChars)
	local body = HttpService:JSONEncode({ scriptName = CFG.scriptName, buildTag = CFG.buildTag, trace = trace })
	local hash = 0
	for i = 1, #body do
		hash = (hash * 31 + body:byte(i)) % 2147483647
	end
	return {
		method = "RemoteSpyInit",
		direction = "outgoing",
		remote_path = "__init__",
		caller = callerTag,
		args = {
			script = CFG.scriptName,
			build = CFG.buildTag,
			source_hash = ("%08x"):format(hash),
			trace = trace,
			replicated_remotes = #ReplicatedStorage:GetDescendants(),
		},
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
end

task.spawn(function()
	task.wait(0.5)
	local ok, code = insertRows({ initRow() })
	stats.lastCode = tostring(code)
	if CFG.verbose then
		print(("[RemoteSpy] init insert -> %s (%s)"):format(tostring(ok), tostring(code)))
	end
	if not ok then
		stats.lastError = tostring(code)
	end
end)

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local function parentGui()
	local ok, hui = pcall(function() return gethui and gethui() or nil end)
	if ok and hui then return hui end
	local ok2, cg = pcall(function() return CoreGui end)
	if ok2 and cg then return cg end
	return player:WaitForChild("PlayerGui")
end

local function corner(i, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r); c.Parent = i
end

local gui = Instance.new("ScreenGui")
gui.Name = "OlliERemoteSpySupabase"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = parentGui()

local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(430, 300)
frame.Position = UDim2.new(0.5, -215, 0.5, -150)
frame.BackgroundColor3 = Color3.fromRGB(18, 20, 22)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = gui
corner(frame, 10)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -60, 0, 20)
title.Position = UDim2.fromOffset(10, 6)
title.BackgroundTransparency = 1
title.Font = Enum.Font.Code
title.TextSize = 12
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(140, 200, 140)
title.Text = ("RemoteSpy -> Supabase  [RightCtrl]  %s"):format(CFG.table)
title.Parent = frame

-- mobile hide (no keyboard on mobile, so RightCtrl can't hide the panel)
local hideBtn = Instance.new("TextButton")
hideBtn.Size = UDim2.fromOffset(22, 20)
hideBtn.Position = UDim2.new(1, -32, 0, 6)
hideBtn.BackgroundColor3 = Color3.fromRGB(34, 37, 41)
hideBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
hideBtn.Font = Enum.Font.GothamSemibold
hideBtn.TextSize = 12
hideBtn.Text = "—"
hideBtn.Parent = frame
corner(hideBtn, 6)

local restoreBtn = Instance.new("TextButton")
restoreBtn.Size = UDim2.fromOffset(64, 24)
restoreBtn.Position = UDim2.new(0, 10, 0, 10)
restoreBtn.BackgroundColor3 = Color3.fromRGB(18, 20, 22)
restoreBtn.TextColor3 = Color3.fromRGB(140, 200, 140)
restoreBtn.Font = Enum.Font.GothamSemibold
restoreBtn.TextSize = 12
restoreBtn.Text = "Spy +"
restoreBtn.Visible = false
restoreBtn.Parent = gui
corner(restoreBtn, 6)

hideBtn.MouseButton1Click:Connect(function()
	frame.Visible = false
	restoreBtn.Visible = true
end)
restoreBtn.MouseButton1Click:Connect(function()
	restoreBtn.Visible = false
	frame.Visible = true
end)

local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1, -20, 0, 34)
statusLbl.Position = UDim2.fromOffset(10, 28)
statusLbl.BackgroundTransparency = 1
statusLbl.Font = Enum.Font.Code
statusLbl.TextSize = 11
statusLbl.TextXAlignment = Enum.TextXAlignment.Left
statusLbl.TextYAlignment = Enum.TextYAlignment.Top
statusLbl.TextColor3 = Color3.fromRGB(200, 200, 200)
statusLbl.Text = "starting"
statusLbl.Parent = frame

local function mkBtn(text, x, w)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromOffset(w, 22)
	b.Position = UDim2.fromOffset(x, 66)
	b.BackgroundColor3 = Color3.fromRGB(34, 37, 41)
	b.TextColor3 = Color3.fromRGB(220, 220, 220)
	b.Font = Enum.Font.GothamSemibold
	b.TextSize = 12
	b.Text = text
	b.Parent = frame
	corner(b, 6)
	return b
end

local toggleBtn = mkBtn("enabled", 10, 90)
toggleBtn.BackgroundColor3 = Color3.fromRGB(38, 74, 46)
toggleBtn.TextColor3 = Color3.fromRGB(170, 255, 190)
toggleBtn.MouseButton1Click:Connect(function()
	CFG.enabled = not CFG.enabled
	toggleBtn.Text = CFG.enabled and "enabled" or "paused"
	toggleBtn.BackgroundColor3 = CFG.enabled and Color3.fromRGB(38, 74, 46) or Color3.fromRGB(76, 34, 34)
	toggleBtn.TextColor3 = CFG.enabled and Color3.fromRGB(170, 255, 190) or Color3.fromRGB(255, 200, 200)
end)

local flushBtn = mkBtn("flush now", 108, 90)
flushBtn.MouseButton1Click:Connect(function()
	pcall(flush)
end)

local clearBtn = mkBtn("clear queue", 206, 90)
clearBtn.MouseButton1Click:Connect(function()
	queue = {}
end)

local testBtn = mkBtn("test insert", 304, 90)
testBtn.MouseButton1Click:Connect(function()
	local ok, code = insertRows({ initRow() })
	stats.lastCode = tostring(code)
	stats.lastError = ok and "-" or tostring(code)
end)

local statsLbl = Instance.new("TextLabel")
statsLbl.Size = UDim2.new(1, -20, 1, -100)
statsLbl.Position = UDim2.fromOffset(10, 96)
statsLbl.BackgroundTransparency = 1
statsLbl.Font = Enum.Font.Code
statsLbl.TextSize = 11
statsLbl.TextXAlignment = Enum.TextXAlignment.Left
statsLbl.TextYAlignment = Enum.TextYAlignment.Top
statsLbl.TextColor3 = Color3.fromRGB(160, 160, 160)
statsLbl.Text = ""
statsLbl.Parent = frame

local function refreshUI()
	statusLbl.Text = ("queue %d | sent %d | dropped %d | last HTTP %s")
		:format(#queue, stats.sent, stats.dropped, stats.lastCode)
	statsLbl.Text = ("last error: %s\noutgoing: %s\nincoming hooks: %d\ncaller: %s\nbuild: %s\nhttp fn: %s")
		:format(tostring(stats.lastError), outgoingMode, hookedOK,
			callerTag, CFG.buildTag, requestFn and "yes" or "MISSING")
end

task.spawn(function()
	while true do
		task.wait(0.5)
		refreshUI()
	end
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.RightControl then
		frame.Visible = not frame.Visible
	end
end)

refreshUI()
print(("[olliE] RemoteSpy -> Supabase loaded | %s | http=%s"):format(CFG.buildTag, requestFn and "yes" or "MISSING"))