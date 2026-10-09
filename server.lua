local RSGCore = exports['rsg-core']:GetCoreObject()
local sessions = {}
local locks = {}

local function round(amount)
    return math.floor(amount * 100 + 0.5) / 100
end

local function logDebug(message, ...)
    if Config.DevMode then
        print(('[kurzy_salary] ' .. message):format(...))
    end
end

local function notify(src, message, kind)
    if not Config.Notify then return end

    TriggerClientEvent('ox_lib:notify', src, {
        title = 'Godzinówka',
        description = message,
        type = kind or 'inform',
    })
end

local function startSession(player)
    if not player or not player.PlayerData then return end

    local src = tonumber(player.PlayerData.source)
    local current = src and RSGCore.Functions.GetPlayer(src)
    if not current or current.PlayerData.citizenid ~= player.PlayerData.citizenid then return end
    if sessions[src] and sessions[src].citizenid == player.PlayerData.citizenid then return end

    sessions[src] = {
        citizenid = player.PlayerData.citizenid,
        nextAccrual = os.time() + Config.PayoutInterval / 1000,
        requests = {},
    }
end

local function isCurrent(src, session)
    local player = RSGCore.Functions.GetPlayer(src)
    return sessions[src] == session and player ~= nil
        and player.PlayerData.citizenid == session.citizenid
end

local function getSession(src)
    local session = sessions[src]
    if session and isCurrent(src, session) then return session end
end

local function allowRequest(session, action, cooldown)
    local now = os.time()
    if now < (session.requests[action] or 0) then return false end

    session.requests[action] = now + math.ceil(cooldown / 1000)
    return true
end

-- SQL guards are still needed: other resources do not share this lock.
local function withLock(citizenid, action)
    if locks[citizenid] then return 0, 'busy' end

    locks[citizenid] = true
    local ok, result, reason = xpcall(action, debug.traceback)
    locks[citizenid] = nil

    if not ok then
        print(('[kurzy_salary] Operation failed for %s: %s'):format(citizenid, result))
        return 0, 'error'
    end

    return result, reason
end

local function getBalance(citizenid)
    local amount = MySQL.scalar.await('SELECT hourlyBalance FROM salary WHERE citizenid = ?', { citizenid })
    return round(tonumber(amount) or 0)
end

local function restoreBalance(citizenid, amount)
    -- Preserve any salary accrued while the payment was pending.
    local affected = MySQL.update.await(
        'UPDATE salary SET hourlyBalance = hourlyBalance + ? WHERE citizenid = ?', { amount, citizenid })
    assert(affected == 1, ('Unable to restore $%.2f for %s'):format(amount, citizenid))
end

local function payPlayer(player, citizenid, amount)
    local ok, paid = pcall(player.Functions.AddMoney, Config.PayoutAccount, amount, 'kurzy_salary:collect')
    if not ok then
        -- AddMoney may throw after crediting the wallet. A refund could duplicate money.
        error(('AddMoney outcome unknown for %s ($%.2f); reconcile manually: %s')
            :format(citizenid, amount, tostring(paid)))
    end

    return paid == true
end

local function collect(src, credit)
    local session = getSession(src)
    if not session or not allowRequest(session, 'collect', Config.CollectCooldown) then return 0 end

    return withLock(session.citizenid, function()
        local player = RSGCore.Functions.GetPlayer(src)
        if credit and (not player.Functions.AddMoney or player.PlayerData.money[Config.PayoutAccount] == nil) then
            return 0
        end

        local amount = getBalance(session.citizenid)
        if amount <= 0 or not isCurrent(src, session) then return 0 end

        local affected = MySQL.update.await(
            'UPDATE salary SET hourlyBalance = 0 WHERE citizenid = ? AND hourlyBalance = ?',
            { session.citizenid, amount })
        if affected ~= 1 then return 0 end

        if not isCurrent(src, session) then
            restoreBalance(session.citizenid, amount)
            return 0
        end

        if credit then
            player = RSGCore.Functions.GetPlayer(src)
            if not payPlayer(player, session.citizenid, amount) then
                restoreBalance(session.citizenid, amount)
                return 0
            end
        end

        logDebug('Collected $%.2f for %s (credit=%s)', amount, session.citizenid, tostring(credit))
        return amount
    end)
end

local function getRate(player)
    local job = player.PlayerData.job
    if Config.RequireDuty and (not job or not job.onduty) then return 0 end

    local grade = job and job.grade
    if type(grade) == 'table' then grade = grade.level or grade.grade or grade.id end
    grade = tonumber(grade) or 0

    local rates = job and Config.Jobs[job.name]
    local amount = rates and (rates[grade] or rates[tostring(grade)])
    return round(amount or Config.PayoutPerInterval)
