------------------------------------------------------------
-- GTNH God Forge
-- Degenerate Quark Gluon Plasma Automation
--
-- GTNH 2.9.x / OpenComputers
------------------------------------------------------------

local os = require("os")
local component = require("component")
local sides = require("sides")
local term = require("term")
local computer = require("computer")

------------------------------------------------------------
-- Version
------------------------------------------------------------

local VERSION = "QGP-AUTO 0.3.0"

------------------------------------------------------------
-- Components
------------------------------------------------------------

local trans = component.transposer
local fInterface = component.fluid_interface
local gtm = component.gt_machine

------------------------------------------------------------
-- Transposer sides
--
-- 按你当前机器实际方位
------------------------------------------------------------

-- 大型原料缓存仓
local sideCacheBuffer = sides.down

-- AE物质聚合器
-- 用于销毁异化器给出的本轮指示材料
local sideAEInfusion = sides.south

-- 主网 Fluid Interface
-- 程序从这里选择并抽取所需等离子体
local sideInterface = sides.east

------------------------------------------------------------
-- QGP parameters
------------------------------------------------------------

-- 每一轮固定7种需求
local EXPECTED_DEMAND_COUNT = 7

-- 异化器输出的普通流体指示量最大64
local INDICATOR_FLUID_MAX = 64

-- 普通流体指示量 -> 等离子需求量
local FLUID_TO_PLASMA = 1000

-- 每个粉 -> 等离子需求量
local DUST_TO_PLASMA = 1296

-- AE任务显示完成以后，
-- 给Fluid Interface一点刷新时间
local CRAFT_DONE_GRACE = 3

-- 日志限流
local STATUS_PRINT_INTERVAL = 5

------------------------------------------------------------
-- BartWorks special materials
------------------------------------------------------------

local bartMaterial = {
    [3]     = "zirconium",
    [30]    = "thorium232",
    [64]    = "ruthenium",
    [78]    = "rhodium",
    [11000] = "hafnium",
    [11012] = "iodine"
}

------------------------------------------------------------
-- GT standard dust special mappings
------------------------------------------------------------

local gtDustPlasmaOverride = {
    [2382] = "ardite",
    [2884] = "desh",
    [2393] = "oriharukon",
    [2340] = "meteoriciron",
    [2103] = "americium",

    [2006] = "lithium",
    [2008] = "beryllium",
    [2010] = "carbon",
    [2017] = "sodium",
    [2018] = "magnesium",

    [2019] = "aluminium",
    [2020] = "silicon",
    [2021] = "phosphorus",
    [2022] = "sulfur",
    [2025] = "potassium",

    [2026] = "calcium",
    [2028] = "titanium",
    [2029] = "vanadium",
    [2031] = "manganese",
    [2032] = "iron",

    [2033] = "cobalt",
    [2034] = "nickel",
    [2035] = "copper",
    [2036] = "zinc",
    [2037] = "gallium",

    [2039] = "arsenic",
    [2043] = "rubidium",
    [2044] = "strontium",
    [2045] = "yttrium",
    [2047] = "niobium",

    [2048] = "molybdenum",
    [2052] = "palladium",
    [2054] = "silver",
    [2055] = "cadmium",
    [2056] = "indium",

    [2057] = "tin",
    [2058] = "antimony",
    [2059] = "tellurium",
    [2062] = "caesium",
    [2063] = "barium",

    [2064] = "lanthanum",
    [2065] = "cerium",
    [2066] = "praseodymium",
    [2067] = "neodymium",
    [2068] = "promethium",

    [2069] = "samarium",
    [2070] = "europium",
    [2071] = "gadolinium",
    [2072] = "terbium",
    [2073] = "dysprosium",

    [2074] = "holmium",
    [2075] = "erbium",
    [2076] = "thulium",
    [2077] = "ytterbium",
    [2078] = "lutetium",

    [2080] = "tantalum",
    [2081] = "tungsten",
    [2086] = "gold",
    [2097] = "uranium235",
    [2098] = "uranium"
}

