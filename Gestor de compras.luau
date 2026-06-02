local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService") 

local map = game.Workspace:WaitForChild("map")
local buttonFolder = map:WaitForChild("buttons")
local sendError = ReplicatedStorage.Events:WaitForChild("SendAlert")
local messageCooldowns = {}

local SOUND_COMPRA_OK = "rbxassetid://250450973" 
local SOUND_COMPRA_FAIL = "rbxassetid://550209561" 

local posicionesOriginales = {}

local function reproducirSonido(parent, soundId)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = 0.5
	sound.PlayOnRemove = true 
	sound.Parent = parent
	sound:Play()
	sound:Destroy() 
end

local function animarObjetoSuelo(targetObject, activar)
	if not targetObject then return end

	local elements = targetObject:GetDescendants()
	table.insert(elements, targetObject)

	local altoDesplazamiento = 15
	if targetObject:IsA("Model") then
		local _, size = targetObject:GetBoundingBox()
		altoDesplazamiento = size.Y + 12 -- Cambiado de + 2 a + 12 (la altura del modelo + 10 studs extra)
	elseif targetObject:IsA("BasePart") then
		altoDesplazamiento = targetObject.Size.Y + 12 -- Cambiado de + 2 a + 12 (la altura de la parte + 10 studs extra)
	end

	for _, v in pairs(elements) do
		-- Si es parte de una Tool (la espada flotante), alteramos su visibilidad/fisicas
		if v:IsA("BasePart") and v:FindFirstAncestorOfClass("Tool") then
			v.Anchored = true
			v.Transparency = activar and 0 or 1
			v.CanCollide = activar
			v.CanTouch = activar
			v.CanQuery = activar

			-- Si son las partes de la vitrina o pedestal, estas suben del suelo
		elseif v:IsA("BasePart") or v:IsA("UnionOperation") then
			v.Anchored = true 

			if not activar then
				if not posicionesOriginales[v] then
					posicionesOriginales[v] = v.Position
				end
				v.Position = posicionesOriginales[v] - Vector3.new(0, altoDesplazamiento, 0)
				v.CanCollide = false
				v.CanTouch = false 
				v.CanQuery = false
			else
				v.CanCollide = true
				v.CanTouch = true 
				v.CanQuery = true

				local infoTween = TweenInfo.new(0.6, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
				local propiedadObjetivo = {Position = posicionesOriginales[v]}
				local tween = TweenService:Create(v, infoTween, propiedadObjetivo)
				tween:Play()
			end

		elseif v:IsA("Light") or v:IsA("ParticleEmitter") or v:IsA("Fire") or v:IsA("Smoke") then
			v.Enabled = activar
		end
	end
end

--==================================================
---- AUXILIARY FUNCTION TO GIVE WEAPON PERMANENTLY
--==================================================
local function darArmaPermanente(player, toolTemplate)
	if not player or not toolTemplate then return end

	-- Clonar para la mochila activa del jugador actual
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack and not backpack:FindFirstChild(toolTemplate.Name) then
		local character = player.Character
		-- Si ya la tiene equipada en la mano, no la duplicamos
		if not (character and character:FindFirstChild(toolTemplate.Name)) then
			local toolClone = toolTemplate:Clone()
			toolClone.Parent = backpack
		end
	end

	-- Clonar al StarterGear para que NUNCA se pierda tras morir
	local starterGear = player:FindFirstChildOfClass("StarterGear")
	if starterGear and not starterGear:FindFirstChild(toolTemplate.Name) then
		local toolCloneStarter = toolTemplate:Clone()
		toolCloneStarter.Parent = starterGear
	end
end

local function initializePurchasable(button)
	local config = button:WaitForChild("Config", 5)
	if not config then return end
	local targetValue = config:FindFirstChild("target")
	local isActivated = false

	-- Ocultar solo si el target esta físicamente en el Workspace (Vitrina/Pedestal)
	if targetValue and targetValue.Value and targetValue.Value:IsDescendantOf(workspace) then
		animarObjetoSuelo(targetValue.Value, false)
	end

	button.Touched:Connect(function(hit)
		if isActivated then return end
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if not player or (messageCooldowns[player] and tick() - messageCooldowns[player] < 2) then return end
		local stats = player:FindFirstChild("resources")
		if not stats then return end

		local character = hit.Parent
		local humanoid = character:FindFirstChild("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end

		local canPurchase = true
		local requirementsToCharge = {}
		local missingItems = {}

		for _, item in pairs(config:GetChildren()) do
			if item:IsA("StringValue") and item.Name ~= "target" and item.Name ~= "BuffToGive" then
				local resourceName = item.Value 
				local priceVal = item:FindFirstChildWhichIsA("IntValue")
				if resourceName ~= "" and priceVal then
					local playerStat = stats:FindFirstChild(resourceName)
					local currentAmount = playerStat and playerStat.Value or 0
					if currentAmount < priceVal.Value then
						canPurchase = false
						table.insert(missingItems, (priceVal.Value - currentAmount) .. " of " .. resourceName)
					else
						table.insert(requirementsToCharge, {stat = playerStat, amount = priceVal.Value})
					end
				end
			end
		end

		if canPurchase and #requirementsToCharge > 0 then
			isActivated = true

			for _, req in pairs(requirementsToCharge) do
				req.stat.Value -= req.amount
			end

			local buffToGive = config:FindFirstChild("BuffToGive")
			local buffValue = config:FindFirstChild("BuffValue")
			if buffToGive and buffValue then
				local buffsFolder = ReplicatedStorage:WaitForChild("Buffs")
				local theBuff = buffsFolder:FindFirstChild(buffToGive.Value)
				if theBuff then
					if theBuff:IsA("BoolValue") then
						theBuff.Value = buffValue.Value
					else
						theBuff.Value += buffValue.Value
					end

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

			--==================================================
			---- GLOBAL WEAPON DELIVERY SYSTEM
			--==================================================
			if targetObject and targetObject:IsA("Tool") and targetObject:FindFirstAncestor("ReplicatedStorage") then
				-- El target apunta a un arma de almacenamiento. Se distribuye a todos los jugadores de forma permanente.
				for _, p in pairs(Players:GetPlayers()) do
					darArmaPermanente(p, targetObject)
				end

				-- Conectar evento para nuevos jugadores que entren al servidor mas tarde
				Players.PlayerAdded:Connect(function(newPlayer)
					newPlayer.CharacterAdded:Connect(function()
						darArmaPermanente(newPlayer, targetObject)
					end)
				end)
			elseif targetObject and targetObject:IsDescendantOf(workspace) then
				-- Si es una vitrina decorativa en el mapa, ejecuta la animacion del suelo normal
				animarObjetoSuelo(targetObject, true)
			end

			reproducirSonido(button, SOUND_COMPRA_OK)
			button:Destroy()
			messageCooldowns[player] = nil
		elseif not canPurchase then
			messageCooldowns[player] = tick()
			reproducirSonido(button, SOUND_COMPRA_FAIL)
			sendError:FireClient(player, "Missing: " .. table.concat(missingItems, ", "))
		end
	end)
end

for _, descendant in pairs(buttonFolder:GetDescendants()) do
	if descendant:IsA("BasePart") and descendant:FindFirstChild("Config") then
		if descendant.Parent.Name ~= "building" then
			initializePurchasable(descendant)
		end
	end
end

Players.PlayerRemoving:Connect(function(player)
	messageCooldowns[player] = nil
end)