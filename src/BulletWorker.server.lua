--!strict
--@EnumEnv
-- Validation --
if not script:GetActor() then
	script.Disabled = true
	return
end

-- Services --
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

-- Variables --
local Actor = script:GetActor()
local Storage = ReplicatedStorage:FindFirstChild("__BSStorage") :: Folder

-- Constants --
local BULLET_UPDATE_INTERVAL = 0.033
local BULLET_SPEED = 1000
local MAX_BULLET_LIFETIME = 12

-- Containers --
local ActiveBullets = {} :: { BulletDataDecoded }

-- Types --
type BulletDataDecoded = {
	Id: string,
	Player: number,
	WeaponDamage: number,
	WeaponRange: number,
	OriginVector: Vector3,
	DirectionVector: Vector3,
	CurrentPosition: Vector3,
	TraveledDistance: number,
	StartTime: number,
	IsInstant: boolean?, -- Optional flag for instant bullets
}

type BulletData = {
	Id: string,
	Player: number,
	WeaponDamage: number,
	WeaponRange: number,
	IsInstant: boolean?,

	OriginPoints: {
		X: number,
		Y: number,
		Z: number,
	},

	DirectionPoints: {
		X: number,
		Y: number,
		Z: number,
	},
}

-- Storage Wait --
if not Storage then
	repeat
		task.wait()
	until ReplicatedStorage:FindFirstChild("__BSStorage")

	Storage = ReplicatedStorage:FindFirstChild("__BSStorage")
end

-- Bindable Events --
local BulletCompleteBindableEvent = Storage:FindFirstChild("BulletCompleteBindableEvent") :: BindableEvent
local BulletHitBindableEvent = Storage:FindFirstChild("BulletHitBindableEvent") :: BindableEvent

-- Functions --
--- Handles bullet hit logic.
--- @param bulletData BulletDataDecoded
--- @param hitResult RaycastResult?
local function BulletHit(bulletData: BulletDataDecoded, hitResult: RaycastResult?)
	local find = table.find(ActiveBullets, bulletData)
	if find then
		table.remove(ActiveBullets, find)
	end

	BulletCompleteBindableEvent:Fire(bulletData.Id, script:GetActor())

	-- If we hit a humanoid, fire the hit event
	if hitResult and hitResult.Instance then
		local hitPart = hitResult.Instance

		if not hitPart.Parent then
			return
		end

		local targetHumanoid = hitPart.Parent:FindFirstChildOfClass("Humanoid")
		if hitPart.Parent:IsA("Model") and targetHumanoid then
			BulletHitBindableEvent:Fire(bulletData.Player, bulletData.WeaponDamage, targetHumanoid)
		end
	end
end

--- Creates raycast parameters for a bullet, excluding the shooter's character
--- @param shooterUserId number
--- @return RaycastParams
local function CreateRaycastParams(shooterUserId: number): RaycastParams
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	local filterList = {}
	local shooterPlayer = Players:GetPlayerByUserId(shooterUserId)
	if shooterPlayer and shooterPlayer.Character then
		table.insert(filterList, shooterPlayer.Character)
	end

	task.synchronize()
	raycastParams.FilterDescendantsInstances = filterList
	task.desynchronize()

	return raycastParams
end

--- Processes an instant bullet (hitscan)
--- @param bulletData BulletDataDecoded
local function ProcessInstantBullet(bulletData: BulletDataDecoded)
	local raycastParams = CreateRaycastParams(bulletData.Player)

	local raycastResult =
		workspace:Raycast(bulletData.OriginVector, bulletData.DirectionVector * bulletData.WeaponRange, raycastParams)

	BulletHit(bulletData, raycastResult)
end