------------------------------------------------------------
-- Current round
------------------------------------------------------------

local plasmaDemands = {}

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function toNumber(v)
    return tonumber(v) or 0
end

local function clearScreen()
    term.clear()
    term.setCursor(1, 1)

    print("========================================")
    print(VERSION)
    print("God Forge QGP Automation")
    print("========================================")
    print("")
end

------------------------------------------------------------
-- Safe component reads
------------------------------------------------------------

local function getFluid(side, tank)
    local ok, result = pcall(function()
        return trans.getFluidInTank(side, tank)
    end)

    if not ok then
        return nil
    end

    return result
end

local function getItem(side, slot)
    local ok, result = pcall(function()
        return trans.getStackInSlot(side, slot)
    end)

    if not ok then
        return nil
    end

    return result
end

------------------------------------------------------------
-- Safe transfers
------------------------------------------------------------

local function transferFluidSafe(fromSide, toSide, amount, tank)
    amount = math.floor(toNumber(amount))

    if amount <= 0 then
        return 0
    end

    local ok, a, b = pcall(function()
        return trans.transferFluid(
            fromSide,
            toSide,
            amount,
            tank
        )
    end)

    if not ok then
        print("[流体转运失败] " .. tostring(a))
        return 0
    end

    -- 你当前版本实际返回形式：
    -- success, moved
    if type(b) == "number" then
        return b
    end

    -- 兼容直接返回移动量的版本
    if type(a) == "number" then
        return a
    end

    return 0
end

local function transferItemSafe(fromSide, toSide, amount, slot)
    amount = math.floor(toNumber(amount))

    if amount <= 0 then
        return 0
    end

    local ok, moved = pcall(function()
        return trans.transferItem(
            fromSide,
            toSide,
            amount,
            slot
        )
    end)

    if not ok then
        print("[物品转运失败] " .. tostring(moved))
        return 0
    end

    return toNumber(moved)
end

------------------------------------------------------------
-- Ordinary fluid -> plasma name
------------------------------------------------------------

local function fluidToPlasma(fluidName)
    if not fluidName then
        return nil
    end

    if fluidName:match("^molten%.") then
        local mat = fluidName:match("^molten%.(.+)$")

        if mat then
            return "plasma." .. mat
        end
    end

    return "plasma." .. fluidName
end

------------------------------------------------------------
-- Dust item -> plasma name
------------------------------------------------------------

local function itemToPlasma(item)
    if not item then
        return nil
    end

    --------------------------------------------------------
    -- GregTech standard dust
    --------------------------------------------------------

    if item.name == "gregtech:gt.metaitem.01" then
        local override =
            gtDustPlasmaOverride[item.damage]

        if override then
            return "plasma." .. override
        end

        local label = item.label or ""
        local mat = label:match("^(.+) Dust$")

        if not mat then
            return nil
        end

        mat = string.lower(
            mat:gsub(" ", "")
        )

        return "plasma." .. mat
    end

    --------------------------------------------------------
    -- BartWorks
    --------------------------------------------------------

    if item.name == "bartworks:gt.bwMetaGenerateddust" then
        local mat = bartMaterial[item.damage]

        if not mat then
            return nil
        end

        return "plasma." .. mat
    end

    --------------------------------------------------------
    -- MiscUtils
    --------------------------------------------------------

    if item.name
        and item.name:match("^miscutils:itemDust")
    then
        local mat =
            item.name:match(
                "^miscutils:itemDust(.+)$"
            )

        if not mat then
            return nil
        end

        return "plasma." .. string.lower(mat)
    end

    return nil
end

------------------------------------------------------------
-- Scan current QGP indicators
------------------------------------------------------------

