-- Saber Simulator - Auto-Swing + Auto-Sell + Auto-Buy Saber + Auto-Buy DNA (MAIN script, v8 - Rayfield)
-- v7: GUI switched to Rayfield (Sirius) - https://docs.sirius.menu/rayfield/
--   local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()
--   Rayfield is the most-used UI on mobile executors, with a built-in
--   minimize button in the top bar. Unload: "Unload Script" button in Main tab.
-- Mobile: the user is on MOBILE and can't see the console, so ALL
-- diagnostics are ON-SCREEN, not console-only. The loading label stays
-- up for 5 seconds saying Rayfield OK / Rayfield failed, and the simple GUI's
-- status line shows Coins / current saber / last buy, so buying can be
-- checked without opening a console. No keyboard needed on mobile:
-- use the on-screen toggle/button, not F or RightShift.
-- Based ONLY on ReplicatedStorage export (Saber.zip)
--   ReplicatedStorage/Events/SwingSaber   -> gains Strength
--   ReplicatedStorage/Events/SellStrength -> converts Strength to Coins
--   StatsCalculator.GetStrengthGain = floor(Swords[Saber].AmountPerClick * StrengthMulti)
--   ItemInfo.Swords[name].Price = Coins price, ItemInfo.Swords_Order = sabers sorted by AmountPerClick (VIP excluded)
--
-- ROOT CAUSE found in the export (why v3/v4 didn't buy):
--   Coins in this game are NOT plain numbers. StatsCalculator uses
--   InfiniteMath for Coins/Strength (values are tables {first, second} or
--   strings like "1,234"), so tonumber(Coins) returns nil and the old code
--   thought Coins were "unknown" forever. It then only ever tried the first
--   10 sabers (Starter..Cursed) - which you already own if you're past them -
--   and never reached your real next saber.
--   v5 fixes it: it reads Coins with the game's own InfiniteMath module,
--   compares Coins >= Price with InfiniteMath, detects your current saber
--   from Best_Saber_Index AND from your Backpack/Character tools, and if
--   Coins still can't be read it cycles through ALL 449 sabers in batches
--   of 20 instead of only the first 10.
--
-- CONFIRMED by RemoteSpy (2026-11-23, your capture):
--   UIAction:FireServer("BuyWeapon", "Daze")
--   So the buy action is "BuyWeapon" with the saber name as arg 2.
--   * Cooldown / server rate-limit is UNKNOWN (server-side, not in the export).

-- Loading indicator FIRST - before any WaitForChild / HttpGet that could hang
print("[AutoFarm] Script file loaded - starting...")
local _loadingGui = Instance.new("ScreenGui")
_loadingGui.Name = "SaberAutoFarmLoading"
_loadingGui.ResetOnSpawn = false
_loadingGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local _loadingLabel = Instance.new("TextLabel")
_loadingLabel.Size = UDim2.new(0, 260, 0, 40)
_loadingLabel.Position = UDim2.new(0.5, -130, 0, 20)
_loadingLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
_loadingLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
_loadingLabel.TextSize = 16
_loadingLabel.Font = Enum.Font.SourceSansBold
_loadingLabel.Text = "Saber Auto-Farm loading..."
_loadingLabel.Parent = _loadingGui
pcall(function() _loadingGui.Parent = game:GetService("CoreGui") end)
if not _loadingGui.Parent then
	pcall(function() _loadingGui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui") end)
end

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
-- WaitForChild with a 10s timeout each - the old code waited FOREVER here,
-- so if Events didn't exist the script hung silently with nothing on screen.
local Events = ReplicatedStorage:WaitForChild("Events", 10)
if not Events then
	_loadingLabel.Text = "ERROR: no Events in ReplicatedStorage - wrong game?"
	warn("[AutoFarm] ERROR: ReplicatedStorage.Events not found after 10s - are you in Saber Simulator?")
	return
end
print("[AutoFarm] Events found")
local SwingSaber = Events:WaitForChild("SwingSaber", 10)
local SellStrength = Events:WaitForChild("SellStrength", 10)
local UIAction = Events:WaitForChild("UIAction", 10)
if not (SwingSaber and SellStrength and UIAction) then
	_loadingLabel.Text = "ERROR: missing SwingSaber / SellStrength / UIAction"
	warn("[AutoFarm] ERROR: a remote is missing - SwingSaber=" .. tostring(SwingSaber) .. " SellStrength=" .. tostring(SellStrength) .. " UIAction=" .. tostring(UIAction))
	return
end
print("[AutoFarm] Remotes found")

-- ===== SETTINGS =====
local SWING_DELAY = 0.25
local SELL_EVERY_SWINGS = 50
local SELL_EVERY_SECONDS = 10
local AUTO_BUY = true
local AUTO_BUY_DNA = false -- Auto-Buy DNA is an OPTION, off by default (it spends the same Coins as sabers)
local BUY_CHECK_EVERY = 5
local BUY_DNA_ACTION = "BuyDNA" -- NOT confirmed yet (see tryBuyDNA below)
local BUY_ACTION = "BuyWeapon" -- CONFIRMED by RemoteSpy: UIAction:FireServer("BuyWeapon", "Daze")
-- ====================

local running = false
local unloaded = false -- set to true by the Unload button, all loops check this and stop
local swingCount = 0
local lastSell = tick()

-- ===== RAYFIELD GUI (with fallback) =====
-- Rayfield is loaded in pcall: if that one loadstring fails, the script
-- prints what happened and falls back to a simple built-in GUI so the farm
-- still loads and works. No more silent "not loading".
print("[AutoFarm] Starting... loading Rayfield...")
local useRayfield = false
local Rayfield, Window, MainTab, statusPara, buyPara, dnaPara
local rayOk, rayResult = pcall(function()
	return loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
end)
if rayOk and rayResult then
	Rayfield = rayResult
	local winOk, winResult = pcall(function()
		return Rayfield:CreateWindow({
			Name = "Saber Simulator | Auto-Farm",
			LoadingTitle = "Saber Simulator",
			LoadingSubtitle = "Auto-Farm",
			ConfigurationSaving = { Enabled = false },
			KeySystem = false,
		})
	end)
	if winOk and winResult then
		Window = winResult
		useRayfield = true
		print("[AutoFarm] Rayfield loaded OK")
		MainTab = Window:CreateTab("Main", nil)
		statusPara = MainTab:CreateParagraph({ Title = "Status", Content = "Stopped | Swings: 0" })
		buyPara = MainTab:CreateParagraph({ Title = "Buy", Content = "Auto-Buy: ON - waiting for first check (every 5s while running)" })
		dnaPara = MainTab:CreateParagraph({ Title = "DNA", Content = "Auto-Buy DNA: OFF - turn it on in the Main tab" })
	else
		print("[AutoFarm] Rayfield window failed: " .. tostring(winResult) .. " - using simple GUI instead")
	end
else
	print("[AutoFarm] Rayfield load failed: " .. tostring(rayResult) .. " - using simple GUI instead")
end

-- Simple fallback GUI (used only if Rayfield fails - same START / X / minimize as v5)
local simpleGui, simpleButton, simpleStatus, simpleFrame, simpleMiniBtn
if not useRayfield then
	simpleGui = Instance.new("ScreenGui")
	simpleGui.Name = "SaberAutoFarm"
	simpleGui.ResetOnSpawn = false
	simpleGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	simpleFrame = Instance.new("Frame")
	simpleFrame.Size = UDim2.new(0, 220, 0, 120)
	simpleFrame.Position = UDim2.new(0, 16, 0, 120)
	simpleFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	simpleFrame.BorderSizePixel = 0
	simpleFrame.Parent = simpleGui
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -64, 0, 24)
	title.Position = UDim2.new(0, 8, 0, 0)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 14
	title.Font = Enum.Font.SourceSansBold
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Saber Auto-Farm"
	title.Parent = simpleFrame
	local minBtn = Instance.new("TextButton")
	minBtn.Size = UDim2.new(0, 24, 0, 24)
	minBtn.Position = UDim2.new(1, -56, 0, 0)
	minBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
	minBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	minBtn.TextSize = 16
	minBtn.Font = Enum.Font.SourceSansBold
	minBtn.Text = "–"
	minBtn.Parent = simpleFrame
	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0, 24, 0, 24)
	closeBtn.Position = UDim2.new(1, -28, 0, 0)
	closeBtn.BackgroundColor3 = Color3.fromRGB(170, 40, 40)
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.TextSize = 16
	closeBtn.Font = Enum.Font.SourceSansBold
	closeBtn.Text = "X"
	closeBtn.Parent = simpleFrame
	simpleMiniBtn = Instance.new("TextButton")
	simpleMiniBtn.Size = UDim2.new(0, 64, 0, 28)
	simpleMiniBtn.Position = UDim2.new(0, 16, 0, 120)
	simpleMiniBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	simpleMiniBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	simpleMiniBtn.TextSize = 14
	simpleMiniBtn.Font = Enum.Font.SourceSansBold
	simpleMiniBtn.Text = "Saber +"
	simpleMiniBtn.Visible = false
	simpleMiniBtn.Parent = simpleGui
	simpleButton = Instance.new("TextButton")
	simpleButton.Size = UDim2.new(0, 184, 0, 36)
	simpleButton.Position = UDim2.new(0, 8, 0, 28)
	simpleButton.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
	simpleButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	simpleButton.TextSize = 16
	simpleButton.Font = Enum.Font.SourceSansBold
	simpleButton.Text = "START Auto-Farm"
	simpleButton.Parent = simpleFrame
	simpleStatus = Instance.new("TextLabel")
	simpleStatus.Size = UDim2.new(1, -16, 0, 44)
	simpleStatus.Position = UDim2.new(0, 8, 0, 68)
	simpleStatus.BackgroundTransparency = 1
	simpleStatus.TextColor3 = Color3.fromRGB(255, 255, 255)
	simpleStatus.TextSize = 13
	simpleStatus.TextWrapped = true
	simpleStatus.Text = "Stopped | Swings: 0"
	simpleStatus.Parent = simpleFrame
	pcall(function() simpleGui.Parent = game:GetService("CoreGui") end)
	if not simpleGui.Parent then simpleGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end
	minBtn.MouseButton1Click:Connect(function() simpleFrame.Visible = false simpleMiniBtn.Visible = true end)
	simpleMiniBtn.MouseButton1Click:Connect(function() simpleFrame.Visible = true simpleMiniBtn.Visible = false end)
	-- closeBtn / simpleButton are wired below, after unload() / setRunning() exist
