local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local DataStoreService = game:GetService("DataStoreService")

local sendError = ReplicatedStorage.Events:WaitForChild("SendAlert")
local animarCamara = ReplicatedStorage.Events:WaitForChild("cinematic")
local mostrarGUI = ReplicatedStorage.Events:WaitForChild("MostrarGUI")

local startPart = game.Workspace:WaitForChild("START", 10)
local tpPart = game.Workspace:WaitForChild("TP", 10)
local mapFolder = workspace:WaitForChild("map")
local barn = mapFolder:WaitForChild("Barn")
local barnHitbox = barn:WaitForChild("HITBOX")
local barnHumanoid = barnHitbox:WaitForChild("Humanoid")

-- Aseguramos los 150 de vida directamente al iniciar el servidor
barnHumanoid.MaxHealth = 150
barnHumanoid.Health = 150

-- Almacenes ordenados para las scoreboards
local DiasDS = DataStoreService:GetOrderedDataStore("Leaderboard_Dias_v1")
local RobuxDS = DataStoreService:GetOrderedDataStore("Leaderboard_Robux_v1")
local TiempoDS = DataStoreService:GetOrderedDataStore("Leaderboard_Tiempo_v1")

-- Eventos de votación
local VotoEvent = ReplicatedStorage.Events:WaitForChild("VotoPartida")
local GameOverEvent = ReplicatedStorage.Events:WaitForChild("GameOver")

local RETRY_PLACE = 92213080106736	
local LOBBY_PLACE = 92388806036847

local juegoIniciado = workspace:WaitForChild("JuegoIniciado")
local activado = false

-- Variables de control para las votaciones
local votos = {
	RETRY = {},
	LOBBY = {}
}
local votacionActiva = false
local tiempoRestante = 23

-- ============================================
-- VARIABLES Y CONFIGURACIÓN DEL DATASTORE
-- ============================================
local PlayerDataStore = DataStoreService:GetDataStore("PlayerStats_v1")
local tiempoEntrada = {} 

local diaActualValue = game.Lighting:WaitForChild("Day", 5)

-- Tutorial guard (lazy lookup so TutorialHandler always runs first)
local function isTutorialActive()
	local ts = ReplicatedStorage:FindFirstChild("TutorialSystem")
	local ta = ts and ts:FindFirstChild("TutorialActive")
	return ta and ta.Value == true
end 

-- ============================================
-- FUNCIONES INTERNAS DEL DATASTORE
-- ============================================
local function cargarDatos(player)
	local key = "Player_" .. player.UserId
	local success, data = pcall(function()
		return PlayerDataStore:GetAsync(key)
	end)

	local statsFolder = Instance.new("Folder")
	statsFolder.Name = "LeaderstatsData"
	statsFolder.Parent = player

	local tiempoTotal = Instance.new("IntValue")
	tiempoTotal.Name = "TiempoTotal"
	tiempoTotal.Parent = statsFolder

	local diaMaximo = Instance.new("IntValue")
	diaMaximo.Name = "DiaMaximo"
	diaMaximo.Parent = statsFolder

	local robuxDonados = Instance.new("IntValue")
	robuxDonados.Name = "RobuxDonados"
	robuxDonados.Parent = statsFolder

	if success and data then
		tiempoTotal.Value = data.TiempoTotal or 0
		diaMaximo.Value = data.DiaMaximo or 0
		robuxDonados.Value = data.RobuxDonados or 0
	else
		tiempoTotal.Value = 0
		diaMaximo.Value = 0
		robuxDonados.Value = 0
	end
end