local function scanCacheBuffer(verbose)
    plasmaDemands = {}

    --------------------------------------------------------
    -- Fluid indicators
    --------------------------------------------------------

    for i = 1, 7 do
        local fluid =
            getFluid(
                sideCacheBuffer,
                i
            )

        if fluid then
            local amount =
                toNumber(fluid.amount)

            local name =
                tostring(fluid.name or "")

            if amount > 0
                and amount <= INDICATOR_FLUID_MAX
                and not name:match("^plasma%.")
            then
                local plasmaName =
                    fluidToPlasma(name)

                if plasmaName then
                    local need =
                        amount * FLUID_TO_PLASMA

                    table.insert(
                        plasmaDemands,
                        {
                            name = plasmaName,
                            amount = need,
                            sourceType = "fluid",
                            sourceIndex = i,
                            sourceName = name
                        }
                    )

                    if verbose then
                        print(
                            string.format(
                                "流体 %s -> %s × %d mB",
                                fluid.label or name,
                                plasmaName,
                                need
                            )
                        )
                    end
                end
            end
        end
    end

    --------------------------------------------------------
    -- Dust indicators
    --------------------------------------------------------

    for i = 1, 7 do
        local item =
            getItem(
                sideCacheBuffer,
                i
            )

        if item then
            local plasmaName =
                itemToPlasma(item)

            if plasmaName then
                local count =
                    toNumber(item.size)

                local need =
                    count * DUST_TO_PLASMA

                table.insert(
                    plasmaDemands,
                    {
                        name = plasmaName,
                        amount = need,
                        sourceType = "item",
                        sourceIndex = i,
                        sourceName = item.name
                    }
                )

                if verbose then
                    print(
                        string.format(
                            "物品 %s -> %s × %d mB",
                            item.label or item.name,
                            plasmaName,
                            need
                        )
                    )
                end
            elseif verbose then
                print(
                    "[无法识别物品] "
                    .. tostring(
                        item.label or item.name
                    )
                    .. " damage="
                    .. tostring(item.damage)
                )
            end
        end
    end

    return #plasmaDemands
end

------------------------------------------------------------
-- Ensure cache currently contains indicator material only
--
-- 防止最终QGP产物或者仍未消费的plasma被误送进物质聚合器。
------------------------------------------------------------

local function validateIndicatorCache()
    --------------------------------------------------------
    -- Fluids
    --------------------------------------------------------

    for i = 1, 7 do
        local fluid =
            getFluid(
                sideCacheBuffer,
                i
            )

        if fluid
            and toNumber(fluid.amount) > 0
        then
            local amount =
                toNumber(fluid.amount)

            local name =
                tostring(fluid.name or "")

            if name:match("^plasma%.") then
                return false,
                    "缓存仓中仍有等离子体: "
                    .. name
                    .. " × "
                    .. tostring(amount)
                    .. " mB"
            end

            if amount > INDICATOR_FLUID_MAX then
                return false,
                    "缓存仓出现非指示大流体: "
                    .. name
                    .. " × "
                    .. tostring(amount)
                    .. " mB"
            end
        end
    end

    --------------------------------------------------------
    -- Items
    --------------------------------------------------------

    for i = 1, 7 do
        local item =
            getItem(
                sideCacheBuffer,
                i
            )

        if item
            and not itemToPlasma(item)
        then
            return false,
                "缓存仓出现未知物品: "
                .. tostring(
                    item.label or item.name
                )
        end
    end

    return true
end

------------------------------------------------------------
-- Clear current seven indicator materials
--
-- 只在确认：
--   1. 完整识别7种需求
--   2. 缓存仓里没有plasma/QGP异常流体
-- 后才执行。
------------------------------------------------------------

