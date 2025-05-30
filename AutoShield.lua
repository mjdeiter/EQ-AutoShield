local mq = require 'mq'

local SCRIPT_VERSION = "2.2"
local SCRIPT_DATE = "2025-05-24"

--[[
Changelog:
v2.2 (2025-05-24)
  - User can now select aggro mode: "primary", "all", or "anyaggro".
  - See config section for AGGRO_MODE.
  - All prior debug and safety features preserved.
]]

----------------------------- CONFIG SECTION -----------------------------
local SHIELD_ITEM = "Shield of the Lightning Lord"
local OFFHAND_ITEM = "Hammer of Rancorous Thoughts"
local PROC_SLOT = 14 -- 13 = mainhand, 14 = offhand

local AGGRO_MODE = "all"    -- "primary", "all", or "anyaggro"
-- "primary": Shield if YOU are primary target of >= AGGRO_MOB_COUNT mobs.
-- "all": Shield if >= AGGRO_MOB_COUNT "Auto Hater" mobs on xtarget, any target.
-- "anyaggro": Shield if YOU have aggro on at least 1 mob (ignores count).

local AGGRO_MOB_COUNT = 3   -- Number of mobs for threshold

local SHIELD_INTERVAL = 25 -- Seconds between shield swap attempts (while safe)
local SHIELD_DURATION = 5  -- Seconds to leave shield equipped for focus benefit

local LOW_HP_THRESHOLD = 15    -- Equip shield below this HP%
local SAFE_HP_THRESHOLD = 25   -- Only unequip shield when above this HP%

local LOW_MANA_THRESHOLD = 10      -- Shield if mana < this %
local LOW_ENDURANCE_THRESHOLD = 10 -- Shield if endurance < this %

local DEFENSIVE_DISC_NAMES = {
    ["Final Stand Discipline"] = true,
    ["Deflection Discipline"] = true,
    ["Mantle of the Preserver"] = true,
    ["Shield Flash"] = true,
}

local BUFF_TRIGGER = "Mortal Coil"
local DEBUFF_TRIGGER = "Doom"

local ENABLE_STATUS_HEARTBEAT = false

local ADVANCED_DEBUG = false
local DEBUG_INTERVAL = 30

----------------------------- STATE SECTION -----------------------------
local lastSwapTime = 0
local shieldEquippedForFocus = false
local combatActive = false
local inDanger = false
local lastDebugTime = 0
local lastHeartbeatTime = 0
local HEARTBEAT_INTERVAL = 15

----------------------------- UTILS -----------------------------
local function echo(msg, ...)
    mq.cmdf('/echo [AutoShield v%s] ' .. msg, SCRIPT_VERSION, ...)
end

local function critical_echo(msg, ...)
    mq.cmdf('/echo \ar[AutoShield v%s] ' .. msg .. '\ax', SCRIPT_VERSION, ...)
end

local function debug_echo(msg, ...)
    if ADVANCED_DEBUG then
        mq.cmdf('/echo [AutoShield-DEBUG] ' .. msg, ...)
    end
end

----------------------------- LOGIC -----------------------------
local function isBusy()
    return mq.TLO.Me.Zoning() or mq.TLO.Me.Feigning() or not mq.TLO.Zone()
end

local function isValidCombatTarget()
    local target = mq.TLO.Target
    return target() and target.Type() == "NPC" and target.Aggressive() and not target.Dead() and mq.TLO.Me.Combat()
end

local function equipItem(slot, itemName)
    if not mq.TLO.FindItem(itemName)() then
        critical_echo("WARNING: Could not find item: %s", itemName)
        return false
    end
    if mq.TLO.InvSlot(slot).Item() and mq.TLO.InvSlot(slot).Item.Name() ~= itemName then
        mq.cmdf('/exchange "%s" %d', itemName, slot)
        mq.delay(200)
    end
    return true
end

local function getCurrentOffhand()
    if mq.TLO.InvSlot(PROC_SLOT).Item() then
        return mq.TLO.InvSlot(PROC_SLOT).Item.Name()
    end
    return ""
end

----------------------------- AGGRO LOGIC CHOICES -----------------------------

