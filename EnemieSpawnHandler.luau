local Lighting        = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players         = game:GetService("Players")
local TweenService    = game:GetService("TweenService")

local enemyFolder   = workspace:WaitForChild("enemies")
local mobsFolder    = ReplicatedStorage:WaitForChild("mobs"):WaitForChild("enemies")
local partsFolder   = workspace:WaitForChild("map"):WaitForChild("floor"):WaitForChild("basepart")
local partsList     = partsFolder:GetChildren()
local dayValue      = Lighting:WaitForChild("Day")
local juegoIniciado = workspace:WaitForChild("JuegoIniciado")
local sendAlert     = ReplicatedStorage.Events:WaitForChild("SendAlert")

local buffsFolder        = ReplicatedStorage:WaitForChild("Buffs")
local radarZombiesValue  = buffsFolder:WaitForChild("radarZombies")
local mutantHordeBuff    = buffsFolder:WaitForChild("mutantHorde")
local enemyBonusHealth   = buffsFolder:WaitForChild("enemyBonusHealth")
local spawnRateBonus     = buffsFolder:WaitForChild("spawnRateBonus")

local MAX_ZOMBIES     = 65
local START_HOUR      = 19
local END_HOUR        = 6
local CHECK_INTERVAL  = 1
local bossSpawned     = false
local bossNightActive = false   -- tracks crimson night state

-- -- Enemy count cache (avoids GetChildren() every tick) ------
local zombieCount = 0
enemyFolder.ChildAdded:Connect(function()   zombieCount += 1 end)
enemyFolder.ChildRemoved:Connect(function() zombieCount = math.max(0, zombieCount - 1) end)

-- -- Enemy table -----------------------------------------------
local normalEnemies = {
	{ model = mobsFolder:WaitForChild("Zombie"),         weight = 45 },
	{ model = mobsFolder:WaitForChild("CrawlingZombie"), weight = 15 },
	{ model = mobsFolder:WaitForChild("FastZombie"),     weight = 15 },
	{ model = mobsFolder:WaitForChild("HeavyZombie"),    weight = 10 },
	{ model = mobsFolder:WaitForChild("KamiZombie"),     weight = 8  },
	{ model = mobsFolder:WaitForChild("Flesh Monster"),  weight = 7  },
}
local totalWeight = 0
for _, e in ipairs(normalEnemies) do totalWeight += e.weight end

local function pickRandomEnemy()
	local roll = math.random(1, totalWeight)
	local acc  = 0
	for _, e in ipairs(normalEnemies) do
		acc += e.weight
		if roll <= acc then return e.model end
	end
	return normalEnemies[1].model
end

-- -- Spawn function --------------------------------------------
local function spawnEnemy(model, position, currentDay, isEscort)
	local effectiveMax = (mutantHordeBuff.Value > 0) and math.floor(MAX_ZOMBIES / 2) or MAX_ZOMBIES
	if zombieCount >= effectiveMax then return end

	local newEnemy = model:Clone()
	for _, part in ipairs(newEnemy:GetDescendants()) do
		if part:IsA("BasePart") then part.Anchored = false end
	end

	local humanoid    = newEnemy:FindFirstChild("Humanoid")
	local configFolder= newEnemy:FindFirstChild("Configurations")
	local damageValue = configFolder and configFolder:FindFirstChild("ATTACK_DAMAGE")

	local isBoss = (model.Name == "Boss")

	local hpMult  = 1 + (0.35 * (currentDay - 1))
	local dmgMult = 1 + (0.25 * (currentDay - 1))
	local spdMult = 1 + (0.06  * (currentDay - 1))

	if enemyBonusHealth.Value > 0 then
		hpMult = hpMult * (1 + enemyBonusHealth.Value)
	end
	if mutantHordeBuff.Value > 0 and not isBoss then
		hpMult  = hpMult  * 3
		dmgMult = dmgMult * 3
	end

	-- Boss gets extra HP/DMG scaling (x3 base)
	if isBoss then
		hpMult  = hpMult  * 3
		dmgMult = dmgMult * 2
	end

	if humanoid then
		humanoid.MaxHealth = humanoid.MaxHealth * hpMult
		humanoid.Health    = humanoid.MaxHealth
		humanoid.WalkSpeed = humanoid.WalkSpeed * spdMult
	end
	if damageValue and damageValue:IsA("IntValue") then
		damageValue.Value = math.round(damageValue.Value * dmgMult)
	end

	newEnemy:PivotTo(CFrame.new(position))
	newEnemy.Parent = enemyFolder
end

-- -- Radar highlight -------------------------------------------
local function actualizarHighlights(val)
	for _, enemy in ipairs(enemyFolder:GetChildren()) do
		local hl = enemy:FindFirstChild("RadarHighlight")
		if hl then hl.Enabled = (val > 0) end
	end