local function clearCacheBuffer()
    --------------------------------------------------------
    -- Fluids
    --------------------------------------------------------

    for i = 1, 7 do
        local fluid =
            getFluid(
                sideCacheBuffer,
                i
            )

        if fluid
            and toNumber(fluid.amount) > 0
        then
            local expected =
                toNumber(fluid.amount)

            local moved =
                transferFluidSafe(
                    sideCacheBuffer,
                    sideAEInfusion,
                    expected,
                    i - 1
                )

            if moved < expected then
                print(
                    string.format(
                        "[清理失败] %s 期望 %d，实际 %d",
                        tostring(fluid.name),
                        expected,
                        moved
                    )
                )

                return false
            end
        end
    end

    --------------------------------------------------------
    -- Items
    --------------------------------------------------------

    for i = 1, 7 do
        local item =
            getItem(
                sideCacheBuffer,
                i
            )

        if item then
            local expected =
                toNumber(item.size)

            local moved =
                transferItemSafe(
                    sideCacheBuffer,
                    sideAEInfusion,
                    expected,
                    i
                )

            if moved < expected then
                print(
                    string.format(
                        "[清理失败] %s 期望 %d，实际 %d",
                        tostring(
                            item.label or item.name
                        ),
                        expected,
                        moved
                    )
                )

                return false
            end
        end
    end

    return true
end

------------------------------------------------------------
-- Fluid Interface filter
------------------------------------------------------------

local function setFluidFilter(fluidName)
    local ok, err =
        pcall(function()
            fInterface.setFluidInterfaceConfiguration(
                0,
                {
                    name = fluidName
                }
            )
        end)

    if not ok then
        print(
            "[接口] 设置过滤器失败: "
            .. tostring(fluidName)
        )

        print(tostring(err))

        return false
    end

    return true
end

local function clearFluidFilter()
    pcall(function()
        fInterface.setFluidInterfaceConfiguration(0)
    end)
end

------------------------------------------------------------
-- AE Craftable handling
--
-- 关键：
-- Craftable是OC AbstractValue/userdata，
-- 不能要求type(value)必须是table。
------------------------------------------------------------
------------------------------------------------------------
-- AE Craftable helpers
------------------------------------------------------------

local function pack(...)
    return {
        n = select("#", ...),
        ...
    }
end

local function hasMethod(obj, methodName)
    if obj == nil then
        return false
    end

    local ok, method = pcall(function()
        return obj[methodName]
    end)

    return ok and type(method) == "function"
end

------------------------------------------------------------
-- 检查一个对象是不是目标 Craftable
------------------------------------------------------------

local function isTargetCraftable(obj, plasmaName)

    if obj == nil then
        return false
    end

    if not hasMethod(obj, "request") then
        return false
    end

    if not hasMethod(obj, "getStack") then
        return false
    end

    local ok, stack = pcall(function()
        return obj.getStack()
    end)

    if not ok or stack == nil then
        return false
    end

    local name = nil

    local okName = pcall(function()
        name = stack.name
    end)

    if not okName then
        return false
    end

    return name == plasmaName
end

------------------------------------------------------------
-- 递归扫描 getCraftables 返回值
------------------------------------------------------------

local function searchCraftable(value, plasmaName, depth)

    depth = depth or 0

    if depth > 5 or value == nil then
        return nil
    end

    --------------------------------------------------------
    -- value 本身就是 Craftable userdata
    --------------------------------------------------------

    if isTargetCraftable(
        value,
        plasmaName
    ) then
        return value
    end

    --------------------------------------------------------
    -- 不是 table 就没法继续向下找
    --------------------------------------------------------

    if type(value) ~= "table" then
        return nil
    end

    --------------------------------------------------------
    -- 遍历容器
    --------------------------------------------------------

    for _, child in pairs(value) do

        local found =
            searchCraftable(
                child,
                plasmaName,
                depth + 1
            )

        if found then
            return found
        end
    end

    return nil
end

------------------------------------------------------------
-- 获取指定 plasma 的 Craftable
------------------------------------------------------------

