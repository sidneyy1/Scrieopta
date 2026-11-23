-- Scrieopta Router - one loadstring for every game.
-- It checks which game you are in and runs ONLY that game's script.
-- To add a new game, add one line to the GAMES table below.
--
-- Usage (same in every game):
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/sidneyy1/Scrieopta/main/router.lua"))()

local BASE = "https://raw.githubusercontent.com/sidneyy1/Scrieopta/main/"

-- One entry per game. PlaceId is the main key (it never changes for a game);
-- UniverseId + name are fallbacks in case a game is re-uploaded under a new PlaceId.
local GAMES = {
	[3823781113] = { -- Saber Simulator (HD Games) - UniverseId 1312971993
		name = "Saber Simulator",
		universeId = 1312971993,
		file = "Saber Simulator/saber_autofarm_option1.lua",
	},
	[120219252362013] = { -- Throw Food For Animals (Goofy Chupacabra) - UniverseId 10766972131
		name = "Throw Food For Animals",
		universeId = 10766972131,
		file = "Throw Food For Animals/throw_food_auto.lua",
	},
	-- Example for the next game:
	-- [1234567890] = {
	-- 	name = "Some Other Game",
	-- 	universeId = 123456789,
	-- 	file = "Some Other Game/script.lua",
	-- },
}

local function loadGame(entry)
	local url = BASE .. entry.file:gsub(" ", "%%20")
	local ok, src = pcall(function() return game:HttpGet(url) end)
	if not ok or not src or src == "" then
		warn("[Router] Failed to download " .. entry.name .. " script: " .. tostring(src))
		return false
	end
	local fn, err = loadstring(src)
	if not fn then
		warn("[Router] Failed to load " .. entry.name .. " script: " .. tostring(err))
		return false
	end
	print("[Router] Running " .. entry.name .. " script (PlaceId " .. game.PlaceId .. ")")
	fn()
	return true
end

local placeId = game.PlaceId

-- 1. Match by PlaceId (most reliable)
local entry = GAMES[placeId]
if entry then
	loadGame(entry)
	return
end

-- 2. Match by UniverseId (same game, different place)
local universeId = game.GameId
if universeId then
	for _, e in pairs(GAMES) do
		if e.universeId == universeId then
			loadGame(e)
			return
		end
	end
end

-- 3. Match by game name (last resort - the name still contains the title
-- even when the game is renamed for an update, e.g. "[🍗UPD] Saber Simulator")
local gameName = game.Name
pcall(function()
	gameName = game:GetService("MarketplaceService"):GetProductInfo(placeId).Name
end)
if gameName then
	for _, e in pairs(GAMES) do
		if string.find(gameName, e.name, 1, true) then
			loadGame(e)
			return
		end
	end
end

warn("[Router] No script for this game (PlaceId " .. tostring(placeId) .. ", name: " .. tostring(gameName) .. ")")
