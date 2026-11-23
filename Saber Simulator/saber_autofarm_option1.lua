-- Saber Simulator - Auto-Swing + Auto-Sell + Auto-Buy Saber (MAIN script, v6 - WindUI)
-- GUI: WindUI by Footagesus - https://github.com/Footagesus/WindUI
--   local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()
--   Minimize/reopen: RightShift (WindUI toggle key) or the floating Open button | Unload: "Unload Script" button in the Main tab
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

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Events = ReplicatedStorage:WaitForChild("Events")
local SwingSaber = Events:WaitForChild("SwingSaber")
local SellStrength = Events:WaitForChild("SellStrength")
local UIAction = Events:WaitForChild("UIAction")

-- ===== SETTINGS =====
local SWING_DELAY = 0.25
local SELL_EVERY_SWINGS = 50
local SELL_EVERY_SECONDS = 10
local AUTO_BUY = true
local BUY_CHECK_EVERY = 5
local BUY_ACTION = "BuyWeapon" -- CONFIRMED by RemoteSpy: UIAction:FireServer("BuyWeapon", "Daze")
-- ====================

local running = false
local unloaded = false -- set to true by the Unload button, all loops check this and stop
local swingCount = 0
local lastSell = tick()

-- ===== WINDUI GUI =====
local WindUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua"))()

local Window = WindUI:CreateWindow({
	Title = "Saber Simulator",
	Folder = "SaberAutoFarm",
	Icon = "swords",
	NewElements = true,
	OpenButton = {
		Title = "Open Saber UI",
		Enabled = true, -- floating button to reopen after minimizing
		Draggable = true,
	},
	Topbar = {
		ButtonsType = "Mac", -- minimize / close buttons in the top bar
	},
})
pcall(function() Window:SetToggleKey(Enum.KeyCode.RightShift) end) -- RightShift = minimize / reopen

local MainTab = Window:Tab({
	Title = "Main",
	Icon = "swords",
})

local statusPara = MainTab:Paragraph({
	Title = "Status",
	Desc = "Stopped | Swings: 0",
})

local buyPara = MainTab:Paragraph({
	Title = "Buy",
	Desc = "Auto-Buy: ON - waiting for first check (every 5s while running)",
})

-- Paragraph update methods vary by WindUI version, so try each in pcall
-- and fall back to the console print (status is always printed there too).
local function updateStatus(text)
	pcall(function() statusPara:SetDesc(text) end)
	pcall(function() statusPara:SetTitle(text) end)
end
local function updateBuyInfo(text)
	pcall(function() buyPara:SetDesc(text) end)
	pcall(function() buyPara:SetTitle(text) end)
end

local autoFarmToggle = nil -- created in the controls section below

local function unload()
	if unloaded then return end
	unloaded = true
	running = false
	print("[AutoFarm] Unloaded - all loops stopped, GUI removed. Re-run the loadstring to start again.")
	pcall(function() Window:Destroy() end)
end

local function setRunning(value)
	if unloaded then return end
	running = value
	if running then
		updateStatus("Running | Swings: " .. swingCount)
	else
		updateStatus("Stopped | Swings: " .. swingCount)
	end
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
local InfiniteMath = require(ReplicatedStorage.Modules.InfiniteMath)

local clientData = nil
local buyCursor = 1 -- persistent cursor for the blind cycle: moves through ALL sabers, wraps to 1
local lastBuyTarget = nil

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
		pcall(function() WindUI:Notify({ Title = "Auto-Buy", Content = "Buying " .. target, Icon = "check" }) end)
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

-- ===== WINDUI CONTROLS (Main tab) =====
autoFarmToggle = MainTab:Toggle({
	Title = "Auto-Farm (Swing + Sell)",
	Value = false,
	Callback = function(state) setRunning(state) end,
})

MainTab:Toggle({
	Title = "Auto-Buy Best Saber",
	Value = true,
	Callback = function(state)
		AUTO_BUY = state
		updateBuyInfo(AUTO_BUY and "Auto-Buy: ON" or "Auto-Buy: OFF")
	end,
})

MainTab:Slider({
	Title = "Swing Delay (seconds)",
	Step = 0.05,
	Value = { Min = 0.1, Max = 1, Default = 0.25 },
	Callback = function(value) SWING_DELAY = value end,
})

MainTab:Slider({
	Title = "Sell Every (swings)",
	Step = 1,
	Value = { Min = 10, Max = 200, Default = 50 },
	Callback = function(value) SELL_EVERY_SWINGS = value end,
})

MainTab:Slider({
	Title = "Buy Check (seconds)",
	Step = 1,
	Value = { Min = 2, Max = 30, Default = 5 },
	Callback = function(value) BUY_CHECK_EVERY = value end,
})

MainTab:Button({
	Title = "Buy Best Saber Now",
	Callback = function() tryBuySaber() end,
})

MainTab:Button({
	Title = "Unload Script",
	Callback = function() unload() end,
})

task.spawn(function()
	while not unloaded do
		task.wait(BUY_CHECK_EVERY)
		if unloaded then break end
		if running then tryBuySaber() end
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

WindUI:Notify({ Title = "Saber Auto-Farm", Content = "Loaded. Turn on Auto-Farm in the Main tab.", Icon = "check" })
print("[AutoFarm] Loaded v6 (WindUI + InfiniteMath Coins fix). Minimize: RightShift or the floating Open button. Unload: button in Main tab.")