end

local function collectAndNotify(src, automatic)
    local session = getSession(src)
    if not session then return end

    local amount = collect(src, true)
    if not isCurrent(src, session) then return end

    if amount > 0 then
        notify(src, ('Wypłacono $%.2f z godzinówki.'):format(amount), 'success')
    elseif not automatic then
        notify(src, 'Brak wypłaty. Spróbuj ponownie później.', 'error')
    end
end

local function accrue(src, session)
    return withLock(session.citizenid, function()
        local amount = getRate(RSGCore.Functions.GetPlayer(src))
        if amount <= 0 then return 0, 'ineligible' end

        MySQL.insert.await('INSERT IGNORE INTO salary (citizenid, hourlyBalance, `count`) VALUES (?, 0, 0)',
            { session.citizenid })

        local row = MySQL.single.await([[
            SELECT s.hourlyBalance, s.`count`, COALESCE(p.outlawstatus, 0) AS outlawstatus
            FROM salary s INNER JOIN players p
                ON p.citizenid COLLATE utf8mb4_general_ci = s.citizenid COLLATE utf8mb4_general_ci
            WHERE s.citizenid = ?
        ]], { session.citizenid })
        if not row or not isCurrent(src, session) then return 0, 'inactive' end

        local balance, count = tonumber(row.hourlyBalance), tonumber(row.count)
        local outlaw = tonumber(row.outlawstatus) >= Config.OutlawStatusThreshold
        local countCap = outlaw and Config.CountCaps.Outlaw or Config.CountCaps.Citizen
        if countCap > 0 and count >= countCap then return 0, 'cap' end

        if Config.Cap > 0 then amount = math.min(amount, round(Config.Cap - balance)) end
        if amount <= 0 then return 0, 'cap' end

        local affected = MySQL.update.await([[
            UPDATE salary SET hourlyBalance = hourlyBalance + ?, `count` = `count` + 1
            WHERE citizenid = ? AND hourlyBalance = ? AND `count` = ?
        ]], { amount, session.citizenid, balance, count })
        if affected ~= 1 then return 0, 'retry' end

        if isCurrent(src, session) then
            notify(src, ('Dodano $%.2f (stan: $%.2f).'):format(amount, balance + amount), 'success')
        end

        logDebug('Accrued $%.2f for %s', amount, session.citizenid)
        return amount
    end)
end

local function processSession(src, session)
    if not isCurrent(src, session) then return end

    if os.time() >= session.nextAccrual then
        local _, reason = accrue(src, session)
        if not isCurrent(src, session) then return end

        if reason ~= 'busy' and reason ~= 'retry' and reason ~= 'error' then
            local now = os.time()
            local interval = Config.PayoutInterval / 1000

            -- Skip missed intervals without accumulating back pay.
            repeat
                session.nextAccrual = session.nextAccrual + interval
            until session.nextAccrual > now
        end
    end

    if Config.AutoCollect then collectAndNotify(src, true) end
end

lib.callback.register('kurzy_salary:getBalance', function(src)
    local session = getSession(src)
    if not session or not allowRequest(session, 'balance', Config.BalanceCooldown) then return 0 end

    local ok, amount = pcall(getBalance, session.citizenid)
    if not ok then
        print(('[kurzy_salary] Balance lookup failed: %s'):format(tostring(amount)))
        return 0
    end

    return isCurrent(src, session) and amount or 0
end)

lib.callback.register('kurzy_salary:collect', function(src)
    return collect(src, true)
end)

-- The calling resource is responsible for delivering these funds.
exports('collectPayout', function(src)
    local amount = collect(tonumber(src), false)
    return amount
end)

AddEventHandler('RSGCore:Server:PlayerLoaded', startSession)

AddEventHandler('RSGCore:Server:OnPlayerUnload', function(src)
    sessions[tonumber(src)] = nil
end)

AddEventHandler('playerDropped', function()
    sessions[tonumber(source)] = nil
end)

CreateThread(function()
    for _, id in ipairs(GetPlayers()) do
        startSession(RSGCore.Functions.GetPlayer(tonumber(id)))
    end

    while true do
        Wait(Config.CheckInterval)

        -- Database waits allow sessions to change during this pass.
        local online = {}
        for src, session in pairs(sessions) do
            online[#online + 1] = { src = src, session = session }
        end

        for _, entry in ipairs(online) do
            processSession(entry.src, entry.session)
        end
    end
end)

if Config.CollectCommand.Enabled then
    RSGCore.Commands.Add(Config.CollectCommand.Name, 'Odbierz godzinówkę', {}, false, function(src)
        collectAndNotify(src, false)
    end, Config.CollectCommand.Permission)
end

