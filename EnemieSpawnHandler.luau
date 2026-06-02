-- =============================================================================
-- SERVICIOS DE ROBLOX
-- =============================================================================
local Lighting         = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players          = game:GetService("Players")
local TweenService    = game:GetService("TweenService")

-- =============================================================================
-- REFERENCIAS DEL ENTORNO Y CONFIGURACIÓN
-- =============================================================================
local enemyFolder   = workspace:WaitForChild("enemies") -- Contenedor de enemigos vivos
local mobsFolder    = ReplicatedStorage:WaitForChild("mobs"):WaitForChild("enemies") -- Plantillas
local partsFolder   = workspace:WaitForChild("map"):WaitForChild("floor"):WaitForChild("basepart") -- Zonas de spawn
local partsList     = partsFolder:GetChildren()
local dayValue      = Lighting:WaitForChild("Day") -- Contador de días actual
local juegoIniciado = workspace:WaitForChild("JuegoIniciado") -- Estado de la partida
local sendAlert     = ReplicatedStorage.Events:WaitForChild("SendAlert") -- Alertas UI a clientes

-- Valores de Estado/Mejoras (Buffs comprados o eventos globales)
local buffsFolder        = ReplicatedStorage:WaitForChild("Buffs")
local radarZombiesValue  = buffsFolder:WaitForChild("radarZombies")
local mutantHordeBuff    = buffsFolder:WaitForChild("mutantHorde")
local enemyBonusHealth   = buffsFolder:WaitForChild("enemyBonusHealth")
local spawnRateBonus     = buffsFolder:WaitForChild("spawnRateBonus")

-- Constantes del balance de juego
local MAX_ZOMBIES     = 65 -- Límite máximo de enemigos en el mapa
local START_HOUR      = 19 -- Hora en la que empieza la noche (7 PM)
local END_HOUR        = 6  -- Hora en la que termina la noche (6 AM)
local CHECK_INTERVAL  = 1  -- Frecuencia del bucle principal (en segundos)
local bossSpawned     = false -- Control de aparición única del jefe
local bossNightActive = false -- Estado de la atmósfera "Noche Carmesí"

-- =============================================================================
-- SISTEMA DE OPTIMIZACIÓN (CACHÉ DE ENEMIGOS)
-- =============================================================================
-- Escucha eventos en la carpeta para no recalcular el tamaño de tablas en cada tick
local zombieCount = 0
enemyFolder.ChildAdded:Connect(function()   zombieCount += 1 end)
enemyFolder.ChildRemoved:Connect(function() zombieCount = math.max(0, zombieCount - 1) end)

-- =============================================================================
-- TABLA DE PROBABILIDADES (SISTEMA DE PESOS)
-- =============================================================================
local normalEnemies = {
	{ model = mobsFolder:WaitForChild("Zombie"),         weight = 45 },
	{ model = mobsFolder:WaitForChild("CrawlingZombie"), weight = 15 },
	{ model = mobsFolder:WaitForChild("FastZombie"),     weight = 15 },
	{ model = mobsFolder:WaitForChild("HeavyZombie"),    weight = 10 },
	{ model = mobsFolder:WaitForChild("KamiZombie"),     weight = 8  },
	{ model = mobsFolder:WaitForChild("Flesh Monster"),  weight = 7  },
}

-- Calcular la masa total de probabilidad
local totalWeight = 0
for _, e in ipairs(normalEnemies) do totalWeight += e.weight end

--[[
    Selecciona un enemigo aleatorio respetando la probabilidad de su peso.
]]
local function pickRandomEnemy()
	local roll = math.random(1, totalWeight)
	local acc  = 0
	for _, e in ipairs(normalEnemies) do
		acc += e.weight
		if roll <= acc then return e.model end
	end
	return normalEnemies[1].model -- Retorno de seguridad
end