local function aggroCount_primary()
    -- Only count mobs where YOU are the primary target
    local count = 0
    if not mq.TLO.Me.Combat() then return 0 end
    for i=1, (mq.TLO.Me.XTargetSlots() or 0) do
        local xtarget = mq.TLO.Me.XTarget(i)
        if xtarget() and xtarget.TargetType() == "Auto Hater" then
            local id = xtarget.ID()
            if id then
                local spawn = mq.TLO.Spawn("id "..id)
                if spawn() and spawn.Aggressive() and not spawn.Dead() then
                    if spawn.TargetOfTarget.ID() == mq.TLO.Me.ID() then
                        count = count + 1
                    end
                end
            end
        end
    end
    return count
end

local function aggroCount_all()
    -- Count all active Auto Hater mobs, regardless of who they're targeting
    local count = 0
    if not mq.TLO.Me.Combat() then return 0 end
    for i=1, (mq.TLO.Me.XTargetSlots() or 0) do
        local xtarget = mq.TLO.Me.XTarget(i)
        if xtarget() and xtarget.TargetType() == "Auto Hater" then
            local id = xtarget.ID()
            if id then
                local spawn = mq.TLO.Spawn("id "..id)
                if spawn() and spawn.Aggressive() and not spawn.Dead() then
                    count = count + 1
                end
            end
        end
    end
    return count
end

local function aggroCount_anyaggro()
    -- Shield if YOU have aggro on at least 1 mob
    local count = 0
    if not mq.TLO.Me.Combat() then return 0 end
    for i=1, (mq.TLO.Me.XTargetSlots() or 0) do
        local xtarget = mq.TLO.Me.XTarget(i)
        if xtarget() and xtarget.TargetType() == "Auto Hater" then
            local id = xtarget.ID()
            if id then
                local spawn = mq.TLO.Spawn("id "..id)
                if spawn() and spawn.Aggressive() and not spawn.Dead() then
                    if spawn.TargetOfTarget.ID() == mq.TLO.Me.ID() then
                        return 1 -- Early exit, just need one!
                    end
                end
            end
        end
    end
    return 0
end

local function aggroCount()
    if AGGRO_MODE == "primary" then
        return aggroCount_primary()
    elseif AGGRO_MODE == "all" then
        return aggroCount_all()
    elseif AGGRO_MODE == "anyaggro" then
        return aggroCount_anyaggro()
    else
        echo("WARNING: Invalid AGGRO_MODE '%s', defaulting to 'all'", AGGRO_MODE)
        return aggroCount_all()
    end
end

----------------------------- DANGER/UTILITY -----------------------------
local function hasActiveDisc()
    for i = 1, 20 do
        local disc = mq.TLO.Me.CombatAbility(i)
        if disc() then
            local discName = disc.Name()
            if discName and DEFENSIVE_DISC_NAMES[discName] and not mq.TLO.Me.CombatAbilityReady(discName)() then
                return true
            end
        end
    end
    return false
end

local function isKnightOrWarrior()
    local class = mq.TLO.Me.Class.ShortName()
    return class == "WAR" or class == "PAL" or class == "SHD"
end

local function manaLow()
    local class = mq.TLO.Me.Class.ShortName()
    if class == "WAR" then return false end
    return mq.TLO.Me.PctMana() and mq.TLO.Me.PctMana() < LOW_MANA_THRESHOLD
end

local function enduranceLow()
    return mq.TLO.Me.PctEndurance() and mq.TLO.Me.PctEndurance() < LOW_ENDURANCE_THRESHOLD
end

local function isRootedMezzedCharmed()
    return mq.TLO.Me.Rooted() or mq.TLO.Me.Mezzed() or mq.TLO.Me.Charmed()
end

local function hasBuff(name)
    return name ~= "" and mq.TLO.Me.Buff(name)()
end

local function hasDebuff(name)
    return name ~= "" and mq.TLO.Me.Buff(name)()
end

