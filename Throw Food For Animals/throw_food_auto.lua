--[[
	Throw Food For Animals - auto perfect throw / equip best / upgrade base + bar
	+ FULL CYCLE (from FullyAuto): N perfect throws -> equip best -> walk to
	stand -> train X sec -> upgrade stand -> walk to shop -> try buy next
	food -> repeat. Toggle "FULL CYCLE" in Rayfield.
	Executor script (client-side). Field build, Nov 2026.
	Rayfield UI (mobile-friendly, minimize in the top bar) with the original
	draggable panel as fallback if Rayfield fails to load.

	Remotes used (from ReplicatedStorage.Shared.Remotes):
		Throw_Start / Throw_Resolve / Throw_Complete / Throw_Cancel  (RemoteFunction)
		Throw_MeterStarted                                            (RemoteEvent)
		Plot_EquipBest / Plot_UpgradeFence / Stand_Upgrade            (RemoteFunction)
		Player_SetThrowPower                                          (RemoteFunction)

	Perfect = meter value >= 0.92 (GameConfig.Throw.MeterRatings), bonus = 20 studs at 1.0.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

local player = Players.LocalPlayer

local CFG = {
	perfectValue = 0.999,      -- what we send to Throw_Resolve (0..1); 0.999 rounds to 20 bonus studs
	tapThreshold = 0.97,       -- tap mode: click when the real meter is this high
	autoPosition = true,       -- teleport to the throw line each cycle
	throwGap = 0.15,           -- extra pause after a throw completes
	equipEvery = 2,            -- seconds between Plot_EquipBest calls
	upgradeEvery = 1.5,        -- seconds between upgrade passes
	upgradeBurst = 12,         -- max upgrade invokes per pass
	verbose = true,

	-- CYCLE knobs (from FullyAuto)
	throwsBeforeTrain = 10,  -- throws per cycle before walking to stand
	trainSeconds = 60,       -- seconds of training per cycle
	cyclePause = 1.5,        -- pause between full cycles
	shopBuy = true,          -- try buying next food at end of cycle
	maxPowerOnce = true,     -- call max throw power once at cycle start
	trainClickInterval = 0,  -- 0 = stand only; >0 = click every N sec while training
	shopBuyRemote = nil,     -- override e.g. "Shop_BuyFood" if the probe name differs
	trainRemote = nil,       -- override e.g. "Train_Start"
	shopOffset = Vector3.new(0, 0, 40),      -- fallback shop position rel. to StarterArea
	trainOffset = Vector3.new(-16, 0, -30.5), -- stand bar position rel. to plot
}

local State = {
	throw = false,
	tapMode = false,           -- false = direct remotes, true = click the real meter
	equip = false,
	fence = false,
	stand = false,
	throws = 0,
	perfects = 0,
	spent = 0,
	lastReason = "-",
	cycle = false,
	cycleStep = "idle",
}

local unloaded = false -- set by the Unload button; all loops check it and stop

--------------------------------------------------------------------------------
-- remotes
--------------------------------------------------------------------------------

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
if not Remotes then
	error("Remotes folder not found - is this the right game?")
end

local function remote(name)
	return Remotes:WaitForChild(name, 15)
end

local throwStart = remote("Throw_Start")
local throwResolve = remote("Throw_Resolve")
local throwComplete = remote("Throw_Complete")
local throwCancel = remote("Throw_Cancel")
local meterStarted = remote("Throw_MeterStarted")
local equipBestR = remote("Plot_EquipBest")
local upgradeFenceR = remote("Plot_UpgradeFence")
local upgradeStandR = remote("Stand_Upgrade")
local setPowerR = remote("Player_SetThrowPower")

local function probe(candidates, override)
	if override then
		local r = Remotes:FindFirstChild(override)
		if r then return r end
	end
	for _, name in ipairs(candidates) do
		local r = Remotes:FindFirstChild(name)
		if r then return r end
	end
	return nil
end

-- CYCLE remotes: these names are PROBES, not confirmed.
-- Training_Start IS a real remote (the probe script uses it), so the train
-- remote will almost always be found. No shop-buy remote is confirmed yet -
-- if none of these names exist, shopBuyR is nil and the cycle just skips
-- the shop step (status line shows shop_remote=MISSING).
local shopBuyR = probe({ "Shop_BuyFood", "Shop_Buy", "Food_Buy", "BuyFood", "Shop_Purchase" }, CFG.shopBuyRemote)
local trainR = probe({ "Train_Start", "Training_Start", "Train_Tick", "Stand_Train" }, CFG.trainRemote)

local function invoke(r, ...)
	if not r then return { Ok = false, Reason = "NoRemote" } end
	local ok, res = pcall(r.InvokeServer, r, ...)
	if not ok or type(res) ~= "table" then
		return { Ok = false, Reason = ok and "BadResponse" or tostring(res) }
	end
	return res
end

--------------------------------------------------------------------------------
-- game config read (meter math, level caps)
--------------------------------------------------------------------------------

local function safeRequire(inst)
	local ok, mod = pcall(require, inst)
	if ok and type(mod) == "table" then
		return mod
	end
	return nil
end

local Config = ReplicatedStorage:FindFirstChild("Config")
local GameConfig = Config and safeRequire(Config:FindFirstChild("GameConfig"))
local LevelConfig = Config and safeRequire(Config:FindFirstChild("LevelConfig"))
local FenceConfig = Config and safeRequire(Config:FindFirstChild("FenceConfig"))

local meterDelay = 1.0845 -- fallback: seconds to full meter
do
	local t = GameConfig and GameConfig.Throw
	if t then
		local base = t.MeterBaseSpeed or 0.55
		local top = (t.MeterTopSpeedFactor or 2.6) - 1
		if top <= 0 then
			meterDelay = 1 / base
		else
			meterDelay = math.log(1 + top) / (base * top)
		end
	end
end

--------------------------------------------------------------------------------
-- world helpers
--------------------------------------------------------------------------------

local function character()
	local char = player.Character
	if not char or not char.Parent then
		return nil, nil
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then
		return nil, nil
	end
	return char, root
end

local function getPlot()
	local index = player:GetAttribute("PlotIndex")
	if not index then
		return nil
	end
	local plots = workspace:FindFirstChild("Plots")
	return plots and plots:FindFirstChild(tostring(index)) or nil
end

local StarterArea = workspace:WaitForChild("StarterArea", 30)
local CrossLine = StarterArea and StarterArea:WaitForChild("CrossLine", 15)

local function throwLinePosition()
	if not StarterArea or not CrossLine then
		return nil
	end
	local groundY = StarterArea.Position.Y + StarterArea.Size.Y / 2
	-- the vanilla controller throws once the root is *past* the cross line (z < line.Z)
	return Vector3.new(StarterArea.Position.X, groundY + 3, CrossLine.Position.Z - 3)
end

local function placeAt(root, pos)
	if not pos then
		return
	end
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.new(pos + Vector3.new(0, 0.02, 0))
end

local function waitUntilReady()
	local readyAt = player:GetAttribute("ThrowReadyAt")
	if type(readyAt) ~= "number" then
		return
	end
	local delta = readyAt - workspace:GetServerTimeNow()
	if delta > 0.05 then
		task.wait(math.min(delta, 1.6))
	end
end

-- stand/train position (plot relative - same spot as the stand bar upgrade)
local function standPosition()
	local plot = getPlot()
	if not plot then return nil end
	return plot.Position + CFG.trainOffset
end

-- shop position: probe workspace, else StarterArea + offset fallback
local function shopPosition()
	for _, name in ipairs({ "Shop", "Shops", "ShopZone", "ShopSign", "FoodShop" }) do
		local inst = workspace:FindFirstChild(name, true)
		if inst and inst:IsA("BasePart") then
			return inst.Position + Vector3.new(0, 3, 0)
		end
	end
	if StarterArea then
		return StarterArea.Position + CFG.shopOffset + Vector3.new(0, 3, 0)
	end
	return nil
end

--------------------------------------------------------------------------------
-- suppress the vanilla auto throw so it doesn't race our remote calls
--------------------------------------------------------------------------------

local clientState = nil
do
	local scripts = player:FindFirstChild("PlayerScripts")
	local client = scripts and scripts:FindFirstChild("Client")
	local controllers = client and client:FindFirstChild("Controllers")
	local mod = controllers and controllers:FindFirstChild("ClientState")
	local ok, res = pcall(require, mod)
	if ok and type(res) == "table" then
		clientState = res
	end
end

local function blockVanillaThrow(blocked)
	if not clientState then
		return
	end
	if blocked then
		if clientState.Busy == nil then
			clientState.Busy = "AutoThrow"
		end
	elseif clientState.Busy == "AutoThrow" then
		clientState.Busy = nil
	end
end

--------------------------------------------------------------------------------
-- one throw, perfect
--------------------------------------------------------------------------------

local function throwOnce()
	local char, root = character()
	if not root then
		return false, "NoCharacter"
	end
	if CFG.autoPosition then
		placeAt(root, throwLinePosition())
	end
	waitUntilReady()

	local start = invoke(throwStart)
	if not start.Ok then
		return false, start.Reason or "StartRefused"
	end

	pcall(function()
		meterStarted:FireServer()
	end)

	task.wait(meterDelay)
	local res = invoke(throwResolve, CFG.perfectValue)
	if not res.Ok then
		pcall(function()
			throwCancel:InvokeServer()
		end)
		return false, res.Reason or "ResolveRefused"
	end

	task.wait((res.FlightTime or 2.2) + 0.4)
	invoke(throwComplete)

	return true, res
end

--------------------------------------------------------------------------------
-- tap mode: let the game run its own sequence, click the meter at the top
--------------------------------------------------------------------------------

local function playerGui()
	return player:FindFirstChild("PlayerGui")
end

local function meterValue()
	local pg = playerGui()
	local seq = pg and pg:FindFirstChild("ThrowSequence")
	local meter = seq and seq:FindFirstChild("Meter")
	local marker = meter and meter:FindFirstChild("Marker")
	if not marker then
		return nil
	end
	-- marker runs from scale 1 (empty) to 0 (full); value = 1 - y
	return 1 - marker.Position.Y.Scale
end

local function waitForMeterAppear(timeout)
	local deadline = os.clock() + (timeout or 15)
	while os.clock() < deadline do
		if meterValue() ~= nil then
			return true
		end
		task.wait()
	end
	return false
end

local function waitForSequenceEnd(timeout)
	local deadline = os.clock() + (timeout or 20)
	while os.clock() < deadline do
		local pg = playerGui()
		if not (pg and pg:FindFirstChild("ThrowSequence")) then
			return true
		end
		task.wait(0.1)
	end
	return false
end

local function tapThrow()
	local char, root = character()
	if not root then
		return false, "NoCharacter"
	end
	if CFG.autoPosition then
		placeAt(root, throwLinePosition())
	end
	-- hand control back to the vanilla controller so it starts the sequence
	blockVanillaThrow(false)
	if not waitForMeterAppear(10) then
		blockVanillaThrow(State.throw)
		return false, "NoMeter"
	end
	local clicked = false
	local deadline = os.clock() + 8
	while os.clock() < deadline do
		local value = meterValue()
		if value and value >= CFG.tapThreshold then
			VirtualUser:ClickButton1(Vector3.new(
				workspace.CurrentCamera.ViewportSize.X / 2,
				workspace.CurrentCamera.ViewportSize.Y / 2
			))
			clicked = true
			break
		end
		task.wait()
	end
	if State.throw then
		blockVanillaThrow(true)
	end
	if not clicked then
		return false, "MissedMeter"
	end
	waitForSequenceEnd(20)
	return true, "tapped"
end

--------------------------------------------------------------------------------
-- upgrades
--------------------------------------------------------------------------------

local function upgradeFencePass()
	local plot = getPlot()
	if not plot then
		return false, "NoPlot"
	end
	local char, root = character()
	if not root then
		return false, "NoCharacter"
	end
	if CFG.autoPosition then
		local sign = plot.Position + (FenceConfig and FenceConfig.SignOffset or Vector3.new(-8.5, 0, -24.6))
		placeAt(root, Vector3.new(sign.X, sign.Y + 3, sign.Z + 3))
		task.wait(0.12)
	end
	local reason = "Burst"
	for _ = 1, CFG.upgradeBurst do
		local res = invoke(upgradeFenceR)
		if not res.Ok then
			reason = res.Reason or "Refused"
			if reason == "TooFar" and CFG.autoPosition then
				task.wait(0.1)
				continue
			end
			break
		end
		State.spent += 1
		task.wait(0.08)
	end
	return reason == "Burst", reason
end

local function upgradeStandPass()
	local plot = getPlot()
	if not plot then
		return false, "NoPlot"
	end
	local char, root = character()
	if not root then
		return false, "NoCharacter"
	end
	if CFG.autoPosition then
		local bar = plot.Position + Vector3.new(-16, 0, -30.5)
		placeAt(root, Vector3.new(bar.X, bar.Y + 3, bar.Z + 3))
		task.wait(0.12)
	end
	local reason = "Burst"
	for _ = 1, CFG.upgradeBurst do
		local res = invoke(upgradeStandR)
		if not res.Ok then
			reason = res.Reason or "Refused"
			break
		end
		State.spent += 1
		task.wait(0.08)
	end
	return reason == "Burst", reason
end

local function equipBestPass()
	local res = invoke(equipBestR)
	return res.Ok, res.Reason or "Ok"
end

local function maxThrowPower()
	if not LevelConfig then
		return false, "NoConfig"
	end
	local level = 1
	do
		local scripts = player:FindFirstChild("PlayerScripts")
		local client = scripts and scripts:FindFirstChild("Client")
		local controllers = client and client:FindFirstChild("Controllers")
		local data = controllers and controllers:FindFirstChild("DataController")
		local mod = data and safeRequire(data)
		if mod and mod.Get then
			level = tonumber(mod.Get("Level")) or 1
		end
	end
	local cap = LevelConfig.ThrowPowerForLevel(level)
	local res = invoke(setPowerR, cap)
	return res.Ok, res.Ok and ("power " .. tostring(math.floor(cap))) or (res.Reason or "Refused")
end

--------------------------------------------------------------------------------
-- CYCLE passes: train + shop (from FullyAuto)
--------------------------------------------------------------------------------

local function currentFoodTier()
	-- probe common attribute/data keys; fall back to 1 (unknown)
	for _, key in ipairs({ "EquippedFood", "FoodTier", "FoodIndex", "EquippedFoodIndex" }) do
		local v = player:GetAttribute(key)
		if type(v) == "number" then return v end
	end
	do
		local scripts = player:FindFirstChild("PlayerScripts")
		local client = scripts and scripts:FindFirstChild("Client")
		local controllers = client and client:FindFirstChild("Controllers")
		local data = controllers and controllers:FindFirstChild("DataController")
		local mod = data and safeRequire(data)
		if mod and mod.Get then
			for _, key in ipairs({ "EquippedFood", "FoodTier", "FoodIndex" }) do
				local v = mod.Get(key)
				if type(v) == "number" then return v end
			end
		end
	end
	return nil
end

local function trainPass(seconds)
	local pos = standPosition()
	if not pos then return false, "NoPlot" end
	local char, root = character()
	if not root then return false, "NoCharacter" end
	if CFG.autoPosition then placeAt(root, pos) end

	if trainR then
		pcall(function()
			if trainR:IsA("RemoteEvent") then trainR:FireServer()
			else trainR:InvokeServer() end
		end)
	end

	local deadline = os.clock() + seconds
	local clickAt = os.clock() + (CFG.trainClickInterval > 0 and CFG.trainClickInterval or math.huge)
	while os.clock() < deadline do
		if not State.cycle then return false, "CycleOff" end
		local _, r = character()
		if not r then return false, "NoCharacter" end
		if not CFG.autoPosition then
			r.AssemblyLinearVelocity = Vector3.zero
		end
		if CFG.trainClickInterval > 0 and os.clock() >= clickAt then
			VirtualUser:ClickButton1(Vector3.new(
				workspace.CurrentCamera.ViewportSize.X / 2,
				workspace.CurrentCamera.ViewportSize.Y / 2
			))
			clickAt = os.clock() + CFG.trainClickInterval
		end
		task.wait(0.25)
	end
	return true, ("trained %ds"):format(math.floor(seconds))
end

local function shopBuyPass()
	if not CFG.shopBuy then return false, "Disabled" end
	if not shopBuyR then return false, "NoRemote" end
	local pos = shopPosition()
	local char, root = character()
	if not root then return false, "NoCharacter" end
	if pos and CFG.autoPosition then
		placeAt(root, pos)
		task.wait(0.15)
	end

	local tier = currentFoodTier() or 1
	local tryTier = tier + 1
	local res = invoke(shopBuyR, tryTier)
	if res.Ok then
		return true, ("bought tier %d"):format(tryTier)
	end
	return false, ("buy %d: %s"):format(tryTier, tostring(res.Reason or "Refused"))
end

--------------------------------------------------------------------------------
-- UI - Rayfield (mobile-friendly), original panel as fallback
--------------------------------------------------------------------------------
-- Loading label FIRST so mobile can see the script started (no console).
local _loadingGui = Instance.new("ScreenGui")
_loadingGui.Name = "ThrowFoodAutoLoading"
_loadingGui.ResetOnSpawn = false
_loadingGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local _loadingLabel = Instance.new("TextLabel")
_loadingLabel.Size = UDim2.new(0, 260, 0, 40)
_loadingLabel.Position = UDim2.new(0.5, -130, 0, 20)
_loadingLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
_loadingLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
_loadingLabel.TextSize = 16
_loadingLabel.Font = Enum.Font.SourceSansBold
_loadingLabel.Text = "Throw Food Auto loading..."
_loadingLabel.Parent = _loadingGui
pcall(function() _loadingGui.Parent = game:GetService("CoreGui") end)
if not _loadingGui.Parent then
	pcall(function() _loadingGui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end)
end

local useRayfield = false
local Rayfield, Window, MainTab, statusPara
local statusLabel, statsLabel -- simple-UI labels (fallback only)
local simpleGui

-- One refresh() for both UIs: Rayfield paragraph, or the simple panel labels.
function refresh()
	local step = State.cycle and ("cycle:" .. State.cycleStep) or (State.throw and "running" or "idle")
	local text = ("throws %d  |  perfect %d\nlast: %s"):format(State.throws, State.perfects, State.lastReason)
	if useRayfield and statusPara then
		pcall(function() statusPara:Set({ Title = "Status (" .. step .. ")", Content = text }) end)
		pcall(function() statusPara:SetTitle(text) end)
	elseif statusLabel then
		statusLabel.Text = text
		if statsLabel then statsLabel.Text = step .. " | shop=" .. (shopBuyR and "yes" or "MISSING") .. " train=" .. (trainR and "yes" or "none") end
	end
end

local function unload()
	unloaded = true
	blockVanillaThrow(false)
	if useRayfield and Rayfield then
		pcall(function() Rayfield:Destroy() end)
	elseif simpleGui then
		pcall(function() simpleGui:Destroy() end)
	end
	pcall(function() _loadingGui:Destroy() end)
	print("[olliE] throw auto unloaded")
end

local function setAll(on)
	State.throw, State.equip, State.fence, State.stand = on, on, on, on
	blockVanillaThrow(on and not State.tapMode)
	refresh()
end

local function stopAll()
	State.throw, State.equip, State.fence, State.stand, State.cycle = false, false, false, false, false
	State.cycleStep = "idle"
	blockVanillaThrow(false)
	State.lastReason = "stopped"
	refresh()
end

local function setCycle(on)
	State.cycle = on
	if on then
		if CFG.maxPowerOnce then maxThrowPower() end
		State.cycleStep = "starting"
	else
		State.cycleStep = "idle"
	end
	blockVanillaThrow(on and not State.tapMode)
	refresh()
end

-- Rayfield load (pcall: if it fails we fall back to the original panel below)
local rayOk = pcall(function()
	Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
end)
useRayfield = rayOk and Rayfield ~= nil

if useRayfield then
	local winOk, win = pcall(function()
		return Rayfield:CreateWindow({
			Name = "Throw Food - Auto",
			LoadingTitle = "Throw Food Auto",
			LoadingSubtitle = "Perfect throws + upgrades",
			ConfigurationSaving = { Enabled = false },
			KeySystem = false,
		})
	end)
	if winOk and win then
		Window = win
		MainTab = Window:CreateTab("Main", nil)
		statusPara = MainTab:CreateParagraph({ Title = "Status (idle)", Content = "idle" })
		MainTab:CreateToggle({
			Name = "Auto Throw (perfect 20)",
			CurrentValue = false,
			Flag = "ThrowToggle",
			Callback = function(state)
				State.throw = state
				blockVanillaThrow(state and not State.tapMode)
				refresh()
			end,
		})
		MainTab:CreateToggle({
			Name = "Auto Equip Best",
			CurrentValue = false,
			Flag = "EquipToggle",
			Callback = function(state) State.equip = state refresh() end,
		})
		MainTab:CreateToggle({
			Name = "Auto Upgrade Base (fence)",
			CurrentValue = false,
			Flag = "FenceToggle",
			Callback = function(state) State.fence = state refresh() end,
		})
		MainTab:CreateToggle({
			Name = "Auto Upgrade Bar (stand)",
			CurrentValue = false,
			Flag = "StandToggle",
			Callback = function(state) State.stand = state refresh() end,
		})
		MainTab:CreateToggle({
			Name = "FULL CYCLE (throws -> train -> upgrade -> shop)",
			CurrentValue = false,
			Flag = "CycleToggle",
			Callback = function(state) setCycle(state) end,
		})
		MainTab:CreateSlider({
			Name = "Throws Before Train",
			Range = { 5, 50 },
			Increment = 5,
			CurrentValue = 10,
			Flag = "ThrowsBeforeTrain",
			Callback = function(value) CFG.throwsBeforeTrain = value end,
		})
		MainTab:CreateSlider({
			Name = "Train Seconds",
			Range = { 30, 300 },
			Increment = 30,
			CurrentValue = 60,
			Flag = "TrainSeconds",
			Callback = function(value) CFG.trainSeconds = value end,
		})
		MainTab:CreateToggle({
			Name = "Shop Buy (buy next food in cycle)",
			CurrentValue = true,
			Flag = "ShopBuyToggle",
			Callback = function(state) CFG.shopBuy = state refresh() end,
		})
		MainTab:CreateToggle({
			Name = "Tap Mode (real meter click)",
			CurrentValue = false,
			Flag = "TapModeToggle",
			Callback = function(state)
				State.tapMode = state
				blockVanillaThrow(State.throw and not state)
				refresh()
			end,
		})
		MainTab:CreateButton({
			Name = "FULL AUTO (all on)",
			Callback = function()
				setAll(not (State.throw and State.equip and State.fence and State.stand))
			end,
		})
		MainTab:CreateButton({
			Name = "Set Max Throw Power",
			Callback = function()
				local ok, msg = maxThrowPower()
				State.lastReason = tostring(ok and msg or msg)
				refresh()
			end,
		})
		MainTab:CreateButton({
			Name = "STOP ALL",
			Callback = function() stopAll() end,
		})
		MainTab:CreateButton({
			Name = "Unload Script",
			Callback = function() unload() end,
		})
		_loadingLabel.Text = "Rayfield loaded OK - turn on Auto Throw"
		pcall(function() Rayfield:Notify({ Title = "Throw Food Auto", Content = "Loaded. Turn on Auto Throw in the Main tab.", Duration = 5 }) end)
	else
		useRayfield = false
	end
end

if not useRayfield then
	-- Original draggable panel, unchanged, as the fallback UI.
local function buildSimpleUI()
	local function parentGui()
		local ok, hui = pcall(function()
			return gethui and gethui() or nil
		end)
		if ok and hui then
			return hui
		end
		return player:WaitForChild("PlayerGui")
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "OlliEThrowAuto"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = parentGui()

	local function corner(inst, r)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, r)
		c.Parent = inst
	end

	local function stroke(inst, color)
		local s = Instance.new("UIStroke")
		s.Color = color
		s.Thickness = 1
		s.Transparency = 0.45
		s.Parent = inst
		return s
	end

	local frame = Instance.new("Frame")
	frame.Name = "Panel"
	frame.Size = UDim2.fromOffset(292, 420)
	frame.Position = UDim2.new(0, 24, 0.5, -210)
	frame.BackgroundColor3 = Color3.fromRGB(18, 20, 22)
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.Draggable = true
	frame.Parent = gui
	corner(frame, 12)
	stroke(frame, Color3.fromRGB(70, 70, 70))

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -20, 0, 26)
	title.Position = UDim2.fromOffset(12, 8)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextColor3 = Color3.fromRGB(235, 235, 235)
	title.Text = "THROW FOOD - AUTO  [RightCtrl]"
	title.Parent = frame

	statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(1, -24, 0, 34)
	statusLabel.Position = UDim2.fromOffset(12, 36)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Font = Enum.Font.Code
	statusLabel.TextSize = 12
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextYAlignment = Enum.TextYAlignment.Top
	statusLabel.TextColor3 = Color3.fromRGB(140, 200, 140)
	statusLabel.Text = "idle"
	statusLabel.Parent = frame

	local function makeButton(text, y, height)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(1, -24, 0, height or 30)
		b.Position = UDim2.fromOffset(12, y)
		b.BackgroundColor3 = Color3.fromRGB(34, 37, 41)
		b.BorderSizePixel = 0
		b.AutoButtonColor = true
		b.Font = Enum.Font.GothamSemibold
		b.TextSize = 12
		b.TextColor3 = Color3.fromRGB(220, 220, 220)
		b.Text = text
		b.Parent = frame
		corner(b, 8)
		stroke(b, Color3.fromRGB(60, 63, 68))
		return b
	end

	local function paint(button, on)
		if on then
			button.BackgroundColor3 = Color3.fromRGB(38, 74, 46)
			button.TextColor3 = Color3.fromRGB(170, 255, 190)
		else
			button.BackgroundColor3 = Color3.fromRGB(34, 37, 41)
			button.TextColor3 = Color3.fromRGB(220, 220, 220)
		end
	end

	local labels = {
		{ key = "throw", text = "Auto Throw (perfect 20)", y = 78 },
		{ key = "equip", text = "Auto Equip Best", y = 114 },
		{ key = "fence", text = "Auto Upgrade Base (fence)", y = 150 },
		{ key = "stand", text = "Auto Upgrade Bar (stand)", y = 186 },
	}

	local buttons = {}
	for _, spec in ipairs(labels) do
		local b = makeButton(spec.text, spec.y)
		buttons[spec.key] = b
		paint(b, State[spec.key])
		b.MouseButton1Click:Connect(function()
			if State.cycle then return end
			State[spec.key] = not State[spec.key]
			paint(b, State[spec.key])
			if spec.key == "throw" then
				blockVanillaThrow(State.throw and not State.tapMode)
			end
			refresh()
		end)
	end

	local cycleBtn = makeButton("", 254, 30)
	local function paintCycle()
		if State.cycle then
			cycleBtn.Text = ("CYCLE: ON  %dx throws | %ds train"):format(CFG.throwsBeforeTrain, CFG.trainSeconds)
			cycleBtn.BackgroundColor3 = Color3.fromRGB(38, 74, 46)
			cycleBtn.TextColor3 = Color3.fromRGB(170, 255, 190)
		else
			cycleBtn.Text = "CYCLE: OFF  (full auto loop)"
			cycleBtn.BackgroundColor3 = Color3.fromRGB(34, 37, 41)
			cycleBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
		end
	end
	paintCycle()
	cycleBtn.MouseButton1Click:Connect(function()
		setCycle(not State.cycle)
		paintCycle()
	end)

	local full = makeButton("FULL AUTO  (all on)", 288)
	corner(full, 8)
	full.BackgroundColor3 = Color3.fromRGB(52, 90, 60)
	full.TextColor3 = Color3.fromRGB(210, 255, 220)
	full.MouseButton1Click:Connect(function()
		local on = not (State.throw and State.equip and State.fence and State.stand)
		State.throw, State.equip, State.fence, State.stand = on, on, on, on
		blockVanillaThrow(on and not State.tapMode)
		for _, spec in ipairs(labels) do
			paint(buttons[spec.key], State[spec.key])
		end
		refresh()
	end)

	local modeBtn = makeButton("", 222, 26)
	local function paintMode()
		if State.tapMode then
			modeBtn.Text = "mode: TAP (real meter click)"
			modeBtn.BackgroundColor3 = Color3.fromRGB(48, 44, 30)
			modeBtn.TextColor3 = Color3.fromRGB(255, 230, 160)
		else
			modeBtn.Text = "mode: DIRECT (remote invoke)"
			modeBtn.BackgroundColor3 = Color3.fromRGB(34, 37, 41)
			modeBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
		end
	end
	paintMode()
	modeBtn.MouseButton1Click:Connect(function()
		State.tapMode = not State.tapMode
		blockVanillaThrow(State.throw and not State.tapMode)
		paintMode()
		refresh()
	end)

	local power = makeButton("Set max throw power", 322, 28)
	power.MouseButton1Click:Connect(function()
		local ok, msg = maxThrowPower()
		State.lastReason = tostring(ok and msg or msg)
		refresh()
	end)

	local stop = makeButton("STOP ALL", 354, 28)
	stop.BackgroundColor3 = Color3.fromRGB(76, 34, 34)
	stop.TextColor3 = Color3.fromRGB(255, 200, 200)
	stop.MouseButton1Click:Connect(function()
		State.throw, State.equip, State.fence, State.stand, State.cycle = false, false, false, false, false
		State.cycleStep = "idle"
		blockVanillaThrow(false)
		for _, spec in ipairs(labels) do
			paint(buttons[spec.key], false)
		end
		paintCycle()
		State.lastReason = "stopped"
		refresh()
	end)

	statsLabel = Instance.new("TextLabel")
	statsLabel.Size = UDim2.new(1, -24, 0, 24)
	statsLabel.Position = UDim2.fromOffset(12, 386)
	statsLabel.BackgroundTransparency = 1
	statsLabel.Font = Enum.Font.Code
	statsLabel.TextSize = 11
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
	statsLabel.Text = ""
	statsLabel.Parent = frame


	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.RightControl then
			frame.Visible = not frame.Visible
		end
	end)
	return gui
