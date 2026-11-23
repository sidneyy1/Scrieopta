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
local swingCount = 0
local lastSell = tick()

local gui = Instance.new("ScreenGui")
gui.Name = "SaberAutoFarm"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local button = Instance.new("TextButton")
button.Size = UDim2.new(0, 170, 0, 44)
button.Position = UDim2.new(0, 16, 0, 120)
button.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
button.TextColor3 = Color3.fromRGB(255, 255, 255)
button.TextSize = 16
button.Font = Enum.Font.SourceSansBold
button.Text = "START Auto-Farm"
button.Parent = gui

local status = Instance.new("TextLabel")
status.Size = UDim2.new(0, 170, 0, 22)
status.Position = UDim2.new(0, 16, 0, 168)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(255, 255, 255)
status.TextSize = 14
status.Text = "Stopped | Swings: 0"
status.Parent = gui

pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end

local function setRunning(value)
	running = value
	button.Text = running and "STOP Auto-Farm" or "START Auto-Farm"
	button.BackgroundColor3 = running and Color3.fromRGB(170, 40, 40) or Color3.fromRGB(30, 30, 30)
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
	if not AUTO_BUY then return end
	local coins = getCoins()
	local current = getCurrentSaber()
	-- Sync assumedIndex from the real current saber when we know it
	if current then assumedIndex = indexOfSaber(current) + 1 end
	local currentGain = (current and Swords[current] and Swords[current].AmountPerClick) or 0

	local target = nil
	if coins then
		-- Best affordable saber BETTER than current - this is the "best saber" fix
		for _, name in ipairs(SwordsOrder) do
			local info = Swords[name]
			local price = info and tonumber(info.Price)
			if info and price and info.AmountPerClick > currentGain and coins >= price then
				if not target or info.AmountPerClick > Swords[target].AmountPerClick then target = name end
			end
		end
	else
		-- Coins unknown: try the next saber in order, one at a time.
		-- Do NOT advance here - only the UpdateClientData hook above advances
		-- us when a buy is confirmed. Advancing blindly was the v2 bug.
		target = SwordsOrder[assumedIndex]
	end

	if not target then
		print("[AutoFarm] Buy check: no affordable upgrade. Coins=" .. tostring(coins) .. " current=" .. tostring(current))
		return
	end
	local price = Swords[target] and Swords[target].Price
	print("[AutoFarm] Buy check: Coins=" .. tostring(coins) .. " current=" .. tostring(current) .. " trying=" .. target .. " price=" .. tostring(price))
	lastBuyTarget = target
	lastBuyCoinsBefore = coins
	pcall(function() UIAction:FireServer(BUY_ACTION, target) end)
end

task.spawn(function()
	while true do
		task.wait(BUY_CHECK_EVERY)
		if running then tryBuySaber() end
	end
end)

-- Main swing/sell loop
task.spawn(function()
	while true do
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

print("[AutoFarm] Loaded v3. Click START or press F.")