----------------------------- DANGER LOGIC -----------------------------
local function getDangerStatus()
    local hp = mq.TLO.Me.PctHPs() or 100
    local stunned = mq.TLO.Me.Stunned()
    local aggro = aggroCount()
    local reasons = {}

    -- Danger triggers
    local hpDanger, stunDanger = false, false

    if hp < LOW_HP_THRESHOLD then
        hpDanger = true
        table.insert(reasons, string.format("Low HP (%.1f%%)", hp))
    end
    if stunned then
        stunDanger = true
        table.insert(reasons, "Stunned")
    end
    if (AGGRO_MODE == "anyaggro" and aggro >= 1) or (AGGRO_MODE ~= "anyaggro" and aggro >= AGGRO_MOB_COUNT) then
        table.insert(reasons, string.format("Aggro Count High (%d)", aggro))
    end
    if isKnightOrWarrior() and hasActiveDisc() then table.insert(reasons, "Defensive Disc Active") end
    if manaLow() then table.insert(reasons, "Low Mana") end
    if enduranceLow() then table.insert(reasons, "Low Endurance") end
    if isRootedMezzedCharmed() then table.insert(reasons, "Root/Mez/Charm") end
    if hasBuff(BUFF_TRIGGER) then table.insert(reasons, "Special Buff") end
    if hasDebuff(DEBUFF_TRIGGER) then table.insert(reasons, "Special Debuff") end

    if #reasons == 0 and inDanger then
        if inDanger == "hp" and hp < SAFE_HP_THRESHOLD then
            table.insert(reasons, string.format("Recovering HP (%.1f%%)", hp))
        elseif inDanger == "stun" and stunned then
            table.insert(reasons, "Recovering from Stun")
        end
    end

    if #reasons > 0 then
        if hpDanger then return true, table.concat(reasons, " & "), "hp" end
        if stunDanger then return true, table.concat(reasons, " & "), "stun" end
        return true, table.concat(reasons, " & "), "other"
    end
    return false, "Safe", false
end

----------------------------- MAIN -----------------------------
mq.cmd('/echo \agOriginally created by Alektra <Lederhosen>\ax')
echo("Script loaded (version %s, %s). AGGRO_MODE: %s", SCRIPT_VERSION, SCRIPT_DATE, AGGRO_MODE)

if not mq.TLO.FindItem(SHIELD_ITEM)() then
    critical_echo("WARNING: Could not find your shield item: %s", SHIELD_ITEM)
end
if not mq.TLO.FindItem(OFFHAND_ITEM)() then
    critical_echo("WARNING: Could not find your offhand item: %s", OFFHAND_ITEM)
end

local lastShieldReason = ""
local lastDangerState = false