-- SISTEMA UNIFICADO DE GUARDADO (Local + Scoreboards)
local function guardarDatosCompleto(player)
	if not player:FindFirstChild("LeaderstatsData") then return end

	local key = "Player_" .. player.UserId
	local stats = player.LeaderstatsData

	-- 1. Calcular tiempo de sesión
	local tiempoSesion = 0
	if tiempoEntrada[player] then
		tiempoSesion = os.time() - tiempoEntrada[player]
	end
	local tiempoTotalActualizado = stats.TiempoTotal.Value + tiempoSesion

	-- 2. Guardar en el DataStore principal (Progreso del jugador)
	local dataToSave = {
		TiempoTotal = tiempoTotalActualizado,
		DiaMaximo = stats.DiaMaximo.Value,
		RobuxDonados = stats.RobuxDonados.Value
	}

	local success, err = pcall(function()
		PlayerDataStore:SetAsync(key, dataToSave)
	end)

	if not success then
		warn("No se pudieron guardar los datos locales de " .. player.Name .. ": " .. tostring(err))
	end

	-- 3. Guardar en los OrderedDataStore (Scoreboards globales)
	-- CORRECCIÓN: Guardamos usando player.UserId de forma numérica directa
	local successGlobal, errGlobal = pcall(function()
		local numericId = player.UserId
		DiasDS:SetAsync(numericId, stats.DiaMaximo.Value)
		RobuxDS:SetAsync(numericId, stats.RobuxDonados.Value)
		TiempoDS:SetAsync(numericId, tiempoTotalActualizado)
	end)

	if not successGlobal then
		warn("No se pudieron actualizar las Scoreboards para " .. player.Name .. ": " .. tostring(errGlobal))
	end
end

local function alTerminarPartida()
	local diaAlcanzado = diaActualValue and diaActualValue.Value or 1
	print("¡La partida ha terminado en el día " .. diaAlcanzado .. "! Guardando datos globales...")

	-- Apagar el candado del tutorial por completo
	local ts = ReplicatedStorage:FindFirstChild("TutorialSystem")
	local ta = ts and ts:FindFirstChild("TutorialActive")
	if ta then ta.Value = false end

	for _, player in pairs(Players:GetPlayers()) do
		local stats = player:FindFirstChild("LeaderstatsData")
		if stats then
			-- Actualizar valores locales en vivo antes de lanzar el guardado masivo
			if diaAlcanzado > stats.DiaMaximo.Value then
				stats.DiaMaximo.Value = diaAlcanzado
			end

			-- Forzar el volcado completo a todas las bases de datos
			guardarDatosCompleto(player)

			-- Reiniciar el reloj de sesión para evitar duplicar el tiempo si se quedan en el juego
			tiempoEntrada[player] = os.time()
		end
	end
end

-- ============================================
-- FUNCIONES AUXILIRES DE VOTACIÓN
-- ============================================
local function obtenerConteo()
	return #votos.RETRY, #votos.LOBBY, #Players:GetPlayers()
end

local function ejecutarTeletransporteFinal()
	if not votacionActiva then return end
	votacionActiva = false

	print("Fin de la votación de 23 segundos. Separando grupos...")

	if #votos.RETRY > 0 then
		local success, err = pcall(function()
			TeleportService:TeleportAsync(RETRY_PLACE, votos.RETRY)
		end)
		if not success then warn("Error en TP Retry: " .. tostring(err)) end
	end

	local grupoLobby = {}
	for _, p in pairs(votos.LOBBY) do
		table.insert(grupoLobby, p)
	end

	for _, p in pairs(Players:GetPlayers()) do
		if not table.find(votos.RETRY, p) and not table.find(votos.LOBBY, p) then
			table.insert(grupoLobby, p)
		end
	end

	if #grupoLobby > 0 then
		local success, err = pcall(function()
			TeleportService:TeleportAsync(LOBBY_PLACE, grupoLobby)
		end)
		if not success then warn("Error en TP Lobby: " .. tostring(err)) end
	end
end

local function iniciarCronometroGameOver()
	if votacionActiva then return end
	votacionActiva = true
	votos.RETRY = {}
	votos.LOBBY = {}
	tiempoRestante = 23

	task.spawn(function()
		local vRetry, vLobby, total = obtenerConteo()
		VotoEvent:FireAllClients(vRetry, vLobby, total, tiempoRestante)

		while tiempoRestante > 0 and votacionActiva do
			task.wait(1)
			tiempoRestante -= 1

			local currentRetry, currentLobby, currentTotal = obtenerConteo()
			VotoEvent:FireAllClients(currentRetry, currentLobby, currentTotal, tiempoRestante)
		end

		if votacionActiva then
			ejecutarTeletransporteFinal()
		end
	end)
end

