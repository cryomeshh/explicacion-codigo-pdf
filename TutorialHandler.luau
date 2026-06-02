-- ============================================================
-- TUTORIAL HANDLER v3 (STABLE & PERFECT INTEGRATION)
-- PHASE 1: Farm  |  PHASE 2: Combat
-- ============================================================
local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
-- Runtime structure (survives restarts)
local tutSys = RS:FindFirstChild("TutorialSystem") or Instance.new("Folder")
tutSys.Name = "TutorialSystem"; tutSys.Parent = RS
local tutEvents = tutSys:FindFirstChild("Events") or Instance.new("Folder")
tutEvents.Name = "Events"; tutEvents.Parent = tutSys
local function getOrCreateRE(name)
	local re = tutEvents:FindFirstChild(name)
	if not re then re = Instance.new("RemoteEvent"); re.Name = name; re.Parent = tutEvents end
	return re
end
local function getOrCreateVal(name, cls, def)
	local v = tutSys:FindFirstChild(name)
	if not v then v = Instance.new(cls); v.Name = name; v.Value = def; v.Parent = tutSys end
	return v
end
local voteEvent      = getOrCreateRE("TutorialVote")
local voteUpdate     = getOrCreateRE("TutorialVoteUpdate")
local stepEvent      = getOrCreateRE("TutorialStep")
local completeEvent = getOrCreateRE("TutorialComplete")
local skipEvent      = getOrCreateRE("TutorialSkip")
local skipMidEvent   = getOrCreateRE("TutorialSkipMid")
local skipMidUpdate = getOrCreateRE("TutorialSkipMidUpdate")
local augPickedRE    = getOrCreateRE("TutorialAugmentPicked")
local stepSoundRE     = getOrCreateRE("TutorialStepSound")
local compassOpenedRE = getOrCreateRE("TutorialCompassOpened")
local tutActive      = getOrCreateVal("TutorialActive", "BoolValue", false)
local tutStepVal     = getOrCreateVal("TutorialStep",   "IntValue",  0)

-- All game-world refs are nil until the place loads them
local juegoIniciado, tpPart, tpStart, mapFolder, buttons
local cinematic, mostrarGUI, sendAlert
local wheatBtn1, wheatBtn2, potatoBtn3, carrotBtn4, tomatoBtn5
local wall1, wall2, wall3, enemyFolder, mobsFolder
local DUMMY_POS = Vector3.new(-93.474, 5.533, -29.175)

local function initWorldRefs()
	juegoIniciado = workspace:FindFirstChild("JuegoIniciado")
	if not juegoIniciado then return false end
	tpPart       = workspace:FindFirstChild("TP")
	tpStart      = workspace:FindFirstChild("StartTP")
	mapFolder    = workspace:FindFirstChild("map")
	if not mapFolder then return false end
	buttons      = mapFolder:FindFirstChild("buttons")
	if not buttons then return false end
	cinematic    = RS.Events:FindFirstChild("cinematic")
	mostrarGUI   = RS.Events:FindFirstChild("MostrarGUI")
	sendAlert    = RS.Events:FindFirstChild("SendAlert")
	wheatBtn1    = buttons.wheat and buttons.wheat:FindFirstChild("1")
	wheatBtn2    = buttons.wheat and buttons.wheat:FindFirstChild("2")
	potatoBtn3   = buttons.potato and buttons.potato:FindFirstChild("3")
	carrotBtn4   = buttons.carrot and buttons.carrot:FindFirstChild("4")
	tomatoBtn5   = buttons.tomato and buttons.tomato:FindFirstChild("5")
	wall1        = buttons.MainWalls and buttons.MainWalls:FindFirstChild("1")
	wall2        = buttons.MainWalls and buttons.MainWalls:FindFirstChild("2")
	wall3        = buttons.MainWalls and buttons.MainWalls:FindFirstChild("3")
	enemyFolder  = workspace:FindFirstChild("enemies")
	mobsFolder   = RS:FindFirstChild("mobs") and RS.mobs:FindFirstChild("enemies")
	return true