while true do
    mq.delay(250)

    if isBusy() then goto continue end

    local now = os.time()
    local currentOffhand = getCurrentOffhand()
    local validCombat = isValidCombatTarget()
    local danger, dangerReason, dangerType = getDangerStatus()
    local aggro = aggroCount()
    local hp = mq.TLO.Me.PctHPs() or 100
    local xtargetSlots = mq.TLO.Me.XTargetSlots() or 0

    -- Debug: Danger state change
    if ADVANCED_DEBUG and danger ~= lastDangerState then
        debug_echo("DANGER STATE: %s -> %s | Reason: %s | HP: %.1f | Aggro: %d | XTargets: %d | Offhand: %s",
            tostring(lastDangerState), tostring(danger), tostring(dangerReason), hp, aggro, xtargetSlots, currentOffhand)
        lastDangerState = danger
    end

    -- Handle danger state transitions and shield equip
    if danger then
        if currentOffhand ~= SHIELD_ITEM then
            if equipItem(PROC_SLOT, SHIELD_ITEM) then
                shieldEquippedForFocus = false
                echo("DANGER: %s. Equipping shield for safety.", dangerReason)
                lastShieldReason = dangerReason
                debug_echo("SWAP: %s -> %s | Reason: %s | HP: %.1f | Aggro: %d | XTargets: %d",
                    currentOffhand, SHIELD_ITEM, dangerReason, hp, aggro, xtargetSlots)
            end
        elseif lastShieldReason ~= dangerReason then
            echo("DANGER: %s. Shield remains equipped.", dangerReason)
            lastShieldReason = dangerReason
        end
        inDanger = dangerType
        goto continue
    elseif not danger and inDanger then
        inDanger = false
        lastShieldReason = ""
        if validCombat and currentOffhand ~= OFFHAND_ITEM then
            if equipItem(PROC_SLOT, OFFHAND_ITEM) then
                shieldEquippedForFocus = false
                lastSwapTime = now
                echo("Recovered from danger. Swapping back to DPS offhand for combat.")
                debug_echo("SWAP: %s -> %s | Reason: Safe | HP: %.1f | Aggro: %d | XTargets: %d",
                    currentOffhand, OFFHAND_ITEM, hp, aggro, xtargetSlots)
            end
        elseif not validCombat and currentOffhand ~= OFFHAND_ITEM then
            if equipItem(PROC_SLOT, OFFHAND_ITEM) then
                shieldEquippedForFocus = false
                echo("Recovered from danger. Out of combat, equipping DPS offhand.")
                debug_echo("SWAP: %s -> %s | Reason: Out of combat | HP: %.1f | Aggro: %d | XTargets: %d",
                    currentOffhand, OFFHAND_ITEM, hp, aggro, xtargetSlots)
            end
        end
    end

    if inDanger then goto continue end

    if validCombat then
        if not combatActive then
            combatActive = true
            shieldEquippedForFocus = false
            lastSwapTime = now
            if currentOffhand ~= OFFHAND_ITEM then
                if equipItem(PROC_SLOT, OFFHAND_ITEM) then
                    echo("Engaged valid combat. Equipping DPS offhand to start swap cycle.")
                    debug_echo("SWAP: %s -> %s | Reason: Combat start | HP: %.1f | Aggro: %d | XTargets: %d",
                        currentOffhand, OFFHAND_ITEM, hp, aggro, xtargetSlots)
                end
            end
        end

        if not shieldEquippedForFocus and (now - lastSwapTime >= SHIELD_INTERVAL) then
            if equipItem(PROC_SLOT, SHIELD_ITEM) then
                shieldEquippedForFocus = true
                lastSwapTime = now
                echo("Equipping shield to benefit from Furious Bash focus effect.")
                debug_echo("SWAP: %s -> %s | Reason: Focus proc | HP: %.1f | Aggro: %d | XTargets: %d",
                    currentOffhand, SHIELD_ITEM, hp, aggro, xtargetSlots)
            end
        elseif shieldEquippedForFocus and (now - lastSwapTime >= SHIELD_DURATION) then
            if equipItem(PROC_SLOT, OFFHAND_ITEM) then
                shieldEquippedForFocus = false
                lastSwapTime = now
                echo("Swapping back to DPS offhand for continued combat.")
                debug_echo("SWAP: %s -> %s | Reason: Focus proc end | HP: %.1f | Aggro: %d | XTargets: %d",
                    SHIELD_ITEM, OFFHAND_ITEM, hp, aggro, xtargetSlots)
            end
        end
    else
        if combatActive then
            combatActive = false
            shieldEquippedForFocus = false
            if not danger and currentOffhand ~= OFFHAND_ITEM then
                if equipItem(PROC_SLOT, OFFHAND_ITEM) then
                    echo("Combat ended. Swapping back to DPS offhand.")
                    debug_echo("SWAP: %s -> %s | Reason: Combat ended | HP: %.1f | Aggro: %d | XTargets: %d",
                        currentOffhand, OFFHAND_ITEM, hp, aggro, xtargetSlots)
                end
            end
        end
        if not danger and currentOffhand ~= OFFHAND_ITEM then
            equipItem(PROC_SLOT, OFFHAND_ITEM)
        end
    end

    if ENABLE_STATUS_HEARTBEAT then
        if not validCombat and not danger then
            if now - lastHeartbeatTime >= HEARTBEAT_INTERVAL then
                echo("Status: Idle or not in valid combat. Offhand: %s", currentOffhand)
                lastHeartbeatTime = now
            end
        end
    end

    if ADVANCED_DEBUG and now - lastDebugTime > DEBUG_INTERVAL then
        debug_echo("STATUS: Combat=%s | Aggro=%d | Offhand=%s | Danger=%s | HP=%.1f | XTargets=%d",
            tostring(validCombat), aggro, currentOffhand, tostring(inDanger), hp, xtargetSlots)
        lastDebugTime = now
    end

    ::continue::
end
