--[[
	Throw Food For Animals - remote probe rig
	Executor script. Fires one shaped call per remote, prints Ok/Reason.

	Every handler in this dump is client-side only, so each probe is a
	hypothesis: does the server re-derive the outcome, or take the client's word?

	OK      -> handler accepted a forged client value. Exploitable.
	Reason  -> guard fired. The reason string names the check.

	On-screen results: Rayfield panel (mobile-friendly) with the original console
	output mirrored into it, so the results are readable without a console.
	No sells. No destructive calls. The only spend is Dreamland_Action "Buy" 1,
	which costs whatever the cheapest dreamland item costs - comment it out if
	you want a zero-risk run.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
if not Remotes then
	error("Remotes missing - wrong game or wrong place")
end

local function remote(name)
	return Remotes:FindFirstChild(name) or Remotes:WaitForChild(name, 8)
end

local function invoke(name, ...)
	local r = remote(name)
	if not r then
		return { Ok = false, Reason = "NoRemote" }
	end
	local ok, res = pcall(r.InvokeServer, r, ...)
	if not ok then
		return { Ok = false, Reason = tostring(res) }
	end
	if type(res) ~= "table" then
		return { Ok = res ~= false, Reason = res == false and "false" or nil }
	end
	return res
end

local function safeRequire(inst)
	if not inst then
		return nil
	end
	local ok, mod = pcall(require, inst)
	if ok and type(mod) == "table" then
		return mod
	end
	return nil
end

local Config = ReplicatedStorage:FindFirstChild("Config")
local IndexConfig = safeRequire(Config and Config:FindFirstChild("IndexRewardsConfig"))

local indexKeys = {}
if IndexConfig then
	local list = IndexConfig.Collections or IndexConfig.All or {}
	for _, entry in ipairs(list) do
		if entry.Key then
			table.insert(indexKeys, entry.Key)
		end
	end
end
if #indexKeys == 0 then
	indexKeys = { "Forest", "Savana", "Desert", "Jungle", "Ocean", "Mountains", "Taiga", "Winter" }
end

local cookKeys = { "Turkey", "Pie", "MashedPotatoes", "CranberrySauce", "Cornbread" }
local ThanksgivingConfig = safeRequire(Config and Config:FindFirstChild("ThanksgivingConfig"))
if ThanksgivingConfig and type(ThanksgivingConfig.Recipes) == "table" then
	local keys = {}
	for key in pairs(ThanksgivingConfig.Recipes) do
		table.insert(keys, key)
	end
	if #keys > 0 then
		cookKeys = keys
	end
end

local function getPlot()
	local index = player:GetAttribute("PlotIndex")
	local plots = workspace:FindFirstChild("Plots")
	if not index or not plots then
		return nil
	end
	return plots:FindFirstChild(tostring(index))
end

local function firstAnimalId()
	local plot = getPlot()
	if not plot then
		return nil
	end
	for _, inst in ipairs(plot:GetDescendants()) do
		local id = inst:GetAttribute("AnimalId")
		if id then
			return id
		end
	end
	return nil
end

local okCount, badCount = 0, 0
local Probe -- forward-declared: the buttons above use it, it is defined below

-- ===== On-screen results (Rayfield, mobile-friendly) =====
-- The probe used to only print() to the console, which mobile can't see.
-- Every result line is now mirrored into this panel as well.
local _loadingGui = Instance.new("ScreenGui")
_loadingGui.Name = "ThrowFoodProbeLoading"
_loadingGui.ResetOnSpawn = false
_loadingGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local _loadingLabel = Instance.new("TextLabel")
_loadingLabel.Size = UDim2.new(0, 260, 0, 40)
_loadingLabel.Position = UDim2.new(0.5, -130, 0, 20)
_loadingLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
_loadingLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
_loadingLabel.TextSize = 16
_loadingLabel.Font = Enum.Font.SourceSansBold
_loadingLabel.Text = "Throw Food Probe loading..."
_loadingLabel.Parent = _loadingGui
pcall(function() _loadingGui.Parent = game:GetService("CoreGui") end)
if not _loadingGui.Parent then
	pcall(function() _loadingGui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end)
end

local logLines = {}
local useRayfield = false
local Rayfield, Window, MainTab, resultsPara
local resultsLabel, resultsScroll -- simple-UI fallback
local simpleGui
local unloaded = false

local function refreshResults()
	local text = table.concat(logLines, "\n")
	if useRayfield and resultsPara then
		pcall(function() resultsPara:Set({ Title = "Results", Content = text ~= "" and text or "No results yet." }) end)
		pcall(function() resultsPara:SetTitle(text) end)
	elseif resultsLabel then
		resultsLabel.Text = text ~= "" and text or "No results yet."
		pcall(function()
			resultsScroll.CanvasSize = UDim2.new(0, 0, 0, math.max(resultsLabel.TextBounds.Y + 10, 200))
		end)
	end
end

local function log(line)
	print(line)
	table.insert(logLines, line)
	if #logLines > 60 then table.remove(logLines, 1) end
	refreshResults()
end

local function unload()
	unloaded = true
	if useRayfield and Rayfield then
		pcall(function() Rayfield:Destroy() end)
	elseif simpleGui then
		pcall(function() simpleGui:Destroy() end)
	end
	pcall(function() _loadingGui:Destroy() end)
	print("[probe] unloaded")
end

-- Rayfield load (pcall: if it fails we fall back to a simple scrolling panel)
local rayOk = pcall(function()
	Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
end)
useRayfield = rayOk and Rayfield ~= nil

if useRayfield then
	local winOk, win = pcall(function()
		return Rayfield:CreateWindow({
			Name = "Throw Food - Probe",
			LoadingTitle = "Throw Food Probe",
			LoadingSubtitle = "Remote probe results",
			ConfigurationSaving = { Enabled = false },
			KeySystem = false,
		})
	end)
	if winOk and win then
		Window = win
		MainTab = Window:CreateTab("Main", nil)
		resultsPara = MainTab:CreateParagraph({ Title = "Results", Content = "Running the sweep..." })
		MainTab:CreateButton({
			Name = "Run Full Sweep",
			Callback = function() task.spawn(function() Probe.all() end) end,
		})
		MainTab:CreateButton({
			Name = "Ring Rush",
			Callback = function() task.spawn(function() Probe.ring() end) end,
		})
		MainTab:CreateButton({
			Name = "Tap Bonus (20)",
			Callback = function() task.spawn(function() Probe.tap(20) end) end,
		})
		MainTab:CreateButton({
			Name = "Throw Forge (8)",
			Callback = function() task.spawn(function() Probe.throwForge(8) end) end,
		})
		MainTab:CreateButton({
			Name = "Index Rewards",
			Callback = function() task.spawn(function() Probe.index() end) end,
		})
		MainTab:CreateButton({
			Name = "Cook Recipes",
			Callback = function() task.spawn(function() Probe.cook() end) end,
		})
		MainTab:CreateButton({
			Name = "Clear Results",
			Callback = function()
				table.clear(logLines)
				refreshResults()
			end,
		})
		MainTab:CreateButton({
			Name = "Unload Script",
			Callback = function() unload() end,
		})
		_loadingLabel.Text = "Rayfield loaded OK - results on screen"
		pcall(function() Rayfield:Notify({ Title = "Throw Food Probe", Content = "Sweep running - results show here.", Duration = 5 }) end)
	else
		useRayfield = false
	end
end

if not useRayfield then
	-- Simple scrolling results panel (fallback if Rayfield fails to load).
	local gui = Instance.new("ScreenGui")
	gui.Name = "ThrowFoodProbe"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(320, 320)
	frame.Position = UDim2.new(0, 24, 0.5, -160)
	frame.BackgroundColor3 = Color3.fromRGB(18, 20, 22)
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Draggable = true
	frame.Parent = gui
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 12)
	fc.Parent = frame
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -44, 0, 26)
	title.Position = UDim2.fromOffset(12, 8)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(235, 235, 235)
	title.Text = "THROW FOOD - PROBE"
	title.Parent = frame
	local close = Instance.new("TextButton")
	close.Size = UDim2.fromOffset(26, 26)
	close.Position = UDim2.new(1, -34, 0, 8)
	close.BackgroundColor3 = Color3.fromRGB(76, 34, 34)
	close.TextColor3 = Color3.fromRGB(255, 200, 200)
	close.Font = Enum.Font.GothamBold
	close.TextSize = 14
	close.Text = "X"
	close.Parent = frame
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 8)
	cc.Parent = close
	close.MouseButton1Click:Connect(function() unload() end)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, -24, 1, -46)
	scroll.Position = UDim2.fromOffset(12, 38)
	scroll.BackgroundColor3 = Color3.fromRGB(24, 26, 28)
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.CanvasSize = UDim2.new(0, 0, 0, 200)
	scroll.Parent = frame
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -8, 0, 200)
	label.Position = UDim2.fromOffset(4, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextColor3 = Color3.fromRGB(200, 220, 200)
	label.TextWrapped = true
	label.Text = "Running the sweep..."
	label.Parent = scroll
	resultsLabel = label
	resultsScroll = scroll
	pcall(function() gui.Parent = game:GetService("CoreGui") end)
	if not gui.Parent then
		pcall(function() gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end)
	end
	simpleGui = gui
	_loadingLabel.Text = "Rayfield failed - simple results panel loaded"
end

task.spawn(function()
	task.wait(5)
	pcall(function() _loadingGui:Destroy() end)
end)

local function show(label, res)
	local passed = res and res.Ok == true
	if passed then
		okCount += 1
	else
		badCount += 1
	end
	local detail = res and (res.Reason or res.Amount or res.Money) or nil
	log(("[probe] %-28s %s%s"):format(label, passed and "OK" or "REFUSED", detail and ("  [" .. tostring(detail) .. "]") or ""))
end

local PROBES = {
	{ "Dev_Action Money", function()
		return invoke("Dev_Action", "Money")
	end },
	{ "Dev_Action Jump", function()
		return invoke("Dev_Action", "Jump", "Forest")
	end },
	{ "Dev_Action AdminTest", function()
		return invoke("Dev_Action", "AdminTest", "1x")
	end },
	{ "Shop_ClaimFree", function()
		return invoke("Shop_ClaimFree")
	end },
	{ "Offline_Claim", function()
		return invoke("Offline_Claim")
	end },
	{ "Plot_EquipBest", function()
		return invoke("Plot_EquipBest")
	end },
	{ "Stand_Upgrade", function()
		return invoke("Stand_Upgrade")
	end },
	{ "Plot_UpgradeFence", function()
		return invoke("Plot_UpgradeFence")
	end },
	{ "SetThrowPower 1e6", function()
		return invoke("Player_SetThrowPower", 1000000)
	end },
	{ "Throw_UseSuper", function()
		return invoke("Throw_UseSuper")
	end },
	{ "Throw_UseSandwich", function()
		return invoke("Throw_UseSandwich", "Regular")
	end },
	{ "Training_Start", function()
		return invoke("Training_Start")
	end },
	{ "Thanksgiving Claim", function()
		return invoke("Thanksgiving_Action", "Claim")
	end },
	{ "Thanksgiving Talked", function()
		return invoke("Thanksgiving_Action", "Talked")
	end },
	{ "Dreamland Claim 1", function()
		return invoke("Dreamland_Action", "Claim", 1)
	end },
	{ "Dreamland Buy 1", function()
		return invoke("Dreamland_Action", "Buy", 1)
	end },
	{ "Gift_Request self", function()
		return invoke("Gift_Request", player.UserId, "Regular")
	end },
	{ "IndexRewards_Claim Forest", function()
		return invoke("IndexRewards_Claim", "Forest")
	end },
}

local function runSweep(label, keys, fn)
	local accepted = 0
	for _, key in ipairs(keys) do
		local res = fn(key)
		if res and res.Ok then
			accepted += 1
			log(("[probe] %s %s -> OK"):format(label, tostring(key)))
		end
		task.wait(0.05)
	end
	log(("[probe] %s sweep: %d/%d accepted"):format(label, accepted, #keys))
end

Probe = {}

function Probe.basic()
	log("[probe] -- baseline calls --")
	for _, entry in ipairs(PROBES) do
		local label, fn = entry[1], entry[2]
		local ok, res = pcall(fn)
		show(label, ok and res or { Ok = false, Reason = tostring(res) })
		task.wait(0.25)
	end
end

function Probe.ring(rings)
	rings = rings or 10
	local begin = invoke("RingRush_Begin")
	show("RingRush_Begin", begin)
	if not begin.Ok then
		return
	end
	local now = workspace:GetServerTimeNow()
	local accepted = 0
	for i = 1, rings do
		local res = invoke("RingRush_Report", i, true, 0.5, 0.5, now)
		if not res.Ok then
			log(("[probe] report #%d refused: %s"):format(i, tostring(res.Reason)))
			break
		end
		accepted += 1
		log(("[probe] report #%d OK money=%s bonus=%s rings=%s ended=%s"):format(
			i, tostring(res.Money), tostring(res.Bonus), tostring(res.Rings), tostring(res.Ended)))
		task.wait(0.05)
	end
	show("RingRush_End", invoke("RingRush_End"))
	log(("[probe] forged rings accepted: %d"):format(accepted))
end

function Probe.tap(count)
	count = count or 40
	local id = firstAnimalId()
	if not id then
		log("[probe] tap: no AnimalId on plot")
		return
	end
	invoke("Training_Start")
	local accepted = 0
	for _ = 1, count do
		local res = invoke("Training_TapBonus", id)
		if res.Ok then
			accepted += 1
		end
		task.wait(0.03)
	end
	invoke("Training_Stop")
	log(("[probe] tap bonus %d/%d accepted on %s"):format(accepted, count, tostring(id)))
end

function Probe.throwForge(count)
	count = count or 8
	local done = 0
	for i = 1, count do
		local start = invoke("Throw_Start")
		if not start.Ok then
			log(("[probe] Throw_Start #%d refused: %s"):format(i, tostring(start.Reason)))
			break
		end
		local res = invoke("Throw_Resolve", 1)
		if not res.Ok then
			log(("[probe] Resolve #%d refused: %s"):format(i, tostring(res.Reason)))
			invoke("Throw_Cancel")
			break
		end
		done += 1
		task.wait((tonumber(res.FlightTime) or 2) + 0.2)
		invoke("Throw_Complete")
	end
	log(("[probe] instant resolve: %d/%d accepted"):format(done, count))
end

function Probe.index()
	runSweep("IndexRewards_Claim", indexKeys, function(key)
		return invoke("IndexRewards_Claim", key)
	end)
end

function Probe.cook()
	runSweep("Thanksgiving Cook", cookKeys, function(key)
		return invoke("Thanksgiving_Action", "Cook", key)
	end)
end

function Probe.all()
	okCount, badCount = 0, 0
	Probe.basic()
	Probe.tap(20)
	Probe.index()
	Probe.cook()
	log(("[probe] done. ok=%d refused=%d"):format(okCount, badCount))
	log("[probe] run Probe.ring(), Probe.throwForge(), Probe.tap(n) for the loops")
end

_G.Probe = Probe

log("[probe] loaded. _G.Probe.all() for the sweep, or Probe.ring() / Probe.tap() / Probe.throwForge()")
Probe.all()
