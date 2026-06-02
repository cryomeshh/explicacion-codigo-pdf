-- =============================================================================
-- SERVICIOS DE ROBLOX
-- =============================================================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService") 

-- =============================================================================
-- REFERENCIAS Y CONFIGURACIÓN
-- =============================================================================
local map = game.Workspace:WaitForChild("map")
local buttonFolder = map:WaitForChild("buttons")
local sendError = ReplicatedStorage.Events:WaitForChild("SendAlert") -- Evento remoto para avisar al cliente

-- Control de tiempos de espera para evitar spam de alertas de compra fallida
local messageCooldowns = {}

-- IDs de Audio de la biblioteca de Roblox
local SOUND_COMPRA_OK = "rbxassetid://250450973" 
local SOUND_COMPRA_FAIL = "rbxassetid://550209561" 

-- Tabla hash para almacenar las posiciones iniciales de los objetos antes de ocultarlos
local posicionesOriginales = {}

-- =============================================================================
-- FUNCIONES AUXILIARES
-- =============================================================================

--[[
    Reproduce un sonido de forma dinámica.
    Crea una instancia temporal, la reproduce al destruirse y limpia la memoria.
]]
local function reproducirSonido(parent, soundId)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = 0.5
	sound.PlayOnRemove = true -- Característica clave: suena justo cuando se destruye
	sound.Parent = parent
	sound:Play()
	sound:Destroy() 
end

--[[
    Controla la animación de los objetos vinculados a los botones.
    Si 'activar' es false, esconde el objeto bajo tierra.
    Si 'activar' es true, el objeto emerge con un efecto visual animado.
]]
local function animarObjetoSuelo(targetObject, activar)
	if not targetObject then return end

	-- Obtener todas las partes que componen el modelo o estructura
	local elements = targetObject:GetDescendants()
	table.insert(elements, targetObject)

	-- Calcular la distancia de desplazamiento dinámicamente según el tamaño del objeto
	local altoDesplazamiento = 15
	if targetObject:IsA("Model") then
		local _, size = targetObject:GetBoundingBox()
		altoDesplazamiento = size.Y + 12 -- Altura del modelo + un margen de 10 studs
	elseif targetObject:IsA("BasePart") then
		altoDesplazamiento = targetObject.Size.Y + 12
	end

	-- Aplicar las propiedades físicas y visuales a cada sub-elemento
	for _, v in pairs(elements) do
		-- Caso A: Es un arma expuesta en una vitrina flotante (altera transparencia)
		if v:IsA("BasePart") and v:FindFirstAncestorOfClass("Tool") then
			v.Anchored = true
			v.Transparency = activar and 0 or 1
			v.CanCollide = activar
			v.CanTouch = activar
			v.CanQuery = activar

		-- Caso B: Son partes sólidas del mapa (vitrinas, pedestales, paredes)
		elseif v:IsA("BasePart") or v:IsA("UnionOperation") then
			v.Anchored = true 

			if not activar then
				-- Guardar la posición original en memoria para el retorno posterior
				if not posicionesOriginales[v] then
					posicionesOriginales[v] = v.Position
				end
				-- Desplazar físicamente hacia abajo (ocultar bajo el mapa)
				v.Position = posicionesOriginales[v] - Vector3.new(0, altoDesplazamiento, 0)
				v.CanCollide = false
				v.CanTouch = false 
				v.CanQuery = false
			else
				-- Restaurar colisiones y animar el regreso a la superficie
				v.CanCollide = true
				v.CanTouch = true 
				v.CanQuery = true

				-- Configuración del Tween: Duración 0.6s con efecto de rebote al final (Back/Out)
				local infoTween = TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
				local propiedadObjetivo = {Position = posicionesOriginales[v]}
				local tween = TweenService:Create(v, infoTween, propiedadObjetivo)
				tween:Play()
			end

		-- Caso C: Elementos estéticos y de efectos (Luces, partículas, fuego, humo)
		elseif v:IsA("Light") or v:IsA("ParticleEmitter") or v:IsA("Fire") or v:IsA("Smoke") then
			v.Enabled = activar
		end
	end
end

--[[
    Otorga un arma a un jugador específico de forma permanente.
    La añade tanto a la mochila de juego como al StarterGear (persistencia tras morir).
]]
local function darArmaPermanente(player, toolTemplate)
	if not player or not toolTemplate then return end

	-- Inserción en la mochila activa
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack and not backpack:FindFirstChild(toolTemplate.Name) then
		local character = player.Character
		-- Evitar duplicación si el jugador ya tiene el objeto equipado en la mano
		if not (character and character:FindFirstChild(toolTemplate.Name)) then
			local toolClone = toolTemplate:Clone()
			toolClone.Parent = backpack
		end
	end

	-- Inserción en el StarterGear (Copia de seguridad de reaparición)
	local starterGear = player:FindFirstChildOfClass("StarterGear")
	if starterGear and not starterGear:FindFirstChild(toolTemplate.Name) then
		local toolCloneStarter = toolTemplate:Clone()
		toolCloneStarter.Parent = starterGear
	end
end

-- =============================================================================
-- LÓGICA PRINCIPAL DEL BOTÓN DE COMPRA
-- =============================================================================