local function getCraftable(plasmaName)

    --------------------------------------------------------
    -- 方法1：
    -- 新版 GTNH OC 有 getCraftable(detail, type)
    --------------------------------------------------------

    if type(fInterface.getCraftable)
        == "function"
    then

        local ok, craftable =
            pcall(function()

                return
                    fInterface.getCraftable(
                        {
                            name = plasmaName
                        },
                        "fluid"
                    )
            end)

        if ok
            and craftable
            and hasMethod(
                craftable,
                "request"
            )
        then

            print(
                "[下单] 精确找到配方: "
                .. plasmaName
            )

            return craftable
        end
    end

    --------------------------------------------------------
    -- 方法2：
    -- 兼容2.9b1：
    --
    -- 不使用过滤器。
    -- 直接读取全部可合成项，然后通过 getStack()
    -- 检查每一个 Craftable 的真实输出。
    --------------------------------------------------------

    local result =
        pack(
            pcall(function()

                return
                    fInterface.getCraftables()
            end)
        )

    --------------------------------------------------------
    -- pcall第一个返回值
    --------------------------------------------------------

    if not result[1] then

        print(
            "[下单] getCraftables异常: "
            .. tostring(result[2])
        )

        return nil
    end

    --------------------------------------------------------
    -- pcall后面的所有返回值都检查
    --
    -- 这么写同时兼容：
    --
    -- getCraftables() -> table
    --
    -- 和某些版本可能出现的：
    --
    -- getCraftables() -> value1,value2,...
    --------------------------------------------------------

    for i = 2, result.n do

        local found =
            searchCraftable(
                result[i],
                plasmaName,
                0
            )

        if found then

            print(
                "[下单] 扫描找到配方: "
                .. plasmaName
            )

            return found
        end
    end

    print(
        "[下单] AE中没有找到目标Craftable: "
        .. plasmaName
    )

    return nil
end


    --------------------------------------------------------
    -- 正常GTNH：
    -- 外层是table，里面是Craftable userdata。
    --
    -- 同时递归处理，避免版本返回结构差异。
    --------------------------------------------------------

    local craftable =
        findRequestObject(
            craftables,
            0
        )

    if not craftable then
        print(
            "[下单] AE中没有可请求配方: "
            .. plasmaName
        )

        return nil
    end

    return craftable
end

------------------------------------------------------------
-- Submit AE crafting request
--
-- remaining就是最终仍缺少的目标等离子数量。
--
-- 不计算：
--   样板输出倍率
--   配方执行次数
--
-- 直接把最终需求交给AE。
------------------------------------------------------------

local function requestPlasmaSynthesis(
    plasmaName,
    remaining
)
    remaining =
        math.floor(
            toNumber(remaining)
        )

    if remaining <= 0 then
        return nil
    end

    print(
        string.format(
            "[下单] AE请求 %s × %d mB",
            plasmaName,
            remaining
        )
    )

    local craftable =
        getCraftable(plasmaName)

    if not craftable then
        return nil
    end

    local ok, status =
        pcall(function()
            return craftable.request(
                remaining,
                true
            )
        end)

    if not ok then
        print(
            "[下单] request失败: "
            .. tostring(status)
        )

        return nil
    end

    if status == nil then
        print(
            "[下单] AE没有返回任务对象"
        )

        return nil
    end

    print("[下单] 请求已提交")

    return status
end

------------------------------------------------------------
-- CraftingStatus
--
-- return:
--   computing
--   running
--   done
--   failed
--   canceled
--   unknown
------------------------------------------------------------

local function getCraftState(status)
    if status == nil then
        return "unknown"
    end

    --------------------------------------------------------
    -- AE still calculating crafting plan
    --------------------------------------------------------

    local okComputing, computing =
        pcall(function()
            return status.isComputing()
        end)

    if okComputing and computing then
        return "computing"
    end

    --------------------------------------------------------
    -- Failed
    --------------------------------------------------------

    local okFailed, failed, failReason =
        pcall(function()
            return status.hasFailed()
        end)

    if okFailed and failed then
        return "failed", failReason
    end

    --------------------------------------------------------
    -- Canceled
    --------------------------------------------------------

    local okCanceled, canceled, cancelReason =
        pcall(function()
            return status.isCanceled()
        end)

    if okCanceled and canceled then
        return "canceled", cancelReason
    end

    --------------------------------------------------------
    -- Done / running
    --------------------------------------------------------

    local okDone, done, doneReason =
        pcall(function()
            return status.isDone()
        end)

    if okDone then
        if done then
            return "done", doneReason
        end

        return "running", doneReason
    end

    return "unknown"
