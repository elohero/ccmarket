script_name('CC Market History')
script_description('Istoriya realnyh sdelok na rynke, neskolko serverov')
script_version('4.0')

local ffi = require('ffi')
local imgui = require('mimgui')
local effil = require('effil')
local encoding = require('encoding')
local inicfg = require('inicfg')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local new = imgui.new

--=========================================================
-- НАСТРОЙКИ
--=========================================================
local cfgFile = 'cc_market.ini'
local cfgData = inicfg.load({
    main = {
        refreshSec = 60,
        keepDays = 14,
        servers = '',      -- доп. серверы через запятую, напр. 201 (Vice City)
        sideFilter = 1,
        periodFilter = 0,
        sortMode = 0,
        minTrades = 0,
        resale = 0,
        serverFilter = 0   -- 0 = все серверы
    },
    window = { sizeX = 1360, sizeY = 620, posX = 0.5, posY = 0.5 },
    sync = {
        enabled = false,
        url = '',
        key = '',
        client = '',
        lastIds = ''       -- '32:1200,201:340'
    },
    currency = {
        default = 'SA$',
        map = '201:VC$',   -- 'номер:код' через запятую
        rates = ''         -- 'номер:курс', сколько единиц валюты по умолчанию за 1 местную
    }
}, cfgFile)

local function toNum(v, d)
    local n = tonumber(v)
    if n == nil then return d end
    return n
end

local function toBool(v, d)
    if v == nil then return d end
    if type(v) == 'boolean' then return v end
    if type(v) == 'number' then return v ~= 0 end
    v = tostring(v):lower()
    if v == 'true' or v == '1' or v == 'yes' then return true end
    if v == 'false' or v == '0' or v == 'no' then return false end
    return d
end

local cfg = {
    refresh   = new.int(toNum(cfgData.main.refreshSec, 60)),
    keepDays  = new.int(toNum(cfgData.main.keepDays, 14)),
    minTrades = new.int(toNum(cfgData.main.minTrades, 0)),
    sizeX     = new.float(toNum(cfgData.window.sizeX, 1360)),
    sizeY     = new.float(toNum(cfgData.window.sizeY, 620)),
    posX      = new.float(toNum(cfgData.window.posX, 0.5)),
    posY      = new.float(toNum(cfgData.window.posY, 0.5))
}
local sideFilter   = toNum(cfgData.main.sideFilter, 1)
local periodFilter = toNum(cfgData.main.periodFilter, 0)
local sortMode     = toNum(cfgData.main.sortMode, 0)
local serverFilter = toNum(cfgData.main.serverFilter, 0)
local resaleMode   = toNum(cfgData.main.resale, 0) ~= 0

local syncEnabled = toBool(cfgData.sync.enabled, false)
local syncUrl     = tostring(cfgData.sync.url or '')
local syncKey     = tostring(cfgData.sync.key or '')
local clientId    = tostring(cfgData.sync.client or '')

if clientId == '' then
    math.randomseed(os.time() + math.floor(os.clock() * 1000))
    clientId = ('cc%d%04d'):format(os.time() % 1000000, math.random(0, 9999))
    cfgData.sync.client = clientId
end

local syncActive = syncEnabled and syncUrl ~= ''
local windowOpen = new.bool(false)

--=========================================================
-- ВАЛЮТЫ
-- На Vice City ходит VC$, на остальных SA$. Цены разных
-- серверов между собой напрямую несопоставимы.
--=========================================================
local currencyDefault = tostring(cfgData.currency.default or 'SA$')
local currencyMap = {}
local currencyRates = {}

for pair in tostring(cfgData.currency.map or ''):gmatch('[^,%s]+') do
    local n, code = pair:match('^(%d+):(.+)$')
    if n then currencyMap[tonumber(n)] = code end
end

for pair in tostring(cfgData.currency.rates or ''):gmatch('[^,%s]+') do
    local n, rate = pair:match('^(%d+):([%d%.]+)$')
    if n and tonumber(rate) then currencyRates[tonumber(n)] = tonumber(rate) end
end

local function currencyOf(srv)
    return currencyMap[tonumber(srv) or 0] or currencyDefault
end

local function rateOf(srv)
    return currencyRates[tonumber(srv) or 0]
end

-- price -> base currency (currencyDefault). second return is
-- true only when comparable: same currency, or a known VC rate.
local function toBase(price, srv)
    if currencyOf(srv) == currencyDefault then return price, true end
    local r = rateOf(srv)
    if r then return price * r, true end
    return price, false
end

local cfgDirty, cfgDirtyAt = false, 0
local function markDirty()
    cfgDirty = true
    cfgDirtyAt = os.clock()
end

--=========================================================
-- СПИСОК ОТСЛЕЖИВАЕМЫХ СЕРВЕРОВ
--=========================================================
local tracked = {}        -- массив номеров
local trackedSet = {}
local srvState = {}       -- номер -> состояние сбора

local function newServerState()
    return {
        prevLots = nil, prevItems = nil,
        lastUpdate = 0, lastFound = 0, snapshots = 0,
        apiStatus = '', errStreak = 0,
        currentBest = {},
        pushQueue = {},
        isHolder = false, leaseHolder = nil,
        lastSid = 0, lastOkTs = nil
    }
end

