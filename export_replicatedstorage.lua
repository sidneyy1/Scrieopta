-- Export game structure from Dex Console / executor (v2)
-- Run this in Dex > Console. It exports these into your executor's
-- workspace folder, under a folder named after the game (e.g. SaberSimulator/):
--   ReplicatedStorage, StarterGui, StarterPlayerScripts, StarterCharacterScripts,
--   PlayerGui (your live UI), Workspace
-- For each one you get:
--   <Name>_tree.txt  (structure - send these to an AI first)
--   <Name>.json      (same structure as JSON)
--   <Name>_<Script>.lua  (decompiled source of every script inside it)
-- Plus Workspace_topLevel.txt (biggest top-level folders in Workspace, so the
-- huge map doesn't have to be read in full).
-- NOTE: this only saves names / properties / script source. Meshes, textures
-- and sounds are saved as asset IDs only, not as files - so trees and other
-- map decoration cost almost nothing here. Exporting is read-only.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Folder named after the game, e.g. "Saber Simulator" -> "SaberSimulator".
-- MarketplaceService gives the real game name; falls back to game.Name.
local OUT = "Game_Export"
do
	local name = nil
	pcall(function()
		name = game:GetService("MarketplaceService"):GetProductInfo(game.PlaceId).Name
	end)
	if not name or name == "" then name = game.Name end
	if name and name ~= "" then
		local clean = name:gsub("%s+", ""):gsub("[^%w%_%-]", "")
		if clean ~= "" then OUT = clean end
	end
end
print("[Export] Game: " .. OUT)

pcall(makefolder, OUT)

local function safeName(s)
	return (s:gsub("[^%w%_%-]", "_"))
end

-- Tree dump with a node cap so a huge service (Workspace) can't freeze the game
local function dumpTree(root, maxNodes, maxDepth)
	local lines, count, truncated = {}, 0, false
	local function dump(inst, depth)
		if count >= maxNodes then truncated = true return end
		if depth > maxDepth then return end
		count += 1
		table.insert(lines, string.rep("  ", depth) .. inst.ClassName .. ": " .. inst.Name)
		for _, child in ipairs(inst:GetChildren()) do
			dump(child, depth + 1)
			if truncated then return end
		end
	end
	dump(root, 0)
	if truncated then
		table.insert(lines, "... TRUNCATED at " .. maxNodes .. " instances (tree is bigger than the cap)")
	end
	return table.concat(lines, "\n"), count, truncated
end

local function buildJson(inst, depth, maxDepth, budget)
	if depth > maxDepth or budget[1] <= 0 then return nil end
	budget[1] -= 1
	local t = { Class = inst.ClassName, Name = inst.Name, Children = {} }
	for _, child in ipairs(inst:GetChildren()) do
		local c = buildJson(child, depth + 1, maxDepth, budget)
		if c then table.insert(t.Children, c) end
		if budget[1] <= 0 then break end
	end
	return t
end

local function decompileAll(root, prefix, outFolder)
	local saved, failed = 0, 0
	for _, obj in ipairs(root:GetDescendants()) do
		if obj:IsA("LuaSourceContainer") then
			local ok, source = pcall(decompile, obj)
			if ok and type(source) == "string" and source ~= "" then
				local name = obj:GetFullName():gsub("^game%.", ""):gsub("%.", "_")
				name = safeName(name)
				local ok2 = pcall(writefile, outFolder .. "/" .. prefix .. name .. "_" .. obj.ClassName .. ".lua", source)
				if ok2 then saved += 1 else failed += 1 end
			else
				failed += 1
			end
			task.wait()
		end
	end
	return saved, failed
end

local function exportService(root, label, outFolder, maxNodes, maxDepth)
	print("[Export] " .. label .. "...")
	local treeText, count = dumpTree(root, maxNodes, maxDepth)
	pcall(writefile, outFolder .. "/" .. label .. "_tree.txt", treeText)
	local budget = { maxNodes }
	local jsonTree = buildJson(root, 0, maxDepth, budget)
	pcall(writefile, outFolder .. "/" .. label .. ".json", HttpService:JSONEncode(jsonTree))
	local saved, failed = decompileAll(root, label .. "_", outFolder)
	print("[Export] " .. label .. ": " .. count .. " instances, scripts saved: " .. saved .. ", failed: " .. failed)
end

-- 1. ReplicatedStorage (same as before: prices, formulas, remotes)
exportService(game:GetService("ReplicatedStorage"), "ReplicatedStorage", OUT, 30000, 12)

-- 2. StarterGui (the game's UI templates - DNA shop buttons, equipped displays)
exportService(game:GetService("StarterGui"), "StarterGui", OUT, 30000, 12)

-- 3. StarterPlayerScripts / StarterCharacterScripts (how the game calls remotes)
local sp = game:GetService("StarterPlayer")
local sps = sp:FindFirstChild("StarterPlayerScripts")
if sps then exportService(sps, "StarterPlayerScripts", OUT, 10000, 12) end
local scs = sp:FindFirstChild("StarterCharacterScripts")
if scs then exportService(scs, "StarterCharacterScripts", OUT, 10000, 12) end

-- 4. PlayerGui (your LIVE UI - what the DNA display actually looks like right now)
local lp = Players.LocalPlayer
if lp then
	local pg = lp:FindFirstChild("PlayerGui")
	if pg then exportService(pg, "PlayerGui", OUT, 30000, 12) end
end

-- 5. Workspace (the map: regions, bosses, eggs, shops, pickups)
-- Top-level summary first, so the big folders are visible without reading the whole tree
local ws = game:GetService("Workspace")
do
	local rows = {}
	for _, child in ipairs(ws:GetChildren()) do
		table.insert(rows, { name = child.Name, class = child.ClassName, count = #child:GetDescendants() })
	end
	table.sort(rows, function(a, b) return a.count > b.count end)
	local out = { "Workspace top-level children (by size):" }
	for _, r in ipairs(rows) do
		table.insert(out, r.class .. ": " .. r.name .. " (" .. r.count .. " descendants)")
	end
	pcall(writefile, OUT .. "/Workspace_topLevel.txt", table.concat(out, "\n"))
	print("[Export] Workspace top-level: " .. #rows .. " children")
end
exportService(ws, "Workspace", OUT, 20000, 10)

print("[Export] Done. Files are in your executor workspace folder, under " .. OUT .. "/")
print("[Export] Send the *_tree.txt files first (StarterGui, StarterPlayerScripts, PlayerGui, Workspace_topLevel)")