end

------------------------------------------------------------
-- Feed one complete QGP round
------------------------------------------------------------

local function processPlasmaDemands()
    for index, demand
        in ipairs(plasmaDemands)
    do
        print("")
        print(
            string.format(
                ">>> %d/%d: %s，需要 %d mB",
                index,
                #plasmaDemands,
                demand.name,
                demand.amount
            )
        )

        ----------------------------------------------------
        -- Select plasma on Fluid Interface
        ----------------------------------------------------

        if not setFluidFilter(demand.name) then
            clearFluidFilter()
            return false
        end

        os.sleep(0.5)

        local remaining =
            math.floor(
                toNumber(demand.amount)
            )

        local craftStatus = nil
        local craftDoneAt = nil
        local lastStatusPrint = 0

        ----------------------------------------------------
        -- Continue until exact amount has been injected
        ----------------------------------------------------

        while remaining > 0 do
            local fluid =
                getFluid(
                    sideInterface,
                    1
                )

            local available = 0
            local fluidName = nil

            if fluid then
                available =
                    toNumber(fluid.amount)

                fluidName =
                    fluid.name
            end

            ------------------------------------------------
            -- Target plasma available
            ------------------------------------------------

            if available > 0
                and fluidName == demand.name
            then
                local take =
                    math.min(
                        remaining,
                        available
                    )

                local moved =
                    transferFluidSafe(
                        sideInterface,
                        sideCacheBuffer,
                        take,
                        0
                    )

                if moved > 0 then
                    remaining =
                        remaining - moved

                    if remaining < 0 then
                        remaining = 0
                    end

                    print(
                        string.format(
                            "已抽取 %d mB，剩余 %d mB",
                            moved,
                            remaining
                        )
                    )

                    os.sleep(0.1)
                else
                    os.sleep(0.5)
                end

            ------------------------------------------------
            -- Interface still exposing previous fluid
            ------------------------------------------------

            elseif available > 0
                and fluidName
                and fluidName ~= demand.name
            then
                local now =
                    computer.uptime()

                if now - lastStatusPrint
                    >= STATUS_PRINT_INTERVAL
                then
                    print(
                        "[接口] 当前为 "
                        .. tostring(fluidName)
                        .. "，等待 "
                        .. demand.name
                    )

                    lastStatusPrint = now
                end

                os.sleep(0.5)

            ------------------------------------------------
            -- No target plasma currently available
            ------------------------------------------------

            else
                ------------------------------------------------
                -- No active/requested job
                ------------------------------------------------

                if craftStatus == nil then
                    print(
                        "接口无目标流体，尝试下单..."
                    )

                    craftStatus =
                        requestPlasmaSynthesis(
                            demand.name,
                            remaining
                        )

                    craftDoneAt = nil

                    if not craftStatus then
                        print(
                            "[下单] 本次失败，5秒后重试"
                        )

                        os.sleep(5)
                    else
                        os.sleep(0.5)
                    end

                ------------------------------------------------
                -- Existing request
                ------------------------------------------------

                else
                    local state, reason =
                        getCraftState(
                            craftStatus
                        )

                    local now =
                        computer.uptime()

                    --------------------------------------------
                    -- AE calculating plan
                    --------------------------------------------

                    if state == "computing" then
                        if now - lastStatusPrint
                            >= STATUS_PRINT_INTERVAL
                        then
                            print(
                                "[AE] 正在计算合成计划..."
                            )

                            lastStatusPrint = now
                        end

                        os.sleep(0.5)

                    --------------------------------------------
                    -- CPU running
                    --------------------------------------------

                    elseif state == "running" then
                        if now - lastStatusPrint
                            >= STATUS_PRINT_INTERVAL
                        then
                            print(
                                string.format(
                                    "[AE] 合成中，仍需 %d mB",
                                    remaining
                                )
                            )

                            lastStatusPrint = now
                        end

                        os.sleep(0.5)

                    --------------------------------------------
                    -- Job done
                    --------------------------------------------

                    elseif state == "done" then
                        if not craftDoneAt then
                            craftDoneAt = now

                            print(
                                "[AE] 合成任务完成，等待接口刷新..."
                            )
                        end

                        if now - craftDoneAt
                            >= CRAFT_DONE_GRACE
                        then
                            ------------------------------------------------
                            -- AE任务已经结束，
                            -- 但过了缓冲时间仍然缺目标流体。
                            --
                            -- 按当前剩余量重新补单。
                            ------------------------------------------------

                            print(
                                string.format(
                                    "[AE] 仍缺 %d mB，重新补单",
                                    remaining
                                )
                            )

                            craftStatus = nil
                            craftDoneAt = nil
                        else
                            os.sleep(0.5)
                        end

                    --------------------------------------------
                    -- Failed / canceled
                    --------------------------------------------

                    elseif state == "failed"
                        or state == "canceled"
                    then
                        print(
                            "[AE] 任务 "
                            .. state
                            .. ": "
                            .. tostring(reason)
                        )

                        craftStatus = nil
                        craftDoneAt = nil

                        os.sleep(2)

                    --------------------------------------------
                    -- Unknown
                    --------------------------------------------

                    else
                        if now - lastStatusPrint
                            >= STATUS_PRINT_INTERVAL
                        then
                            print(
                                "[AE] 无法读取任务状态，继续等待..."
                            )

                            lastStatusPrint = now
                        end

                        -- unknown时不重复下单，
                        -- 防止已有CPU任务时造成重复请求。
                        os.sleep(1)
                    end
                end
            end
        end

        ----------------------------------------------------
        -- Current plasma complete
        ----------------------------------------------------

        print(
            demand.name
            .. " 输入完成"
        )

        clearFluidFilter()

        os.sleep(0.5)
    end

    clearFluidFilter()

    print("")
    print("========================================")
    print("本轮7种等离子体输入完成")
    print("等待异化器生成下一轮指示材料")
    print("========================================")
    print("")

    --------------------------------------------------------
    -- 注意：
    --
    -- 此处绝对不清缓存仓。
    --
    -- 送入的大量等离子体必须让异化器自己消费。
    --------------------------------------------------------

    return true
