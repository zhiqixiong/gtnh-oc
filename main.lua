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

local VERSION = "QGP-AUTO 0.2.0"

------------------------------------------------------------
-- Components
------------------------------------------------------------

local trans = component.transposer
local fInterface = component.fluid_interface
local gtm = component.gt_machine

------------------------------------------------------------
-- Transposer sides
------------------------------------------------------------

-- 大型原料缓存仓
local sideCacheBuffer = sides.west

-- AE物质聚合器
-- 用于销毁/移走本轮7种指示材料
local sideAEInfusion = sides.south

-- 主网 Fluid Interface
-- 程序通过它选择并抽取目标等离子
local sideInterface = sides.down

------------------------------------------------------------
-- QGP parameters
------------------------------------------------------------

-- 每轮应有7种元素需求
local EXPECTED_DEMAND_COUNT = 7

-- 神锻输出的普通流体指示量范围很小
local INDICATOR_FLUID_MAX = 64

-- 1单位普通流体指示 -> 1000 mB plasma
local FLUID_TO_PLASMA = 1000

-- 1个粉 -> 1296 mB plasma
local DUST_TO_PLASMA = 1296

-- AE任务已经完成，但接口还没刷新时，
-- 给网络一些缓冲时间
local CRAFT_DONE_GRACE = 5

-- AE任务状态无法读取时，不主动重复下单，
-- 避免重复订单。
local UNKNOWN_STATUS_PRINT_INTERVAL = 10

------------------------------------------------------------
-- BartWorks materials
------------------------------------------------------------

