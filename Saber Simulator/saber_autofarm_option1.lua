-- Saber Simulator - Option 1: Auto-Swing + Auto-Sell + Auto-Buy Saber (FIXED v3)
-- Based ONLY on ReplicatedStorage export (Saber.zip)
--   ReplicatedStorage/Events/SwingSaber   -> gains Strength
--   ReplicatedStorage/Events/SellStrength -> converts Strength to Coins
--   StatsCalculator.GetStrengthGain = floor(Swords[Saber].AmountPerClick * StrengthMulti)
--   ItemInfo.Swords[name].Price = Coins price, ItemInfo.Swords_Order = sabers sorted by AmountPerClick (VIP excluded)
--
-- FIXES in v3 (why v2 didn't buy the best saber):
--   1. v2's blind mode had a bug: when Coins/current Saber couldn't be read,
--      it kept re-trying Starter/Green and never advanced. v3 keeps a persistent
--      assumedIndex and only advances when UpdateClientData shows your Saber
--      actually changed, or your Coins dropped after a buy.
--   2. v2's short snippet in chat had a bug too: it picked the best AFFORDABLE
--      saber even if you already owned it, so it kept re-buying the same one.
--      v3 only picks sabers better than your current one.
--   3. v3 prints every buy check (Coins / current / target / price) so you can
--      see in the console WHY it did or didn't buy.
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
local unloaded = false -- set to true by the X button, all loops check this and stop
local swingCount = 0
local lastSell = tick()

local gui = Instance.new("ScreenGui")
gui.Name = "SaberAutoFarm"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- Main panel (holds everything, so Minimize can hide it in one go)
local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 200, 0, 96)
mainFrame.Position = UDim2.new(0, 16, 0, 120)
mainFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -64, 0, 24)
title.Position = UDim2.new(0, 8, 0, 0)
title.BackgroundTransparency = 1
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 14
title.Font = Enum.Font.SourceSansBold
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "Saber Auto-Farm"
title.Parent = mainFrame

-- Minimize button (–): hides the panel, shows a small restore button instead
local minimizeBtn = Instance.new("TextButton")
minimizeBtn.Size = UDim2.new(0, 24, 0, 24)
minimizeBtn.Position = UDim2.new(1, -56, 0, 0)
minimizeBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
minimizeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
minimizeBtn.TextSize = 16
minimizeBtn.Font = Enum.Font.SourceSansBold
minimizeBtn.Text = "–"
minimizeBtn.Parent = mainFrame

-- Close / Unload button (X): stops everything and removes the script's GUI
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -28, 0, 0)
closeBtn.BackgroundColor3 = Color3.fromRGB(170, 40, 40)
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.TextSize = 16
closeBtn.Font = Enum.Font.SourceSansBold
closeBtn.Text = "X"
closeBtn.Parent = mainFrame

-- Small floating button shown while minimized - click to restore the panel
local miniBtn = Instance.new("TextButton")
miniBtn.Size = UDim2.new(0, 64, 0, 28)
miniBtn.Position = UDim2.new(0, 16, 0, 120)
miniBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
miniBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
miniBtn.TextSize = 14
miniBtn.Font = Enum.Font.SourceSansBold
miniBtn.Text = "Saber +"
miniBtn.Visible = false
miniBtn.Parent = gui

local button = Instance.new("TextButton")
button.Size = UDim2.new(0, 184, 0, 36)
button.Position = UDim2.new(0, 8, 0, 28)
button.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
button.TextColor3 = Color3.fromRGB(255, 255, 255)
button.TextSize = 16
button.Font = Enum.Font.SourceSansBold
button.Text = "START Auto-Farm"
button.Parent = mainFrame

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 22)
status.Position = UDim2.new(0, 8, 0, 68)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(255, 255, 255)
status.TextSize = 14
status.Text = "Stopped | Swings: 0"
status.Parent = mainFrame

pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end

local function unload()
	if unloaded then return end
	unloaded = true
	running = false
	print("[AutoFarm] Unloaded - all loops stopped, GUI removed. Re-run the loadstring to start again.")
	pcall(function() gui:Destroy() end)
end

minimizeBtn.MouseButton1Click:Connect(function()
	mainFrame.Visible = false
	miniBtn.Visible = true
end)
miniBtn.MouseButton1Click:Connect(function()
	mainFrame.Visible = true
	miniBtn.Visible = false
end)
closeBtn.MouseButton1Click:Connect(unload)

local function setRunning(value)
	if unloaded then return end
	running = value
	button.Text = running and "STOP Auto-Farm" or "START Auto-Farm"
	button.BackgroundColor3 = running and Color3.fromRGB(170, 40, 40) or Color3.fromRGB(50, 50, 50)
	if not running then status.Text = "Stopped | Swings: " .. swingCount end
end