end

-- Paragraph update methods vary by Rayfield version, so try each in pcall
-- and fall back to the console print (status is always printed there too).
-- Rayfield paragraph: Set({Title=..., Content=...}) - try that first,
-- then other spellings, all in pcall so a missing method never breaks the farm.
local function updateStatus(text)
	if useRayfield and statusPara then
		pcall(function() statusPara:Set({ Title = "Status", Content = text }) end)
		pcall(function() statusPara:SetTitle(text) end)
	elseif simpleStatus then
		pcall(function() simpleStatus.Text = text end)
	end
end
local function updateBuyInfo(text)
	if useRayfield and buyPara then
		pcall(function() buyPara:Set({ Title = "Buy", Content = text }) end)
		pcall(function() buyPara:SetTitle(text) end)
	elseif simpleStatus then
		-- Mobile: show buy info on the simple GUI itself, no console needed
		pcall(function() simpleStatus.Text = text end)
	end
end
local function updateDNAInfo(text)
	if useRayfield and dnaPara then
		pcall(function() dnaPara:Set({ Title = "DNA", Content = text }) end)
		pcall(function() dnaPara:SetTitle(text) end)
	elseif simpleStatus then
		pcall(function() simpleStatus.Text = text end)
	end
end

local autoFarmToggle = nil -- created in the controls section below (Rayfield only)