end
-- ============================================================
-- HELPERS
-- ============================================================
local function isGone(part) return not part or not part.Parent end
-- Forzar 0 absoluto de recursos al finalizar
local function clearResources(forceZero)
	for _, p in pairs(Players:GetPlayers()) do
		local res = p:FindFirstChild("resources")
		if res then
			for _, s in ipairs(res:GetChildren()) do
				if s:IsA("IntValue") or s:IsA("NumberValue") then 
					s.Value = forceZero and 0 or 1000
				end
			end
		end
		local ls = p:FindFirstChild("leaderstats")
		local gold = ls and (ls:FindFirstChild("Gold") or ls:FindFirstChild("gold"))
		if gold and forceZero then gold.Value = 0 end
	end
end
local function totalResource(name)
	local t = 0
	for _, p in pairs(Players:GetPlayers()) do
		local res = p:FindFirstChild("resources")
		local s = res and res:FindFirstChild(name)
		if s then t += s.Value end
	end
	return t
end
local function playStepSound()
	stepSoundRE:FireAllClients()
end
local function advanceStep(id, data)
	tutStepVal.Value = id
	stepEvent:FireAllClients(id, data or {})
	playStepSound()
end
local function giveStartedSword()
	local template = RS.weapons:FindFirstChild("started") or RS.weapons:WaitForChild("started", 5)
	if not template then 
		warn("[Tutorial Error] No se encontro la espada en ReplicatedStorage.weapons")
		return 
	end
	for _, p in pairs(Players:GetPlayers()) do
		local bp = p:FindFirstChildOfClass("Backpack")
		local sg = p:FindFirstChildOfClass("StarterGear")
		local tieneEnMochila = bp and bp:FindFirstChild("started")
		local tieneEnMano = p.Character and p.Character:FindFirstChild("started")
		if bp and not tieneEnMochila and not tieneEnMano then 
			template:Clone().Parent = bp 
		end
		if sg and not sg:FindFirstChild("started") then 
			template:Clone().Parent = sg 
		end
	end
end
-- ============================================================
-- SKIP-MID VOTE
-- ============================================================
local skipMidVotes    = {}
local skipMidOpen      = false
local skipMidResolved = false
local skipMidTotal    = 0
local function openSkipMid()
	skipMidOpen = true
	skipMidVotes = {}
	skipMidTotal = #Players:GetPlayers()
	skipMidUpdate:FireAllClients(0, skipMidTotal)
