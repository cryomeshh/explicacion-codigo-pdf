-- =============================================================================
-- HANDLER DE AUMENTOS Y PERKS COOPERATIVOS
-- UBICACIÓN: ServerScriptService.MainHandlers.AugmentHandler
-- =============================================================================
-- Se dispara en días específicos a las 9:00 AM del juego.
-- Controla la selección aleatoria de cartas, la lógica cooperativa de compra,
-- la deducción proporcional de recursos y la aplicación de bufos globales.
-- =============================================================================

local Players         = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting        = game:GetService("Lighting")
local TweenService    = game:GetService("TweenService")

-- Importación del módulo de configuración de ventajas y rarezas
local AugmentModule   = require(ReplicatedStorage.AugmentSystem.AugmentModule)
local augEvents       = ReplicatedStorage.AugmentSystem.Events

-- Referencias de estado global y carpetas de red
local buffsFolder     = ReplicatedStorage:WaitForChild("Buffs")
local dayValue        = Lighting:WaitForChild("Day")
local juegoIniciado   = workspace:WaitForChild("JuegoIniciado")

-- Control de comunicación bidireccional (RemoteEvents)
local showCardsEvent  = augEvents:WaitForChild("AugmentShowCards")   -- Envía las 3 cartas a la pantalla
local buyEvent        = augEvents:WaitForChild("AugmentBuy")         -- Escucha la solicitud de compra
local updateEvent     = augEvents:WaitForChild("AugmentUpdateVotes")
local appliedEvent    = augEvents:WaitForChild("AugmentApplied")     -- Notifica el éxito de la compra
local noFundsEvent    = augEvents:WaitForChild("AugmentNoFunds")     -- Alerta de falta de fondos globales

-- =============================================================================
-- ESTADO DE LA SESIÓN DE MEJORAS
-- =============================================================================
local activePerks      = {}  -- Diccionario interno hash: [perkId] = cantidadDeAcumulaciones (stacks)
local sessionActive    = false -- Bloqueo lógico: Evita compras duplicadas o múltiples por día
local currentCards     = {}  -- Contenedor de las 3 tablas de datos de perks elegidas en la ronda actual
local lastTriggeredDay = -1  -- Bandera preventiva para no ejecutar la sesión dos veces el mismo día

-- =============================================================================
-- ASISTENTES DE ECONOMÍA GLOBAL Y COOPERATIVA
-- =============================================================================
local RESOURCE_KEYS = {"gold", "wheat", "potato", "carrot", "tomato"}

--[[
    Suma las carteras de todos los jugadores presentes en el servidor.
    Retorna una tabla indexada con los totales acumulados de cada recurso.
]]
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

--[[
    Valida si el fondo común de todos los jugadores cubre el costo de una rareza.
]]
local function canAfford(rarityName)
	local cost = AugmentModule.Costs[rarityName]
	if not cost then return false end
	
	local totals = getTotalResources()
	for key, amount in pairs(cost) do
		if (totals[key] or 0) < amount then return false end
	end
	return true
end

--[[
    SISTEMA DE COBRO PROPORCIONAL: Deduce recursos de las carteras individuales de
    forma equitativa basándose en el porcentaje de riqueza que posee cada jugador.
]]
local function deductResources(rarityName)
	local cost = AugmentModule.Costs[rarityName]
	if not cost then return end
	
	for key, totalCost in pairs(cost) do
		if totalCost <= 0 then continue end
		
		-- Calcular el total disponible de este recurso específico en la sesión actual
		local grandTotal = 0
		for _, player in ipairs(Players:GetPlayers()) do
			local res = player:FindFirstChild("resources")
			if res then
				local stat = res:FindFirstChild(key)
				if stat then grandTotal += stat.Value end
			end
		end
		if grandTotal <= 0 then continue end
		
		-- Repartir la deuda proporcionalmente
		local remaining = totalCost
		local playerList = Players:GetPlayers()
		
		for i, player in ipairs(playerList) do
			local res = player:FindFirstChild("resources")
			if not res then continue end
			local stat = res:FindFirstChild(key)
			if not stat then continue end
			
			local share
			if i == #playerList then
				share = remaining  -- Red de seguridad: El último jugador absorbe los decimales flotantes por redondeo
			else
				-- El costo se calcula multiplicando el precio por el porcentaje de aporte del jugador
				share = math.floor(totalCost * (stat.Value / grandTotal))
			end
			
			share = math.min(share, stat.Value) -- Impedir cobros superiores al dinero real del jugador
			stat.Value -= share
			remaining -= share -- Descontar del saldo restante de la deuda
		end
	end
end