local function unload()
	if unloaded then return end
	unloaded = true
	running = false
	print("[AutoFarm] Unloaded - all loops stopped, GUI removed. Re-run the loadstring to start again.")
	if useRayfield and Rayfield then pcall(function() Rayfield:Destroy() end) end
	if simpleGui then pcall(function() simpleGui:Destroy() end) end
end

local function setRunning(value)
	if unloaded then return end
	running = value
	if simpleButton then
		simpleButton.Text = running and "STOP Auto-Farm" or "START Auto-Farm"
		simpleButton.BackgroundColor3 = running and Color3.fromRGB(170, 40, 40) or Color3.fromRGB(50, 50, 50)
	end
	if running then
		updateStatus("Running | Swings: " .. swingCount)
	else
		updateStatus("Stopped | Swings: " .. swingCount)
	end
end

if simpleGui then
	-- wire the fallback GUI buttons now that unload/setRunning exist
	for _, child in ipairs(simpleFrame:GetChildren()) do
		if child:IsA("TextButton") and child.Text == "X" then
			child.MouseButton1Click:Connect(unload)
		end
	end
	simpleButton.MouseButton1Click:Connect(function() setRunning(not running) end)
end

-- Toggles / sliders are created after the buy functions below, because
-- the "Buy Now" button needs tryBuySaber - see the GUI controls section
-- at the end of the buy code. setRunning / unload are defined here so
-- those controls can call them.