--- Updates a projectile bullet's position and checks for hits
--- @param bulletData BulletDataDecoded
--- @param deltaTime number
--- @return boolean -- true if bullet should be removed
local function UpdateProjectileBullet(bulletData: BulletDataDecoded, deltaTime: number): boolean
	local previousPosition = bulletData.CurrentPosition
	local moveDistance = BULLET_SPEED * deltaTime
	local newPosition = previousPosition + (bulletData.DirectionVector.Unit * moveDistance)

	-- Check if bullet has exceeded its range
	bulletData.TraveledDistance += moveDistance
	if bulletData.TraveledDistance >= bulletData.WeaponRange then
		BulletHit(bulletData, nil)
		return true
	end

	-- Check if bullet has exceeded max lifetime
	if tick() - bulletData.StartTime >= MAX_BULLET_LIFETIME then
		BulletHit(bulletData, nil)
		return true
	end

	-- Raycast from previous position to new position for interpolated hit detection
	local raycastParams = CreateRaycastParams(bulletData.Player)
	local moveVector = newPosition - previousPosition

	local raycastResult = workspace:Raycast(previousPosition, moveVector, raycastParams)

	if raycastResult then
		-- Hit something, check if it's a valid target
		local hitPart = raycastResult.Instance
		if hitPart and hitPart.Parent then
			-- Hit terrain or parts - stop bullet
			if hitPart.Parent == workspace or not hitPart.Parent:IsA("Model") then
				BulletHit(bulletData, raycastResult)
				return true
			end

			-- Hit a character
			if hitPart.Parent:FindFirstChildOfClass("Humanoid") then
				BulletHit(bulletData, raycastResult)
				return true
			end
		end
	end

	-- Update bullet position
	bulletData.CurrentPosition = newPosition
	return false
end

--- Handles all processing of bullets.
--- This function is called every BULLET_UPDATE_INTERVAL seconds.
local function BulletProcessHandler()
	-- Process bullets in reverse order so we can safely remove them
	for i = #ActiveBullets, 1, -1 do
		local bullet = ActiveBullets[i]

		-- Validate that the shooter still exists
		local parentPlayer = Players:GetPlayerByUserId(bullet.Player)
		if not parentPlayer then
			table.remove(ActiveBullets, i)
			BulletCompleteBindableEvent:Fire(bullet.Id, script:GetActor())
			continue
		end

		-- Process based on bullet type
		if bullet.IsInstant then
			-- Instant bullets should have been processed immediately, remove them
			table.remove(ActiveBullets, i)
		else
			-- Update projectile bullet
			local shouldRemove = UpdateProjectileBullet(bullet, BULLET_UPDATE_INTERVAL)
			if shouldRemove then
				table.remove(ActiveBullets, i)
			end
		end
	end
end

-- Message Connections --
local processBulletConnection = Actor:BindToMessageParallel("ProcessBullet", function(bulletData: string)
	local decodedData = HttpService:JSONDecode(bulletData) :: BulletData
	local currentTime = tick()

	local actualData: BulletDataDecoded = {
		Id = decodedData.Id,
		Player = decodedData.Player,
		WeaponDamage = decodedData.WeaponDamage,
		WeaponRange = decodedData.WeaponRange,
		IsInstant = decodedData.IsInstant or false,

		OriginVector = Vector3.new(decodedData.OriginPoints.X, decodedData.OriginPoints.Y, decodedData.OriginPoints.Z),

		DirectionVector = Vector3.new(
			decodedData.DirectionPoints.X,
			decodedData.DirectionPoints.Y,
			decodedData.DirectionPoints.Z
		),

		CurrentPosition = Vector3.new(
			decodedData.OriginPoints.X,
			decodedData.OriginPoints.Y,
			decodedData.OriginPoints.Z
		),

		TraveledDistance = 0,
		StartTime = currentTime,
	}

	if actualData.IsInstant then
		-- Process instant bullet immediately
		ProcessInstantBullet(actualData)
	else
		-- Add projectile bullet to active list
		table.insert(ActiveBullets, actualData)
	end
end)

local cancelBulletConnection = Actor:BindToMessageParallel("CancelBullet", function(bulletId: string)
	for index, bullet in ActiveBullets do
		if bullet and bullet.Id == bulletId then
			table.remove(ActiveBullets, index)
			break
		end
	end
end)

Actor:BindToMessageParallel("Destruct", function()
	processBulletConnection:Disconnect()
	cancelBulletConnection:Disconnect()
	table.clear(ActiveBullets)
end)

-- Main Loop --
while task.wait(BULLET_UPDATE_INTERVAL) do
	BulletProcessHandler()
end