end
skipMidEvent.OnServerEvent:Connect(function(player)
	if not skipMidOpen then return end
	if table.find(skipMidVotes, player) then return end
	table.insert(skipMidVotes, player)
	local total = #Players:GetPlayers()
	skipMidUpdate:FireAllClients(#skipMidVotes, total)
	if #skipMidVotes >= total then
		skipMidResolved = true; skipMidOpen = false
	end
end)
local function waitOrSkip(condFn)
	while true do
		task.wait(0.8)
		if skipMidResolved then return "skip" end
		if condFn() then return "done" end
	end
end
-- ============================================================
-- DUMMY SPAWNER
-- ============================================================
local tutDummies = {}
local function spawnDummy(modelName, pos, scale)
	local template = mobsFolder:FindFirstChild(modelName)
	if not template then return nil end
	local d = template:Clone()
	d:SetAttribute("TutorialDummy", true)
	for _, s in ipairs(d:GetDescendants()) do
		if s:IsA("Script") or s:IsA("LocalScript") then s.Enabled = false end
	end
	local hum = d:FindFirstChild("Humanoid")
	local hrp = d:FindFirstChild("HumanoidRootPart") 
		or d:FindFirstChild("Torso") 
		or d:FindFirstChild("UpperTorso") 
		or d.PrimaryPart 
		or d:FindFirstChildWhichIsA("BasePart")
	if hum and hrp then
		hum.WalkSpeed = 0; hum.JumpPower = 0
		hum.EvaluateStateMachine = true 
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		-- === RECONSTRUCCIÓN DE TU BARRA DE VIDA PROPIA ===
		local bg = Instance.new("BillboardGui", hrp)
		bg.Size = UDim2.new(4,0,0.5,0); bg.StudsOffset = Vector3.new(0,4,0); bg.Adornee = hrp
		local backgroundFrame = Instance.new("Frame", bg)
		backgroundFrame.Size = UDim2.new(1,0,1,0); backgroundFrame.BackgroundColor3 = Color3.fromRGB(50,50,50); backgroundFrame.BorderSizePixel = 0
		local healthBar = Instance.new("Frame", backgroundFrame)
		healthBar.Size = UDim2.new(1,0,1,0); healthBar.BackgroundColor3 = Color3.fromRGB(0,200,0); healthBar.BorderSizePixel = 0
		Instance.new("UICorner", backgroundFrame).CornerRadius = UDim.new(0.3,0)
		Instance.new("UICorner", healthBar).CornerRadius = UDim.new(0.3,0)
		hum.HealthChanged:Connect(function(healthValue)
			local healthPercentage = math.clamp(healthValue/hum.MaxHealth,0,1)
			healthBar.Size = UDim2.new(healthPercentage,0,1,0)
			healthBar.BackgroundColor3 = healthPercentage > 0.5 and Color3.fromRGB(0,200,0) or healthPercentage > 0.25 and Color3.fromRGB(255,165,0) or Color3.fromRGB(200,0,0)
		end)
		hum.Died:Connect(function()
			-- Give gold to nearest player (tutorial feedback)
			local nearestPlayer, minDist = nil, math.huge
			for _, p in ipairs(Players:GetPlayers()) do
				local proot = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
				if proot then
					local dist = hrp and (hrp.Position - proot.Position).Magnitude or 0
					if dist < minDist then minDist = dist; nearestPlayer = p end
				end
			end
			if nearestPlayer then
				local res = nearestPlayer:FindFirstChild("resources")
				local gold = res and res:FindFirstChild("gold")
				if gold then gold.Value += math.random(2, 5) end
			end
			task.wait(0.2)
			d:Destroy()
		end)
	end
	for _, part in ipairs(d:GetDescendants()) do
		if part:IsA("BasePart") then 
			part.Anchored = false 
			part.CanCollide = true 
			part.CanTouch = true      
		end
	end
	d:PivotTo(CFrame.new(pos))
	local modelSize = d:GetExtentsSize()
	local groundOffset = modelSize.Y / 2
	local finalCFrame = CFrame.new(pos.X, pos.Y + groundOffset, pos.Z) * CFrame.Angles(0, math.rad(180), 0)
	d:PivotTo(finalCFrame)
	if hrp then hrp.Anchored = true end
	d.Parent = enemyFolder
	table.insert(tutDummies, d)
	task.spawn(function()
		local t = 0
		while not _G.rastrearDamage and t < 5 do
			task.wait(0.2)
			t += 0.2
		end
		if _G.rastrearDamage then _G.rastrearDamage(d) end
	end)
	return d
end
local function clearDummies()
	for _, d in ipairs(tutDummies) do if d and d.Parent then d:Destroy() end end
	tutDummies = {}
end
local function countAlive()
	local n = 0
	for _, d in ipairs(tutDummies) do
		if d and d.Parent then
			local h = d:FindFirstChild("Humanoid")
			if h and h.Health > 0 then n += 1 end
		end
	end
	return n
end
-- ============================================================
-- LAUNCH GAME
-- ============================================================
local function applySkipBuffs()
	-- Wait for BuffsHandler to create the Buffs folder
	local buffs = game:GetService("ReplicatedStorage"):WaitForChild("Buffs", 10)
	if not buffs then return end

	-- x2 harvest: set multis to 2 (they start at 1, this doubles them)
	for _, key in ipairs({"wheatMulti", "potatoMulti", "carrotMulti", "tomatoMulti"}) do
		local b = buffs:FindFirstChild(key)
		if b and b.Value <= 1 then b.Value = 2 end  -- only apply if not already boosted by augments
	end

	-- +50% speed base (add 0.5 to whatever speed buff exists)
	local speed = buffs:FindFirstChild("speed")
	if speed then speed.Value = math.max(speed.Value, 0.5) end
end
local function launchGame()
	if juegoIniciado.Value then return end
	tutActive.Value = false
	clearResources(true)  -- reset all resources before real game starts
	local target = tpStart or tpPart
	local spawn = Instance.new("SpawnLocation")
	spawn.Size = Vector3.new(target.Size.X, 1, target.Size.Z)
	spawn.CFrame = target.CFrame + Vector3.new(0, target.Size.Y/2+0.5, 0)
	spawn.Anchored = true; spawn.Transparency = 1
	spawn.CanCollide = false; spawn.Enabled = true; spawn.Neutral = true
	spawn.Parent = workspace
	for _, p in pairs(Players:GetPlayers()) do
		p.RespawnLocation = spawn
		if p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
			p.Character.HumanoidRootPart.CFrame = target.CFrame + Vector3.new(0,3,0)
		end
		cinematic:FireClient(p, target)
	end
	juegoIniciado.Value = true
	task.wait(3)
	for _, p in pairs(Players:GetPlayers()) do
		mostrarGUI:FireClient(p)
		sendAlert:FireClient(p, "DEFEND YOUR FARM OR DIE")
	end
end
-- ============================================================
-- PHASE 1: FARM
-- ============================================================
local function runPhase1()
	tutActive.Value = true
	clearResources(false)
	openSkipMid()

	-- STEP 1: Harvest 20 wheat
	advanceStep(1, {})
	local r = waitOrSkip(function() return totalResource("wheat") >= 20 end)
	if r == "skip" then return end

	-- STEP 2: Open the compass (tutorial step)
	local compassOpened = false
	local compassConn
	compassConn = compassOpenedRE.OnServerEvent:Connect(function()
		compassOpened = true
	end)
	stepEvent:FireAllClients("compass_tip", {})
	stepSoundRE:FireAllClients()
	-- Wait until compass opened, then give 6 more seconds to read
	r = waitOrSkip(function() return compassOpened end)
	if compassConn then compassConn:Disconnect() end
	if r == "skip" then return end
	task.wait(6)  -- 6s to read after opening

	-- STEP 3: Buy wheat button 1
	advanceStep(2, {})
	task.wait(2)
	r = waitOrSkip(function() return isGone(wheatBtn1) end)
	if r == "skip" then return end
	advanceStep(3, {})
	r = waitOrSkip(function() return isGone(wall1) end)
	if r == "skip" then return end
	advanceStep(4, {})
	r = waitOrSkip(function() return isGone(potatoBtn3) end)
	if r == "skip" then return end
	advanceStep(5, {})
	r = waitOrSkip(function() return isGone(wheatBtn2) end)
	if r == "skip" then return end
	advanceStep(6, {})
	r = waitOrSkip(function() return isGone(wall2) end)
	if r == "skip" then return end
	advanceStep(7, {})
	r = waitOrSkip(function() return isGone(carrotBtn4) end)
	if r == "skip" then return end
	advanceStep(8, {})
	r = waitOrSkip(function() return isGone(wall3) end)
	if r == "skip" then return end
	advanceStep(9, {})
	r = waitOrSkip(function() return isGone(tomatoBtn5) end)
	if r == "skip" then return end
	advanceStep(10, {})
	task.wait(3)
end
-- ============================================================
-- PHASE 2: COMBAT
-- ============================================================
local function runPhase2()
	clearResources(false)
	skipMidResolved = false
	openSkipMid()
	local listaJugadores = Players:GetPlayers()
	local totalJugadores = #listaJugadores
	local centroCFrame = tpPart.CFrame + Vector3.new(0, 3, 0)
	local espaciado = 4 
	for i, p in ipairs(listaJugadores) do
		if p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
			local offsetLateral = (i - (totalJugadores + 1) / 2) * espaciado
			local cframeDestino = centroCFrame * CFrame.new(offsetLateral, 0, 0)
			p.Character.HumanoidRootPart.CFrame = cframeDestino
			local hum = p.Character:FindFirstChildOfClass("Humanoid")  -- FIX: define hum here
			if hum then
				hum.WalkSpeed = 0
				hum.JumpPower = 0
				task.delay(3, function()
					if hum and hum.Parent then
						hum.WalkSpeed = 16
						hum.JumpPower = 50
					end
				end)
			end
		end
	end
	task.wait(2.5)
	giveStartedSword()
	advanceStep(11, {})
	task.wait(3.6) 
	local z1 = spawnDummy("Zombie", DUMMY_POS, 1)
	local z2 = spawnDummy("Zombie", DUMMY_POS + Vector3.new(-6, 0, 0), 1)
	local z3 = spawnDummy("Zombie", DUMMY_POS + Vector3.new(6, 0, 0), 1)
	-- STEP 12: MATAR ZOMBIES
	advanceStep(12, {})
	local goldTipSent = false
	local prevAlive = 3
	while countAlive() > 0 do
		task.wait(0.5)
		if skipMidResolved then break end
		local alive = countAlive()
		if not goldTipSent and alive < prevAlive then
			goldTipSent = true
			stepEvent:FireAllClients(12, { goldTip = true })
		end
		prevAlive = alive
	end
	if skipMidResolved then clearDummies(); return end
	-- STEP 13: SELECCIÓN DE AUMENTO
	advanceStep(13, {})

	-- Fire the real AugmentsGui with 3 fixed tutorial perks (cost = 0)
	local augShowCards = RS.AugmentSystem.Events:FindFirstChild("AugmentShowCards")
	local augBuyRE     = RS.AugmentSystem.Events:FindFirstChild("AugmentBuy")
	if augShowCards then
		local tutCards = {
			{ index=1, id="PercentStrike", name="Percent Strike", rarity="Epic",
			  description="Attacks deal +1.5% of enemy max HP as bonus damage.",
			  colorR=163/255, colorG=53/255, colorB=238/255,
			  costGold=0, costWheat=0, costPotato=0, costCarrot=0, costTomato=0, stackCount=0 },
			{ index=2, id="EarthBlessing", name="Earth Blessing", rarity="Legendary",
			  description="+2 res/s, +50% HP, +15% speed, +1% HP regen/s.",
			  colorR=255/255, colorG=185/255, colorB=0/255,
			  costGold=0, costWheat=0, costPotato=0, costCarrot=0, costTomato=0, stackCount=0 },
			{ index=3, id="FarmDouble", name="Farm Double", rarity="Common",
			  description="+2% chance to harvest double on E press.",
			  colorR=160/255, colorG=160/255, colorB=160/255,
			  costGold=0, costWheat=0, costPotato=0, costCarrot=0, costTomato=0, stackCount=0 },
		}
		augShowCards:FireAllClients(tutCards, 0)
	end

	-- Listen on AugmentBuy as fallback (player clicks BUY in AugmentsGui)
	local tutorialAugmentSelectionDone = false
	local selectedPerkId = nil
	local augConn = nil
	local augBuyConn = nil

	augConn = augPickedRE.OnServerEvent:Connect(function(player, perkId)
		if tutorialAugmentSelectionDone then return end
		selectedPerkId = perkId
		tutorialAugmentSelectionDone = true
	end)

	if augBuyRE then
		augBuyConn = augBuyRE.OnServerEvent:Connect(function(player, cardIndex)
			if tutorialAugmentSelectionDone then return end
			local ids = {"PercentStrike", "EarthBlessing", "FarmDouble"}
			selectedPerkId = ids[cardIndex]
			tutorialAugmentSelectionDone = true
		end)
	end

	while not tutorialAugmentSelectionDone do
		task.wait(0.5)
		if skipMidResolved then tutorialAugmentSelectionDone = true end
	end
	if augConn then augConn:Disconnect(); augConn = nil end
	if augBuyConn then augBuyConn:Disconnect(); augBuyConn = nil end
	if skipMidResolved then clearDummies(); return end
	if selectedPerkId then
		local buffs = RS:FindFirstChild("Buffs")
		if buffs then
			if selectedPerkId == "PercentStrike" then
				local b = buffs:FindFirstChild("percentStrike"); if b then b.Value += 0.02 end
			elseif selectedPerkId == "EarthBlessing" then
				for _, k in ipairs({"wheatPerSecond","potatoPerSecond","carrotPerSecond","tomatoPerSecond"}) do
					local b = buffs:FindFirstChild(k); if b then b.Value += 2 end
				end
				local h = buffs:FindFirstChild("health"); if h then h.Value += 0.50 end
				local s = buffs:FindFirstChild("speed");  if s then s.Value += 0.15 end
				local rg = buffs:FindFirstChild("hpregPLAYER"); if rg then rg.Value += 0.01 end
				local eb = buffs:FindFirstChild("earthBlessing"); if eb then eb.Value = 1 end
			elseif selectedPerkId == "FarmDouble" then
				local b = buffs:FindFirstChild("farmDoubleChance"); if b then b.Value += 0.02 end
			end
		end
		stepEvent:FireAllClients(13, { augmentApplied = selectedPerkId })
		playStepSound()
	end
	task.wait(2)
	-- STEP 14: BOSS
	advanceStep(14, {})
	task.wait(1)
	local BOSS_POS = DUMMY_POS + Vector3.new(0, 0, -15)
	local boss = spawnDummy("Boss", BOSS_POS, 1.4)
	while true do
		task.wait(0.5)
		if skipMidResolved then break end
		if not boss or not boss.Parent then break end
		local bHum = boss:FindFirstChild("Humanoid")
		if bHum and bHum.Health <= 0 then break end
	end
	clearDummies()
	if skipMidResolved then return end
	-- STEP 15: FINAL
	advanceStep(15, {})
	clearResources(true)
	for _, p in pairs(Players:GetPlayers()) do
		if p.Character then
			local hum = p.Character:FindFirstChild("Humanoid")
			if hum then 
				hum.WalkSpeed = 0 
				hum.JumpPower = 0 
			end
		end
	end
	task.wait(3.5)
end  -- closes runPhase2

-- ============================================================
-- FULL RUN
-- ============================================================
local function runTutorial()
	runPhase1()
	if skipMidResolved then
		giveStartedSword()
		applySkipBuffs()  
		skipEvent:FireAllClients()
	else
		runPhase2()
		completeEvent:FireAllClients()
	end
	task.wait(1.5)
	launchGame()
end
-- ============================================================
-- INITIAL VOTE (CON CUENTA REGRESIVA DE 20 SEGUNDOS REAL)
-- ============================================================
local votes = { tutorial = {}, skip = {} }
local voteOpen = false
local function startVotePhase()
	voteOpen = true; votes = { tutorial = {}, skip = {} }
	local total = #Players:GetPlayers()
	for secondsLeft = 20, 0, -1 do
		if not voteOpen then break end
		total = #Players:GetPlayers()
		local tut, sk = #votes.tutorial, #votes.skip
		voteUpdate:FireAllClients(tut, sk, total, secondsLeft)
		if tut >= math.ceil(total/2) or sk >= math.ceil(total/2) then
			voteOpen = false; break
		end
		task.wait(1)
	end
	voteOpen = false
	local tutFinal, skFinal = #votes.tutorial, #votes.skip
	if tutFinal >= skFinal then
		task.spawn(runTutorial)
	else
	-- Si eligen Skip, se les entrega la espada inicial y buffs compensatorios
		giveStartedSword()
		applySkipBuffs() 
		skipEvent:FireAllClients()
		task.wait(2); launchGame()
	end
end
voteEvent.OnServerEvent:Connect(function(player, choice)
	if not voteOpen then return end
	if table.find(votes.tutorial, player) or table.find(votes.skip, player) then return end
	if choice == "tutorial" then table.insert(votes.tutorial, player)
	elseif choice == "skip" then table.insert(votes.skip, player) end
	voteUpdate:FireAllClients(#votes.tutorial, #votes.skip, #Players:GetPlayers(), nil)
end)

-- When a player joins mid-vote, send current state
Players.PlayerAdded:Connect(function(player)
	if voteOpen then
		task.wait(2)  -- wait for client GUI to load
		voteUpdate:FireClient(player, #votes.tutorial, #votes.skip, #Players:GetPlayers(), nil)
	end
end)
task.spawn(function()
	warn("[TUT] task.spawn started")
	if #Players:GetPlayers() == 0 then Players.PlayerAdded:Wait() end
	warn("[TUT] player found, calling initWorldRefs")
	initWorldRefs()
	warn("[TUT] initWorldRefs done, calling startVotePhase")
	task.wait(1.5); startVotePhase()
end)