local bartMaterial = {
    [3] = "zirconium",
    [30] = "thorium232",
    [64] = "ruthenium",
    [78] = "rhodium",
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
-- Current round demands
------------------------------------------------------------

local plasmaDemands = {}

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function toNumber(value)
    return tonumber(value) or 0
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
-- Safe fluid read
------------------------------------------------------------

local function getFluid(side, index)
    local ok, result = pcall(function()
        return trans.getFluidInTank(side, index)
    end)

    if not ok then
        return nil
    end

    return result
end

------------------------------------------------------------
-- Safe item read
------------------------------------------------------------

local function getItem(side, index)
    local ok, result = pcall(function()
        return trans.getStackInSlot(side, index)
    end)

    if not ok then
        return nil
    end

    return result
end

------------------------------------------------------------
-- Safe fluid transfer
--
-- 兼容不同transferFluid返回格式：
--   amount
-- 或
--   success, amount
------------------------------------------------------------

local function transferFluidSafe(
    fromSide,
    toSide,
    amount,
    tank
)
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
        print(
            "[流体转运失败] "
            .. tostring(a)
        )

        return 0
    end

    if tonumber(b) then
        return tonumber(b)
    end

    if tonumber(a) then
        return tonumber(a)
    end

    return 0
end

------------------------------------------------------------
-- Safe item transfer
------------------------------------------------------------

local function transferItemSafe(
    fromSide,
    toSide,
    amount,
    slot
)
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
        print(
            "[物品转运失败] "
            .. tostring(moved)
        )

        return 0
    end

    return tonumber(moved) or 0
end

------------------------------------------------------------
-- Fluid name -> plasma name
------------------------------------------------------------

local function fluidToPlasma(fluidName)

    if not fluidName then
        return nil
    end

    if fluidName:match("^molten%.") then

        local mat =
            fluidName:match(
                "^molten%.(.+)$"
            )

        if mat then
            return "plasma." .. mat
        end
    end

    return "plasma." .. fluidName
end

------------------------------------------------------------
-- Item -> plasma name
------------------------------------------------------------

local function itemToPlasma(item)

    if not item then
        return nil
    end

    --------------------------------------------------------
    -- GregTech standard dust
    --------------------------------------------------------

    if item.name
        == "gregtech:gt.metaitem.01"
    then

        local override =
            gtDustPlasmaOverride[
                item.damage
            ]

        if override then
            return "plasma." .. override
        end

        local label =
            item.label or ""

        local mat =
            label:match(
                "^(.+) Dust$"
            )

        if not mat then
            return nil
        end

        mat =
            string.lower(
                mat:gsub(
                    " ",
                    ""
                )
            )

        return "plasma." .. mat
    end

    --------------------------------------------------------
    -- BartWorks dust
    --------------------------------------------------------

    if item.name
        == "bartworks:gt.bwMetaGenerateddust"
    then

        local mat =
            bartMaterial[
                item.damage
            ]

        if not mat then
            return nil
        end

        return "plasma." .. mat
    end

    --------------------------------------------------------
    -- MiscUtils dust
    --------------------------------------------------------

    if item.name
        and item.name:match(
            "^miscutils:itemDust"
        )
    then

        local mat =
            item.name:match(
                "^miscutils:itemDust(.+)$"
            )

        if not mat then
            return nil
        end

        return
            "plasma."
            .. string.lower(mat)
    end

    return nil
end

------------------------------------------------------------
-- Scan indicator materials
------------------------------------------------------------

local function scanCacheBuffer()

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
                toNumber(
                    fluid.amount
                )

            local name =
                fluid.name or ""

            ------------------------------------------------
            -- 新一轮指示流体：
            -- 非plasma且数量<=64
            ------------------------------------------------

            if amount > 0
                and amount
                    <= INDICATOR_FLUID_MAX
                and not name:match(
                    "^plasma%."
                )
            then

                local plasmaName =
                    fluidToPlasma(name)

                if plasmaName then

                    local need =
                        amount
                        * FLUID_TO_PLASMA

                    table.insert(
                        plasmaDemands,
                        {
                            name = plasmaName,
                            amount = need
                        }
                    )

                    print(
                        string.format(
                            "流体 %-24s -> %-28s %d mB",
                            fluid.label or name,
                            plasmaName,
                            need
                        )
                    )
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
                    toNumber(
                        item.size
                    )

                local need =
                    count
                    * DUST_TO_PLASMA

                table.insert(
                    plasmaDemands,
                    {
                        name = plasmaName,
                        amount = need
                    }
                )

                print(
                    string.format(
                        "物品 %-24s -> %-28s %d mB",
                        item.label
                            or item.name,
                        plasmaName,
                        need
                    )
                )

            else

                print(
                    "[无法识别粉末] "
                    .. tostring(
                        item.label
                            or item.name
                    )
                    .. " damage="
                    .. tostring(
                        item.damage
                    )
                )
            end
        end
    end

    return #plasmaDemands
end

------------------------------------------------------------
-- Clear indicator cache
--
-- 这个函数只在确认完整读取到7种需求之后调用。
--
-- 因此这里可以沿用原程序的设计：
-- 把缓存仓中的本轮指示材料全部送到物质聚合器。
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

            transferFluidSafe(
                sideCacheBuffer,
                sideAEInfusion,
                fluid.amount,
                i - 1
            )
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

            transferItemSafe(
                sideCacheBuffer,
                sideAEInfusion,
                item.size,
                i
            )
        end
    end
end

------------------------------------------------------------
-- Fluid Interface filter
------------------------------------------------------------

local function setFluidFilter(
    fluidName
)

    local ok, err =
        pcall(function()

            fInterface
                .setFluidInterfaceConfiguration(
                    0,
                    {
                        name = fluidName
                    }
                )
        end)

    if not ok then

        print(
            "[接口] 无法设置过滤器: "
            .. tostring(fluidName)
        )

        print(
            tostring(err)
        )

        return false
    end

    return true
end

------------------------------------------------------------
-- Clear Fluid Interface filter
------------------------------------------------------------

local function clearFluidFilter()

    pcall(function()

        fInterface
            .setFluidInterfaceConfiguration(
                0
            )
    end)
end

------------------------------------------------------------
-- Recursively find an object that has request()
--
-- 用于兼容不同版本getCraftables返回结构。
------------------------------------------------------------

local function findRequestObject(
    value,
    depth
)

    depth = depth or 0

    if depth > 4 then
        return nil
    end

    if type(value) ~= "table" then
        return nil
    end

    if type(value.request)
        == "function"
    then
        return value
    end

    for _, child
        in pairs(value)
    do

        local found =
            findRequestObject(
                child,
                depth + 1
            )

        if found then
            return found
        end
    end

    return nil
end

------------------------------------------------------------
-- Find AE craftable
------------------------------------------------------------

local function getCraftable(
    plasmaName
)

    --------------------------------------------------------
    -- pcall保留多返回值，
    -- 同时兼容“直接table”和“多返回值”两种情况。
    --------------------------------------------------------

    local ok, a, b, c, d =
        pcall(function()

            return
                fInterface.getCraftables(
                    {
                        name = plasmaName
                    }
                )
        end)

    if not ok then

        print(
            "[下单] getCraftables异常: "
            .. tostring(a)
        )

        return nil
    end

    --------------------------------------------------------
    -- 第一种：
    -- getCraftables()直接返回数组
    --------------------------------------------------------

    local found =
        findRequestObject(
            a,
            0
        )

    if found then
        return found
    end

    --------------------------------------------------------
    -- 第二种：
    -- 某些版本表现为多返回值
    --------------------------------------------------------

    local wrapper = {
        a,
        b,
        c,
        d
    }

    found =
        findRequestObject(
            wrapper,
            0
        )

    return found
end

------------------------------------------------------------
-- Request missing plasma from AE
--
-- 重点：
--
-- remaining就是最终还缺少的目标流体数量。
--
-- 不计算样板倍率，
-- 不计算配方执行次数，
-- 不假设8000/16000/其他输出量。
--
-- 直接把需求量交给AE crafting planner。
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
        getCraftable(
            plasmaName
        )

    if not craftable then

        print(
            "[下单] 未找到可合成项: "
            .. plasmaName
        )

        return nil
    end

    --------------------------------------------------------
    -- 直接请求remaining
    --------------------------------------------------------

    local ok, status =
        pcall(function()

            return
                craftable.request(
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

    if not status then

        print(
            "[下单] AE没有返回任务对象"
        )

        return nil
    end

    print(
        "[下单] 请求已提交"
    )

    return status
end

------------------------------------------------------------
-- AE craft status
--
-- return:
--   running
--   done
--   failed
--   canceled
--   unknown
------------------------------------------------------------

local function getCraftState(status)

    if not status then
        return "unknown"
    end

    --------------------------------------------------------
    -- failed
    --------------------------------------------------------

    local okFailed, failed =
        pcall(function()

            return
                status.hasFailed()
        end)

    if okFailed and failed then
        return "failed"
    end

    --------------------------------------------------------
    -- canceled
    --------------------------------------------------------

    local okCanceled, canceled =
        pcall(function()

            return
                status.isCanceled()
        end)

    if okCanceled and canceled then
        return "canceled"
    end

    --------------------------------------------------------
    -- done
    --------------------------------------------------------

    local okDone, done =
        pcall(function()

            return
                status.isDone()
        end)

    if okDone then

        if done then
            return "done"
        end

        return "running"
    end

    --------------------------------------------------------
    -- 某些版本可能没有isDone，
    -- 但hasFailed可调用，仍视为有效运行对象。
    --------------------------------------------------------

    if okFailed or okCanceled then
        return "running"
    end

    return "unknown"
end

------------------------------------------------------------
-- Process one QGP round
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
        -- Select target plasma
        ----------------------------------------------------

        if not setFluidFilter(
            demand.name
        )
        then

            clearFluidFilter()

            print(
                "[错误] 无法设置接口过滤器"
            )

            return false
        end

        os.sleep(0.5)

        local remaining =
            math.floor(
                toNumber(
                    demand.amount
                )
            )

        local craftStatus = nil

        local craftDoneAt = nil

        local lastUnknownPrint = 0

        ----------------------------------------------------
        -- Continue until exact QGP requirement is supplied
        ----------------------------------------------------

        while remaining > 0 do

            ------------------------------------------------
            -- Read Fluid Interface
            ------------------------------------------------

            local fluid =
                getFluid(
                    sideInterface,
                    1
                )

            local available = 0
            local fluidName = nil

            if fluid then

                available =
                    toNumber(
                        fluid.amount
                    )

                fluidName =
                    fluid.name
            end

            ------------------------------------------------
            -- Correct plasma available
            ------------------------------------------------

            if available > 0
                and fluidName
                    == demand.name
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

                    ------------------------------------------------
                    -- 网络已经开始提供流体，
                    -- 不因为“原AE任务结束”立刻重复下单。
                    ------------------------------------------------

                    if remaining == 0 then
                        break
                    end

                    os.sleep(0.1)

                else

                    os.sleep(0.5)
                end

            ------------------------------------------------
            -- Interface currently exposes another fluid
            ------------------------------------------------

            elseif available > 0
                and fluidName
                and fluidName
                    ~= demand.name
            then

                print(
                    "[等待] 接口当前为 "
                    .. tostring(fluidName)
                    .. "，目标为 "
                    .. demand.name
                )

                os.sleep(1)

            ------------------------------------------------
            -- No target fluid available
            ------------------------------------------------

            else

                ------------------------------------------------
                -- No order yet
                ------------------------------------------------

                if not craftStatus then

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

                        os.sleep(1)
                    end

                else

                    local state =
                        getCraftState(
                            craftStatus
                        )

                    ------------------------------------------------
                    -- AE still crafting
                    ------------------------------------------------

                    if state == "running" then

                        os.sleep(1)

                    ------------------------------------------------
                    -- Task finished
                    ------------------------------------------------

                    elseif state == "done" then

                        if not craftDoneAt then

                            craftDoneAt =
                                computer.uptime()

                            print(
                                "[AE] 合成任务已结束，等待接口刷新..."
                            )
                        end

                        local elapsed =
                            computer.uptime()
                            - craftDoneAt

                        if elapsed
                            >= CRAFT_DONE_GRACE
                        then

                            ------------------------------------------------
                            -- AE说任务结束，
                            -- 但接口缓冲过后仍没有足够目标流体。
                            --
                            -- 此时按新的remaining补单。
                            ------------------------------------------------

                            print(
                                string.format(
                                    "[AE] 任务结束后仍缺 %d mB，补单",
                                    remaining
                                )
                            )

                            craftStatus =
                                requestPlasmaSynthesis(
                                    demand.name,
                                    remaining
                                )

                            craftDoneAt = nil

                            if not craftStatus then
                                os.sleep(5)
                            end

                        else

                            os.sleep(1)
                        end

                    ------------------------------------------------
                    -- Failed or canceled
                    ------------------------------------------------

                    elseif state == "failed"
                        or state == "canceled"
                    then

                        print(
                            "[AE] 任务状态: "
                            .. state
                            .. "，重新下单"
                        )

                        os.sleep(2)

                        craftStatus =
                            requestPlasmaSynthesis(
                                demand.name,
                                remaining
                            )

                        craftDoneAt = nil

                    ------------------------------------------------
                    -- Unknown status
                    ------------------------------------------------

                    else

                        local now =
                            computer.uptime()

                        if now
                            - lastUnknownPrint
                            >= UNKNOWN_STATUS_PRINT_INTERVAL
                        then

                            print(
                                "[AE] 无法读取任务状态，继续等待流体..."
                            )

                            lastUnknownPrint =
                                now
                        end

                        ------------------------------------------------
                        -- 注意：
                        -- unknown时不自动重复request，
                        -- 避免任务其实已经在跑却重复下单。
                        ------------------------------------------------

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

    --------------------------------------------------------
    -- Entire round complete
    --------------------------------------------------------

    clearFluidFilter()

    print("")
    print("========================================")
    print("本轮7种等离子体全部输入完成")
    print("等待异化器生成下一轮指示材料")
    print("========================================")
    print("")

    --------------------------------------------------------
    -- 这里绝对不调用clearCacheBuffer()
    --------------------------------------------------------

    return true
end

------------------------------------------------------------
-- Check whether a new indicator round is appearing
------------------------------------------------------------

local function hasPotentialIndicators()

    --------------------------------------------------------
    -- Small non-plasma fluids
    --------------------------------------------------------

    for i = 1, 7 do

        local fluid =
            getFluid(
                sideCacheBuffer,
                i
            )

        if fluid then

            local amount =
                toNumber(
                    fluid.amount
                )

            local name =
                fluid.name or ""

            if amount > 0
                and amount
                    <= INDICATOR_FLUID_MAX
                and not name:match(
                    "^plasma%."
                )
            then
                return true
            end
        end
    end

    --------------------------------------------------------
    -- Dusts
    --------------------------------------------------------

    for i = 1, 7 do

        local item =
            getItem(
                sideCacheBuffer,
                i
            )

        if item then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- Machine enable check
------------------------------------------------------------

local function waitIfMachineDisabled()

    if not gtm then
        return
    end

    local ok, allowed =
        pcall(function()

            return
                gtm.isWorkAllowed()
        end)

    if not ok then
        return
    end

    if allowed then
        return
    end

    print(
        "机器已关闭，等待重新启动..."
    )

    while true do

        os.sleep(5)

        local ok2, state =
            pcall(function()

                return
                    gtm.isWorkAllowed()
            end)

        if ok2 and state then

            print(
                "机器已重新启动"
            )

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

        print(
            "错误：找不到 transposer"
        )

        return
    end

    if not fInterface then

        print(
            "错误：找不到 fluid_interface"
        )

        return
    end

    print("组件检查通过")
    print("等待QGP指示材料...")
    print("")

    --------------------------------------------------------
    -- Main loop
    --------------------------------------------------------

    while true do

        waitIfMachineDisabled()

        ----------------------------------------------------
        -- Wait until at least part of a new round appears
        ----------------------------------------------------

        if hasPotentialIndicators() then

            ------------------------------------------------
            -- 给AE输出子网一点时间，
            -- 避免7种指示物还没全部到齐就清仓。
            ------------------------------------------------

            os.sleep(1)

            local count =
                scanCacheBuffer()

            ------------------------------------------------
            -- Only execute a complete seven-element round
            ------------------------------------------------

            if count
                == EXPECTED_DEMAND_COUNT
            then

                clearScreen()

                print(
                    "=== 检测到完整QGP新一轮 ==="
                )

                print("")

                ------------------------------------------------
                -- 再打印一次完整需求
                ------------------------------------------------

                scanCacheBuffer()

                print("")
                print(
                    "共识别 "
                    .. tostring(
                        #plasmaDemands
                    )
                    .. " 种需求"
                )

                print(
                    "清理本轮指示材料..."
                )

                ------------------------------------------------
                -- 清掉指示物
                ------------------------------------------------

                clearCacheBuffer()

                os.sleep(0.5)

                ------------------------------------------------
                -- Feed plasma
                ------------------------------------------------

                local success =
                    processPlasmaDemands()

                if not success then

                    clearFluidFilter()

                    print(
                        "[错误] 本轮处理异常，5秒后继续"
                    )

                    os.sleep(5)
                end

            else

                ------------------------------------------------
                -- 指示物尚未全部进入缓存仓
                ------------------------------------------------

                print(
                    string.format(
                        "[等待] 当前识别 %d/%d 种指示材料",
                        count,
                        EXPECTED_DEMAND_COUNT
                    )
                )

                ------------------------------------------------
                -- 不清任何东西，继续等完整一轮
                ------------------------------------------------

                os.sleep(1)
            end
        end

        os.sleep(1)
    end
end

------------------------------------------------------------
-- Start with traceback
------------------------------------------------------------

local ok, err =
    xpcall(
        main,
        debug.traceback
    )

------------------------------------------------------------
-- Always clear interface filter on exit/crash
------------------------------------------------------------

clearFluidFilter()

if not ok then

    print("")
    print("========================================")
    print("程序异常退出")
    print("========================================")
    print(tostring(err))
end