end

	simpleGui = buildSimpleUI()
	_loadingLabel.Text = "Rayfield failed - simple GUI loaded"
end

task.spawn(function()
	task.wait(5)
	pcall(function() _loadingGui:Destroy() end)
end)


--------------------------------------------------------------------------------
-- loops
--------------------------------------------------------------------------------

task.spawn(function()
	while not unloaded do
		if State.throw and not State.cycle then
			local ok, res
			if State.tapMode then
				ok, res = tapThrow()
			else
				ok, res = throwOnce()
			end
			if ok then
				State.throws += 1
				State.perfects += 1
				State.lastReason = ("perfect +%d studs"):format(math.floor(20 * CFG.perfectValue + 0.5))
			else
				State.lastReason = tostring(res)
				task.wait(0.5)
			end
			refresh()
		end
		task.wait(CFG.throwGap)
	end
end)

task.spawn(function()
	while not unloaded do
		if State.equip and not State.cycle then
			local ok, reason = equipBestPass()
			State.lastReason = ok and "equipped best" or ("equip: " .. tostring(reason))
			refresh()
			task.wait(CFG.equipEvery)
		else
			task.wait(0.25)
		end
	end
end)

task.spawn(function()
	while not unloaded do
		if State.fence and not State.cycle then
			local ok, reason = upgradeFencePass()
			if ok then
				State.lastReason = "base upgraded"
			elseif reason == "Money" then
				State.lastReason = "base maxed / no money"
			else
				State.lastReason = "base: " .. tostring(reason)
			end
			refresh()
			task.wait(CFG.upgradeEvery)
		else
			task.wait(0.25)
		end
	end
end)