end

------------------------------------------------------------
-- Detect whether a new round is appearing
------------------------------------------------------------

local function hasPotentialIndicators()
    --------------------------------------------------------
    -- Fluid indicators
    --------------------------------------------------------

    for i = 1, 7 do
        local fluid =
            getFluid(
                sideCacheBuffer,
                i
            )

        if fluid then
            local amount =
                toNumber(fluid.amount)

            local name =
                tostring(fluid.name or "")

            if amount > 0
                and amount <= INDICATOR_FLUID_MAX
                and not name:match("^plasma%.")
            then
                return true
            end
        end
    end

    --------------------------------------------------------
    -- Recognized dust indicators
    --------------------------------------------------------

    for i = 1, 7 do
        local item =
            getItem(
                sideCacheBuffer,
                i
            )

        if item
            and itemToPlasma(item)
        then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- Machine on/off handling
------------------------------------------------------------

local function waitIfMachineDisabled()
    if not gtm then
        return
    end

    local ok, allowed =
        pcall(function()
            return gtm.isWorkAllowed()
        end)

    if not ok then
        return
    end

    if allowed then
        return
    end

    print("机器已关闭，等待重新启动...")

    while true do
        os.sleep(5)

        local ok2, state =
            pcall(function()
                return gtm.isWorkAllowed()
            end)

        if ok2 and state then
            print("机器已重新启动")
            return
        end
    end
end