end
radarZombiesValue.Changed:Connect(actualizarHighlights)
enemyFolder.ChildAdded:Connect(function(child)
	task.wait(0.05)
	local hl = child:FindFirstChild("RadarHighlight")
	if hl then hl.Enabled = (radarZombiesValue.Value > 0) end
end)

-- -- Crimson night helpers -------------------------------------
local originalFogColor  = Lighting.FogColor
local originalFogEnd    = Lighting.FogEnd
local originalAmbient   = Lighting.OutdoorAmbient

local function startCrimsonNight()
	if bossNightActive then return end
	bossNightActive = true
	TweenService:Create(Lighting, TweenInfo.new(4, Enum.EasingStyle.Sine), {
		FogColor        = Color3.fromRGB(80, 5, 5),
		OutdoorAmbient  = Color3.fromRGB(90, 10, 10),
		FogEnd          = 60,
	}):Play()
	sendAlert:FireAllClients("? THE BOSS WALKS TONIGHT...")
end

local function endCrimsonNight()
	if not bossNightActive then return end
	bossNightActive = false
	TweenService:Create(Lighting, TweenInfo.new(6, Enum.EasingStyle.Sine), {
		FogColor       = Color3.fromRGB(20, 20, 35),
		OutdoorAmbient = Color3.fromRGB(40, 45, 70),
		FogEnd         = 120,
	}):Play()
end

-- -- Augment upcoming alert (30s before even-day 9AM) ---------
local augAlertSent = -1
task.spawn(function()
	while true do
		task.wait(2)
		if not juegoIniciado.Value then continue end
		local day  = dayValue.Value
		local hour = Lighting.ClockTime
		-- 9AM is the trigger. Warn at ~8:55 (ClockTime ~8.92)
		-- DayCycleHandler increments 12/100 per 0.1s during day ? ~0.12/s
		-- 30s before 9AM ˜ ClockTime 8.92 to 9.0
		if day % 2 == 0 and hour >= 8.85 and hour < 9.0 and augAlertSent ~= day then
			augAlertSent = day
			sendAlert:FireAllClients("? AUGMENT INCOMING in ~30 seconds!")
		end
	end
end)

-- -- Wait for game start ---------------------------------------
while not juegoIniciado.Value do task.wait(CHECK_INTERVAL) end

-- -- Main loop -------------------------------------------------
while true do
	local currentTime = Lighting.ClockTime
	local isNight     = (currentTime >= START_HOUR or currentTime < END_HOUR)
	local currentDay  = dayValue.Value
	local isBossDay   = (currentDay % 5 == 0)

	if isNight then
		-- -- BOSS NIGHT --------------------------------------
		if isBossDay and not bossSpawned then
			bossSpawned = true
			startCrimsonNight()

			local randomPart = partsList[math.random(1, #partsList)]
			local bossPos    = randomPart.Position + Vector3.new(0, 8, 0)
			spawnEnemy(mobsFolder.Boss, bossPos, currentDay, false)

			-- Escort: 4-6 regular zombies ring around the boss
			local escortCount = math.random(4, 6)
			for i = 1, escortCount do
				local angle  = (i / escortCount) * math.pi * 2
				local offset = Vector3.new(math.cos(angle) * 6, 8, math.sin(angle) * 6)
				spawnEnemy(pickRandomEnemy(), bossPos + offset, currentDay, true)
			end
		end

		-- -- NORMAL SPAWN ------------------------------------
		local baseChance = math.max(2, 7 - math.floor(currentDay / 3))
		if spawnRateBonus.Value > 0 then
			baseChance = math.max(1, math.floor(baseChance / (1 + spawnRateBonus.Value)))
		end

		if math.random(1, baseChance) == 1 then
			local groupSize = math.random(1, 1 + math.floor(currentDay / 5))
			for _ = 1, groupSize do
				if zombieCount >= MAX_ZOMBIES then break end
				local part = partsList[math.random(1, #partsList)]
				if part:IsA("BasePart") then
					spawnEnemy(pickRandomEnemy(), part.Position + Vector3.new(math.random(-2,2), 8, math.random(-2,2)), currentDay, false)
				end
			end
		end
	else
		-- -- DAYTIME -----------------------------------------
		if bossNightActive then endCrimsonNight() end
		bossSpawned = false

		for _, enemy in ipairs(enemyFolder:GetChildren()) do
			local h = enemy:FindFirstChild("Humanoid")
			if h then
				if h.Health > 0 then
					enemy:SetAttribute("DanoPorSol", true)
					h:TakeDamage(h.MaxHealth * 0.05)
				else
					enemy:Destroy()
				end
			end
		end
	end

	task.wait(CHECK_INTERVAL)
end
