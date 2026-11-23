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

-- ===== X / Minimize GUI =====
local unloaded = false
local gui = Instance.new("ScreenGui")
gui.Name = "SaberBuyBest"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 200, 0, 48)
mainFrame.Position = UDim2.new(0, 16, 0, 220)
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
title.Text = "Buy Best Saber"
title.Parent = mainFrame

local minimizeBtn = Instance.new("TextButton")
minimizeBtn.Size = UDim2.new(0, 24, 0, 24)
minimizeBtn.Position = UDim2.new(1, -56, 0, 0)
minimizeBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 60)
minimizeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
minimizeBtn.TextSize = 16
minimizeBtn.Font = Enum.Font.SourceSansBold
minimizeBtn.Text = "–"
minimizeBtn.Parent = mainFrame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 24, 0, 24)
closeBtn.Position = UDim2.new(1, -28, 0, 0)
closeBtn.BackgroundColor3 = Color3.fromRGB(170, 40, 40)
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.TextSize = 16
closeBtn.Font = Enum.Font.SourceSansBold
closeBtn.Text = "X"
closeBtn.Parent = mainFrame

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -16, 0, 20)
status.Position = UDim2.new(0, 8, 0, 24)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(255, 255, 255)
status.TextSize = 13
status.Text = "Running - checking every 5s"
status.Parent = mainFrame

local miniBtn = Instance.new("TextButton")
miniBtn.Size = UDim2.new(0, 64, 0, 28)
miniBtn.Position = UDim2.new(0, 16, 0, 220)
miniBtn.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
miniBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
miniBtn.TextSize = 14
miniBtn.Font = Enum.Font.SourceSansBold
miniBtn.Text = "Saber +"
miniBtn.Visible = false
miniBtn.Parent = gui

pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui") end

minimizeBtn.MouseButton1Click:Connect(function()
	mainFrame.Visible = false
	miniBtn.Visible = true
end)
miniBtn.MouseButton1Click:Connect(function()
	mainFrame.Visible = true
	miniBtn.Visible = false
end)
closeBtn.MouseButton1Click:Connect(function()
	unloaded = true
	print("[BuyBest] Unloaded - loop stopped, GUI removed. Re-run the loadstring to start again.")
	pcall(function() gui:Destroy() end)
end)
-- ============================

while not unloaded do
	task.wait(5)
	if unloaded then break end
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
			if unloaded then break end
			local name = Order[i]
			print("[BuyBest] Trying: " .. name .. " price=" .. tostring(Swords[name].Price))
			local args = { "BuyWeapon", name }
			pcall(function() UIAction:FireServer(unpack(args)) end)
			task.wait(0.3)
		end
	end
end