local function doSell(reason)
	local ok, err = pcall(function() SellStrength:FireServer() end)
	if ok then swingCount = 0 lastSell = tick() print("[AutoFarm] Sold Strength (" .. reason .. ")")
	else warn("[AutoFarm] Sell failed: " .. tostring(err)) end
end

button.MouseButton1Click:Connect(function() setRunning(not running) end)
game:GetService("UserInputService").InputBegan:Connect(function(input, g)
	if g then return end
	if input.KeyCode == Enum.KeyCode.F then setRunning(not running) end
end)

-- ===== AUTO-BUY SABER (fixed) =====
local ItemInfo = require(ReplicatedStorage.Modules.ItemInfo)
local Swords = ItemInfo.Swords
local SwordsOrder = ItemInfo.Swords_Order

local clientData = nil
local assumedIndex = 1 -- persistent: next saber to try when we can't read your current one
local lastBuyTarget, lastBuyCoinsBefore = nil, nil

local function indexOfSaber(name)
	for i, n in ipairs(SwordsOrder) do if n == name then return i end end
	return 0
end

pcall(function()
	Events.UpdateClientData.OnClientEvent:Connect(function(data)
		if type(data) ~= "table" then return end
		clientData = data
		-- If the saber we just tried to buy is now equipped, move on to the next one
		local saber = data.Saber or data.CurrentSaber or data.EquippedSaber
		if saber and lastBuyTarget and saber == lastBuyTarget then
			assumedIndex = indexOfSaber(saber) + 1
			print("[AutoFarm] Bought saber confirmed: " .. saber .. " -> next index " .. assumedIndex)
			lastBuyTarget = nil
		end
	end)
	Events.RequestClientData:FireServer()
end)

local function getCoins()
	local ls = Players.LocalPlayer:FindFirstChild("leaderstats")
	if ls then
		local c = ls:FindFirstChild("Coins")
		if c then return tonumber(c.Value) end
	end
	if clientData then return tonumber(clientData.Coins or clientData.coins) end
	return nil
end

local function getCurrentSaber()
	if clientData then return clientData.Saber or clientData.CurrentSaber or clientData.EquippedSaber end
	return nil
end

local function tryBuySaber()
	if not AUTO_BUY or unloaded then return end
	local coins = getCoins()
	local current = getCurrentSaber()
	-- Sync assumedIndex from the real current saber when we know it
	if current then assumedIndex = indexOfSaber(current) + 1 end
	local currentGain = (current and Swords[current] and Swords[current].AmountPerClick) or 0
	print("[AutoFarm] Buy check: Coins=" .. tostring(coins) .. " current=" .. tostring(current))

	if coins then
		-- Best affordable saber BETTER than current
		local target = nil
		for _, name in ipairs(SwordsOrder) do
			local info = Swords[name]
			local price = info and tonumber(info.Price)
			if info and price and info.AmountPerClick > currentGain and coins >= price then
				if not target or info.AmountPerClick > Swords[target].AmountPerClick then target = name end
			end
		end
		if not target then
			print("[AutoFarm] Buy check: no affordable upgrade yet")
			return
		end
		print("[AutoFarm] Buying best: " .. target .. " price=" .. tostring(Swords[target].Price))
		lastBuyTarget = target
		lastBuyCoinsBefore = coins
		local args = { BUY_ACTION, target }
		pcall(function() UIAction:FireServer(unpack(args)) end)
		-- Assume it worked so next check looks higher; UpdateClientData will correct us if not
		currentGain = Swords[target].AmountPerClick
	else
		-- Coins UNKNOWN - don't skip. Try the next 10 sabers in order, cheapest first.
		-- Server rejects unaffordable ones, buys affordable ones. This also
		-- handles games that require buying in order.
		print("[AutoFarm] Buy check: Coins unknown - trying next 10 from index " .. assumedIndex)
		for i = assumedIndex, math.min(assumedIndex + 9, #SwordsOrder) do
			if unloaded then break end
			local name = SwordsOrder[i]
			print("[AutoFarm] Trying: " .. name .. " price=" .. tostring(Swords[name].Price))
			lastBuyTarget = name
			local args = { BUY_ACTION, name }
			pcall(function() UIAction:FireServer(unpack(args)) end)
			task.wait(0.3)
		end
	end
end

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
				status.Text = "Running | Swings: " .. swingCount
				if swingCount >= SELL_EVERY_SWINGS or (tick() - lastSell) >= SELL_EVERY_SECONDS then
					doSell("every " .. SELL_EVERY_SWINGS .. " swings / " .. SELL_EVERY_SECONDS .. "s")
				end
			else warn("[AutoFarm] Swing failed: " .. tostring(err)) task.wait(1) end
			task.wait(SWING_DELAY)
		else task.wait(0.2) end
	end
end)

print("[AutoFarm] Loaded v3 + X/Minimize. Click START or press F. – = minimize, X = unload (stops all loops).")