local function doSell(reason)
	local ok, err = pcall(function() SellStrength:FireServer() end)
	if ok then swingCount = 0 lastSell = tick() print("[AutoFarm] Sold Strength (" .. reason .. ")")
	else warn("[AutoFarm] Sell failed: " .. tostring(err)) end
end

game:GetService("UserInputService").InputBegan:Connect(function(input, g)
	if g or unloaded then return end
	if input.KeyCode == Enum.KeyCode.F then
		setRunning(not running)
		if autoFarmToggle then pcall(function() autoFarmToggle:Set(running) end) end
	end
end)

-- ===== AUTO-BUY SABER (v5: InfiniteMath Coins) =====
local ItemInfo = require(ReplicatedStorage.Modules.ItemInfo)
local Swords = ItemInfo.Swords
local SwordsOrder = ItemInfo.Swords_Order
local DNAs = ItemInfo.DNAs
local DNAsOrder = ItemInfo.DNAs_Order -- sorted by MaxStorage, VIP DNA + Infinite excluded
local InfiniteMath = require(ReplicatedStorage.Modules.InfiniteMath)

local clientData = nil
local buyCursor = 1 -- persistent cursor for the blind cycle: moves through ALL sabers, wraps to 1
local dnaCursor = 1 -- same for DNA
local lastBuyTarget = nil
local lastBuyDNATarget = nil

local function indexOfSaber(name)
	for i, n in ipairs(SwordsOrder) do if n == name then return i end end
	return 0
end

pcall(function()
	Events.UpdateClientData.OnClientEvent:Connect(function(data)
		if type(data) ~= "table" then return end
		clientData = data
		local saber = data.Saber or data.CurrentSaber or data.EquippedSaber
		if saber and lastBuyTarget and saber == lastBuyTarget then
			print("[AutoFarm] Bought saber confirmed: " .. saber)
			lastBuyTarget = nil
		end
	end)
	Events.RequestClientData:FireServer()
end)

-- Coins are InfiniteMath values in this game (table {first, second} or
-- a string like "1,234"), NOT plain numbers - tonumber() returns nil on them.
-- Convert any form to an InfiniteMath value, or nil if we truly can't read it.
local function toIM(value)
	if value == nil then return nil end
	local ok, im = pcall(function() return InfiniteMath.new(value) end)
	if ok and im then return im end
	if type(value) == "string" then
		-- "1.23K" / "12.3M" style - strip suffix, tonumber the front part
		local num = tonumber((value:gsub(",", ""):gsub("[KMBtqQ]", "")))
		if num then
			local ok2, im2 = pcall(function() return InfiniteMath.new(num) end)
			if ok2 then return im2 end
		end
	end
	return nil
end

local function getCoinsIM()
	local ls = Players.LocalPlayer:FindFirstChild("leaderstats")
	if ls then
		local c = ls:FindFirstChild("Coins")
		if c then
			local im = toIM(c.Value)
			if im then return im, "leaderstats (" .. typeof(c.Value) .. ")" end
		end
	end
	if clientData then
		local raw = clientData.Coins or clientData.coins
		if raw ~= nil then
			local im = toIM(raw)
			if im then return im, "clientData (" .. typeof(raw) .. ")" end
			-- Still unknown, but print the type once so the console shows WHY
			print("[AutoFarm] Coins raw type=" .. typeof(raw) .. " value=" .. tostring(raw))
		end
		if clientData.Data then
			local im = toIM(clientData.Data.Coins)
			if im then return im, "clientData.Data" end
		end
	end
	return nil, nil
