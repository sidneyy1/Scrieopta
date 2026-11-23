-- Buy Best Saber ONLY (standalone, Saber Simulator)
-- Every 5s: buy the best saber you can afford that is better than your current one.
-- Uses: ReplicatedStorage/Modules/ItemInfo (Swords_Order sorted by AmountPerClick, VIP excluded)
--        ReplicatedStorage/Events/UIAction ("BuyWeapon", saberName) - CONFIRMED by RemoteSpy: ("BuyWeapon", "Daze")
-- Run in Dex Console / executor. Stop it by re-executing / closing the game.

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

local currentGain = 0
while true do
	task.wait(5)
	local coins = getCoins()
	if not coins then print("[BuyBest] Coins unknown, skipping") continue end

	-- Sync current saber from server data when available
	if clientData and clientData.Saber and Swords[clientData.Saber] then
		currentGain = Swords[clientData.Saber].AmountPerClick
	end

	-- Best affordable saber better than current (Order is ascending, so last match wins)
	local best
	for _, name in ipairs(Order) do
		local s = Swords[name]
		if s and s.AmountPerClick > currentGain and coins >= tonumber(s.Price) then
			best = name
		end
	end

	if best then
		print("[BuyBest] Coins=" .. coins .. " buying " .. best .. " (price " .. Swords[best].Price .. ")")
		pcall(function() UIAction:FireServer("BuyWeapon", best) end)
		currentGain = Swords[best].AmountPerClick -- assume bought, so next loop picks the next one up
	else
		print("[BuyBest] No upgrade affordable. Coins=" .. coins)
	end
end
