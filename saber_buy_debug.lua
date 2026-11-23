-- Saber Simulator - BUY DEBUG (run this alone, 30 seconds)
-- Paste in Dex Console, swing/sell normally, then read the output.
-- It tells us WHY the auto-buy isn't working. Paste the output back to me.

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local Events = RS:WaitForChild("Events")

print("=== 1. leaderstats ===")
local ls = LocalPlayer:FindFirstChild("leaderstats")
if ls then
	for _, v in ipairs(ls:GetChildren()) do
		print("leaderstats:", v.ClassName, v.Name, "=", tostring(v.Value), "type:", type(v.Value))
	end
else
	print("leaderstats: NOT FOUND")
end

print("=== 2. Swords data ===")
local ItemInfo = require(RS.Modules.ItemInfo)
print("Swords_Order count:", #ItemInfo.Swords_Order)
for i = 1, 10 do
	local name = ItemInfo.Swords_Order[i]
	local s = ItemInfo.Swords[name]
	print(i, name, "AmountPerClick:", tostring(s.AmountPerClick), "Price:", tostring(s.Price), "type Price:", type(s.Price))
end

print("=== 3. UpdateClientData - what the server actually sends ===")
local gotData = false
Events.UpdateClientData.OnClientEvent:Connect(function(data)
	if gotData then return end
	gotData = true
	print("UpdateClientData type:", type(data))
	if type(data) == "table" then
		for k, v in pairs(data) do
			print("  data.", tostring(k), "=", tostring(v), "type:", type(v))
		end
	else
		print("  data =", tostring(data))
	end
end)
Events.RequestClientData:FireServer()
print("Requested client data, waiting 5s for UpdateClientData...")
task.wait(5)
if not gotData then
	print("UpdateClientData: NO DATA RECEIVED in 5s - hook may need a swing/sell first")
end

print("=== 4. Manual buy test - Green (15 Coins) ===")
print("Coins before test: see leaderstats above. Now firing UIAction BuyWeapon Green...")
local ok, err = pcall(function()
	Events.UIAction:FireServer("BuyWeapon", "Green")
end)
print("FireServer ok:", tostring(ok), "err:", tostring(err))
print("Watch your Coins / Saber in-game for 5 seconds. Did Green get bought/equipped?")
task.wait(5)
print("=== DEBUG DONE - paste all of this output back ===")