-- ============================================
-- ESCUCHADORES DE EVENTOS DE RED (VOTOS Y CONEXIÓN)
-- ============================================
Players.PlayerAdded:Connect(function(player)
	tiempoEntrada[player] = os.time()
	cargarDatos(player)
end)

Players.PlayerRemoving:Connect(function(player)
	-- Guardado total e inmediato al desconectarse por cualquier motivo
	guardarDatosCompleto(player)

	tiempoEntrada[player] = nil

	local idxR = table.find(votos.RETRY, player)
	local idxL = table.find(votos.LOBBY, player)
	if idxR then table.remove(votos.RETRY, idxR) end
	if idxL then table.remove(votos.LOBBY, idxL) end

	if votacionActiva then
		local vRetry, vLobby, total = obtenerConteo()
		VotoEvent:FireAllClients(vRetry, vLobby, total, tiempoRestante)

		if total > 0 then
			if vRetry == total then
				votacionActiva = false
				TeleportService:TeleportAsync(RETRY_PLACE, Players:GetPlayers())
			elseif vLobby == total then
				votacionActiva = false
				TeleportService:TeleportAsync(LOBBY_PLACE, Players:GetPlayers())
			end
		end
	end
end)

VotoEvent.OnServerEvent:Connect(function(player, tipoVoto)
	if not votacionActiva then return end
	if table.find(votos.RETRY, player) or table.find(votos.LOBBY, player) then return end

	if tipoVoto == "RETRY" then
		table.insert(votos.RETRY, player)
	elseif tipoVoto == "LOBBY" then
		table.insert(votos.LOBBY, player)
	end

	local vRetry, vLobby, total = obtenerConteo()
	VotoEvent:FireAllClients(vRetry, vLobby, total, tiempoRestante)
end)

-- ============================================
-- COMPORTAMIENTO DEL BARN (VIDA Y DESTRUCCIÓN)
-- ============================================
local barnHighlight = Instance.new("Highlight")
barnHighlight.FillColor = Color3.fromRGB(220, 30, 30)
barnHighlight.FillTransparency = 0.5
barnHighlight.OutlineColor = Color3.fromRGB(255, 50, 50)
barnHighlight.OutlineTransparency = 0
barnHighlight.Adornee = barn 
barnHighlight.Enabled = false
barnHighlight.Parent = barn

local barnMuerto = false
local lastBarnHP = barnHumanoid.Health
barnHumanoid.HealthChanged:Connect(function(newHP)
	if newHP < lastBarnHP and not barnMuerto then
		barnHighlight.Enabled = true
		task.delay(0.3, function() barnHighlight.Enabled = false end)
	end
	lastBarnHP = newHP
end)

barnHumanoid.HealthChanged:Connect(function(vida)
	if vida <= 0 and not barnMuerto and juegoIniciado.Value == true then
		barnMuerto = true
		juegoIniciado.Value = false

		-- Laugh sound on barn death
		local playSoundRE = game:GetService("ReplicatedStorage").Events:FindFirstChild("PlaySoundEvent")
		if not playSoundRE then
			playSoundRE = Instance.new("RemoteEvent")
			playSoundRE.Name = "PlaySoundEvent"
			playSoundRE.Parent = game:GetService("ReplicatedStorage").Events
		end
		playSoundRE:FireAllClients("rbxassetid://139944924921354", 1)

		-- Destrucción del Barn
		task.spawn(function()
			for _, part in ipairs(barn:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = false
					local ex = Instance.new("Explosion")
					ex.Position = part.Position
					ex.BlastRadius = 0
					ex.BlastPressure = 0
					ex.Parent = workspace
				end
			end
			task.wait(3)
			barn:Destroy()
		end) 

		alTerminarPartida()

		task.wait(2)

		GameOverEvent:FireAllClients()
		iniciarCronometroGameOver()
	end
end)

-- RED DE SEGURIDAD ABSOLUTA: Cierre inesperado del servidor o crash
game:BindToClose(function()
	for _, player in pairs(Players:GetPlayers()) do
		guardarDatosCompleto(player)
	end
	task.wait(2) -- Tiempo de gracia para solicitudes HTTP salientes de Roblox
end)