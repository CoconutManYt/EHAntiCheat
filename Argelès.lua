local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer
local SIT_OFFSET = 0x1ea

-- ============================================================
-- CONFIG
-- ============================================================
local WEBHOOK_URL = "https://discord.com/api/webhooks/1519647743654498444/2N2vYVSwLx526-GJ0BfuWGVKkhJdYh380o32ibbF2rDPdXvDJeO4bQ_5g8Vy_WD-XIfd"
local PLR_WEBHOOK_URL = "https://discord.com/api/webhooks/1519738845917085746/G6T6jQA_jniRFCRSxeCcmNN5xGy1ASz2ZDzIZXmfo5dzBgwEPwhMBhmZiD0u400X9Ezn"

local config = {
    -- under-map check
    underY = -97,           -- Y below which counts as "under map"
    underSustain = 3.0,     -- seconds under before flagging

    -- car-fly check
    flyHeight = 30,         -- Y above which a seated player is "high"
    flySustain = 2.5,       -- seconds seated+high before flagging

    checkInterval = 0.5,    -- poll rate
    realertCooldown = 60,   -- seconds before the same player+cheat can re-alert

    -- player/car check
    maxSeatDif = 5,      -- max Y difference between seat and HRP to count as "in car"

    -- player count
    playerCountCheckInterval = 10,  -- seconds between player count checks
}

-- per-player state: name -> { underSince, underFlagged, underLastAlert,
--                             flySince, flyFlagged, flyLastAlert }
local tracking = {}

local timeSincePLRCheck = 0

-- ============================================================
-- seat detection (memory_read at confirmed offset 0x1ea)
-- ============================================================
local function isSeated(character)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end

    local Vehicles = game.Workspace:FindFirstChild("Vehicles")
    -- print(Vehicles)
    local playerCar = Vehicles:FindFirstChild(character.Name)
    -- print(playerCar)

    if not playerCar then return false end

    local playerSeat = playerCar:FindFirstChild("DriveSeat")
    -- print(playerSeat)
    if not playerSeat then return false end

    local difY = math.abs(character:FindFirstChild("HumanoidRootPart").Position.Y - playerSeat.Position.Y)
    -- print(dif)
    if difY > config.maxSeatDif then return false end
    local difX = math.abs(character:FindFirstChild("HumanoidRootPart").Position.X - playerSeat.Position.X)
    if difX > config.maxSeatDif then return false end
    local difZ = math.abs(character:FindFirstChild("HumanoidRootPart").Position.Z - playerSeat.Position.Z)
    if difZ > config.maxSeatDif then return false end

    local ok, sit = pcall(memory_read, "byte", humanoid.Address + SIT_OFFSET)
    return ok and sit == 1
end

-- ============================================================
-- webhook sender
-- ============================================================
local ROLE_ID = "1359600520448184402"

local function sendWebhook(cheatType, playerName, yPos, duration, webhookUrl)
    if not webhookUrl or webhookUrl == "" then
        warn("[anticheat] webhook URL not set")
        return
    end

    local title, color
    if cheatType == "carfly" then
        title = "🚗 Car Fly Detected"
        color = 16744192
    elseif cheatType == "undermap" then
        title = "🕳️ Under-Map Detected"
        color = 15158332
        elseif cheatType == "players" then
        title = "👥 Player Count"
        color = 15158332
    end

    local body = HttpService:JSONEncode({
        username = "Anticheat",
        content = "<@&" .. ROLE_ID .. ">",   -- role ping
        allowed_mentions = {
            roles = { ROLE_ID },             -- explicitly allow this role to be pinged
        },
        embeds = {{
            title = title,
            description = string.format(
                "**Player:** %s\n**Y Position:** %.1f\n**Sustained:** %.1fs",
                playerName, yPos, duration
            ),
            color = color,
            footer = { text = "Anticheat • " .. os.date("%H:%M:%S") },
        }},
    })

    pcall(function() game:HttpPost(webhookUrl, body, "application/json") end)
    print(string.format("[anticheat] webhook sent: %s for %s (Y=%.1f)", cheatType, playerName, yPos))
end

local function sendPlrWebhook(playerNumber, webhookUrl)
    if not webhookUrl or webhookUrl == "" then
        warn("[anticheat] webhook URL not set")
        return
    end

    local body = HttpService:JSONEncode({
        username = "Anticheat",
        content = "🌴" .. playerNumber .. " 🌴",   -- role ping
    })

    pcall(function() game:HttpPost(webhookUrl, body, "application/json") end)
    print(string.format("[anticheat] webhook sent: %s for %s", "players", playerNumber))
end

local function getPlayers()
    local players = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            table.insert(players, plr)
        end
    end
    return players
end

-- ============================================================
-- main check (both detections in one pass)
-- ============================================================
local function checkPlayers()
    local now = tick()

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer then
            local char = plr.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            local humanoid = char and char:FindFirstChild("Humanoid")
            local alive = humanoid and humanoid.Health > 0

            if hrp and alive then
                local y = hrp.Position.Y
                local seated = isSeated(char)

                local t = tracking[plr.Name]
                if not t then t = {} ; tracking[plr.Name] = t end

                -- ---------- UNDER-MAP CHECK ----------
                if y < config.underY then
                    if not t.underSince then
                        t.underSince = now
                    elseif now - t.underSince >= config.underSustain and not t.underFlagged then
                        if not t.underLastAlert or now - t.underLastAlert >= config.realertCooldown then
                            sendWebhook("undermap", plr.Name, y, now - t.underSince, WEBHOOK_URL)
                            t.underLastAlert = now
                        end
                        t.underFlagged = true
                    end
                else
                    t.underSince = nil
                    t.underFlagged = nil
                end

                -- ---------- CAR-FLY CHECK ----------
                if seated and y > config.flyHeight then
                    if not t.flySince then
                        t.flySince = now
                    elseif now - t.flySince >= config.flySustain and not t.flyFlagged then
                        if not t.flyLastAlert or now - t.flyLastAlert >= config.realertCooldown then
                            sendWebhook("carfly", plr.Name, y, now - t.flySince, WEBHOOK_URL)
                            t.flyLastAlert = now
                        end
                        t.flyFlagged = true
                    end
                else
                    t.flySince = nil
                    t.flyFlagged = nil
                end

            elseif tracking[plr.Name] then
                -- no HRP or dead: reset timers so respawn doesn't false-trigger
                local t = tracking[plr.Name]
                t.underSince = nil ; t.underFlagged = nil
                t.flySince = nil ; t.flyFlagged = nil
            end
        end
    end

    -- drop players who left
    for name in pairs(tracking) do
        local here = false
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Name == name then here = true break end
        end
        if not here then tracking[name] = nil end
    end
end

-- ============================================================
-- start
-- ============================================================
print(string.format("[anticheat] started | underY=%d | flyHeight=%d", config.underY, config.flyHeight))
spawn(function()
    while true do
        wait(config.checkInterval)
        -- print("[anticheat] checking players...")
        timeSincePLRCheck = timeSincePLRCheck + config.checkInterval
        if timeSincePLRCheck >= config.playerCountCheckInterval then
            timeSincePLRCheck = 0
            sendPlrWebhook(#getPlayers(),PLR_WEBHOOK_URL)
            -- print("[anticheat] checking players...")

        end
        local ok, err = pcall(checkPlayers)
        if not ok then
            warn(err)
        end
    end
end)