local function addServer(n)
    n = tonumber(n)
    if not n or n <= 0 or trackedSet[n] then return end
    trackedSet[n] = true
    tracked[#tracked + 1] = n
    srvState[n] = newServerState()
    table.sort(tracked)
end

for part in tostring(cfgData.main.servers or ''):gmatch('[^,%s]+') do
    addServer(part)
end

-- lastIds из конфига: '32:1200,201:340'
for pair in tostring(cfgData.sync.lastIds or ''):gmatch('[^,%s]+') do
    local srv, sid = pair:match('^(%d+):(%d+)$')
    if srv then
        addServer(srv)
        srvState[tonumber(srv)].lastSid = tonumber(sid) or 0
    end
end

local function serializeLastIds()
    local parts = {}
    for _, n in ipairs(tracked) do
        parts[#parts + 1] = n .. ':' .. (srvState[n].lastSid or 0)
    end
    return table.concat(parts, ',')
end

local function serializeServers()
    return table.concat(tracked, ',')
end

local function saveCfg()
    cfgData.main.refreshSec = cfg.refresh[0]
    cfgData.main.keepDays = cfg.keepDays[0]
    cfgData.main.minTrades = cfg.minTrades[0]
    cfgData.main.servers = serializeServers()
    cfgData.main.sideFilter = sideFilter
    cfgData.main.periodFilter = periodFilter
    cfgData.main.sortMode = sortMode
    cfgData.main.serverFilter = serverFilter
    cfgData.main.resale = resaleMode and 1 or 0
    cfgData.window.sizeX = cfg.sizeX[0]
    cfgData.window.sizeY = cfg.sizeY[0]
    cfgData.window.posX = cfg.posX[0]
    cfgData.window.posY = cfg.posY[0]
    cfgData.sync.client = clientId
    cfgData.sync.lastIds = serializeLastIds()
    pcall(inicfg.save, cfgData, cfgFile)
    cfgDirty = false
end

--=========================================================
-- АВТОРИЗАЦИЯ
--=========================================================
local authFile = 'cc_market_auth.ini'
local authData = inicfg.load({
    auth = { token = '', serverId = '', authKey = 'nil', authClient = '' }
}, authFile)

local myToken      = tostring(authData.auth.token or '')
local myServerId   = tostring(authData.auth.serverId or '')
local myAuthKey    = tostring(authData.auth.authKey or 'nil')
if myAuthKey == '' then myAuthKey = 'nil' end
local myAuthClient = tostring(authData.auth.authClient or '')

pcall(ffi.cdef, [[
    typedef void* HKEY;
    typedef HKEY* PHKEY;
    typedef unsigned long DWORD;
    typedef DWORD* LPDWORD;
    typedef unsigned char BYTE;
    typedef BYTE* LPBYTE;
    typedef long LONG;
    LONG RegOpenKeyExA(HKEY hKey, const char* lpSubKey, DWORD ulOptions, DWORD samDesired, PHKEY phkResult);
    LONG RegQueryValueExA(HKEY hKey, const char* lpValueName, void* lpReserved, LPDWORD lpType, LPBYTE lpData, LPDWORD lpcbData);
    LONG RegCloseKey(HKEY hKey);
]])

local function readRegistryString(valueName)
    local ok, value = pcall(function()
        local hkey = ffi.new('HKEY[1]')
        local root = ffi.cast('HKEY', 0x80000001)
        if ffi.C.RegOpenKeyExA(root, 'Software\\ArzMarket\\info', 0, 0x20019, hkey) ~= 0 then return nil end
        local vt = ffi.new('DWORD[1]')
        local size = ffi.new('DWORD[1]', 0)
        if ffi.C.RegQueryValueExA(hkey[0], valueName, nil, vt, nil, size) ~= 0 or size[0] == 0 then
            ffi.C.RegCloseKey(hkey[0]); return nil
        end
        local buf = ffi.new('char[?]', size[0] + 1)
        local r = ffi.C.RegQueryValueExA(hkey[0], valueName, nil, vt, ffi.cast('LPBYTE', buf), size)
        ffi.C.RegCloseKey(hkey[0])
        if r ~= 0 then return nil end
        return ffi.string(buf)
    end)
    if ok then return value end
    return nil
end

local function loadArzMarketAuth()
    local ok, data = pcall(inicfg.load, { cfg = { myServerToken = '', myServerId = '' } }, 'ArzMarket/ArzMarket.ini')
    if not ok or not data or not data.cfg then return end
    local t = tostring(data.cfg.myServerToken or '')
    local s = tostring(data.cfg.myServerId or '')
    if t ~= '' then myToken = t; authData.auth.token = t end
    if s ~= '' then myServerId = s; authData.auth.serverId = s end
end

local function refreshAuthFromRegistry()
    local pt = readRegistryString('premiumTokenAuth')
    if pt and pt ~= '' then myAuthClient = pt; authData.auth.authClient = pt end
    if myAuthKey == '' then myAuthKey = 'nil' end
    authData.auth.authKey = myAuthKey
end

local function currentAuthClient()
    if myAuthClient and myAuthClient ~= '' then return myAuthClient end
    return 'desktop'
end

loadArzMarketAuth()
refreshAuthFromRegistry()

--=========================================================
-- HTTP
--=========================================================
local function requestRunner()
    return effil.thread(function(method, url, args)
        local requests = require 'requests'
        local _args = {}
        local function assign(target, def, deep)
            for k, v in pairs(def) do
                if target[k] == nil then
                    if type(v) == 'table' or type(v) == 'userdata' then
                        target[k] = {}; assign(target[k], v)
                    else target[k] = v end
                elseif deep and (type(v) == 'table' or type(v) == 'userdata')
                    and (type(target[k]) == 'table' or type(target[k]) == 'userdata') then
                    assign(target[k], v, deep)
                end
            end
            return target
        end
        assign(_args, args, true)
        local ok, response = pcall(requests.request, method, url, _args)
        if ok then
            response.json, response.xml = nil, nil
            return true, response
        end
        return false, response
    end)
end

local function httpThread(runner, resolve, reject)
    local status, err
    repeat status, err = runner:status(); wait(0) until status ~= 'running'
    if not err then
        if status == 'completed' then
            local ok, response = runner:get()
            if ok then resolve(response) else reject(response) end
            return
        elseif status == 'canceled' then return reject(status) end
    else return reject(err) end
end

local function asyncHttp(method, url, args, resolve, reject)
    local thread = requestRunner()(method, url, effil.table(args))
    resolve = resolve or function() end
    reject = reject or function() end
    return lua_thread.create(httpThread, thread, resolve, reject)
end

--=========================================================
-- КОДИРОВКИ
--=========================================================

-- ==== auto-update ====
local UPDATE_RAW_URL = 'https://raw.githubusercontent.com/elohero/ccmarket/main/cc_market_history.lua'

local function parseVer(s)
    local t = {}
    for n in tostring(s):gmatch('%d+') do t[#t + 1] = tonumber(n) end
    return t
end

local function verNewer(remote, cur)
    local a, b = parseVer(remote), parseVer(cur)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x ~= y then return x > y end
    end
    return false
end

local function checkUpdate()
    asyncHttp('GET', UPDATE_RAW_URL, {}, function(r)
        if not r or not r.text or #r.text < 200 then return end
        local body = r.text
        local rv = body:match("script_version%('([^']+)'") or body:match('script_version%("([^"]+)"')
        if not rv or not verNewer(rv, thisScript().version) then return end
        local f = io.open(thisScript().path, 'wb')
        if not f then return end
        f:write(body); f:close()
        sampAddChatMessage('[CC] update -> v' .. rv .. ', reload...', 0x66CCFF)
        wait(200)
        thisScript():reload()
    end, function() end)
end
local function isValidUtf8(s)
    local i, n = 1, #s
    while i <= n do
        local c = s:byte(i)
        if c < 0x80 then
            i = i + 1
        elseif c >= 0xC2 and c <= 0xDF then
            local c2 = s:byte(i + 1)
            if not c2 or c2 < 0x80 or c2 > 0xBF then return false end
            i = i + 2
        elseif c >= 0xE0 and c <= 0xEF then
            local c2, c3 = s:byte(i + 1), s:byte(i + 2)
            if not c3 or c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF then return false end
            i = i + 3
        elseif c >= 0xF0 and c <= 0xF4 then
            local c2, c3, c4 = s:byte(i + 1), s:byte(i + 2), s:byte(i + 3)
            if not c4 or c2 < 0x80 or c2 > 0xBF or c3 < 0x80 or c3 > 0xBF or c4 < 0x80 or c4 > 0xBF then return false end
            i = i + 4
        else
            return false
        end
    end
    return true
end

local function toDisplay(s)
    s = tostring(s or '')
    if s == '' then return s end
    if isValidUtf8(s) then return s end
    local ok, c = pcall(u8, s)
    if ok then return c end
    return s
end

local function toAnsi(s)
    local ok, c = pcall(function() return u8:decode(s) end)
    if ok and c then return c end
    return s
end

--=========================================================
-- СПРАВОЧНИК ПРЕДМЕТОВ
--=========================================================
local itemsIndex = {}
local itemsUrl = 'https://raw.githubusercontent.com/FREYM1337/forumnick/main/ArzMarketV3/items.json'

local function loadItemsIndex()
    asyncHttp('GET', itemsUrl, {}, function(r)
        if r.status_code ~= 200 then return end
        local ok, data = pcall(decodeJson, r.text)
        if ok and type(data) == 'table' then
            itemsIndex = data
            local c = 0
            for _ in pairs(itemsIndex) do c = c + 1 end
            print('[CC] предметов в справочнике: ' .. c)
        end
    end)
end

local function itemNameById(id)
    local k = tostring(id)
    return toDisplay(itemsIndex[k] or ('#' .. k))
end

--=========================================================
-- ХЕЛПЕРЫ
--=========================================================
local function formatMoney(a)
    a = tonumber(a) or 0
    if a == 0 then return '0' end
    local neg = a < 0
    local s = tostring(math.floor(math.abs(a)))
    s = s:reverse():gsub('(%d%d%d)', '%1.'):reverse()
    if s:sub(1, 1) == '.' then s = s:sub(2) end
    if neg then s = '-' .. s end
    return s
end

local function agoText(ts)
    local d = os.time() - ts
    if d < 60 then return u8('только что') end
    if d < 3600 then return math.floor(d / 60) .. u8(' мин') end
    if d < 86400 then return math.floor(d / 3600) .. u8(' ч') end
    return math.floor(d / 86400) .. u8(' д')
end

local itemIdFields = { 'id', 'itemId', 'item_id', 'item', 'model', 'modelId' }
local function extractItemId(item)
    if type(item) == 'table' then
        for i = 1, #itemIdFields do
            local id = item[itemIdFields[i]]
            if id ~= nil then return tostring(id):match('(%d+)') end
        end
    end
    return tostring(item or ''):match('^%s*(%d+)') or tostring(item or ''):match('(%d+)')
end

local function tableValueAt(src, idx)
    if type(src) ~= 'table' then return src end
    return src[idx] or src[tostring(idx)]
end

local enchPatterns = { '%(%s*%+%s*(%d+)%s*%)', '[Ee]nchant%w*%s*[:=]%s*(%d+)', '[Uu]pgrade%s*[:=]%s*(%d+)' }
local function normEnch(v)
    if v == nil then return nil end
    if type(v) == 'number' then
        local l = math.floor(v)
        if l >= 1 and l <= 16 then return l end
        return nil
    end
    if type(v) == 'table' then
        for _, f in ipairs({ 'enchantment', 'enchant', 'ench', 'upgrade' }) do
            local l = normEnch(v[f]); if l then return l end
        end
        return nil
    end
    local t = tostring(v)
    if t == '' or t == '0' or t == 'nil' then return nil end
    for i = 1, #enchPatterns do
        local l = tonumber(t:match(enchPatterns[i]))
        if l and l >= 1 and l <= 16 then return math.floor(l) end
    end
    return nil
end

local enchFields = {
    sell = { 'enchantment_sell', 'enchant_sell', 'ench_sell', 'upgrade_sell', 'items_enchantment_sell' },
    buy  = { 'enchantment_buy', 'enchant_buy', 'ench_buy', 'upgrade_buy', 'items_enchantment_buy' },
    any  = { 'enchantment', 'enchant', 'ench', 'upgrade', 'items_enchantment', 'params' }
}
local function extractEnch(item, shop, idx, side)
    local l = normEnch(item); if l then return l end
    for _, list in ipairs({ enchFields[side] or {}, enchFields.any }) do
        for i = 1, #list do
            l = normEnch(tableValueAt(shop and shop[list[i]], idx))
            if l then return l end
        end
    end
    return nil
end

local ruUp = u8('ЁАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ')
local ruLo = u8('ёабвгдежзийклмнопрстуфхцчшщъыьэюя')
local ruMap = {}
for i = 1, #ruUp, 2 do ruMap[ruUp:sub(i, i + 1)] = ruLo:sub(i, i + 1) end

local function lower(text)
    text = tostring(text or ''):lower()
    return (text:gsub('[\208\209][\128-\191]', function(c) return ruMap[c] or c end))
end

--=========================================================
-- СЕРВЕРЫ
--=========================================================
local arizonaServers = nil
local serverNames = {}
local homeServer = 0

local function normalize(t) return tostring(t or ''):gsub('%-', ''):gsub('%s+', '') end

local function serverName(n)
    n = tonumber(n) or 0
    if serverNames[n] then return serverNames[n] end
    if n == 201 then return 'Vice City' end
    return u8('Сервер ') .. n
end

local function buildServerNames()
    if type(arizonaServers) ~= 'table' then return end
    for _, s in ipairs(arizonaServers) do
        local num = tonumber(s.number)
        if num and s.name then serverNames[num] = toDisplay(s.name) end
    end
    if not serverNames[201] then serverNames[201] = 'Vice City' end
end

local function getServerNumber()
    local name = sampGetCurrentServerName():match('Arizona R[ole ]*P[lay]* | (.+)') or 'Unknown'
    name = name:gsub('%s*|.+', '')
    if arizonaServers then
        for _, s in ipairs(arizonaServers) do
            if normalize(s.name) == normalize(name) then return tonumber(s.number) or 0 end
        end
    end
    if normalize(name):lower() == 'vicecity' then return 201 end
    return 0
end

-- Vice City числится как 201, но в запросе уходит как 0
local function requestServerId(n)
    n = tonumber(n) or 0
    if n == 201 then return '0' end
    return tostring(n)
end

local function serverMatches(sid, target)
    local a, b = tonumber(sid) or 0, tonumber(target) or 0
    if b == 201 and a == 0 then return true end
    if b == 0 and a == 201 then return true end
    return a == b
end

--=========================================================
-- ХРАНИЛИЩЕ СДЕЛОК
--=========================================================
-- trade = { ts, srv, id, ench, name, side, price, qty, shop, exact, sid }
local trades = {}
local byKey = {}
local statsCache = {}
local dataVersion = 0
local seenSid = {}

local csvPath = getWorkingDirectory() .. '\\config\\cc_trades.csv'
local csvHandle = nil

local function keyOf(srv, id, ench, side)
    return srv .. '#' .. id .. '#' .. ench .. '#' .. side
end

local function indexTrade(t)
    trades[#trades + 1] = t
    local k = keyOf(t.srv, t.id, t.ench, t.side)
    local list = byKey[k]
    if not list then list = {}; byKey[k] = list end
    list[#list + 1] = t
    statsCache[k] = nil
end

local function storeTrade(t, persist)
    local sidKey = t.srv .. ':' .. (t.sid or 0)
    if t.sid and t.sid > 0 then
        if seenSid[sidKey] then return false end
        seenSid[sidKey] = true
    end

    indexTrade(t)
    dataVersion = dataVersion + 1

    if persist then
        if not csvHandle then
            local exists = false
            local probe = io.open(csvPath, 'r')
            if probe then exists = true; probe:close() end
            csvHandle = io.open(csvPath, 'a')
            if csvHandle and not exists then
                csvHandle:write('time;ts;server;side;item_id;ench;name;price;qty;shop;exact;sid\n')
            end
        end
        if csvHandle then
            csvHandle:write(('%s;%d;%d;%s;%s;%d;%s;%d;%d;%s;%d;%d\n'):format(
                os.date('%Y-%m-%d %H:%M:%S', t.ts), t.ts, t.srv, t.side,
                t.id, t.ench, toAnsi(t.name):gsub(';', ','), t.price, t.qty,
                tostring(t.shop or ''), t.exact and 1 or 0, t.sid or 0))
            csvHandle:flush()
        end
    end
    return true
end

local function loadTradesFromCsv()
    local f = io.open(csvPath, 'r')
    if not f then return end
    local cutoff = os.time() - math.max(1, cfg.keepDays[0]) * 86400
    local loaded, skipped = 0, 0
    local first = true

    for line in f:lines() do
        if first then
            first = false
        elseif line ~= '' then
            local parts = {}
            for field in (line .. ';'):gmatch('([^;]*);') do parts[#parts + 1] = field end
            local ts = tonumber(parts[2])
            local srv = tonumber(parts[3])
            if ts and ts >= cutoff and srv then
                if trackedSet[srv] then
                    local side = parts[4]
                    local id = parts[5]
                    local ench = tonumber(parts[6]) or 0
                    local price = tonumber(parts[8])
                    local qty = tonumber(parts[9])
                    local sid = tonumber(parts[12]) or 0
                    local sidKey = srv .. ':' .. sid
                    if id and price and qty and (side == 'sell' or side == 'buy')
                        and not (sid > 0 and seenSid[sidKey]) then
                        local name = toDisplay(parts[7] or '')
                        if name == '' then name = itemNameById(id) end
                        if sid > 0 then seenSid[sidKey] = true end
                        indexTrade({
                            ts = ts, srv = srv, id = id, ench = ench, name = name,
                            side = side, price = price, qty = qty,
                            shop = parts[10], exact = (parts[11] == '1'), sid = sid
                        })
                        loaded = loaded + 1
                    end
                else
                    skipped = skipped + 1
                end
            end
        end
    end
    f:close()

    table.sort(trades, function(a, b) return a.ts < b.ts end)
    dataVersion = dataVersion + 1
    print(('[CC] загружено сделок: %d (пропущено по нецелевым серверам: %d)'):format(loaded, skipped))
end

--=========================================================
-- ДЕТЕКТ СДЕЛОК ПО СРЕЗАМ
--=========================================================
local nameById = {}

local function scanShopSide(shop, side, lots, items)
    local list, prices, counts
    if side == 'sell' then
        list, prices, counts = shop.items_sell, shop.price_sell, shop.count_sell
    else
        list, prices, counts = shop.items_buy, shop.price_buy, shop.count_buy
    end
    if type(list) ~= 'table' then return end

    for i = 1, #list do
        local id = extractItemId(list[i])
        if id then
            local price = tonumber(prices and prices[i]) or 0
            local count = tonumber(counts and counts[i]) or 0
            if price > 0 and count > 0 then
                local ench = extractEnch(list[i], shop, i, side) or 0
                local base = side .. '|' .. id .. '|' .. ench
                local lotKey = base .. '|' .. price
                lots[lotKey] = (lots[lotKey] or 0) + count
                items[base] = true
                if not nameById[id .. '#' .. ench] then
                    local n = itemNameById(id)
                    if ench > 0 then n = n .. ' (+' .. ench .. ')' end
                    nameById[id .. '#' .. ench] = n
                end
            end
        end
    end
end

local function detectTrades(srv, curLots, curItems)
    local st = srvState[srv]
    local found = {}
    if not st or not st.prevLots then return found end
    local now = os.time()

    for shopId, lots in pairs(st.prevLots) do
        local cur = curLots[shopId]
        -- лавка целиком пропала из выдачи: могла закрыться, а не распродаться
        if cur then
            local curItemSet = curItems[shopId] or {}
            for lotKey, prevCount in pairs(lots) do
                local curCount = cur[lotKey] or 0
                local sold, exact = 0, true
                if curCount > 0 then
                    if curCount < prevCount then sold = prevCount - curCount end
                else
                    local base = lotKey:match('^(.*)|%d+$')
                    if base and curItemSet[base] then
                        sold = 0   -- переставили цену, а не продали
                    else
                        sold = prevCount
                        exact = false
                    end
                end

                if sold > 0 then
                    local side, id, ench, price = lotKey:match('^(%a+)|(%d+)|(%d+)|(%d+)$')
                    if side then
                        ench = tonumber(ench)
                        found[#found + 1] = {
                            ts = now, srv = srv, id = id, ench = ench,
                            name = nameById[id .. '#' .. ench] or itemNameById(id),
                            side = side, price = tonumber(price), qty = sold,
                            shop = shopId, exact = exact, sid = 0
                        }
                    end
                end
            end
        end
    end
    return found
end

--=========================================================
-- ЗАПРОС К API
--=========================================================
local apiUrl = 'https://api.arz.market/api/getMarketplace/'
local scriptVersion = '3.55'
local updating = false
local totalSnapshots = 0

local function doRefresh(srv)
    local st = srvState[srv]
    if not st or updating then return end

    loadArzMarketAuth()
    refreshAuthFromRegistry()

    if myServerId == '' or myToken == '' then
        st.apiStatus = u8('нет авторизации')
        st.lastUpdate = os.clock()
        return
    end

    updating = true

    local url = apiUrl .. requestServerId(srv)
    local body = encodeJson({
        authClient = tostring(currentAuthClient()),
        authKey = tostring(myAuthKey),
        authToken = tostring(myToken),
        scriptVersion = tostring(scriptVersion),
        serverId = tostring(myServerId)
    })

    asyncHttp('GET', url, {
        headers = { ['content-type'] = 'application/json' },
        data = body
    }, function(response)
        updating = false
        st.lastUpdate = os.clock()

        if response.status_code ~= 200 and response.status_code ~= 304 then
            st.apiStatus = u8('код ') .. tostring(response.status_code)
            st.errStreak = st.errStreak + 1
            return
        end
        local ok, data = pcall(decodeJson, response.text)
        if not ok or type(data) ~= 'table' then
            st.apiStatus = u8('битый JSON')
            st.errStreak = st.errStreak + 1
            return
        end

        local list = (type(data.list) == 'table') and data.list or data
        local curLots, curItems = {}, {}
        local best = {}

        for i = 1, #list do
            local shop = list[i]
            if type(shop) == 'table' and serverMatches(shop.serverId, srv) then
                local shopId = tostring(shop.LavkaUid or i)
                curLots[shopId] = curLots[shopId] or {}
                curItems[shopId] = curItems[shopId] or {}
                scanShopSide(shop, 'sell', curLots[shopId], curItems[shopId])
                scanShopSide(shop, 'buy', curLots[shopId], curItems[shopId])
            end
        end

        for _, lots in pairs(curLots) do
            for lotKey in pairs(lots) do
                local side, id, ench, price = lotKey:match('^(%a+)|(%d+)|(%d+)|(%d+)$')
                if side then
                    price = tonumber(price)
                    local k = id .. '#' .. ench
                    local b = best[k]
                    if not b then b = {}; best[k] = b end
                    if side == 'sell' then
                        if not b.sellMin or price < b.sellMin then b.sellMin = price end
                    else
                        if not b.buyMax or price > b.buyMax then b.buyMax = price end
                    end
                end
            end
        end
        st.currentBest = best

        local found = detectTrades(srv, curLots, curItems)
        st.lastFound = #found
        if syncActive then
            for i = 1, #found do st.pushQueue[#st.pushQueue + 1] = found[i] end
        else
            for i = 1, #found do storeTrade(found[i], true) end
        end

        st.prevLots, st.prevItems = curLots, curItems
        st.snapshots = st.snapshots + 1
        st.lastOkTs = os.time()
        totalSnapshots = totalSnapshots + 1
        st.apiStatus = ''
        st.errStreak = 0
    end, function()
        updating = false
        st.lastUpdate = os.clock()
        st.apiStatus = u8('нет связи')
        st.errStreak = st.errStreak + 1
    end)
end

--=========================================================
-- ОБЩАЯ БАЗА
-- Один запрос на все серверы сразу: продление аренды,
-- отправка накопленного и получение нового за один заход.
--=========================================================
local tickBusy = false
local nextTickAt = 0
local lastTickOk = 0
local syncStatus = ''

local PUSH_EVERY   = 180   -- сборщик: отправка накопленного + продление аренды
local OPEN_EVERY   = 120   -- окно открыто: подтягиваем свежее
local IDLE_EVERY   = 300   -- окно закрыто и мы не сборщик: только проверка аренды

local function anyHolder()
    for _, n in ipairs(tracked) do
        if srvState[n].isHolder then return true end
    end
    return false
end

local function tickInterval()
    if anyHolder() then return PUSH_EVERY end
    if windowOpen[0] then return OPEN_EVERY end
    return IDLE_EVERY
end

local function doTick()
    if tickBusy or #tracked == 0 then return end
    tickBusy = true
    nextTickAt = os.clock() + tickInterval()

    -- читаем ленту, если окно открыто, либо если сами что-то отправляем:
    -- иначе курсор нельзя двигать, можно перескочить чужие записи
    local sending = {}
    local payload = { op = 'tick', client = clientId, servers = {} }
    if syncKey ~= '' then payload.key = syncKey end

    for _, n in ipairs(tracked) do
        local st = srvState[n]
        local batch = {}
        if st.isHolder then
            local cnt = math.min(#st.pushQueue, 200)
            for i = 1, cnt do batch[i] = st.pushQueue[i] end
        end
        sending[n] = #batch

        payload.servers[#payload.servers + 1] = {
            id = n,
            since = st.lastSid,
            renew = st.isHolder and true or false,
            pull = (windowOpen[0] or #batch > 0) and true or false,
            trades = batch
        }
    end

    asyncHttp('POST', syncUrl, {
        headers = { ['content-type'] = 'application/json' },
        data = encodeJson(payload)
    }, function(r)
        tickBusy = false
        if r.status_code ~= 200 then
            syncStatus = 'HTTP ' .. tostring(r.status_code)
            return
        end
        local ok, d = pcall(decodeJson, r.text)
        if not ok or type(d) ~= 'table' or not d.ok or type(d.servers) ~= 'table' then
            syncStatus = u8('плохой ответ базы')
            return
        end

        syncStatus = ''
        lastTickOk = os.time()

        for i = 1, #d.servers do
            local res = d.servers[i]
            local n = tonumber(res.id)
            local st = n and srvState[n]
            if st then
                local was = st.isHolder
                st.isHolder = res.isHolder and true or false
                st.leaseHolder = res.holder
                if was and not st.isHolder then
                    -- роль ушла: старый срез устарел, иначе на возврате
                    -- разница даст пачку ложных сделок
                    st.prevLots, st.prevItems = nil, nil
                    st.pushQueue = {}
                end

                -- сначала чужое из ленты
                if type(res.trades) == 'table' then
                    for j = 1, #res.trades do
                        local t = res.trades[j]
                        local sid = tonumber(t.sid) or 0
                        local price, qty = tonumber(t.price), tonumber(t.qty)
                        if sid > 0 and price and qty and t.id then
                            local ench = tonumber(t.ench) or 0
                            local name = toDisplay(t.name or '')
                            if name == '' then name = itemNameById(t.id) end
                            storeTrade({
                                ts = tonumber(t.ts) or os.time(), srv = n,
                                id = tostring(t.id), ench = ench, name = name,
                                side = (t.side == 'buy') and 'buy' or 'sell',
                                price = price, qty = qty,
                                shop = tostring(t.shop or ''),
                                exact = (tonumber(t.exact) == 1),
                                sid = sid
                            }, true)
                        end
                    end
                end

                -- затем своё, уже с присвоенными базой номерами
                local added = tonumber(res.added) or 0
                local firstId = tonumber(res.firstPushedId) or 0
                if added > 0 and firstId > 0 then
                    for j = 1, added do
                        local t = st.pushQueue[j]
                        if t then
                            t.sid = firstId + j - 1
                            storeTrade(t, true)
                        end
                    end
                    for _ = 1, math.min(added, #st.pushQueue) do
                        table.remove(st.pushQueue, 1)
                    end
                elseif sending[n] and sending[n] > 0 then
                    -- база не приняла: скорее всего аренду перехватили
                    st.pushQueue = {}
                end

                local newLast = tonumber(res.lastId)
                if newLast and newLast > st.lastSid then
                    st.lastSid = newLast
                    markDirty()
                end
                if res.more then nextTickAt = 0 end
            end
        end
    end, function()
        tickBusy = false
        syncStatus = u8('нет связи')
    end)
end

--=========================================================
-- ПЕРЕХВАТ ТОКЕНА
--=========================================================
addEventHandler('onReceivePacket', function(packetId, bs)
    if packetId ~= 220 then return true end
    local saved = raknetBitStreamGetReadOffset(bs)
    raknetBitStreamIgnoreBits(bs, 8)
    if raknetBitStreamReadInt8(bs) == 17 then
        raknetBitStreamIgnoreBits(bs, 32)
        local len = raknetBitStreamReadInt16(bs)
        local extra = raknetBitStreamReadInt8(bs)
        local text
        if extra ~= 0 then
            text = raknetBitStreamDecodeString(bs, len + extra)
        else
            text = raknetBitStreamReadString(bs, len)
        end
        if text and text:find('event.api.setToken') then
            local token = text:match('"token":"(.-)"')
            local sid = text:match('"server":(%d+)')
            if token and sid then
                myToken = tostring(token)
                myServerId = tostring(sid)
                local n = tonumber(sid) or 0
                if n > 0 and n ~= homeServer then
                    homeServer = n
                    if not trackedSet[n] then
                        addServer(n)
                        markDirty()
                    end
                end
                authData.auth.token = myToken
                authData.auth.serverId = myServerId
                authData.auth.authKey = myAuthKey
                authData.auth.authClient = myAuthClient
                pcall(inicfg.save, authData, authFile)
            end
        end
    end
    raknetBitStreamSetReadOffset(bs, saved)
    return true
end)

--=========================================================
-- СТАТИСТИКА
--=========================================================
local function periodCutoff()
    if periodFilter == 1 then return os.time() - 86400 end
    if periodFilter == 2 then return os.time() - 7 * 86400 end
    return 0
end

local function computeStats(k)
    local list = byKey[k]
    if not list or #list == 0 then return nil end
    local cutoff = periodCutoff()

    local prices, qty, count = {}, 0, 0
    local minP, maxP, last, lastTs
    for i = 1, #list do
        local t = list[i]
        if t.ts >= cutoff then
            count = count + 1
            qty = qty + t.qty
            prices[#prices + 1] = t.price
            if not minP or t.price < minP then minP = t.price end
            if not maxP or t.price > maxP then maxP = t.price end
            if not lastTs or t.ts >= lastTs then lastTs = t.ts; last = t.price end
        end
    end
    if count == 0 then return nil end

    table.sort(prices)
    local mid = math.floor(#prices / 2)
    local median
    if #prices % 2 == 1 then
        median = prices[mid + 1]
    else
        median = math.floor((prices[mid] + prices[mid + 1]) / 2)
    end

    local first = list[1]
    return {
        key = k, srv = first.srv, id = first.id, ench = first.ench, name = first.name,
        nameLower = lower(first.name), side = first.side,
        count = count, qty = qty, min = minP, max = maxP,
        median = median, last = last, lastTs = lastTs
    }
end

local rowsCache = {}
local rowsVersion = -1
local rowsQuery, rowsSide, rowsPeriod, rowsSort, rowsMin, rowsSrv = nil, -1, -1, -1, -1, -2
local searchBuf = new.char[128]()

local sortNames = {
    [0] = u8('по времени'),
    [1] = u8('по числу сделок'),
    [2] = u8('по названию'),
    [3] = u8('по цене'),
    [4] = u8('по объёму')
}

local function rebuildRows()
    local query = lower(ffi.string(searchBuf))
    if query == '' then query = nil end
    if rowsVersion == dataVersion and rowsQuery == query and rowsSide == sideFilter
        and rowsPeriod == periodFilter and rowsSort == sortMode
        and rowsMin == cfg.minTrades[0] and rowsSrv == serverFilter then
        return
    end

    local out = {}
    for k in pairs(byKey) do
        local stats = statsCache[k]
        if stats == nil then
            stats = computeStats(k) or false
            statsCache[k] = stats
        end
        if stats then
            local ok = true
            if serverFilter ~= 0 and stats.srv ~= serverFilter then ok = false end
            if ok and sideFilter == 1 and stats.side ~= 'sell' then ok = false end
            if ok and sideFilter == 2 and stats.side ~= 'buy' then ok = false end
            if ok and query and not stats.nameLower:find(query, 1, true) then ok = false end
            if ok and cfg.minTrades[0] > 0 and stats.count < cfg.minTrades[0] then ok = false end
            if ok then out[#out + 1] = stats end
        end
    end

    local cmp
    if sortMode == 1 then
        cmp = function(a, b) return a.count > b.count end
    elseif sortMode == 2 then
        cmp = function(a, b) return a.nameLower < b.nameLower end
    elseif sortMode == 3 then
        cmp = function(a, b) return a.median > b.median end
    elseif sortMode == 4 then
        cmp = function(a, b) return a.qty > b.qty end
    else
        cmp = function(a, b) return a.lastTs > b.lastTs end
    end
    table.sort(out, cmp)

    rowsCache = out
    rowsVersion = dataVersion
    rowsQuery, rowsSide, rowsPeriod = query, sideFilter, periodFilter
    rowsSort, rowsMin, rowsSrv = sortMode, cfg.minTrades[0], serverFilter
end

-- resale table: for every item, find where it is cheapest to buy
-- (min sell-median in base currency) and where it sells highest
-- (max buy-median in base currency) on a DIFFERENT server.
local resaleCache = {}
local resaleVersion = -1
local resaleWarn = false
local resaleQuery, resalePeriod, resaleSort, resaleMin = nil, -1, -1, -1

local function rebuildResaleRows()
    local query = lower(ffi.string(searchBuf))
    if query == '' then query = nil end
    if resaleVersion == dataVersion and resaleQuery == query
        and resalePeriod == periodFilter and resaleSort == sortMode
        and resaleMin == cfg.minTrades[0] then
        return
    end

    -- group per item (id#ench) with each server's sell/buy stats
    local groups = {}
    for k in pairs(byKey) do
        local srv, id, ench, side = k:match('^(%d+)#(%d+)#(%d+)#(%a+)$')
        if srv then
            local stats = statsCache[k]
            if stats == nil then
                stats = computeStats(k) or false
                statsCache[k] = stats
            end
            if stats then
                local gk = id .. '#' .. ench
                local g = groups[gk]
                if not g then g = { id = id, ench = tonumber(ench) or 0, name = stats.name, srv = {} }; groups[gk] = g end
                if stats.name and stats.name ~= '' then g.name = stats.name end
                local sn = tonumber(srv)
                local perc = g.srv[sn]
                if not perc then perc = {}; g.srv[sn] = perc end
                perc[side] = stats
            end
        end
    end

    local minT = cfg.minTrades[0]
    local warn = false
    local out = {}
    for _, g in pairs(groups) do
        if not query or lower(g.name):find(query, 1, true) then
            local srcSrv, srcStats, srcBase
            local dstSrv, dstStats, dstBase
            for sn, sides in pairs(g.srv) do
                local sell = sides.sell
                if sell and (minT <= 0 or sell.count >= minT) then
                    local base, ok = toBase(sell.median, sn)
                    if not ok then warn = true end
                    if ok and (not srcBase or base < srcBase) then
                        srcBase, srcSrv, srcStats = base, sn, sell
                    end
                end
                local buy = sides.buy
                if buy and (minT <= 0 or buy.count >= minT) then
                    local base, ok = toBase(buy.median, sn)
                    if not ok then warn = true end
                    if ok and (not dstBase or base > dstBase) then
                        dstBase, dstSrv, dstStats = base, sn, buy
                    end
                end
            end
            if srcSrv and dstSrv and srcSrv ~= dstSrv then
                local margin = dstBase - srcBase
                if margin > 0 then
                    out[#out + 1] = {
                        key = g.id .. '#' .. g.ench, id = g.id, ench = g.ench, name = g.name,
                        srcSrv = srcSrv, srcPrice = srcStats.median, srcCur = currencyOf(srcSrv),
                        dstSrv = dstSrv, dstPrice = dstStats.median, dstCur = currencyOf(dstSrv),
                        marginBase = margin,
                        marginPct = (srcBase > 0) and (margin / srcBase * 100) or 0,
                        count = math.min(srcStats.count, dstStats.count),
                        srcKey = keyOf(srcSrv, g.id, g.ench, 'sell'),
                        dstKey = keyOf(dstSrv, g.id, g.ench, 'buy')
                    }
                end
            end
        end
    end

    local cmp
    if sortMode == 2 then
        cmp = function(a, b) return lower(a.name) < lower(b.name) end
    elseif sortMode == 1 then
        cmp = function(a, b) return a.count > b.count end
    else
        cmp = function(a, b) return a.marginBase > b.marginBase end
    end
    table.sort(out, cmp)

    resaleCache = out
    resaleWarn = warn
    resaleVersion = dataVersion
    resaleQuery, resalePeriod = query, periodFilter
    resaleSort, resaleMin = sortMode, cfg.minTrades[0]
end

local function invalidateStats()
    for k in pairs(statsCache) do statsCache[k] = nil end
    dataVersion = dataVersion + 1
end

--=========================================================
-- КУРСОР
--=========================================================
local CURSOR_MODE = 2
local cursorActive = false
local cursorMode = nil
local cursorNextRefresh = 0

local function setCursorMode(mode, force)
    local now = os.clock()
    if not force and cursorMode == mode and now < cursorNextRefresh then return end
    if pcall(sampSetCursorMode, mode) then
        cursorMode = mode
        cursorNextRefresh = now + ((mode ~= 0) and 0.25 or 1.00)
    end
end

local function syncCursor()
    if windowOpen[0] then
        setCursorMode(CURSOR_MODE)
        cursorActive = true
    elseif cursorActive then
        setCursorMode(0, true)
        pcall(sampToggleCursor, false)
        cursorActive = false
    end
end

local function openWindow()
    windowOpen[0] = true
    setCursorMode(CURSOR_MODE, true)
    cursorActive = true
    nextTickAt = 0   -- догоняем пропущенное сразу при открытии
end

local function closeWindow()
    windowOpen[0] = false
    syncCursor()
end

addEventHandler('onScriptTerminate', function(scr)
    if scr == thisScript() then
        if cursorActive then
            pcall(sampSetCursorMode, 0)
            pcall(sampToggleCursor, false)
        end
        if csvHandle then pcall(function() csvHandle:close() end) end
    end
end)

--=========================================================
-- ИНТЕРФЕЙС
--=========================================================
imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    local s = imgui.GetStyle()
    local c = s.Colors
    local C = imgui.Col
    s.WindowPadding = imgui.ImVec2(10, 10)
    s.FramePadding = imgui.ImVec2(5, 3)
    s.ItemSpacing = imgui.ImVec2(8, 4)
    s.WindowRounding = 4
    s.ChildRounding = 4
    s.FrameRounding = 3
    s.ScrollbarRounding = 9
    c[C.Text] = imgui.ImVec4(0.90, 0.90, 0.95, 1.00)
    c[C.TextDisabled] = imgui.ImVec4(0.50, 0.50, 0.55, 1.00)
    c[C.WindowBg] = imgui.ImVec4(0.13, 0.14, 0.17, 0.96)
    c[C.ChildBg] = imgui.ImVec4(0.10, 0.11, 0.14, 0.60)
    c[C.FrameBg] = imgui.ImVec4(0.18, 0.19, 0.23, 1.00)
    c[C.Button] = imgui.ImVec4(0.20, 0.28, 0.40, 1.00)
    c[C.ButtonHovered] = imgui.ImVec4(0.26, 0.36, 0.52, 1.00)
    c[C.ButtonActive] = imgui.ImVec4(0.16, 0.24, 0.36, 1.00)
    c[C.Header] = imgui.ImVec4(0.22, 0.30, 0.44, 0.80)
    c[C.HeaderHovered] = imgui.ImVec4(0.26, 0.36, 0.52, 0.80)
end)

local COL_NAME, COL_SRV, COL_WHERE, COL_LAST, COL_MIN, COL_MED, COL_MAX, COL_CNT, COL_QTY, COL_WHEN =
      10, 275, 375, 440, 540, 625, 710, 800, 855, 915
local NAME_WIDTH = 250

local WHITE  = imgui.ImVec4(0.90, 0.90, 0.95, 1.00)
local GREEN  = imgui.ImVec4(0.40, 0.85, 0.50, 1.00)
local ORANGE = imgui.ImVec4(0.95, 0.70, 0.35, 1.00)
local GREY   = imgui.ImVec4(0.55, 0.55, 0.60, 1.00)
local CYAN   = imgui.ImVec4(0.45, 0.75, 0.95, 1.00)

local fitCache = {}
local function fitText(text, width, cacheKey)
    local cached = fitCache[cacheKey]
    if cached then return cached end
    local result = text
    if imgui.CalcTextSize(text).x > width then
        local s = text
        while #s > 1 do
            local i = #s
            while i > 1 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i - 1 end
            s = s:sub(1, i - 1)
            if imgui.CalcTextSize(s .. '...').x <= width then
                result = s .. '...'
                break
            end
        end
    end
    fitCache[cacheKey] = result
    return result
end

local function headerCell(x, label, mode)
    imgui.SetCursorPosX(x)
    local active = (sortMode == mode)
    if active then imgui.PushStyleColor(imgui.Col.Text, CYAN) end
    imgui.Text(u8(label) .. (active and ' <' or ''))
    if active then imgui.PopStyleColor() end
    if imgui.IsItemHovered() and imgui.IsMouseClicked(0) then
        sortMode = mode
        rowsVersion = -1
        markDirty()
    end
end

local function colored(color, text)
    imgui.PushStyleColor(imgui.Col.Text, color)
    imgui.Text(text)
    imgui.PopStyleColor()
end

local selectedKey = nil

local function detailPanel(stats)
    local cur = currencyOf(stats.srv)
    local rate = rateOf(stats.srv)

    imgui.TextWrapped(stats.name)
    colored(GREY, serverName(stats.srv) .. u8('   валюта ') .. cur .. u8('   ID ') .. stats.id)
    colored(GREY, u8('сделок: ') .. stats.count .. u8('   штук: ') .. formatMoney(stats.qty))

    imgui.Separator()
    imgui.Text(u8('медиана: ') .. formatMoney(stats.median) .. ' ' .. cur)
    colored(GREY, u8('мин ') .. formatMoney(stats.min) .. u8('   макс ') .. formatMoney(stats.max))
    if rate and cur ~= currencyDefault then
        colored(CYAN, u8('~ ') .. formatMoney(stats.median * rate) .. ' ' .. currencyDefault
            .. u8('  (курс из конфига)'))
    end

    local st = srvState[stats.srv]
    local best = st and st.currentBest[stats.id .. '#' .. stats.ench]
    if best then
        imgui.Separator()
        colored(GREY, u8('сейчас на рынке'))
        if best.buyMax then imgui.Text(u8('скуп до:  ') .. formatMoney(best.buyMax) .. ' ' .. cur) end
        if best.sellMin then imgui.Text(u8('лавки от: ') .. formatMoney(best.sellMin) .. ' ' .. cur) end
    end

    imgui.Separator()
    colored(GREY, u8('последние сделки'))

    local list = byKey[stats.key]
    local cutoff = periodCutoff()
    local shown = 0
    for i = #list, 1, -1 do
        local t = list[i]
        if t.ts >= cutoff then
            shown = shown + 1
            if shown > 25 then break end
            imgui.Text(os.date('%d.%m %H:%M', t.ts))
            imgui.SameLine(85)
            imgui.PushStyleColor(imgui.Col.Text, t.exact and WHITE or ORANGE)
            imgui.Text(formatMoney(t.price))
            imgui.PopStyleColor()
            imgui.SameLine(200)
            colored(GREY, 'x' .. t.qty .. (t.exact and '' or ' ~'))
        end
    end
    if shown == 0 then
        colored(GREY, u8('нет сделок за период'))
    else
        imgui.Separator()
        colored(GREY, u8('~ = лот исчез целиком,'))
        colored(GREY, u8('мог быть снят, а не продан'))
    end
end

-- resale table column X positions
local RC_NAME, RC_BUY, RC_BUYP, RC_SELL, RC_SELLP, RC_MARGIN, RC_PCT, RC_CNT =
      10, 250, 350, 470, 570, 700, 810, 875

local function resaleLadder(key)
    local list = byKey[key]
    if not list then colored(GREY, '-'); return end
    local cutoff = periodCutoff()
    local shown = 0
    for i = #list, 1, -1 do
        local t = list[i]
        if t.ts >= cutoff then
            shown = shown + 1
            if shown > 12 then break end
            imgui.Text(os.date('%d.%m %H:%M', t.ts))
            imgui.SameLine(85)
            imgui.PushStyleColor(imgui.Col.Text, t.exact and WHITE or ORANGE)
            imgui.Text(formatMoney(t.price))
            imgui.PopStyleColor()
            imgui.SameLine(190)
            colored(GREY, 'x' .. t.qty)
        end
    end
    if shown == 0 then colored(GREY, '-') end
end

local function resaleDetailPanel(row)
    imgui.TextWrapped(row.name)
    colored(GREY, 'ID ' .. row.id)
    imgui.Separator()

    imgui.Text(u8('\xCA\xF3\xEF\xE8\xF2\xFC\x20\xED\xE0\x20') .. serverName(row.srcSrv))
    colored(WHITE, formatMoney(row.srcPrice) .. ' ' .. row.srcCur)
    imgui.Text(u8('\xCF\xF0\xEE\xE4\xE0\xF2\xFC\x20\xED\xE0\x20') .. serverName(row.dstSrv))
    colored(WHITE, formatMoney(row.dstPrice) .. ' ' .. row.dstCur)

    imgui.Separator()
    imgui.Text(u8('\xCC\xE0\xF0\xE6\xE0\x3A\x20') .. formatMoney(math.floor(row.marginBase)) .. ' ' .. currencyDefault)
    colored(GREEN, u8('\xCD\xE0\xE2\xE0\xF0\x20') .. string.format('%.0f%%', row.marginPct))

    imgui.Separator()
    colored(GREY, u8('\xD6\xE5\xED\xFB\x20\xEF\xEE\xEA\xF3\xEF\xEA\xE8\x20\x28\xE8\xF1\xF2\xEE\xF7\xED\xE8\xEA\x29'))
    resaleLadder(row.srcKey)
    imgui.Separator()
    colored(GREY, u8('\xD6\xE5\xED\xFB\x20\xEF\xF0\xEE\xE4\xE0\xE6\xE8\x20\x28\xEF\xF0\xE8\xB8\xEC\xED\xE8\xEA\x29'))
    resaleLadder(row.dstKey)
end

local function renderResaleTable(tableW, tableH)
    imgui.BeginChild('##table', imgui.ImVec2(tableW, tableH), true)

    headerCell(RC_NAME, '\xCF\xF0\xE5\xE4\xEC\xE5\xF2', 2)
    imgui.SameLine(); imgui.SetCursorPosX(RC_BUY);    colored(GREY, u8('\xCA\xF3\xEF\xE8\xF2\xFC'))
    imgui.SameLine(); imgui.SetCursorPosX(RC_SELL);   colored(GREY, u8('\xCF\xF0\xEE\xE4\xE0\xF2\xFC'))
    imgui.SameLine(); headerCell(RC_MARGIN, '\xCC\xE0\xF0\xE6\xE0\x20' .. currencyDefault, 3)
    imgui.SameLine(); imgui.SetCursorPosX(RC_PCT);    colored(GREY, '%')
    imgui.SameLine(); headerCell(RC_CNT, '\xD1\xE4\xE5\xEB\xEE\xEA', 1)
    imgui.Separator()

    for i = 1, #resaleCache do
        local row = resaleCache[i]
        local y = imgui.GetCursorPosY()

        if imgui.Selectable('##rr' .. row.key, selectedKey == row.key) then
            selectedKey = row.key
        end
        imgui.SetCursorPosY(y)

        imgui.SetCursorPosX(RC_NAME)
        imgui.Text(fitText(row.name, RC_BUY - RC_NAME - 15, 'rn' .. row.name))
        if imgui.IsItemHovered() then
            imgui.BeginTooltip(); imgui.Text(row.name); imgui.EndTooltip()
        end

        imgui.SetCursorPosY(y); imgui.SetCursorPosX(RC_BUY)
        colored(GREY, fitText(serverName(row.srcSrv), 95, 'rb' .. row.srcSrv))
        imgui.SetCursorPosY(y); imgui.SetCursorPosX(RC_BUYP)
        colored(WHITE, formatMoney(row.srcPrice) .. ' ' .. row.srcCur)

        imgui.SetCursorPosY(y); imgui.SetCursorPosX(RC_SELL)
        colored(GREY, fitText(serverName(row.dstSrv), 95, 'rs' .. row.dstSrv))
        imgui.SetCursorPosY(y); imgui.SetCursorPosX(RC_SELLP)
        colored(WHITE, formatMoney(row.dstPrice) .. ' ' .. row.dstCur)

        imgui.SetCursorPosY(y); imgui.SetCursorPosX(RC_MARGIN)
        colored(GREEN, formatMoney(math.floor(row.marginBase)))

        imgui.SetCursorPosY(y); imgui.SetCursorPosX(RC_PCT)
        colored(CYAN, string.format('%.0f%%', row.marginPct))

        imgui.SetCursorPosY(y); imgui.SetCursorPosX(RC_CNT)
        colored(GREY, tostring(row.count))
    end

    if #resaleCache == 0 then
        colored(GREY, u8('\xCD\xE5\xF2\x20\xE2\xFB\xE3\xEE\xE4\xED\xFB\xF5\x20\xEF\xE5\xF0\xE5\xEF\xF0\xEE\xE4\xE0\xE6\x2E'))
        colored(GREY, u8('\xCD\xF3\xE6\xED\xEE\x20\xE1\xEE\xEB\xFC\xF8\xE5\x20\xF1\xE4\xE5\xEB\xEE\xEA\x20\xEF\xEE\x20\xEE\xE1\xEE\xE8\xEC\x20\xF1\xE5\xF0\xE2\xE5\xF0\xE0\xEC\x2C'))
        colored(GREY, u8('\xE8\xEB\xE8\x20\xED\xE5\x20\xE7\xE0\xE4\xE0\xED\x20\xEA\xF3\xF0\xF1\x20\x56\x43\x24\x20\x28\x72\x61\x74\x65\x73\x3D\x32\x30\x31\x29\x2E'))
    end
    imgui.EndChild()
end

imgui.OnFrame(
    function() return windowOpen[0] end,
    function(this)
        this.HideCursor = true
        imgui.GetIO().MouseDrawCursor = true
        syncCursor()

        local resX, resY = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(cfg.posX[0] * resX, cfg.posY[0] * resY), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(cfg.sizeX[0], cfg.sizeY[0]), imgui.Cond.FirstUseEver)
        imgui.Begin(u8('CC — история сделок'), windowOpen)

        local sz = imgui.GetWindowSize()
        if math.abs(sz.x - cfg.sizeX[0]) > 0.5 or math.abs(sz.y - cfg.sizeY[0]) > 0.5 then
            cfg.sizeX[0], cfg.sizeY[0] = sz.x, sz.y
            markDirty()
        end
        local wp = imgui.GetWindowPos()
        cfg.posX[0] = (wp.x + sz.x * 0.5) / resX
        cfg.posY[0] = (wp.y + sz.y * 0.5) / resY

        -- ряд 1: поиск, стороны, период, фильтр
        imgui.PushItemWidth(220)
        imgui.InputText('##search', searchBuf, ffi.sizeof(searchBuf))
        imgui.PopItemWidth()
        if imgui.IsItemHovered() then imgui.SetMouseCursor(imgui.MouseCursor.TextInput) end
        imgui.SameLine()
        colored(GREY, u8('поиск'))

        imgui.SameLine(0, 18)
        local sideLabels = { [0] = 'Все', [1] = 'Лавки', [2] = 'Скуп' }
        for i = 0, 2 do
            if i > 0 then imgui.SameLine(0, 4) end
            local active = (sideFilter == i)
            if active then imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.30, 0.45, 0.65, 1.00)) end
            if imgui.Button(u8(sideLabels[i]) .. '##side' .. i, imgui.ImVec2(58, 0)) then
                sideFilter = i; rowsVersion = -1; markDirty()
            end
            if active then imgui.PopStyleColor() end
        end

        imgui.SameLine(0, 18)
        local periodLabels = { [0] = 'Всё', [1] = '24ч', [2] = '7д' }
        for i = 0, 2 do
            if i > 0 then imgui.SameLine(0, 4) end
            local active = (periodFilter == i)
            if active then imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.30, 0.45, 0.65, 1.00)) end
            if imgui.Button(u8(periodLabels[i]) .. '##per' .. i, imgui.ImVec2(48, 0)) then
                periodFilter = i; invalidateStats(); rowsVersion = -1; markDirty()
            end
            if active then imgui.PopStyleColor() end
        end

        imgui.SameLine(0, 18)
        imgui.PushItemWidth(75)
        if imgui.InputInt('##mint', cfg.minTrades) then
            if cfg.minTrades[0] < 0 then cfg.minTrades[0] = 0 end
            rowsVersion = -1; markDirty()
        end
        imgui.PopItemWidth()
        imgui.SameLine()
        colored(GREY, u8('мин. сделок'))

        -- ряд 2: выбор сервера
        colored(GREY, u8('сервер:'))
        imgui.SameLine(0, 8)
        do
            local active = (serverFilter == 0)
            if active then imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.30, 0.45, 0.65, 1.00)) end
            if imgui.Button(u8('Все') .. '##srvall', imgui.ImVec2(50, 0)) then
                serverFilter = 0; rowsVersion = -1; markDirty()
            end
            if active then imgui.PopStyleColor() end
        end
        for _, n in ipairs(tracked) do
            imgui.SameLine(0, 4)
            local active = (serverFilter == n)
            if active then imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.30, 0.45, 0.65, 1.00)) end
            if imgui.Button(serverName(n) .. '##srv' .. n) then
                serverFilter = n; rowsVersion = -1; markDirty()
            end
            if active then imgui.PopStyleColor() end

            if imgui.IsItemHovered() then
                local st = srvState[n]
                imgui.BeginTooltip()
                imgui.Text(serverName(n) .. u8('  (номер ') .. n .. ')')
                imgui.Text(u8('валюта: ') .. currencyOf(n))
                imgui.Text(u8('срезов: ') .. st.snapshots)
                if st.lastOkTs then
                    imgui.Text(u8('последний срез: ') .. agoText(st.lastOkTs))
                else
                    imgui.Text(u8('срезов пока не было'))
                end
                if st.apiStatus ~= '' then
                    imgui.Text(u8('рынок: ') .. st.apiStatus)
                end
                if syncActive then
                    if st.isHolder then
                        imgui.Text(u8('база: собираю я'))
                    else
                        imgui.Text(u8('база: собирает ') .. tostring(st.leaseHolder or '?'))
                    end
                end
                imgui.EndTooltip()
            end
        end

        imgui.SameLine(0, 18)
        if imgui.Button(u8('Обновить все')) then
            for _, n in ipairs(tracked) do srvState[n].lastUpdate = 0 end
        end

        imgui.SameLine(0, 18)
        do
            local active = resaleMode
            if active then imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.30, 0.45, 0.65, 1.00)) end
            if imgui.Button(u8('\xCF\xE5\xF0\xE5\xEF\xF0\xEE\xE4\xE0\xE6\xE8') .. '##resale') then
                resaleMode = not resaleMode; rowsVersion = -1; resaleVersion = -1; markDirty()
            end
            if active then imgui.PopStyleColor() end
            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.Text(u8('\xD2\xE0\xE1\xEB\xE8\xF6\xE0\x20\xEF\xE5\xF0\xE5\xEF\xF0\xEE\xE4\xE0\xE6\x20\xEC\xE5\xE6\xE4\xF3\x20\xF1\xE5\xF0\xE2\xE5\xF0\xE0\xEC\xE8'))
                imgui.EndTooltip()
            end
        end

        -- статус
        if resaleMode then rebuildResaleRows() else rebuildRows() end
        local status = ('позиций: %d  |  сделок: %d  |  срезов: %d  |  сортировка: ')
            :format(resaleMode and #resaleCache or #rowsCache, #trades, totalSnapshots)
        colored(GREY, u8(status) .. (sortNames[sortMode] or ''))
        imgui.SameLine()
        if updating then
            colored(CYAN, u8('обновление...'))
        elseif not syncActive then
            colored(GREY, u8('общая база: выкл'))
        elseif syncStatus ~= '' then
            colored(ORANGE, u8('общая база: ') .. syncStatus)
        else
            local mine = 0
            for _, n in ipairs(tracked) do
                if srvState[n].isHolder then mine = mine + 1 end
            end
            colored(mine > 0 and GREEN or CYAN,
                u8('общая база: собираю ') .. mine .. u8(' из ') .. #tracked)
        end

        -- дыра в сборе видна сразу: восстановить пропущенное неоткуда
        do
            local stale = nil
            for _, n in ipairs(tracked) do
                local st = srvState[n]
                local age = st.lastOkTs and (os.time() - st.lastOkTs) or nil
                if age and age > 600 and (not stale or age > stale.age) then
                    stale = { name = serverName(n), age = age }
                end
            end
            if stale then
                imgui.SameLine(0, 15)
                colored(ORANGE, u8('! ') .. stale.name .. u8(': нет срезов ') .. agoText(os.time() - stale.age))
            end
        end

        imgui.Separator()

        -- цены в разных валютах в одном списке напрямую не сравниваются
        if resaleMode and resaleWarn then
            colored(ORANGE, u8('\xCD\xE5\xF2\x20\xEA\xF3\xF0\xF1\xE0\x20\x56\x43\x24\x3A\x20\xE2\xEF\xE8\xF8\xE8\x20\x5B\x63\x75\x72\x72\x65\x6E\x63\x79\x5D\x20\x72\x61\x74\x65\x73\x3D\x32\x30\x31\x3A\xEA\xF3\xF0\xF1\x20\x97\x20\xE8\xED\xE0\xF7\xE5\x20\xEF\xE5\xF0\xE5\xEF\xF0\xEE\xE4\xE0\xE6\xE8\x20\xF1\x20\x56\x69\x63\x65\x20\x43\x69\x74\x79\x20\xED\xE5\x20\xE2\x20\xF1\xF7\xB8\xF2'))
        end
        if (not resaleMode) and serverFilter == 0 then
            local seen, mixed = nil, false
            for _, n in ipairs(tracked) do
                local c = currencyOf(n)
                if seen == nil then seen = c elseif c ~= seen then mixed = true end
            end
            if mixed then
                if sortMode == 3 then
                    colored(ORANGE, u8('Внимание: в списке разные валюты, а сортировка идёт по цене — ')
                        .. u8('числа сравниваются напрямую. Выбери конкретный сервер.'))
                else
                    colored(GREY, u8('В списке серверы с разной валютой, цены между ними не сопоставимы.'))
                end
            end
        end

        local style = imgui.GetStyle()
        local innerW = sz.x - style.WindowPadding.x * 2
        local detailW = 300
        local tableW = innerW - detailW - style.ItemSpacing.x
        local showDetail = true
        if tableW < 420 then
            tableW = innerW
            showDetail = false
        end
        local tableH = sz.y - imgui.GetCursorPosY() - style.WindowPadding.y - 4

        if resaleMode then
            renderResaleTable(tableW, tableH)
        else
        imgui.BeginChild('##table', imgui.ImVec2(tableW, tableH), true)
        COL_NAME = style.WindowPadding.x
        NAME_WIDTH = COL_SRV - COL_NAME - 15

        headerCell(COL_NAME, 'Предмет', 2)
        imgui.SameLine(); headerCell(COL_SRV, 'Сервер', 2)
        imgui.SameLine(); headerCell(COL_WHERE, 'Где', 2)
        imgui.SameLine(); headerCell(COL_LAST, 'Последняя', 0)
        imgui.SameLine(); headerCell(COL_MIN, 'Мин', 3)
        imgui.SameLine(); headerCell(COL_MED, 'Медиана', 3)
        imgui.SameLine(); headerCell(COL_MAX, 'Макс', 3)
        imgui.SameLine(); headerCell(COL_CNT, 'Сделок', 1)
        imgui.SameLine(); headerCell(COL_QTY, 'Штук', 4)
        imgui.SameLine(); headerCell(COL_WHEN, 'Когда', 0)
        imgui.Separator()

        for i = 1, #rowsCache do
            local row = rowsCache[i]
            local y = imgui.GetCursorPosY()

            if imgui.Selectable('##r' .. row.key, selectedKey == row.key) then
                selectedKey = row.key
            end
            imgui.SetCursorPosY(y)

            imgui.SetCursorPosX(COL_NAME)
            imgui.Text(fitText(row.name, NAME_WIDTH, 'n' .. row.name))
            if imgui.IsItemHovered() then
                imgui.BeginTooltip(); imgui.Text(row.name); imgui.EndTooltip()
            end

            imgui.SetCursorPosY(y); imgui.SetCursorPosX(COL_SRV)
            colored(GREY, fitText(serverName(row.srv), 90, 's' .. row.srv))

            imgui.SetCursorPosY(y); imgui.SetCursorPosX(COL_WHERE)
            colored(GREY, row.side == 'sell' and u8('лавка') or u8('скуп'))

            imgui.SetCursorPosY(y); imgui.SetCursorPosX(COL_LAST)
            colored(WHITE, formatMoney(row.last))

            imgui.SetCursorPosY(y); imgui.SetCursorPosX(COL_MIN)
            colored(GREEN, formatMoney(row.min))

            imgui.SetCursorPosY(y); imgui.SetCursorPosX(COL_MED)
            colored(CYAN, formatMoney(row.median))

            imgui.SetCursorPosY(y); imgui.SetCursorPosX(COL_MAX)
            colored(ORANGE, formatMoney(row.max))

            imgui.SetCursorPosY(y); imgui.SetCursorPosX(COL_CNT)
            colored(WHITE, tostring(row.count))

            imgui.SetCursorPosY(y); imgui.SetCursorPosX(COL_QTY)
            colored(GREY, formatMoney(row.qty))

            imgui.SetCursorPosY(y); imgui.SetCursorPosX(COL_WHEN)
            colored(GREY, agoText(row.lastTs))
        end

        if #rowsCache == 0 then
            colored(GREY, u8('Сделок пока нет.'))
            colored(GREY, u8('Первая появится после второго среза рынка,'))
            colored(GREY, u8('дальше история будет копиться сама.'))
        end
        imgui.EndChild()
        end

        if showDetail then
            imgui.SameLine()
            imgui.BeginChild('##detail', imgui.ImVec2(detailW, tableH), true)
            local rows = resaleMode and resaleCache or rowsCache
            local sel = nil
            if selectedKey then
                for i = 1, #rows do
                    if rows[i].key == selectedKey then sel = rows[i]; break end
                end
            end
            if sel then
                if resaleMode then resaleDetailPanel(sel) else detailPanel(sel) end
            else
                colored(GREY, u8('Кликни по строке,'))
                colored(GREY, u8('чтобы увидеть все'))
                colored(GREY, u8('сделки по предмету.'))
            end
            imgui.EndChild()
        end

        imgui.End()
    end
)

--=========================================================
-- MAIN
--=========================================================
function main()
    while not isSampAvailable() do wait(0) end
    checkUpdate()

    loadItemsIndex()

    asyncHttp('GET', 'https://arizona-ping.react.group/desktop/ping/Arizona/ping.json', {}, function(r)
        local ok, data = pcall(decodeJson, r.text)
        if ok and type(data) == 'table' then
            arizonaServers = data.servers or data
        else
            arizonaServers = {}
        end
        buildServerNames()
    end, function() arizonaServers = {} end)

    sampRegisterChatCommand('cc', function()
        if windowOpen[0] then closeWindow() else openWindow() end
    end)

    sampRegisterChatCommand('ccreload', function()
        loadItemsIndex()
        sampAddChatMessage('[CC] справочник предметов перезагружен', 0x66CCFF)
    end)

    sampRegisterChatCommand('ccpath', function()
        sampAddChatMessage('[CC] история: ' .. csvPath, 0x66CCFF)
    end)

    sampRegisterChatCommand('ccadd', function(arg)
        local n = tonumber(arg)
        if not n or n <= 0 then
            sampAddChatMessage('[CC] укажи номер сервера, например: /ccadd 201', 0xFF9955)
            return
        end
        if trackedSet[n] then
            sampAddChatMessage('[CC] этот сервер уже отслеживается', 0xFF9955)
            return
        end
        addServer(n)
        markDirty()
        sampAddChatMessage('[CC] добавлен сервер ' .. n, 0x66CCFF)
    end)

    sampRegisterChatCommand('cclist', function()
        for _, n in ipairs(tracked) do
            local st = srvState[n]
            sampAddChatMessage(('[CC] %d - срезов %d %s'):format(
                n, st.snapshots, st.apiStatus ~= '' and ('(' .. toAnsi(st.apiStatus) .. ')') or ''), 0x66CCFF)
        end
    end)

    local waited = 0
    while arizonaServers == nil and waited < 100 do wait(100); waited = waited + 1 end
    while sampGetGamestate() ~= 3 do wait(100) end
    buildServerNames()

    homeServer = getServerNumber()
    if homeServer == 0 then homeServer = tonumber(myServerId) or 0 end
    if homeServer > 0 then addServer(homeServer) end
    if #tracked == 0 then addServer(1) end

    loadTradesFromCsv()
    markDirty()

    sampAddChatMessage('[ValechkeMarket] Дима педик дырявый. Окно: /cc', 0x66CCFF)

    local VK_ESCAPE = 0x1B
    local escWasDown = false
    local rr = 1

    while true do
        wait(0)
        syncCursor()

        local escDown = false
        local okEsc, res = pcall(isKeyDown, VK_ESCAPE)
        if okEsc then escDown = res end
        if windowOpen[0] and escDown and not escWasDown then closeWindow() end
        escWasDown = escDown

        if syncActive and os.clock() >= nextTickAt then
            doTick()
        end

        -- по кругу обходим серверы, чтобы не бить все запросы разом
        if #tracked > 0 then
            rr = rr + 1
            if rr > #tracked then rr = 1 end
            local n = tracked[rr]
            local st = srvState[n]

            -- рынок опрашивает только держатель аренды
            local mayPoll = (not syncActive) or st.isHolder
            -- после ошибок увеличиваем паузу, чтобы не долбить API
            local interval = cfg.refresh[0] * math.min(8, 1 + st.errStreak)

            if mayPoll and not updating and os.clock() - st.lastUpdate > interval then
                doRefresh(n)
            end
        end

        if cfgDirty and os.clock() - cfgDirtyAt > 1.0 then
            saveCfg()
        end
    end
end

--=========================================================
-- [trade] min shop price (sellMin) for items in the trade window
-- Reads Arizona inventory CEF events (packet 220) and shows a small
-- overlay near the cursor with each tracked server's cheapest listing.
-- Debug capture: /cctdbg  ->  config/cc_trade_debug.log
--=========================================================
do
    -- NoTitleBar+NoResize+NoMove+NoScrollbar+NoCollapse+AlwaysAutoResize
    -- +NoSavedSettings+NoMouseInputs+NoFocusOnAppearing+NoNav (stable ImGui bits)
    local TRADE_FLAGS = 1 + 2 + 4 + 8 + 32 + 64 + 256 + 512 + 8192 + 196608

    local tradeOpen = false
    local tradeGrids = {}   -- inventory type -> array of { id=string, ench=number }

    local tradeDbg = false
    local dbgPath = getWorkingDirectory() .. '/config/cc_trade_debug.log'
    local function dlog(dir, text)
        local f = io.open(dbgPath, 'a')
        if not f then return end
        f:write(os.date('%H:%M:%S ') .. dir .. ' ' .. text .. string.char(10))
        f:close()
    end

    -- decode a packet-220 CEF payload (same frame as the setToken reader)
    local function cefText(bs)
        local text
        local saved = raknetBitStreamGetReadOffset(bs)
        raknetBitStreamIgnoreBits(bs, 8)
        if raknetBitStreamReadInt8(bs) == 17 then
            raknetBitStreamIgnoreBits(bs, 32)
            local len = raknetBitStreamReadInt16(bs)
            local extra = raknetBitStreamReadInt8(bs)
            if extra ~= 0 then
                text = raknetBitStreamDecodeString(bs, len + extra)
            else
                text = raknetBitStreamReadString(bs, len)
            end
        end
        raknetBitStreamSetReadOffset(bs, saved)
        return text
    end

    -- window.executeEvent('name', `<json>`);  ->  name, json
    local function splitEvent(text)
        local name = text:match("executeEvent%('([^']+)'")
        if not name then return nil end
        local arg = text:match("executeEvent%('[^']+'%s*,%s*(.-)%s*%)%s*;?%s*$")
        if arg then arg = arg:gsub("^[`']", ''):gsub("[`']$", '') end
        return name, arg
    end

    local function parseGrid(items)
        local out = {}
        if type(items) ~= 'table' then return out end
        for i = 1, #items do
            local it = items[i]
            if type(it) == 'table' and it.item then
                local id = tostring(it.item):match('(%d+)')
                if id then
                    out[#out + 1] = { id = id, ench = tonumber(it.enchant) or 0 }
                end
            end
        end
        return out
    end

    local function handleEvent(name, arg)
        if name == 'event.inventory.setTradeVisible' then
            tradeOpen = (arg ~= nil) and (arg:find('true') ~= nil)
            if not tradeOpen then tradeGrids = {} end
        elseif name == 'event.inventory.playerInventory' and tradeOpen and arg then
            local ok, data = pcall(decodeJson, arg)
            if not ok or type(data) ~= 'table' then return end
            for i = 1, #data do
                local e = data[i]
                if type(e) == 'table' and tonumber(e.action) == 2
                    and type(e.data) == 'table' and e.data.items then
                    local ty = tonumber(e.data.type)
                    -- type 1 is the player's own inventory panel; others are trade sides
                    if ty and ty ~= 1 then
                        tradeGrids[ty] = parseGrid(e.data.items)
                    end
                end
            end
        end
    end

    addEventHandler('onReceivePacket', function(id, bs)
        if id ~= 220 then return end
        local ok, text = pcall(cefText, bs)
        if not ok or not text or text == '' then return end
        if tradeDbg then dlog('RECV', text) end
        if text:find('event.inventory.', 1, true) then
            local name, arg = splitEvent(text)
            if name then pcall(handleEvent, name, arg) end
        end
    end)

    addEventHandler('onSendPacket', function(id, bs)
        if not tradeDbg or id ~= 220 then return end
        local ok, text = pcall(cefText, bs)
        if ok and text and text ~= '' then dlog('SEND', text) end
    end)

    local function tradeItems()
        local list = {}
        for _, grid in pairs(tradeGrids) do
            for _, it in ipairs(grid) do list[#list + 1] = it end
        end
        return list
    end

    imgui.OnFrame(
        function() return tradeOpen end,
        function()
            local items = tradeItems()
            if #items == 0 then return end
            local mp = imgui.GetMousePos()
            imgui.SetNextWindowPos(imgui.ImVec2(mp.x + 18, mp.y + 18), imgui.Cond.Always)
            imgui.SetNextWindowBgAlpha(0.88)
            imgui.Begin('##cc_trade_price', nil, TRADE_FLAGS)
            for n = 1, #items do
                local it = items[n]
                local key = it.id .. '#' .. it.ench
                local nm = itemNameById(it.id)
                if it.ench and it.ench > 0 then nm = nm .. ' +' .. it.ench end
                colored(CYAN, nm)
                for _, srv in ipairs(tracked) do
                    local st = srvState[srv]
                    local best = st and st.currentBest and st.currentBest[key]
                    imgui.Text(serverName(srv) .. ':')
                    imgui.SameLine(140)
                    if best and best.sellMin then
                        imgui.Text(formatMoney(best.sellMin) .. ' ' .. currencyOf(srv))
                    else
                        colored(GREY, '-')
                    end
                end
                if n < #items then imgui.Separator() end
            end
            imgui.End()
        end)

    lua_thread.create(function()
        while not isSampAvailable() do wait(0) end
        sampRegisterChatCommand('cctdbg', function()
            tradeDbg = not tradeDbg
            if tradeDbg then
                sampAddChatMessage('[CC] trade debug ON -> config/cc_trade_debug.log', 0x66CCFF)
            else
                sampAddChatMessage('[CC] trade debug OFF', 0x66CCFF)
            end
        end)
    end)
end
