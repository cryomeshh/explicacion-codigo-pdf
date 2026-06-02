-- ============================================================
-- AUGMENT HANDLER | ServerScriptService.MainHandlers.AugmentHandler
-- Triggers every even day at 9:00 AM game time.
-- Handles perk voting, purchase, application.
-- ============================================================
local Players         = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting        = game:GetService("Lighting")
local AugmentModule   = require(ReplicatedStorage.AugmentSystem.AugmentModule)
local augEvents       = ReplicatedStorage.AugmentSystem.Events
local buffsFolder     = ReplicatedStorage:WaitForChild("Buffs")
local dayValue        = Lighting:WaitForChild("Day")
local juegoIniciado   = workspace:WaitForChild("JuegoIniciado")
local showCardsEvent  = augEvents:WaitForChild("AugmentShowCards")
local buyEvent        = augEvents:WaitForChild("AugmentBuy")
local updateEvent     = augEvents:WaitForChild("AugmentUpdateVotes")
local appliedEvent    = augEvents:WaitForChild("AugmentApplied")
local noFundsEvent    = augEvents:WaitForChild("AugmentNoFunds")
-- ============================================================
-- STATE
-- ============================================================
local activePerks     = {}   -- [perkId] = stackCount
local sessionActive   = false
local currentCards    = {}   -- 3 perk tables for current vote
local lastTriggeredDay = -1  -- prevent double-trigger same day
-- ============================================================
-- RESOURCE HELPERS
-- ============================================================
local RESOURCE_KEYS = {"gold", "wheat", "potato", "carrot", "tomato"}
local function getTotalResources()
	local totals = {}
	for _, key in ipairs(RESOURCE_KEYS) do totals[key] = 0 end
	for _, player in ipairs(Players:GetPlayers()) do
		local res = player:FindFirstChild("resources")
		if res then
			for _, key in ipairs(RESOURCE_KEYS) do
				local stat = res:FindFirstChild(key)
				if stat then totals[key] += stat.Value end
			end
		end
	end
	return totals
end
local function canAfford(rarityName)
	local cost = AugmentModule.Costs[rarityName]
	if not cost then return false end
	local totals = getTotalResources()
	for key, amount in pairs(cost) do
		if (totals[key] or 0) < amount then return false end
	end
	return true
end
-- Deduct cost proportionally from all players based on their share
local function deductResources(rarityName)
	local cost = AugmentModule.Costs[rarityName]
	if not cost then return end
	for key, totalCost in pairs(cost) do
		if totalCost <= 0 then continue end
		-- Gather total available of this resource
		local grandTotal = 0
		for _, player in ipairs(Players:GetPlayers()) do
			local res = player:FindFirstChild("resources")
			if res then
				local stat = res:FindFirstChild(key)
				if stat then grandTotal += stat.Value end
			end
		end
		if grandTotal <= 0 then continue end
		-- Deduct proportionally
		local remaining = totalCost
		local playerList = Players:GetPlayers()
		for i, player in ipairs(playerList) do
			local res = player:FindFirstChild("resources")
			if not res then continue end
			local stat = res:FindFirstChild(key)
			if not stat then continue end
			local share
			if i == #playerList then
				share = remaining  -- last player gets the remainder to avoid rounding drift
			else
				share = math.floor(totalCost * (stat.Value / grandTotal))
			end
			share = math.min(share, stat.Value)
			stat.Value -= share
			remaining -= share
		end
	end
end
-- ============================================================
-- BUFF APPLICATION
-- ============================================================
local function applyPerk(perk)
	local stacks = (activePerks[perk.id] or 0) + 1
	activePerks[perk.id] = stacks
	local buff = buffsFolder:FindFirstChild(perk.buffKey)
	if buff then
		buff.Value += perk.effectValue
	end
	-- Side effects for Epic perks
	if perk.sideEffect then
		local seBuff = buffsFolder:FindFirstChild(perk.sideEffect.buffKey)
		if seBuff then
			seBuff.Value += perk.sideEffect.value
		end
	end
	-- Legendary composite perks
	if perk.id == "EarthBlessing" then
		-- +2/s all resources except gold (handled in BuffsHandler loop)
		local perSecondKeys = {"wheatPerSecond", "potatoPerSecond", "carrotPerSecond", "tomatoPerSecond"}
		for _, k in ipairs(perSecondKeys) do
			local b = buffsFolder:FindFirstChild(k)
			if b then b.Value += 2 end
		end
		-- +50% HP, +5% dmg reduction, +15% speed, +1% hpregen
		local hp = buffsFolder:FindFirstChild("health")
		if hp then hp.Value += 0.50 end
		local dmgRed = buffsFolder:FindFirstChild("playerDmgReduction")
		if dmgRed then dmgRed.Value += 0.05 end
		local spd = buffsFolder:FindFirstChild("speed")
		if spd then spd.Value += 0.15 end
		local regen = buffsFolder:FindFirstChild("hpregPLAYER")
		if regen then regen.Value += 0.01 end
	end
	if perk.id == "MutantHorde" then
		-- Signal to EnemieSpawnHandler via buff flag (value = 1)
		local b = buffsFolder:FindFirstChild("mutantHorde")
		if b then b.Value = 1 end
	end
	if perk.id == "ElectricAura" then
		local b = buffsFolder:FindFirstChild("electricAura")
		if b then b.Value = 1 end
	end