-- =============================================================================
-- LÓGICA DE SPAWN Y ESCALADO DE ESTADÍSTICAS
-- =============================================================================
local function spawnEnemy(model, position, currentDay, isEscort)
	-- Si el modificador "mutantHorde" está activo, el límite de enemigos concurrentes se reduce a la mitad
	local effectiveMax = (mutantHordeBuff.Value > 0) and math.floor(MAX_ZOMBIES / 2) or MAX_ZOMBIES
	if zombieCount >= effectiveMax then return end

	-- Clonar y desanclar partes físicas para permitir el movimiento
	local newEnemy = model:Clone()
	for _, part in ipairs(newEnemy:GetDescendants()) do
		if part:IsA("BasePart") then part.Anchored = false end
	end

	local humanoid     = newEnemy:FindFirstChild("Humanoid")
	local configFolder = newEnemy:FindFirstChild("Configurations")
	local damageValue  = configFolder and configFolder:FindFirstChild("ATTACK_DAMAGE")

	local isBoss = (model.Name == "Boss")

	-- FÓRMULAS DE ESCALADO POR DÍA
	local hpMult  = 1 + (0.35 * (currentDay - 1))
	local dmgMult = 1 + (0.25 * (currentDay - 1))
	local spdMult = 1 + (0.06 * (currentDay - 1))

	-- Aplicar multiplicadores según los Buffs activos del juego
	if enemyBonusHealth.Value > 0 then
		hpMult = hpMult * (1 + enemyBonusHealth.Value)
	end
	if mutantHordeBuff.Value > 0 and not isBoss then
		hpMult  = hpMult  * 3 -- Multiplica x3 estadísticas si es horda mutante
		dmgMult = dmgMult * 3
	end

	-- Modificadores base exclusivos del Jefe
	if isBoss then
		hpMult  = hpMult  * 3
		dmgMult = dmgMult * 2
	end

	-- Aplicar valores calculados al Humanoid del clon
	if humanoid then
		humanoid.MaxHealth = humanoid.MaxHealth * hpMult
		humanoid.Health    = humanoid.MaxHealth
		humanoid.WalkSpeed = humanoid.WalkSpeed * spdMult
	end
	if damageValue and damageValue:IsA("IntValue") then
		damageValue.Value = math.round(damageValue.Value * dmgMult)
	end

	-- Posicionar en el mapa e integrar en el Workspace
	newEnemy:PivotTo(CFrame.new(position))
	newEnemy.Parent = enemyFolder
end

-- =============================================================================
-- SISTEMA DE VISUALIZACIÓN EN RADAR
-- =============================================================================
local function actualizarHighlights(val)
	for _, enemy in ipairs(enemyFolder:GetChildren()) do
		local hl = enemy:FindFirstChild("RadarHighlight")
		if hl then hl.Enabled = (val > 0) end
	end
end
radarZombiesValue.Changed:Connect(actualizarHighlights)

-- Asegura que los nuevos enemigos respeten el estado del radar al aparecer
enemyFolder.ChildAdded:Connect(function(child)
	task.wait(0.05) -- Breve espera para asegurar la carga de instancias hijas
	local hl = child:FindFirstChild("RadarHighlight")
	if hl then hl.Enabled = (radarZombiesValue.Value > 0) end
end)

-- =============================================================================
-- ADMINISTRACIÓN DE LA ATMÓSFERA: NOCHE CARMESÍ
-- =============================================================================
local originalFogColor  = Lighting.FogColor
local originalFogEnd    = Lighting.FogEnd
local originalAmbient   = Lighting.OutdoorAmbient

local function startCrimsonNight()
	if bossNightActive then return end
	bossNightActive = true
	-- Transición de 4 segundos a un ambiente rojizo y cerrado por niebla
	TweenService:Create(Lighting, TweenInfo.new(4, Enum.EasingStyle.Sine), {
		FogColor        = Color3.fromRGB(80, 5, 5),
		OutdoorAmbient  = Color3.fromRGB(90, 10, 10),
		FogEnd          = 60,
	}):Play()
	sendAlert:FireAllClients("☠ THE BOSS WALKS TONIGHT...")
end

local function endCrimsonNight()
	if not bossNightActive then return end
	bossNightActive = false
	-- Transición de 6 segundos de regreso a la paleta nocturna normal del mapa
	TweenService:Create(Lighting, TweenInfo.new(6, Enum.EasingStyle.Sine), {
		FogColor       = Color3.fromRGB(20, 20, 35),
		OutdoorAmbient = Color3.fromRGB(40, 45, 70),
		FogEnd          = 120,
	}):Play()
