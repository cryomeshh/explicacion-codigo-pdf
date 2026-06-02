-- =============================================================================
-- SERVICIOS CENTRALES DE ROBLOX
-- =============================================================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService") -- Gestiona el viaje entre servidores/lugares
local DataStoreService = game:GetService("DataStoreService") -- Servicio de base de datos en la nube

-- =============================================================================
-- EVENTOS DE RED AND CONFIGURACIÓN DE INSTANCIAS
-- =============================================================================
local sendError = ReplicatedStorage.Events:WaitForChild("SendAlert")
local animarCamara = ReplicatedStorage.Events:WaitForChild("cinematic")
local mostrarGUI = ReplicatedStorage.Events:WaitForChild("MostrarGUI")

local startPart = game.Workspace:WaitForChild("START", 10)
local tpPart = game.Workspace:WaitForChild("TP", 10)
local mapFolder = workspace:WaitForChild("map")
local barn = mapFolder:WaitForChild("Barn") -- Estructura objetivo que los jugadores defienden
local barnHitbox = barn:WaitForChild("HITBOX")
local barnHumanoid = barnHitbox:WaitForChild("Humanoid")

-- Inicialización forzada de la vida del objetivo del juego
barnHumanoid.MaxHealth = 150
barnHumanoid.Health = 150

-- Inicialización de Almacenes Ordenados para Tablas de Clasificación Globales
local DiasDS = DataStoreService:GetOrderedDataStore("Leaderboard_Dias_v1")
local RobuxDS = DataStoreService:GetOrderedDataStore("Leaderboard_Robux_v1")
local TiempoDS = DataStoreService:GetOrderedDataStore("Leaderboard_Tiempo_v1")

-- Eventos de comunicación Servidor-Cliente para la fase final del juego
local VotoEvent = ReplicatedStorage.Events:WaitForChild("VotoPartida")
local GameOverEvent = ReplicatedStorage.Events:WaitForChild("GameOver")

-- Identificadores de Universos/Lugares en Roblox (Asset IDs)
local RETRY_PLACE = 92213080106736	-- ID del mapa de juego (Reiniciar)
local LOBBY_PLACE = 92388806036847 -- ID del Lobby principal

local juegoIniciado = workspace:WaitForChild("JuegoIniciado")
local activado = false

-- Estructura de datos para el control de la votación democrática de fin de juego
local votos = {
	RETRY = {}, -- Lista de jugadores que quieren reintentar
	LOBBY = {}  -- Lista de jugadores que quieren ir al lobby
}
local votacionActiva = false
local tiempoRestante = 23 -- Duración de la votación en segundos

-- =============================================================================
-- VARIABLES Y ALMACENAMIENTO LOCAL DEL DATASTORE
-- =============================================================================
local PlayerDataStore = DataStoreService:GetDataStore("PlayerStats_v1") -- Base de datos persistente estándar
local tiempoEntrada = {} -- Diccionario/Tabla Hash para almacenar el os.time() de ingreso de cada jugador

local diaActualValue = game.Lighting:WaitForChild("Day", 5)

--[[
    Función de consulta diferida para verificar si el tutorial está activo.
    Evita errores de orden de ejecución si el TutorialHandler no ha cargado.
]]
local function isTutorialActive()
	local ts = ReplicatedStorage:FindFirstChild("TutorialSystem")
	local ta = ts and ts:FindFirstChild("TutorialActive")
	return ta and ta.Value == true
end 

-- =============================================================================
-- LOGÍSTICA DE PERSISTENCIA DE DATOS (DATASTORE CORES)
-- =============================================================================

--[[
    Carga el perfil de datos del jugador al entrar al servidor.
    Si no existen registros previos o la solicitud falla, genera valores iniciales de cero.
]]
local function cargarDatos(player)
	local key = "Player_" .. player.UserId
	
	-- Uso de pcall (protected call) para mitigar caídas de conexión con los servidores de Roblox
	local success, data = pcall(function()
		return PlayerDataStore:GetAsync(key)
	end)

	-- Creación de la jerarquía de almacenamiento temporal dentro del Player
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

	-- Asignación de datos recuperados o por defecto
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