-- =============================================================================
-- LOGÍSTICA DE APLICACIÓN Y EFECTOS DE VENTAJAS (PERKS)
-- =============================================================================
local function applyPerk(perk)
	local stacks = (activePerks[perk.id] or 0) + 1
	activePerks[perk.id] = stacks -- Registrar acumulación del bufo
	
	-- Incremento base sobre el multiplicador global
	local buff = buffsFolder:FindFirstChild(perk.buffKey)
	if buff then
		buff.Value += perk.effectValue
	end
	
	-- Efectos secundarios perjudiciales o de balance (Exclusivo de cartas Épicas)
	if perk.sideEffect then
		local seBuff = buffsFolder:FindFirstChild(perk.sideEffect.buffKey)
		if seBuff then
			seBuff.Value += perk.sideEffect.value
		end
	end
	
	-- COMPORTAMIENTO COMPUESTO: Perk Legendario "Bendición de la Tierra" (EarthBlessing)
	if perk.id == "EarthBlessing" then
		-- Otorga de forma pasiva +2 unidades por segundo en recursos de agricultura
		local perSecondKeys = {"wheatPerSecond", "potatoPerSecond", "carrotPerSecond", "tomatoPerSecond"}
		for _, k in ipairs(perSecondKeys) do
			local b = buffsFolder:FindFirstChild(k)
			if b then b.Value += 2 end
		end
		-- Incremento masivo de atributos de supervivencia para todos los combatientes
		local hp = buffsFolder:FindFirstChild("health")
		if hp then hp.Value += 0.50 end -- +50% Puntos de vida máximos
		local dmgRed = buffsFolder:FindFirstChild("playerDmgReduction")
		if dmgRed then dmgRed.Value += 0.05 end -- +5% de mitigación de daño
		local spd = buffsFolder:FindFirstChild("speed")
		if spd then spd.Value += 0.15 end -- +15% de velocidad de carrera
		local regen = buffsFolder:FindFirstChild("hpregPLAYER")
		if regen then regen.Value += 0.01 end -- +1% de regeneración de vida por tick
	end
	
	-- COMPORTAMIENTO COMPUESTO: Perk Legendario "Horda Mutante" (MutantHorde)
	if perk.id == "MutantHorde" then
		-- Envía una bandera de activación al script de Spawning para triplicar estadísticas de enemigos
		local b = buffsFolder:FindFirstChild("mutantHorde")
		if b then b.Value = 1 end
	end
	
	-- COMPORTAMIENTO COMPUESTO: Perk Legendario "Aura Eléctrica" (ElectricAura)
	if perk.id == "ElectricAura" then
		local b = buffsFolder:FindFirstChild("electricAura")
		if b then b.Value = 1 end
	end
end

-- =============================================================================
-- SERIALIZACIÓN Y EMPAQUETADO PARA RED (NETWORK CONVERTER)
-- =============================================================================
--[[
    Traduce tablas complejas de objetos del servidor a diccionarios primitivos ligeros.
    Esto permite transmitirlos a través de RemoteEvents sin sobrecargar el ancho de banda.
]]
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

-- =============================================================================
-- INICIO DE INTERFAZ DE ELECCIÓN DE CARTAS
-- =============================================================================
local function startAugmentSession(dayNum)
	if sessionActive then return end
	sessionActive = true
	
	-- Invocar método externo para filtrar y obtener 3 aumentos pseudoaleatorios
	currentCards = AugmentModule.PickThreePerks(activePerks)
	if #currentCards == 0 then
		sessionActive = false
		return
	end
	
	local serialized = serializeCards(currentCards)
	showCardsEvent:FireAllClients(serialized, dayNum) -- Desplegar pantallas en todos los clientes
end

-- =============================================================================
-- MANEJO DEL BOTÓN DE COMPRA (ESTILO COOPERATIVO VELOZ)
-- =============================================================================
-- El primer jugador que presione comprar en su pantalla adquiere el aumento para todo el equipo.
buyEvent.OnServerEvent:Connect(function(player, cardIndex)
	if not sessionActive then return end
	if type(cardIndex) ~= "number" then return end
	
	local perk = currentCards[cardIndex]
	if not perk then return end
	
	-- Control financiero
	if not canAfford(perk.rarity) then
		noFundsEvent:FireAllClients(perk.name, perk.rarity) -- Emitir error visual de fondos insuficientes
		return
	end
	
	-- Candado de exclusión inmediata: Evita que pulsaciones simultáneas en el mismo milisegundo cobren doble
	sessionActive = false
	
	deductResources(perk.rarity) -- Descontar recursos de forma equitativa
	applyPerk(perk)            -- Aplicar bufos lógicos a las variables
	
	-- Generar historial y estado actual de ventajas activas para actualizar el inventario UI de los clientes
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
	
	-- Propagar la confirmación de adquisición y quién fue el comprador a todo el servidor
	appliedEvent:FireAllClients(perk.name, perk.rarity, color.R, color.G, color.B, player.Name, activeList)
end)

-- =============================================================================
-- DISPARADOR HORARIO DEL EVENTO (SISTEMA DE RELOJ DE ALTA PRECISIÓN)
-- =============================================================================
local previousClock = Lighting.ClockTime

task.spawn(function()
	while true do
		task.wait(0.5) -- Muestreo continuo cada medio segundo
		
		if not juegoIniciado.Value then
			previousClock = Lighting.ClockTime
			continue
		end
		
		local currentClock = Lighting.ClockTime
		local currentDay   = dayValue.Value
		
		-- Intercepción matemática: Evalúa si la aguja horaria acaba de cruzar el umbral de las 9:00 AM
		local crossed9AM = (previousClock < 9.0 and currentClock >= 9.0)
		
		-- Caso borde de resguardo: Captura transiciones de reinicio de ciclo de medianoche
		local wrappedCross = (previousClock > 20.0 and currentClock < 9.0 and currentClock >= 0)
		
		-- Lógica de disparo: Verifica que se crucen las 9:00 AM y que no se haya ejecutado ya en el presente día
		if crossed9AM and currentDay % 1 == 0 and currentDay ~= lastTriggeredDay then
			lastTriggeredDay = currentDay
			task.spawn(startAugmentSession, currentDay) -- Arrancar sesión en un nuevo hilo para no colgar el reloj
		end
		
		previousClock = currentClock -- Actualizar marca horaria del cuadro anterior
	end
end)