end

-- =============================================================================
-- HILO SECUNDARIO: ALERTAS DE MEJORAS (AUGMENTS)
-- =============================================================================
local augAlertSent = -1
task.spawn(function()
	while true do
		task.wait(2)
		if not juegoIniciado.Value then continue end
		local day  = dayValue.Value
		local hour = Lighting.ClockTime
		
		-- Lógica predictiva: Notificar 30s antes de las 9:00 AM en días pares
		if day % 2 == 0 and hour >= 8.85 and hour < 9.0 and augAlertSent ~= day then
			augAlertSent = day
			sendAlert:FireAllClients("⚡ AUGMENT INCOMING in ~30 seconds!")
		end
	end
end)

-- =============================================================================
-- BUCLE PRINCIPAL DEL JUEGO
-- =============================================================================
while not juegoIniciado.Value do task.wait(CHECK_INTERVAL) end -- Bloqueo hasta que comience el juego

while true do
	local currentTime = Lighting.ClockTime
	local isNight     = (currentTime >= START_HOUR or currentTime < END_HOUR)
	local currentDay  = dayValue.Value
	local isBossDay   = (currentDay % 5 == 0) -- Cada 5 días es noche de jefe

	if isNight then
		-- ── COMPORTAMIENTO NOCTURNO: JEFE ──
		if isBossDay and not bossSpawned then
			bossSpawned = true
			startCrimsonNight()

			-- Seleccionar punto aleatorio del suelo y spawnear al Jefe
			local randomPart = partsList[math.random(1, #partsList)]
			local bossPos    = randomPart.Position + Vector3.new(0, 8, 0)
			spawnEnemy(mobsFolder.Boss, bossPos, currentDay, false)

			-- Mecánica de Escolta: Generar un anillo de 4 a 6 zombis normales alrededor del Jefe
			local escortCount = math.random(4, 6)
			for i = 1, escortCount do
				local angle  = (i / escortCount) * math.pi * 2
				local offset = Vector3.new(math.cos(angle) * 6, 8, math.sin(angle) * 6)
				spawnEnemy(pickRandomEnemy(), bossPos + offset, currentDay, true)
			end
		end

		-- ── COMPORTAMIENTO NOCTURNO: SPAWN ORDINARIO ──
		-- La probabilidad base aumenta con los días (la probabilidad disminuye el divisor 'baseChance')
		local baseChance = math.max(2, 7 - math.floor(currentDay / 3))
		if spawnRateBonus.Value > 0 then
			baseChance = math.max(1, math.floor(baseChance / (1 + spawnRateBonus.Value)))
		end

		-- Intento aleatorio de generación
		if math.random(1, baseChance) == 1 then
			-- El tamaño del grupo de enemigos que spawnean juntos crece cada 5 días
			local groupSize = math.random(1, 1 + math.floor(currentDay / 5))
			for _ = 1, groupSize do
				if zombieCount >= MAX_ZOMBIES then break end
				local part = partsList[math.random(1, #partsList)]
				if part:IsA("BasePart") then
					-- Spawn con desfase aleatorio para evitar colisiones idénticas
					spawnEnemy(pickRandomEnemy(), part.Position + Vector3.new(math.random(-2,2), 8, math.random(-2,2)), currentDay, false)
				end
			end
		end
	else
		-- ── COMPORTAMIENTO DIURNO (LIMPIEZA) ──
		if bossNightActive then endCrimsonNight() end
		bossSpawned = false

		-- Mecánica de Quemadura Solar: Los enemigos sufren un 5% de su daño máximo por segundo
		for _, enemy in ipairs(enemyFolder:GetChildren()) do
			local h = enemy:FindFirstChild("Humanoid")
			if h then
				if h.Health > 0 then
					enemy:SetAttribute("DanoPorSol", true)
					h:TakeDamage(h.MaxHealth * 0.05)
				else
					enemy:Destroy() -- Limpieza si ya están muertos
				end
			end
		end
	end

	task.wait(CHECK_INTERVAL) -- Pausa del bucle
end