end
-- ============================================================
-- SERIALIZE CARDS FOR NETWORK
-- ============================================================
local function serializeCards(cards)
	local serialized = {}
	for i, perk in ipairs(cards) do
		local cost = AugmentModule.Costs[perk.rarity]
		local color = AugmentModule.GetRarityColor(perk.rarity)
		local stacks = activePerks[perk.id] or 0
		table.insert(serialized, {
			index       = i,
			id          = perk.id,
			name        = perk.name,
			rarity      = perk.rarity,
			description = perk.description,
			colorR      = color.R,
			colorG      = color.G,
			colorB      = color.B,
			costGold    = cost.gold,
			costWheat   = cost.wheat,
			costPotato  = cost.potato,
			costCarrot  = cost.carrot,
			costTomato  = cost.tomato,
			stackCount  = stacks,
		})
	end
	return serialized
end
-- ============================================================
-- VOTE SESSION
-- ============================================================
local function startAugmentSession(dayNum)
	if sessionActive then return end
	sessionActive = true
	currentCards = AugmentModule.PickThreePerks(activePerks)
	if #currentCards == 0 then
		sessionActive = false
		return
	end
	local serialized = serializeCards(currentCards)
	showCardsEvent:FireAllClients(serialized, dayNum)
end
-- ============================================================
-- BUY HANDLER (first player to press buys for all)
-- ============================================================
buyEvent.OnServerEvent:Connect(function(player, cardIndex)
	if not sessionActive then return end
	if type(cardIndex) ~= "number" then return end
	local perk = currentCards[cardIndex]
	if not perk then return end
	-- Check affordability
	if not canAfford(perk.rarity) then
		noFundsEvent:FireAllClients(perk.name, perk.rarity)
		return
	end
	-- Close session immediately to block duplicate purchases
	sessionActive = false
	-- Deduct resources
	deductResources(perk.rarity)
	-- Apply perk
	applyPerk(perk)
	-- Broadcast result to all clients
	local color = AugmentModule.GetRarityColor(perk.rarity)
	local activeList = {}
	for id, count in pairs(activePerks) do
		local pd = AugmentModule.GetPerkById(id)
		if pd then
			local c = AugmentModule.GetRarityColor(pd.rarity)
			table.insert(activeList, {
				name        = pd.name,
				rarity      = pd.rarity,
				description = pd.description,
				stackCount  = count,
				colorR      = c.R,
				colorG      = c.G,
				colorB      = c.B,
			})
		end
	end
	appliedEvent:FireAllClients(perk.name, perk.rarity, color.R, color.G, color.B, player.Name, activeList)
end)
-- ============================================================
-- DAY TRIGGER: even day + clock crosses 9:00 AM
-- ============================================================
local previousClock = Lighting.ClockTime
task.spawn(function()
	while true do
		task.wait(0.5)
		if not juegoIniciado.Value then
			previousClock = Lighting.ClockTime
			continue
		end
		local currentClock = Lighting.ClockTime
		local currentDay   = dayValue.Value
		-- Detect crossing 9.0 (previousClock < 9 and currentClock >= 9)
		local crossed9AM = (previousClock < 9.0 and currentClock >= 9.0)
		-- Also handle wrap-around from previous night (edge case)
		local wrappedCross = (previousClock > 20.0 and currentClock < 9.0 and currentClock >= 0)
		if crossed9AM and currentDay % 1 == 0 and currentDay ~= lastTriggeredDay then
			lastTriggeredDay = currentDay
			task.spawn(startAugmentSession, currentDay)
		end
		previousClock = currentClock
	end
end)