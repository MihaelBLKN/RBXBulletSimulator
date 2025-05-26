--!strict
--@EnumEnv

--[[
MIT License

Copyright (c) 2025 MihaelBLKN (github)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
--]]

-- Services --
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

-- Variables --
local BulletWorker = script.BulletWorker

-- Constants --
local DEBUG_COLLISION_GROUP = "BulletSimulatorDebugCollisionGroup"
local HITBOX_COLLISION_GROUP = "BulletSimulatorHitboxCollisionGroup"
local MAX_BULLETS_PER_ACTOR = 35
local BULLET_TIMEOUT_DURATION = 15
local ACTOR_AMOUNT = 14
local BULLET_CLEANUP_INTERVAL = BULLET_TIMEOUT_DURATION / 2

-- Class --
local BulletSimulator = {}
BulletSimulator.__index = BulletSimulator

-- Create storage --
local Storage = ReplicatedStorage:FindFirstChild("Storage") :: Folder or Instance.new("Folder")
Storage.Name = "__BSStorage"
Storage.Parent = ReplicatedStorage

-- Load collision groups --
if not PhysicsService:IsCollisionGroupRegistered(DEBUG_COLLISION_GROUP) then
	PhysicsService:RegisterCollisionGroup(DEBUG_COLLISION_GROUP)
end

if not PhysicsService:IsCollisionGroupRegistered(HITBOX_COLLISION_GROUP) then
	PhysicsService:RegisterCollisionGroup(HITBOX_COLLISION_GROUP)
end

PhysicsService:CollisionGroupSetCollidable(DEBUG_COLLISION_GROUP, HITBOX_COLLISION_GROUP, false)
PhysicsService:CollisionGroupSetCollidable("Default", DEBUG_COLLISION_GROUP, false)
PhysicsService:CollisionGroupSetCollidable("Default", HITBOX_COLLISION_GROUP, false)

-- Types --
export type Bullet = {
	Player: number, --> Player.UserId
	WeaponDamage: number,
	WeaponRange: number,
	Origin: Vector3,
	Direction: Vector3,
	IsInstant: boolean?, --> Optional: true for hitscan, false/nil for projectile
}

export type BulletProcessData = {
	Id: string, --> Unique identifier for the bullet
	Bullet: Bullet,
	BeingProcessed: boolean, --> Indicates if the bullet is currently being processed
	AssignedActor: Actor?, --> Which actor is processing this bullet
	StartTime: number, --> When the bullet started processing (tick())
	TimeoutDuration: number?, --> Custom timeout for this bullet (optional)
}

export type ActorMetadata = {
	Actor: Actor,
	BulletsProcessing: number, --> The amount of bullets currently being processed by the actor
	AssignedBullets: { [string]: BulletProcessData }, --> Map of bullet IDs to bullet data assigned to this actor
}

export type BulletSimulator = typeof(BulletSimulator) & {
	_bulletHitBindableEvent: BindableEvent,
	_bulletCompleteBindableEvent: BindableEvent, --> For actors to report completion
	_actors: { ActorMetadata },
	_connections: { RBXScriptConnection },
	_bulletProcessQueue: { BulletProcessData },
	_activeBullets: { [string]: BulletProcessData }, --> Track all active bullets by ID
	_lastCleanupTime: number,
}

-- Constructor --
---- Creates a new instance of BulletSimulator.
---@return BulletSimulator
function BulletSimulator.new(): BulletSimulator
	local self: BulletSimulator = setmetatable({}, BulletSimulator) :: any --> strip metatable type

	self._actors = {}
	self._connections = {}
	self._bulletProcessQueue = {}
	self._activeBullets = {}
	self._lastCleanupTime = tick()

	self._bulletHitBindableEvent = Instance.new("BindableEvent")
	self._bulletHitBindableEvent.Name = "BulletHitBindableEvent"
	self._bulletHitBindableEvent.Parent = Storage

	self._bulletCompleteBindableEvent = Instance.new("BindableEvent")
	self._bulletCompleteBindableEvent.Name = "BulletCompleteBindableEvent"
	self._bulletCompleteBindableEvent.Parent = Storage

	self:_initActors()

	local bulletCompleteConnection = self._bulletCompleteBindableEvent.Event:Connect(
		function(bulletId: string, actorInstance: Actor)
			self:_onBulletComplete(bulletId, actorInstance)
		end
	)

	local heartbeatConnection = RunService.Heartbeat:Connect(function()
		self:_updateCycle()
	end)

	table.insert(self._connections, bulletCompleteConnection)
	table.insert(self._connections, heartbeatConnection)

	return self
end

