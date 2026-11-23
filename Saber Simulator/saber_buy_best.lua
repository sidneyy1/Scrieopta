-- Buy Best Saber ONLY (standalone, Saber Simulator) - v4 FIXED
-- Why v3 didn't buy: it SKIPPED buying entirely when it couldn't read your
-- Coins ("Coins unknown, skipping"). v4 never skips for that reason.
-- Instead, if Coins can't be read, it tries the next sabers in order -
-- the server itself rejects the ones you can't afford.
--
-- Confirmed by RemoteSpy:
--   game:GetService("ReplicatedStorage").Events.UIAction:FireServer("BuyWeapon", "Daze")
-- So buying is UIAction("BuyWeapon", saberName).
--
-- Run in Dex Console / executor. Watch the console output - it prints
-- exactly what it is doing every 5 seconds. Paste that output back if it
-- still doesn't buy.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Events = RS:WaitForChild("Events")
local UIAction = Events:WaitForChild("UIAction")
local ItemInfo = require(RS.Modules.ItemInfo)
local Swords, Order = ItemInfo.Swords, ItemInfo.Swords_Order

local clientData = nil
pcall(function()
	Events.UpdateClientData.OnClientEvent:Connect(function(d)
		if type(d) == "table" then clientData = d end
	end)
	Events.RequestClientData:FireServer()
end)

local function getCoins()
	local ls = Players.LocalPlayer:FindFirstChild("leaderstats")
	if ls and ls:FindFirstChild("Coins") then return tonumber(ls.Coins.Value) end
	if clientData then return tonumber(clientData.Coins or clientData.coins) end
	return nil
end

local function getCurrentSaber()
	if clientData then return clientData.Saber or clientData.CurrentSaber or clientData.EquippedSaber end
	return nil
end

-- How many sabers to try per check in fallback mode (cheapest first)
local TRY_COUNT = 10

while true do
	task.wait(5)
	local coins = getCoins()
	local current = getCurrentSaber()
	local currentGain = (current and Swords[current] and Swords[current].AmountPerClick) or 0
	print("[BuyBest] Coins=" .. tostring(coins) .. " current=" .. tostring(current) .. " currentGain=" .. tostring(currentGain))

	if coins then
		-- Best affordable saber better than current
		local best
		for _, name in ipairs(Order) do
			local s = Swords[name]
			if s and s.AmountPerClick > currentGain and coins >= tonumber(s.Price) then
				best = name
			end
		end
		if best then
			print("[BuyBest] Buying best: " .. best .. " price=" .. tostring(Swords[best].Price))
			local args = { "BuyWeapon", best }
			pcall(function() UIAction:FireServer(unpack(args)) end)
			-- Assume it worked so next loop looks for the next one up.
			-- If UpdateClientData says otherwise, it will correct currentGain above.
			currentGain = Swords[best].AmountPerClick
		else
			print("[BuyBest] No upgrade affordable yet")
		end
	else
		-- Coins UNKNOWN - don't skip. Try the next TRY_COUNT sabers in order,
		-- cheapest first. Server rejects unaffordable ones, buys affordable ones.
		-- This also handles games that require buying in order.
		local startIdx = 1
		if current then
			for i, name in ipairs(Order) do
				if name == current then startIdx = i + 1 break end
			end
		end
		print("[BuyBest] Coins unknown - trying next " .. TRY_COUNT .. " sabers from index " .. startIdx)
		for i = startIdx, math.min(startIdx + TRY_COUNT - 1, #Order) do
			local name = Order[i]
			print("[BuyBest] Trying: " .. name .. " price=" .. tostring(Swords[name].Price))
			local args = { "BuyWeapon", name }
			pcall(function() UIAction:FireServer(unpack(args)) end)
			task.wait(0.3)
		end
	end
end