--[[
    Guarda el progreso del usuario de forma unificada tanto en el perfil local 
    como en los OrderedDataStores globales de las scoreboards.
]]
local function guardarDatosCompleto(player)
	if not player:FindFirstChild("LeaderstatsData") then return end

	local key = "Player_" .. player.UserId
	local stats = player.LeaderstatsData

	-- Cálculo del tiempo de juego consumido durante la presente sesión
	local tiempoSesion = 0
	if tiempoEntrada[player] then
		tiempoSesion = os.time() - tiempoEntrada[player]
	end
	local tiempoTotalActualizado = stats.TiempoTotal.Value + tiempoSesion

	-- Empaquetamiento de datos para el DataStore principal
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

	-- Volcado en OrderedDataStores públicos (Usa la ID del jugador de manera numérica como clave)
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

--[[
    Interrumpe los flujos del juego y actualiza los récords personales 
    de los jugadores al cumplirse la condición de Game Over.
]]
local function alTerminarPartida()
	local diaAlcanzado = diaActualValue and diaActualValue.Value or 1
	print("¡La partida ha terminado en el día " .. diaAlcanzado .. "! Guardando datos globales...")

	-- Desactivación forzada del sistema de tutoriales
	local ts = ReplicatedStorage:FindFirstChild("TutorialSystem")
	local ta = ts and ts:FindFirstChild("TutorialActive")
	if ta then ta.Value = false end

	-- Procesamiento masivo de datos para los jugadores presentes
	for _, player in pairs(Players:GetPlayers()) do
		local stats = player:FindFirstChild("LeaderstatsData")
		if stats then
			-- Comprobación e inscripción de récord de supervivencia (Día Máximo)
			if diaAlcanzado > stats.DiaMaximo.Value then
				stats.DiaMaximo.Value = diaAlcanzado
			end

			-- Ejecución del guardado físico
			guardarDatosCompleto(player)

			-- Resetear la marca temporal para evitar acumulaciones duplicadas futuras
			tiempoEntrada[player] = os.time()
		end
	end
end

-- =============================================================================
-- SISTEMA DE CONTROL DE VOTACIONES Y FLUJO DE TELETRANSPORTE
-- =============================================================================

--[[
    Retorna el estado actual del conteo de votos de las opciones disponibles.
]]
local function obtenerConteo()
	return #votos.RETRY, #votos.LOBBY, #Players:GetPlayers()
end

--[[
    Evalúa los resultados de la votación y segmenta de forma masiva a los 
    jugadores redirigiéndolos al servidor correspondiente usando TeleportAsync.
]]
local function ejecutarTeletransporteFinal()
	if not votacionActiva then return end
	votacionActiva = false

	print("Fin de la votación de 23 segundos. Separando grupos...")

	-- Segmentación Grupo A: Volver a jugar
	if #votos.RETRY > 0 then
		local success, err = pcall(function()
			TeleportService:TeleportAsync(RETRY_PLACE, votos.RETRY)
		end)
		if not success then warn("Error en TP Retry: " .. tostring(err)) end
	end

	-- Segmentación Grupo B: Retorno al menú principal (Lobby)
	local grupoLobby = {}
	for _, p in pairs(votos.LOBBY) do
		table.insert(grupoLobby, p)
	end

	-- Jugadores que no votaron (indecisos) son enviados al Lobby por defecto
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

--[[
    Inicia el conteo regresivo de la votación de fin de partida en un hilo asíncrono
    e informa constantemente del estado del escrutinio a todos los clientes.
]]
local function iniciarCronometroGameOver()
	if votacionActiva then return end
	votacionActiva = true
	votos.RETRY = {}
	votos.LOBBY = {}
	tiempoRestante = 23

	task.spawn(function()
		local vRetry, vLobby, total = obtenerConteo()
		VotoEvent:FireAllClients(vRetry, vLobby, total, tiempoRestante) -- Difusión inicial

		-- Bucle del segundero de votación
		while tiempoRestante > 0 and votacionActiva do
			task.wait(1)
			tiempoRestante -= 1

			local currentRetry, currentLobby, currentTotal = obtenerConteo()
			VotoEvent:FireAllClients(currentRetry, currentLobby, currentTotal, tiempoRestante)
		end

		-- Al agotarse el tiempo, procesar el destino físico
		if votacionActiva then
			ejecutarTeletransporteFinal()
		end
	end)
end

-- =============================================================================
-- ESCUCHADORES DE RED Y GESTIÓN DE CONEXIONES
-- =============================================================================

-- Registro de entrada del jugador
Players.PlayerAdded:Connect(function(player)
	tiempoEntrada[player] = os.time() -- Estampar hora de llegada
	cargarDatos(player)
end)