task.spawn(function()
	while not unloaded do
		if State.stand and not State.cycle then
			local ok, reason = upgradeStandPass()
			if ok then
				State.lastReason = "bar upgraded"
			elseif reason == "Money" then
				State.lastReason = "bar maxed / no money"
			else
				State.lastReason = "bar: " .. tostring(reason)
			end
			refresh()
			task.wait(CFG.upgradeEvery)
		else
			task.wait(0.25)
		end
	end
end)

-- CYCLE controller (from FullyAuto): throws -> equip -> train -> upgrade stand -> shop -> repeat
task.spawn(function()
	while not unloaded do
		if not State.cycle then
			task.wait(0.3)
		else
			-- 1. N perfect throws
			State.cycleStep = ("throw x%d"):format(CFG.throwsBeforeTrain)
			refresh()
			for i = 1, CFG.throwsBeforeTrain do
				if not State.cycle then break end
				local ok, res
				if State.tapMode then ok, res = tapThrow() else ok, res = throwOnce() end
				if ok then
					State.throws += 1
					State.perfects += 1
					State.lastReason = ("throw %d/%d perfect"):format(i, CFG.throwsBeforeTrain)
				else
					State.lastReason = ("throw %d: %s"):format(i, tostring(res))
					task.wait(0.4)
				end
				refresh()
				task.wait(CFG.throwGap)
			end

			-- 2. equip best
			if State.cycle then
				State.cycleStep = "equip"
				refresh()
				local eqOk, eqReason = equipBestPass()
				State.lastReason = eqOk and "equipped best" or ("equip: " .. tostring(eqReason))
				refresh()
				task.wait(0.3)
			end

			-- 3. walk to stand + train
			if State.cycle then
				State.cycleStep = ("train %ds"):format(CFG.trainSeconds)
				refresh()
				local trOk, trReason = trainPass(CFG.trainSeconds)
				State.lastReason = trOk and tostring(trReason) or ("train: " .. tostring(trReason))
				refresh()
			end

			-- 4. upgrade stand
			if State.cycle then
				State.cycleStep = "upgrade stand"
				refresh()
				local upOk, upReason = upgradeStandPass()
				State.lastReason = upOk and "bar upgraded"
					or (upReason == "Money" and "bar maxed / no money" or ("bar: " .. tostring(upReason)))
				refresh()
				task.wait(0.3)
			end

			-- 5. walk to shop + try buy next food
			if State.cycle and CFG.shopBuy then
				State.cycleStep = "shop"
				refresh()
				local shOk, shReason = shopBuyPass()
				State.lastReason = shOk and tostring(shReason) or ("shop: " .. tostring(shReason))
				refresh()
			end

			State.cycleStep = "cycle pause"
			refresh()
			task.wait(CFG.cyclePause)
		end
	end
end)

refresh()
print("[olliE] throw auto loaded (Rayfield" .. (useRayfield and "" or " FAILED - simple GUI") .. " + FULL CYCLE) - meterDelay " .. string.format("%.4f", meterDelay) .. "s shop_remote=" .. (shopBuyR and "yes" or "MISSING") .. " train_remote=" .. (trainR and "yes" or "none"))