--- Destroys the BulletSimulator instance.
function BulletSimulator.Destroy(self: BulletSimulator)
	for _, connection in self._connections do
		connection:Disconnect()
	end

	for _, actor in self._actors do
		actor.Actor:SendMessage("Destruct")

		task.delay(1.25, function()
			if actor and actor.Actor then
				actor.Actor:Destroy()
			end
		end)
	end

	if self._bulletHitBindableEvent then
		self._bulletHitBindableEvent:Destroy()
	end

	if self._bulletCompleteBindableEvent then
		self._bulletCompleteBindableEvent:Destroy()
	end

	table.clear(self._actors)
	table.clear(self._connections)
	table.clear(self._bulletProcessQueue)
	table.clear(self._activeBullets)
end

--- Returns the BindableEvent used for bullet hit events.
---@return BindableEvent
function BulletSimulator.GetBulletHitBindableEvent(self: BulletSimulator): BindableEvent
	return self._bulletHitBindableEvent or Storage:FindFirstChild("BulletHitBindableEvent") :: BindableEvent
end

--- Returns the BindableEvent used for bullet completion events.
--- @return BindableEvent
function BulletSimulator.GetBulletCompleteBindableEvent(self: BulletSimulator): BindableEvent
	return self._bulletCompleteBindableEvent or Storage:FindFirstChild("BulletCompleteBindableEvent") :: BindableEvent
end

--- Adds a bullet to the processing queue. General method for all bullet types.
--- @param bullet Bullet The bullet data to process
--- @param customTimeout number? Optional custom timeout duration for this bullet
--- @return string The unique ID assigned to this bullet
function BulletSimulator.QueueGeneralBullet(self: BulletSimulator, bullet: Bullet, customTimeout: number?): string
	local bulletId = HttpService:GenerateGUID(false)

	local bulletData: BulletProcessData = {
		Id = bulletId,
		Bullet = bullet,
		BeingProcessed = false,
		AssignedActor = nil,
		StartTime = 0,
		TimeoutDuration = customTimeout,
	}

	table.insert(self._bulletProcessQueue, bulletData)

	return bulletId
end

--- Convenience method to fire an instant bullet (hitscan)
--- @param player number Player.UserId
--- @param damage number Weapon damage
--- @param range number Weapon range
--- @param origin Vector3 Bullet origin position
--- @param direction Vector3 Bullet direction (should be unit vector)
--- @return string The unique ID assigned to this bullet
function BulletSimulator.QueueInstantBullet(
	self: BulletSimulator,
	player: number,
	damage: number,
	range: number,
	origin: Vector3,
	direction: Vector3
): string
	local bullet: Bullet = {
		Player = player,
		WeaponDamage = damage,
		WeaponRange = range,
		Origin = origin,
		Direction = direction,
		IsInstant = true,
	}

	return self:QueueGeneralBullet(bullet)
end

--- Convenience method to fire a projectile bullet
--- @param player number Player.UserId
--- @param damage number Weapon damage
--- @param range number Weapon range
--- @param origin Vector3 Bullet origin position
--- @param direction Vector3 Bullet direction (should be unit vector)
--- @return string The unique ID assigned to this bullet
function BulletSimulator.QueueProjectileBullet(
	self: BulletSimulator,
	player: number,
	damage: number,
	range: number,
	origin: Vector3,
	direction: Vector3
): string
	local bullet: Bullet = {
		Player = player,
		WeaponDamage = damage,
		WeaponRange = range,
		Origin = origin,
		Direction = direction,
		IsInstant = false,
	}

	return self:QueueGeneralBullet(bullet)
end

--- Gets statistics about the current state of the bullet simulator.
--- @return table Statistics about bullets and actors
function BulletSimulator.GetStats(self: BulletSimulator): {
	QueuedBullets: number,
	ActiveBullets: number,
	TotalActors: number,
	ActorUtilization: { [Actor]: number },
	BulletsByActor: { [Actor]: { string } },
}
	local actorUtilization = {}
	local bulletsByActor = {}

	for _, actorMetadata in self._actors do
		actorUtilization[actorMetadata.Actor] = actorMetadata.BulletsProcessing

		local bulletIds = {}
		for bulletId, _ in actorMetadata.AssignedBullets do
			table.insert(bulletIds, bulletId)
		end

		bulletsByActor[actorMetadata.Actor] = bulletIds
	end

	local activeBulletCount = 0
	for _ in self._activeBullets do
		activeBulletCount += 1
	end

	return {
		QueuedBullets = #self._bulletProcessQueue,
		ActiveBullets = activeBulletCount,
		TotalActors = #self._actors,
		ActorUtilization = actorUtilization,
		BulletsByActor = bulletsByActor,
	}
end

---------------------
-- PRIVATE METHODS --
---------------------

--- Initializes the actors for the BulletSimulator.
--- This method creates the specified number of actors and sets them up for processing bullets.
function BulletSimulator._initActors(self: BulletSimulator)
	for i = 1, ACTOR_AMOUNT do
		local actorInstance = Instance.new("Actor")
		actorInstance.Name = "BulletSimulatorActor" .. i
		actorInstance.Parent = script

		local actorMetadata: ActorMetadata = {
			Actor = actorInstance,
			BulletsProcessing = 0,
			AssignedBullets = {},
		}

		local worker = BulletWorker:Clone()
		worker.Parent = actorInstance
		worker.Disabled = false

		table.insert(self._actors, actorMetadata)
	end