-- Manejo de salidas del servidor
Players.PlayerRemoving:Connect(function(player)
	-- Resguardo inmediato de datos para evitar pérdidas por desconexión forzada
	guardarDatosCompleto(player)
	tiempoEntrada[player] = nil

	-- Limpieza de sus registros de votos si estaba participando de una elección
	local idxR = table.find(votos.RETRY, player)
	local idxL = table.find(votos.LOBBY, player)
	if idxR then table.remove(votos.RETRY, idxR) end
	if idxL then table.remove(votos.LOBBY, idxL) end

	-- Si una votación estaba activa, recalcular si los votos restantes hacen unánime la decisión
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

-- Procesamiento del voto entrante enviado por el cliente
VotoEvent.OnServerEvent:Connect(function(player, tipoVoto)
	if not votacionActiva then return end
	-- Antifraude elemental: Evitar que un jugador vote más de una vez
	if table.find(votos.RETRY, player) or table.find(votos.LOBBY, player) then return end

	if tipoVoto == "RETRY" then
		table.insert(votos.RETRY, player)
	elseif tipoVoto == "LOBBY" then
		table.insert(votos.LOBBY, player)
	end

	-- Replicar actualización de votos en tiempo real a las pantallas de todos los usuarios
	local vRetry, vLobby, total = obtenerConteo()
	VotoEvent:FireAllClients(vRetry, vLobby, total, tiempoRestante)
end)

-- =============================================================================
-- MANEJO DE SALUD, EFECTOS Y DESTRUCCIÓN DEL OBJETIVO ("BARN")
-- =============================================================================

-- Generación dinámica de un efecto visual de contorno (Highlight) para indicar daño en la base
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

-- Evento A: Destello de alerta visual cuando la base recibe impactos de enemigos
barnHumanoid.HealthChanged:Connect(function(newHP)
	if newHP < lastBarnHP and not barnMuerto then
		barnHighlight.Enabled = true
		task.delay(0.3, function() barnHighlight.Enabled = false end) -- Apagado tras 0.3 segundos
	end
	lastBarnHP = newHP
end)

-- Evento B: Lógica de destrucción total al agotarse los puntos de salud de la estructura
barnHumanoid.HealthChanged:Connect(function(vida)
	if vida <= 0 and not barnMuerto and juegoIniciado.Value == true then
		barnMuerto = true
		juegoIniciado.Value = false -- Frenar el bucle del generador de zombis

		-- Creación dinámica del disparador de efectos de audio ambientales de derrota
		local playSoundRE = game:GetService("ReplicatedStorage").Events:FindFirstChild("PlaySoundEvent")
		if not playSoundRE then
			playSoundRE = Instance.new("RemoteEvent")
			playSoundRE.Name = "PlaySoundEvent"
			playSoundRE.Parent = game:GetService("ReplicatedStorage").Events
		end
		playSoundRE:FireAllClients("rbxassetid://139944924921354", 1) -- Audio de risa malvada/derrota

		-- Animación de colapso físico mediante desanclaje de piezas y micro-explosiones estéticas
		task.spawn(function()
			for _, part in ipairs(barn:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = false -- Activa la gravedad en las piezas
					local ex = Instance.new("Explosion")
					ex.Position = part.Position
					ex.BlastRadius = 0    -- Fuerza cero para evitar que salgan volando de forma caótica
					ex.BlastPressure = 0
					ex.Parent = workspace
				end
			end
			task.wait(3)
			barn:Destroy() -- Liberación de recursos del mapa colapsado
		end) 

		alTerminarPartida() -- Ejecución de guardados masivos en DataStores

		task.wait(2)

		-- Invocar las interfaces visuales de Game Over e iniciar la fase de escrutinio
		GameOverEvent:FireAllClients()
		iniciarCronometroGameOver()
	end
end)

-- =============================================================================
-- RED DE SEGURIDAD ABSOLUTA (CIERRE IMPREVISTO)
-- =============================================================================
--[[
    Este evento intercepta el proceso de apagado del servidor (crash, migración de versión
    o salida de todos los usuarios) reteniendo la instancia 2 segundos extra en memoria.
    Esto previene la pérdida y corrupción de inventarios y récords.
]]
game:BindToClose(function()
	for _, player in pairs(Players:GetPlayers()) do
		guardarDatosCompleto(player)
	end
	task.wait(2) -- Ventana de tiempo crítica para que terminen de enviarse los paquetes HTTP a la API de Roblox
end)