------------------------------------------------------------
-- Main
------------------------------------------------------------

local function main()
    clearScreen()

    --------------------------------------------------------
    -- Component checks
    --------------------------------------------------------

    if not trans then
        print("错误：未找到 transposer")
        return
    end

    if not fInterface then
        print("错误：未找到 fluid_interface")
        return
    end

    print("组件检查通过")
    print("")
    print("缓存仓方向 : DOWN")
    print("物质聚合器 : SOUTH")
    print("Fluid接口  : EAST")
    print("")
    print("等待QGP新一轮指示材料...")
    print("")

    local lastPartialCount = -1

    --------------------------------------------------------
    -- Main loop
    --------------------------------------------------------

    while true do
        waitIfMachineDisabled()

        ----------------------------------------------------
        -- New indicator material detected
        ----------------------------------------------------

        if hasPotentialIndicators() then
            ------------------------------------------------
            -- 第一遍静默扫描
            ------------------------------------------------

            local count =
                scanCacheBuffer(false)

            ------------------------------------------------
            -- 完整7种
            ------------------------------------------------

            if count == EXPECTED_DEMAND_COUNT then
                ------------------------------------------------
                -- 再等一小段时间，
                -- 防止正处于输出更新瞬间。
                ------------------------------------------------

                os.sleep(0.5)

                local count2 =
                    scanCacheBuffer(false)

                if count2 == EXPECTED_DEMAND_COUNT then
                    ------------------------------------------------
                    -- 确认缓存仓没有plasma/QGP等异常内容
                    ------------------------------------------------

                    local valid, reason =
                        validateIndicatorCache()

                    if not valid then
                        print(
                            "[保护] "
                            .. tostring(reason)
                        )

                        print(
                            "[保护] 不执行清仓，请检查输出分流。"
                        )

                        os.sleep(5)
                    else
                        ------------------------------------------------
                        -- 正式显示本轮
                        ------------------------------------------------

                        clearScreen()

                        print(
                            "=== 检测到完整QGP新一轮 ==="
                        )

                        print("")

                        scanCacheBuffer(true)

                        print("")
                        print(
                            "共识别 "
                            .. tostring(
                                #plasmaDemands
                            )
                            .. "/"
                            .. tostring(
                                EXPECTED_DEMAND_COUNT
                            )
                            .. " 种需求"
                        )

                        ------------------------------------------------
                        -- Clear seven indicator materials
                        ------------------------------------------------

                        print("")
                        print("清理本轮指示材料...")

                        if not clearCacheBuffer() then
                            print("")
                            print(
                                "[严重] 指示材料未完全清理"
                            )

                            print(
                                "停止本轮，避免错误输入。"
                            )

                            clearFluidFilter()

                            return
                        end

                        print(
                            "指示材料清理完成"
                        )

                        os.sleep(0.5)

                        ------------------------------------------------
                        -- Feed seven plasma requirements
                        ------------------------------------------------

                        if not processPlasmaDemands() then
                            clearFluidFilter()

                            print(
                                "[错误] 本轮处理失败"
                            )

                            os.sleep(5)
                        end

                        lastPartialCount = -1
                    end
                end

            ------------------------------------------------
            -- Waiting for complete set
            ------------------------------------------------

            elseif count ~= lastPartialCount then
                print(
                    string.format(
                        "[等待] 当前识别 %d/%d 种指示材料",
                        count,
                        EXPECTED_DEMAND_COUNT
                    )
                )

                lastPartialCount = count
            end
        else
            lastPartialCount = -1
        end

        os.sleep(1)
    end
end

------------------------------------------------------------
-- Start
------------------------------------------------------------

local ok, err =
    xpcall(
        main,
        debug.traceback
    )

------------------------------------------------------------
-- Always clear Fluid Interface filter
------------------------------------------------------------

clearFluidFilter()

if not ok then
    print("")
    print("========================================")
    print("程序异常退出")
    print("========================================")
    print(tostring(err))
end
