-- Saber Simulator - BUY TEST (run once, Dex Console)
-- This is the definitive test: it tries to buy the first 30 sabers in order,
-- cheapest first, and prints your Coins before/after each try.
-- If this doesn't buy anything you can afford, then BuyWeapon is NOT the
-- whole story (shop must be open / you must be somewhere / etc.)
-- Paste the console output back to me.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local UIAction = RS.Events.UIAction
local ItemInfo = require(RS.Modules.ItemInfo)
local Swords, Order = ItemInfo.Swords, ItemInfo.Swords_Order

local function getCoins()
	local ls = Players.LocalPlayer:FindFirstChild("leaderstats")
	if ls and ls:FindFirstChild("Coins") then return tostring(ls.Coins.Value) end
	return "unknown (no leaderstats.Coins)"
end

print("=== BUY TEST START ===")
print("Coins at start:", getCoins())
print("First 30 sabers in order:")
for i = 1, 30 do
	local name = Order[i]
	local coinsBefore = getCoins()
	print(i .. ". Trying " .. name .. " price=" .. tostring(Swords[name].Price) .. " Coins before=" .. coinsBefore)
	local args = { "BuyWeapon", name }
	pcall(function() UIAction:FireServer(unpack(args)) end)
	task.wait(0.5)
	print("   Coins after=" .. getCoins())
end
print("=== BUY TEST DONE ===")
print("Coins at end:", getCoins())
print("Which saber are you holding now? Paste all of the above back.")