end

--- Internal method called when a bullet completes processing (called by BindableEvent).
--- @param bulletId string The ID of the bullet that completed
--- @param actorInstance Actor The actor that was processing the bullet
function BulletSimulator._onBulletComplete(self: BulletSimulator, bulletId: string, actorInstance: Actor)
	local bulletData = self._activeBullets[bulletId]
	if not bulletData then
		return
	end

	self._activeBullets[bulletId] = nil

	for _, actorMetadata in self._actors do
		if actorMetadata.Actor == actorInstance then
			actorMetadata.BulletsProcessing = math.max(0, actorMetadata.BulletsProcessing - 1)
			actorMetadata.AssignedBullets[bulletId] = nil
			break
		end
	end
end

--- Finds a qualified actor to process a bullet.
--- @return Actor?, ActorMetadata?
function BulletSimulator._findQualifiedActor(self: BulletSimulator): (Actor?, ActorMetadata?)
	local minBullets = MAX_BULLETS_PER_ACTOR
	local qualifiedActorInstance = nil
	local qualifiedActorMetadata = nil

	for _, actor in self._actors do
		local actorInstance = actor.Actor
		local bulletsAmount = actor.BulletsProcessing

		if actorInstance and bulletsAmount < MAX_BULLETS_PER_ACTOR then
			if bulletsAmount < minBullets then
				minBullets = bulletsAmount
				qualifiedActorInstance = actorInstance
				qualifiedActorMetadata = actor
			end
		end
	end

	return qualifiedActorInstance, qualifiedActorMetadata
end

--- Cleans up timed out bullets.
function BulletSimulator._cleanupTimedOutBullets(self: BulletSimulator)
	local currentTime = tick()
	local bulletsToCleanup = {}

	for bulletId, bulletData in self._activeBullets do
		local timeoutDuration = bulletData.TimeoutDuration or BULLET_TIMEOUT_DURATION
		local elapsedTime = currentTime - bulletData.StartTime

		if elapsedTime >= timeoutDuration then
			table.insert(bulletsToCleanup, bulletId)
		end
	end

	for _, bulletId in bulletsToCleanup do
		local bulletData = self._activeBullets[bulletId]
		if bulletData and bulletData.AssignedActor then
			bulletData.AssignedActor:SendMessage("CancelBullet", bulletId)
		end

		for _, actorMetadata in self._actors do
			if actorMetadata.AssignedBullets[bulletId] then
				actorMetadata.BulletsProcessing = math.max(0, actorMetadata.BulletsProcessing - 1)
				actorMetadata.AssignedBullets[bulletId] = nil
				break
			end
		end

		self._activeBullets[bulletId] = nil
	end
end

--- Handles bullet update cycles for cleanup and processing.
function BulletSimulator._updateCycle(self: BulletSimulator)
	local currentTime = tick()

	if currentTime - self._lastCleanupTime >= BULLET_CLEANUP_INTERVAL then
		self:_cleanupTimedOutBullets()
		self._lastCleanupTime = currentTime
	end

	for i = #self._bulletProcessQueue, 1, -1 do
		local bulletData = self._bulletProcessQueue[i]
		if bulletData.BeingProcessed then
			continue
		end

		bulletData.BeingProcessed = true

		local bullet = bulletData.Bullet
		if not bullet then
			table.remove(self._bulletProcessQueue, i)
			continue
		end

		local qualifiedActor, actorMetadata = self:_findQualifiedActor()

		if not qualifiedActor and self._actors[1] then
			qualifiedActor = self._actors[1].Actor
			actorMetadata = self._actors[1]
		end

		if not qualifiedActor or not actorMetadata then
			bulletData.BeingProcessed = false
			continue
		end

		bulletData.AssignedActor = qualifiedActor
		bulletData.StartTime = currentTime

		actorMetadata.BulletsProcessing += 1
		actorMetadata.AssignedBullets[bulletData.Id] = bulletData

		self._activeBullets[bulletData.Id] = bulletData

		local bulletWithId = {
			Id = bulletData.Id,
			Player = bullet.Player,
			WeaponDamage = bullet.WeaponDamage,
			WeaponRange = bullet.WeaponRange,
			IsInstant = bullet.IsInstant,

			OriginPoints = {
				X = bullet.Origin.X,
				Y = bullet.Origin.Y,
				Z = bullet.Origin.Z,
			},

			DirectionPoints = {
				X = bullet.Direction.X,
				Y = bullet.Direction.Y,
				Z = bullet.Direction.Z,
			},
		}

		local encoded = HttpService:JSONEncode(bulletWithId)
		qualifiedActor:SendMessage("ProcessBullet", encoded)

		table.remove(self._bulletProcessQueue, i)
	end
end

-- End --
return BulletSimulator :: BulletSimulator