--[[
    Inicializa los eventos táctiles y de validación de costos para cada botón del juego.
]]
local function initializePurchasable(button)
	local config = button:WaitForChild("Config", 5)
	if not config then return end
	
	local targetValue = config:FindFirstChild("target")
	local isActivated = false -- Candado lógico para asegurar que solo se compre una vez

	-- Fase de inicio: Si el objetivo está en el Workspace, se oculta bajo tierra de inmediato
	if targetValue and targetValue.Value and targetValue.Value:IsDescendantOf(workspace) then
		animarObjetoSuelo(targetValue.Value, false)
	end

	-- Evento de colisión (Detección de jugador)
	button.Touched:Connect(function(hit)
		if isActivated then return end -- Si ya se compró, ignorar código posterior
		
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		-- Anti-spam: Verificar cooldown de notificaciones (mínimo 2 segundos por intento fallido)
		if not player or (messageCooldowns[player] and tick() - messageCooldowns[player] < 2) then return end
		
		local stats = player:FindFirstChild("resources")
		if not stats then return end

		-- Validación de estado del personaje (No procesar compras si está muerto)
		local character = hit.Parent
		local humanoid = character:FindFirstChild("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end

		local canPurchase = true
		local requirementsToCharge = {}
		local missingItems = {}

		-- Bucle dinámico: Valida todos los precios configurados dentro del objeto "Config"
		for _, item in pairs(config:GetChildren()) do
			if item:IsA("StringValue") and item.Name ~= "target" and item.Name ~= "BuffToGive" then
				local resourceName = item.Value 
				local priceVal = item:FindFirstChildWhichIsA("IntValue")
				
				if resourceName ~= "" and priceVal then
					local playerStat = stats:FindFirstChild(resourceName)
					local currentAmount = playerStat and playerStat.Value or 0
					
					-- Si el jugador no tiene suficiente dinero
					if currentAmount < priceVal.Value then
						canPurchase = false
						table.insert(missingItems, (priceVal.Value - currentAmount) .. " of " .. resourceName)
					else
						-- Guardar temporalmente la transacción autorizada
						table.insert(requirementsToCharge, {stat = playerStat, amount = priceVal.Value})
					end
				end
			end
		end

		-- CASO 1: TRANSACCIÓN EXITOSA
		if canPurchase and #requirementsToCharge > 0 then
			isActivated = true -- Bloquear el botón

			-- Cobrar los recursos requeridos
			for _, req in pairs(requirementsToCharge) do
				req.stat.Value -= req.amount
			end

			-- Procesamiento de Mejoras Globales (Buffs)
			local buffToGive = config:FindFirstChild("BuffToGive")
			local buffValue = config:FindFirstChild("BuffValue")
			if buffToGive and buffValue then
				local buffsFolder = ReplicatedStorage:WaitForChild("Buffs")
				local theBuff = buffsFolder:FindFirstChild(buffToGive.Value)
				if theBuff then
					-- Aplicar valor según el tipo de dato (Booleano o Acumulativo)
					if theBuff:IsA("BoolValue") then
						theBuff.Value = buffValue.Value
					else
						theBuff.Value += buffValue.Value
					end

					-- Mecánica especial: Si se activa el radar de zombis, habilita los contornos (Highlights)
					if theBuff.Name == "radarZombies" and theBuff.Value > 0 then
						local enemyFolder = workspace:FindFirstChild("enemies")
						if enemyFolder then
							for _, enemy in pairs(enemyFolder:GetChildren()) do
								local hl = enemy:FindFirstChild("RadarHighlight")
								if hl and hl:IsA("Highlight") then
									hl.Enabled = true
								end
							end
						end
					end
				end
			end

			local targetObject = targetValue and targetValue.Value or nil

			-- Sistema Global de Entrega de Armas
			if targetObject and targetObject:IsA("Tool") and targetObject:FindFirstAncestor("ReplicatedStorage") then
				-- Repartir a todos los jugadores actuales
				for _, p in pairs(Players:GetPlayers()) do
					darArmaPermanente(p, targetObject)
				end

				-- Escuchador persistente para futuros jugadores que entren a la partida
				Players.PlayerAdded:Connect(function(newPlayer)
					newPlayer.CharacterAdded:Connect(function()
						darArmaPermanente(newPlayer, targetObject)
					end)
				end)
			elseif targetObject and targetObject:IsDescendantOf(workspace) then
				-- Si es una estructura física, hacer que emerja del suelo
				animarObjetoSuelo(targetObject, true)
			end

			-- Efectos de finalización y limpieza del botón
			reproducirSonido(button, SOUND_COMPRA_OK)
			button:Destroy()
			messageCooldowns[player] = nil

		-- CASO 2: TRANSACCIÓN RECHAZADA (FALTA DE FONDOS)
		elseif not canPurchase then
			messageCooldowns[player] = tick() -- Registrar marca de tiempo del error
			reproducirSonido(button, SOUND_COMPRA_FAIL)
			-- Enviar los requisitos faltantes al cliente mediante interfaz de usuario
			sendError:FireClient(player, "Missing: " .. table.concat(missingItems, ", "))
		end
	end)
end

-- =============================================================================
-- BUCLE DE INICIALIZACIÓN Y RECOLECCIÓN DE RESIDUOS
-- =============================================================================

-- Recorrer la carpeta de botones para activar el script en cada uno de ellos
for _, descendant in pairs(buttonFolder:GetDescendants()) do
	if descendant:IsA("BasePart") and descendant:FindFirstChild("Config") then
		-- Exclusión preventiva para objetos que pertenezcan a la categoría 'building'
		if descendant.Parent.Name ~= "building" then
			initializePurchasable(descendant)
		end
	end
end

-- Limpieza de memoria: Remover el registro de cooldown cuando un jugador sale del servidor
Players.PlayerRemoving:Connect(function(player)
	messageCooldowns[player] = nil
end)