end

local function getCurrentSaber()
	if clientData then
		-- StatsCalculator uses data.Saber (string) and data.Best_Saber_Index (number)
		if clientData.Saber then return clientData.Saber end
		if clientData.CurrentSaber then return clientData.CurrentSaber end
		if clientData.EquippedSaber then return clientData.EquippedSaber end
		if clientData.Best_Saber_Index then
			local name = SwordsOrder[clientData.Best_Saber_Index]
			if name then return name end
		end
	end
	-- Fallback: the equipped saber is a Tool in your Backpack / Character
	local lp = Players.LocalPlayer
	for _, container in ipairs({ lp:FindFirstChild("Backpack"), lp.Character }) do
		if container then
			for _, tool in ipairs(container:GetChildren()) do
				if tool:IsA("Tool") and Swords[tool.Name] then return tool.Name end
			end
		end
	end
	return nil
end

local function tryBuySaber()
	if not AUTO_BUY or unloaded then return end
	local coinsIM, coinsSource = getCoinsIM()
	local current = getCurrentSaber()
	local currentGain = (current and Swords[current] and Swords[current].AmountPerClick) or 0
	print("[AutoFarm] Buy check: Coins=" .. (coinsIM and tostring(coinsIM) or "UNKNOWN") .. " source=" .. tostring(coinsSource) .. " current=" .. tostring(current))
	updateBuyInfo("Coins: " .. (coinsIM and tostring(coinsIM) or "UNKNOWN") .. " | Current: " .. tostring(current))

	if coinsIM then
		-- Best affordable saber BETTER than current, compared with InfiniteMath
		local target = nil
		for _, name in ipairs(SwordsOrder) do
			local info = Swords[name]
			if info and info.AmountPerClick > currentGain then
				local priceIM = toIM(info.Price)
				if priceIM and coinsIM >= priceIM then
					if not target or info.AmountPerClick > Swords[target].AmountPerClick then target = name end
				end
			end
		end
		if not target then
			print("[AutoFarm] Buy check: no affordable upgrade yet")
			updateBuyInfo("No affordable upgrade yet | Coins: " .. tostring(coinsIM) .. " | Current: " .. tostring(current))
			return
		end
		print("[AutoFarm] Buying best: " .. target .. " price=" .. tostring(Swords[target].Price))
		updateBuyInfo("Buying: " .. target .. " | Price: " .. tostring(Swords[target].Price))
		if useRayfield then pcall(function() Rayfield:Notify({ Title = "Auto-Buy", Content = "Buying " .. target, Duration = 3 }) end) end
		lastBuyTarget = target
		local args = { BUY_ACTION, target }
		pcall(function() UIAction:FireServer(unpack(args)) end)
	else
		-- Coins STILL unknown: cycle through ALL sabers in batches of 20,
		-- starting where we left off, wrapping around. The server rejects
		-- unaffordable ones and buys affordable ones, wherever you are
		-- in the progression - not just the first 10 cheap ones.
		if current then buyCursor = indexOfSaber(current) + 1 end
		if buyCursor < 1 or buyCursor > #SwordsOrder then buyCursor = 1 end
		local last = math.min(buyCursor + 19, #SwordsOrder)
		print("[AutoFarm] Buy check: Coins unknown - trying sabers " .. buyCursor .. "-" .. last .. " of " .. #SwordsOrder)
		for i = buyCursor, last do
			if unloaded then break end
			local name = SwordsOrder[i]
			print("[AutoFarm] Trying: " .. name .. " price=" .. tostring(Swords[name].Price))
			lastBuyTarget = name
			local args = { BUY_ACTION, name }
			pcall(function() UIAction:FireServer(unpack(args)) end)
			task.wait(0.15)
		end
		buyCursor = last + 1
		if buyCursor > #SwordsOrder then buyCursor = 1 end
	end
end

-- ===== AUTO-BUY DNA (v8) =====
-- From the export: ItemInfo.DNAs[name] = {MaxStorage, Price} (Coins, except
-- VIP DNA which is Robux and is already excluded from DNAs_Order),
-- DNAs_Order is sorted by MaxStorage, current DNA is data.DNA
-- (StatsCalculator uses DNAs[data.DNA]).
-- WARNING - buy action NOT confirmed: the export has no server code, so
-- "BuyDNA" is a guess by analogy with the CONFIRMED "BuyWeapon" for sabers
-- (UIAction:FireServer("BuyWeapon", "Daze")). If DNA doesn't buy, do a
-- RemoteSpy capture of one manual DNA buy in-game and send me that line -
-- it will show the real action name, like it did for sabers.
local function indexOfDNA(name)
	for i, n in ipairs(DNAsOrder) do if n == name then return i end end
	return 0
end

local function getCurrentDNA()
	if clientData then return clientData.DNA or clientData.CurrentDNA or clientData.EquippedDNA end
	return nil
end

local function tryBuyDNA()
	if not AUTO_BUY_DNA or unloaded then return end
	local coinsIM, coinsSource = getCoinsIM()
	local current = getCurrentDNA()
	local currentStorage = (current and DNAs[current] and DNAs[current].MaxStorage) or 0
	print("[AutoFarm] DNA check: Coins=" .. (coinsIM and tostring(coinsIM) or "UNKNOWN") .. " current=" .. tostring(current))
	updateDNAInfo("Coins: " .. (coinsIM and tostring(coinsIM) or "UNKNOWN") .. " | Current: " .. tostring(current))

	if coinsIM then
		-- Best affordable DNA with MORE storage than current, Coins only (skip Robux)
		local target = nil
		for _, name in ipairs(DNAsOrder) do
			local info = DNAs[name]
			if info and info.Currency ~= "Robux" and info.MaxStorage > currentStorage then
				local priceIM = toIM(info.Price)
				if priceIM and coinsIM >= priceIM then
					if not target or info.MaxStorage > DNAs[target].MaxStorage then target = name end
				end
			end
		end
		if not target then
			print("[AutoFarm] DNA check: no affordable upgrade yet")
			updateDNAInfo("No affordable DNA upgrade yet | Coins: " .. tostring(coinsIM) .. " | Current: " .. tostring(current))
			return
		end
		print("[AutoFarm] Buying DNA: " .. target .. " price=" .. tostring(DNAs[target].Price))
		updateDNAInfo("Buying DNA: " .. target .. " | Price: " .. tostring(DNAs[target].Price))
		if useRayfield then pcall(function() Rayfield:Notify({ Title = "Auto-Buy DNA", Content = "Buying " .. target, Duration = 3 }) end) end
		lastBuyDNATarget = target
		local args = { BUY_DNA_ACTION, target }
		pcall(function() UIAction:FireServer(unpack(args)) end)
	else
		-- Coins unknown: cycle through ALL DNAs in batches of 20, like sabers
		if current then dnaCursor = indexOfDNA(current) + 1 end
		if dnaCursor < 1 or dnaCursor > #DNAsOrder then dnaCursor = 1 end
		local last = math.min(dnaCursor + 19, #DNAsOrder)
		print("[AutoFarm] DNA check: Coins unknown - trying DNAs " .. dnaCursor .. "-" .. last .. " of " .. #DNAsOrder)
		for i = dnaCursor, last do
			if unloaded then break end
			local name = DNAsOrder[i]
			if DNAs[name].Currency ~= "Robux" then
				print("[AutoFarm] Trying DNA: " .. name .. " price=" .. tostring(DNAs[name].Price))
				lastBuyDNATarget = name
				local args = { BUY_DNA_ACTION, name }
				pcall(function() UIAction:FireServer(unpack(args)) end)
				task.wait(0.15)
			end
		end
		dnaCursor = last + 1
		if dnaCursor > #DNAsOrder then dnaCursor = 1 end
	end
end

-- ===== RAYFIELD CONTROLS (Main tab) - skipped if Rayfield failed, simple GUI is already wired above =====
if useRayfield then
autoFarmToggle = MainTab:CreateToggle({
	Name = "Auto-Farm (Swing + Sell)",
	CurrentValue = false,
	Flag = "AutoFarmToggle",
	Callback = function(state) setRunning(state) end,
})

MainTab:CreateToggle({
	Name = "Auto-Buy Best Saber",
	CurrentValue = true,
	Flag = "AutoBuyToggle",
	Callback = function(state)
		AUTO_BUY = state
		updateBuyInfo(AUTO_BUY and "Auto-Buy: ON" or "Auto-Buy: OFF")
	end,
})

MainTab:CreateToggle({
	Name = "Auto-Buy DNA",
	CurrentValue = false,
	Flag = "AutoBuyDNAToggle",
	Callback = function(state)
		AUTO_BUY_DNA = state
		updateDNAInfo(AUTO_BUY_DNA and "Auto-Buy DNA: ON" or "Auto-Buy DNA: OFF")
	end,
})

MainTab:CreateSlider({
	Name = "Swing Delay (seconds)",
	Range = { 0.1, 1 },
	Increment = 0.05,
	CurrentValue = 0.25,
	Flag = "SwingDelay",
	Callback = function(value) SWING_DELAY = value end,
})

MainTab:CreateSlider({
	Name = "Sell Every (swings)",
	Range = { 10, 200 },
	Increment = 1,
	CurrentValue = 50,
	Flag = "SellEverySwings",
	Callback = function(value) SELL_EVERY_SWINGS = value end,
})

MainTab:CreateSlider({
	Name = "Buy Check (seconds)",
	Range = { 2, 30 },
	Increment = 1,
	CurrentValue = 5,
	Flag = "BuyCheckEvery",
	Callback = function(value) BUY_CHECK_EVERY = value end,
})

MainTab:CreateButton({
	Name = "Buy Best Saber Now",
	Callback = function() tryBuySaber() end,
})

MainTab:CreateButton({
	Name = "Buy Best DNA Now",
	Callback = function()
		local was = AUTO_BUY_DNA
		AUTO_BUY_DNA = true -- one test buy only, toggle stays as it was
		tryBuyDNA()
		AUTO_BUY_DNA = was
	end,
})

MainTab:CreateButton({
	Name = "Unload Script",
	Callback = function() unload() end,
})
end -- if useRayfield

task.spawn(function()
	while not unloaded do
		task.wait(BUY_CHECK_EVERY)
		if unloaded then break end
		if running then
			tryBuySaber() -- sabers first (priority for Coins)
			if AUTO_BUY_DNA then tryBuyDNA() end
		end
	end
end)

-- Main swing/sell loop
task.spawn(function()
	while not unloaded do
		if running then
			local ok, err = pcall(function() SwingSaber:FireServer() end)
			if ok then
				swingCount += 1
				updateStatus("Running | Swings: " .. swingCount)
				if swingCount >= SELL_EVERY_SWINGS or (tick() - lastSell) >= SELL_EVERY_SECONDS then
					doSell("every " .. SELL_EVERY_SWINGS .. " swings / " .. SELL_EVERY_SECONDS .. "s")
				end
			else warn("[AutoFarm] Swing failed: " .. tostring(err)) task.wait(1) end
			task.wait(SWING_DELAY)
		else task.wait(0.2) end
	end
end)

-- Mobile: keep the loading label on screen for 5s with the result,
-- so it can be read without a console, then remove it.
pcall(function()
	_loadingLabel.Text = useRayfield and "Rayfield loaded OK - turn on Auto-Farm" or "Rayfield failed - simple GUI loaded"
end)
task.spawn(function()
	task.wait(5)
	pcall(function() _loadingGui:Destroy() end)
end)
if useRayfield then
	pcall(function() Rayfield:Notify({ Title = "Saber Auto-Farm", Content = "Loaded. Turn on Auto-Farm in the Main tab.", Duration = 5 }) end)
end
print("[AutoFarm] Loaded v8 (Rayfield + Auto-Buy DNA" .. (useRayfield and "" or " FAILED - simple GUI") .. " + InfiniteMath Coins fix). Minimize: Rayfield top-bar button. Unload: button in Main tab.")
