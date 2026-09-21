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

local VERSION = "QGP-AUTO 0.3.2"

------------------------------------------------------------
-- Components
------------------------------------------------------------

local trans = component.transposer
local fInterface = component.fluid_interface
local gtm = component.gt_machine

------------------------------------------------------------
-- Current machine directions
------------------------------------------------------------

local sideCacheBuffer = sides.down      -- 大型原料缓存仓
local sideAEInfusion  = sides.south     -- AE物质聚合器
local sideInterface   = sides.east      -- 主网 Fluid Interface

------------------------------------------------------------
-- QGP parameters
------------------------------------------------------------

local EXPECTED_DEMAND_COUNT = 7
local INDICATOR_FLUID_MAX = 64

-- 指示流体 ×1000 -> 所需等离子
local FLUID_TO_PLASMA = 1000

-- 粉 ×1296 -> 所需等离子
local DUST_TO_PLASMA = 1296

-- AE合成计划最大等待时间
local CRAFT_PLAN_TIMEOUT = 60

-- AE显示任务完成后，等待接口刷新
local CRAFT_DONE_GRACE = 3

-- 状态日志输出间隔
local STATUS_PRINT_INTERVAL = 5

-- AE request最终是int
local MAX_REQUEST_AMOUNT = 2147483647

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
-- Basic helpers
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
-- Safe reads
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
-- Safe fluid transfer
--
-- 解决：
-- attempt to compare number with string
--
-- transferFluid失败时可能返回：
-- nil, "reason"
--
-- 所以绝不能直接：
-- local _, moved = transferFluid(...)
-- if moved > 0 then ...
------------------------------------------------------------

local function transferFluidSafe(
    fromSide,
    toSide,
    amount,
    sourceTank
)
    amount = math.floor(toNumber(amount))

    if amount <= 0 then
        return 0
    end

    local callOk, a, b = pcall(function()
        return trans.transferFluid(
            fromSide,
            toSide,
            amount,
            sourceTank
        )
    end)

    if not callOk then
        print(
            "[转运异常] "
            .. tostring(a)
        )

        return 0
    end

    --------------------------------------------------------
    -- 常见成功：
    -- true, moved
    --------------------------------------------------------

    if a == true then
        local moved =
            tonumber(b)

        if moved then
            return moved
        end

        print(
            "[转运失败] 返回移动量异常: "
            .. tostring(b)
        )

        return 0
    end

    --------------------------------------------------------
    -- 常见失败：
    -- nil/false, "reason"
    --------------------------------------------------------

    if a == nil
        or a == false
    then

        if b ~= nil then
            print(
                "[转运失败] "
                .. tostring(b)
            )
        end

        return 0
    end

    --------------------------------------------------------
    -- 兼容某些版本直接返回number
    --------------------------------------------------------

    if type(a) == "number" then
        return a
    end

    if type(b) == "number" then
        return b
    end

    print(
        "[转运失败] 未知返回值: "
        .. tostring(a)
        .. ", "
        .. tostring(b)
    )

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

    local callOk, a, b = pcall(function()
        return trans.transferItem(
            fromSide,
            toSide,
            amount,
            slot
        )
    end)

    if not callOk then
        print(
            "[物品转运异常] "
            .. tostring(a)
        )

        return 0
    end

    if type(a) == "number" then
        return a
    end

    if a == true
        and type(b) == "number"
    then
        return b
    end

    if a == nil
        or a == false
    then

        if b ~= nil then
            print(
                "[物品转运失败] "
                .. tostring(b)
            )
        end

        return 0
    end

    return tonumber(b) or 0
end

------------------------------------------------------------
-- Fluid -> plasma name
------------------------------------------------------------

local function fluidToPlasma(
    fluidName
)
    if not fluidName then
        return nil
    end

    if fluidName:match(
        "^molten%."
    )
    then
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
    -- GregTech
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
    -- BartWorks
    --------------------------------------------------------

    if item.name
        == "bartworks:gt.bwMetaGenerateddust"
    then

        local mat =
            bartMaterial[
                item.damage
            ]

        if mat then
            return "plasma." .. mat
        end

        return nil
    end

    --------------------------------------------------------
    -- MiscUtils
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

        if mat then
            return
                "plasma."
                .. string.lower(mat)
        end
    end

    return nil
end

------------------------------------------------------------
-- Scan QGP indicators
------------------------------------------------------------

local function scanCacheBuffer(
    verbose
)
    plasmaDemands = {}

    --------------------------------------------------------
    -- Fluids
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
                tostring(
                    fluid.name or ""
                )

            if amount > 0
                and amount
                    <= INDICATOR_FLUID_MAX
                and not name:match(
                    "^plasma%."
                )
            then

                local plasmaName =
                    fluidToPlasma(
                        name
                    )

                if plasmaName then

                    local need =
                        amount
                        * FLUID_TO_PLASMA

                    table.insert(
                        plasmaDemands,
                        {
                            name =
                                plasmaName,

                            amount =
                                need
                        }
                    )

                    if verbose then

                        print(
                            string.format(
                                "流体 %s -> %s × %d mB",
                                fluid.label
                                    or name,
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
    -- Dusts
    --------------------------------------------------------

    for i = 1, 7 do

        local item =
            getItem(
                sideCacheBuffer,
                i
            )

        if item then

            local plasmaName =
                itemToPlasma(
                    item
                )

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
                        name =
                            plasmaName,

                        amount =
                            need
                    }
                )

                if verbose then

                    print(
                        string.format(
                            "物品 %s -> %s × %d mB",
                            item.label
                                or item.name,
                            plasmaName,
                            need
                        )
                    )
                end

            elseif verbose then

                print(
                    "[无法识别物品] "
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
-- Validate cache before deleting indicators
------------------------------------------------------------

local function validateIndicatorCache()

    for i = 1, 7 do

        local fluid =
            getFluid(
                sideCacheBuffer,
                i
            )

        if fluid
            and toNumber(
                fluid.amount
            ) > 0
        then

            local amount =
                toNumber(
                    fluid.amount
                )

            local name =
                tostring(
                    fluid.name or ""
                )

            if name:match(
                "^plasma%."
            )
            then

                return false,
                    "缓存仓中仍有等离子体: "
                    .. name
                    .. " × "
                    .. tostring(
                        amount
                    )
                    .. " mB"
            end

            if amount
                > INDICATOR_FLUID_MAX
            then

                return false,
                    "缓存仓出现非指示大流体: "
                    .. name
                    .. " × "
                    .. tostring(
                        amount
                    )
                    .. " mB"
            end
        end
    end

    for i = 1, 7 do

        local item =
            getItem(
                sideCacheBuffer,
                i
            )

        if item
            and not itemToPlasma(
                item
            )
        then

            return false,
                "缓存仓出现未知物品: "
                .. tostring(
                    item.label
                        or item.name
                )
        end
    end

    return true
end

------------------------------------------------------------
-- Clear current QGP indicator materials
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
            and toNumber(
                fluid.amount
            ) > 0
        then

            local expected =
                toNumber(
                    fluid.amount
                )

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
                        tostring(
                            fluid.name
                        ),
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
                toNumber(
                    item.size
                )

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
                            item.label
                                or item.name
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

local function setFluidFilter(
    fluidName
)
    local ok, err =
        pcall(function()

            fInterface
                .setFluidInterfaceConfiguration(
                    0,
                    {
                        name =
                            fluidName
                    }
                )
        end)

    if not ok then

        print(
            "[接口] 设置过滤器失败: "
            .. tostring(
                fluidName
            )
            .. " ("
            .. tostring(
                err
            )
            .. ")"
        )

        return false
    end

    return true
end

local function clearFluidFilter()

    pcall(function()

        fInterface
            .setFluidInterfaceConfiguration(
                0
            )
    end)
end

------------------------------------------------------------
-- AE crafting request
--
-- amount就是最终仍缺少的plasma数量。
--
-- 不识别样板倍率。
-- 不计算配方次数。
-- 直接交给AE crafting planner。
------------------------------------------------------------

local function requestPlasmaSynthesis(
    plasmaName,
    amount
)
    amount =
        math.floor(
            tonumber(
                amount
            )
            or 1
        )

    if amount < 1 then
        amount = 1
    end

    if amount
        > MAX_REQUEST_AMOUNT
    then
        amount =
            MAX_REQUEST_AMOUNT
    end

    print(
        "[下单] 查找: "
        .. plasmaName
        .. " × "
        .. tostring(
            amount
        )
        .. " mB"
    )

    --------------------------------------------------------
    -- 已经验证可用的查询方式
    --------------------------------------------------------

    local ok, craftables =
        pcall(function()

            return
                fInterface.getCraftables(
                    {
                        name =
                            plasmaName
                    }
                )
        end)

    if not ok then

        print(
            "[下单] 查询失败: "
            .. tostring(
                craftables
            )
        )

        return nil
    end

    if type(craftables)
        ~= "table"
        or not craftables[1]
    then

        print(
            "[下单] 未找到配方: "
            .. plasmaName
        )

        return nil
    end

    print(
        "[下单] 找到配方，开始计算..."
    )

    --------------------------------------------------------
    -- 直接请求当前缺口
    --------------------------------------------------------

    local reqOk, status =
        pcall(function()

            return
                craftables[1]
                    .request(
                        amount,
                        true
                    )
        end)

    if not reqOk then

        print(
            "[下单] request异常: "
            .. tostring(
                status
            )
        )

        return nil
    end

    if not status then

        print(
            "[下单] 没有任务对象"
        )

        return nil
    end

    --------------------------------------------------------
    -- 等AE真正完成crafting plan
    --------------------------------------------------------

    for i = 1,
        CRAFT_PLAN_TIMEOUT
    do

        local okDone,
            done,
            doneInfo =
            pcall(function()

                return
                    status.isDone()
            end)

        local okCancel,
            canceled,
            cancelInfo =
            pcall(function()

                return
                    status.isCanceled()
            end)

        if okCancel
            and canceled
        then

            print(
                "[下单] 请求失败/取消: "
                .. tostring(
                    cancelInfo
                )
            )

            return nil
        end

        local computing =
            (
                okDone
                and doneInfo
                    == "computing"
            )
            or
            (
                okCancel
                and cancelInfo
                    == "computing"
            )

        ----------------------------------------------------
        -- 不再处于computing阶段
        ----------------------------------------------------

        if not computing then

            if okDone
                and done
            then

                print(
                    "[下单] 任务已快速完成: "
                    .. plasmaName
                )

            else

                print(
                    "[下单] 已真正提交到CPU: "
                    .. plasmaName
                    .. " × "
                    .. tostring(
                        amount
                    )
                    .. " mB"
                )
            end

            return status
        end

        if i % 5 == 0 then

            print(
                "[下单] AE正在计算配方... "
                .. tostring(i)
                .. "s"
            )
        end

        os.sleep(1)
    end

    print(
        "[下单] 配方计算超时"
    )

    return nil
end

------------------------------------------------------------
-- Check AE task state
------------------------------------------------------------

local function getCraftState(
    status
)
    if not status then
        return "none"
    end

    local okCancel,
        canceled,
        cancelInfo =
        pcall(function()

            return
                status.isCanceled()
        end)

    if okCancel
        and canceled
    then

        return
            "canceled",
            cancelInfo
    end

    local okDone,
        done,
        doneInfo =
        pcall(function()

            return
                status.isDone()
        end)

    if okDone then

        if doneInfo
            == "computing"
        then

            return
                "computing",
                doneInfo
        end

        if done then

            return
                "done",
                doneInfo
        end

        return
            "running",
            doneInfo
    end

    if okCancel
        and cancelInfo
            == "computing"
    then

        return
            "computing",
            cancelInfo
    end

    return "unknown"
end

------------------------------------------------------------
-- Process all seven plasma requirements
------------------------------------------------------------

local function processPlasmaDemands()

    for index, demand
        in ipairs(
            plasmaDemands
        )
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

            return false
        end

        os.sleep(0.5)

        local remaining =
            math.floor(
                toNumber(
                    demand.amount
                )
            )

        local craftStatus =
            nil

        local craftDoneAt =
            nil

        local lastStatusPrint =
            0

        ----------------------------------------------------
        -- Feed until exact requirement is satisfied
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
                    toNumber(
                        fluid.amount
                    )

                fluidName =
                    fluid.name
            end

            ------------------------------------------------
            -- Correct target plasma available
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

                ------------------------------------------------
                -- 关键：
                -- 这里不再直接读取第二返回值然后和0比较。
                ------------------------------------------------

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
                            "已抽取 %d mB，剩余需求 %d mB",
                            moved,
                            remaining
                        )
                    )

                    os.sleep(0.1)

                else

                    os.sleep(0.5)
                end

            ------------------------------------------------
            -- Interface currently exposes previous fluid
            ------------------------------------------------

            elseif available > 0
                and fluidName
                and fluidName
                    ~= demand.name
            then

                local now =
                    computer.uptime()

                if now
                    - lastStatusPrint
                    >= STATUS_PRINT_INTERVAL
                then

                    print(
                        "[接口] 当前为 "
                        .. tostring(
                            fluidName
                        )
                        .. "，等待 "
                        .. demand.name
                    )

                    lastStatusPrint =
                        now
                end

                os.sleep(0.5)

            ------------------------------------------------
            -- Interface has no target plasma
            ------------------------------------------------

            else

                ------------------------------------------------
                -- No active request
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

                    craftDoneAt =
                        nil

                    if not craftStatus then

                        print(
                            "[下单] 本次失败，5秒后重试"
                        )

                        os.sleep(5)

                    else

                        os.sleep(0.5)
                    end

                ------------------------------------------------
                -- Existing AE request
                ------------------------------------------------

                else

                    local state,
                        reason =
                        getCraftState(
                            craftStatus
                        )

                    local now =
                        computer.uptime()

                    --------------------------------------------
                    -- Still calculating
                    --------------------------------------------

                    if state
                        == "computing"
                    then

                        if now
                            - lastStatusPrint
                            >= STATUS_PRINT_INTERVAL
                        then

                            print(
                                "[AE] 正在计算合成计划..."
                            )

                            lastStatusPrint =
                                now
                        end

                        os.sleep(0.5)

                    --------------------------------------------
                    -- CPU is working
                    --------------------------------------------

                    elseif state
                        == "running"
                    then

                        if now
                            - lastStatusPrint
                            >= STATUS_PRINT_INTERVAL
                        then

                            print(
                                string.format(
                                    "[AE] 合成中，仍需 %d mB",
                                    remaining
                                )
                            )

                            lastStatusPrint =
                                now
                        end

                        os.sleep(0.5)

                    --------------------------------------------
                    -- Task completed
                    --------------------------------------------

                    elseif state
                        == "done"
                    then

                        if not craftDoneAt then

                            craftDoneAt =
                                now

                            print(
                                "[AE] 合成任务完成，等待接口刷新..."
                            )
                        end

                        if now
                            - craftDoneAt
                            >= CRAFT_DONE_GRACE
                        then

                            print(
                                string.format(
                                    "[AE] 任务结束后仍缺 %d mB，重新补单",
                                    remaining
                                )
                            )

                            craftStatus =
                                nil

                            craftDoneAt =
                                nil

                        else

                            os.sleep(0.5)
                        end

                    --------------------------------------------
                    -- Canceled
                    --------------------------------------------

                    elseif state
                        == "canceled"
                    then

                        print(
                            "[AE] 任务已取消: "
                            .. tostring(
                                reason
                            )
                        )

                        craftStatus =
                            nil

                        craftDoneAt =
                            nil

                        os.sleep(2)

                    --------------------------------------------
                    -- Unknown
                    --------------------------------------------

                    else

                        if now
                            - lastStatusPrint
                            >= STATUS_PRINT_INTERVAL
                        then

                            print(
                                "[AE] 无法读取任务状态，继续等待..."
                            )

                            lastStatusPrint =
                                now
                        end

                        -- 不重复下单
                        os.sleep(1)
                    end
                end
            end
        end

        ----------------------------------------------------
        -- Current plasma done
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

    print(
        "========================================"
    )

    print(
        "本轮7种等离子体全部输入完成"
    )

    print(
        "等待异化器生成下一轮指示材料"
    )

    print(
        "========================================"
    )

    print("")

    --------------------------------------------------------
    -- 注意：
    -- 此处绝对不能clearCacheBuffer()
    --------------------------------------------------------

    return true
end

------------------------------------------------------------
-- Detect potential new QGP round
------------------------------------------------------------

local function hasPotentialIndicators()

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
                tostring(
                    fluid.name or ""
                )

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

    for i = 1, 7 do

        local item =
            getItem(
                sideCacheBuffer,
                i
            )

        if item
            and itemToPlasma(
                item
            )
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

            return
                gtm.isWorkAllowed()
        end)

    if not ok
        or allowed
    then
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

        if ok2
            and state
        then

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
            "错误：未找到 transposer"
        )

        return
    end

    if not fInterface then

        print(
            "错误：未找到 fluid_interface"
        )

        return
    end

    print(
        "组件检查通过"
    )

    print("")

    print(
        "缓存仓方向 : DOWN"
    )

    print(
        "物质聚合器 : SOUTH"
    )

    print(
        "Fluid接口  : EAST"
    )

    print("")

    print(
        "等待QGP新一轮指示材料..."
    )

    print("")

    local lastPartialCount =
        -1

    --------------------------------------------------------
    -- Main loop
    --------------------------------------------------------

    while true do

        waitIfMachineDisabled()

        if hasPotentialIndicators()
        then

            ------------------------------------------------
            -- First silent scan
            ------------------------------------------------

            local count =
                scanCacheBuffer(
                    false
                )

            ------------------------------------------------
            -- Complete 7/7 round
            ------------------------------------------------

            if count
                == EXPECTED_DEMAND_COUNT
            then

                ------------------------------------------------
                -- 再等0.5秒确认输出已经稳定
                ------------------------------------------------

                os.sleep(0.5)

                local count2 =
                    scanCacheBuffer(
                        false
                    )

                if count2
                    == EXPECTED_DEMAND_COUNT
                then

                    ------------------------------------------------
                    -- Safety check
                    ------------------------------------------------

                    local valid,
                        reason =
                        validateIndicatorCache()

                    if not valid then

                        print(
                            "[保护] "
                            .. tostring(
                                reason
                            )
                        )

                        print(
                            "[保护] 不清仓，请检查输出分流。"
                        )

                        os.sleep(5)

                    else

                        clearScreen()

                        print(
                            "=== 检测到完整QGP新一轮 ==="
                        )

                        print("")

                        ------------------------------------------------
                        -- Print complete requirements
                        ------------------------------------------------

                        scanCacheBuffer(
                            true
                        )

                        print("")

                        print(
                            string.format(
                                "共识别 %d/%d 种需求",
                                #plasmaDemands,
                                EXPECTED_DEMAND_COUNT
                            )
                        )

                        print("")

                        ------------------------------------------------
                        -- Remove indicator materials
                        ------------------------------------------------

                        print(
                            "清理本轮指示材料..."
                        )

                        if not clearCacheBuffer()
                        then

                            print(
                                "[严重] 指示材料未完全清理"
                            )

                            print(
                                "停止程序，避免错误输入。"
                            )

                            return
                        end

                        print(
                            "指示材料清理完成"
                        )

                        os.sleep(0.5)

                        ------------------------------------------------
                        -- Feed plasma
                        ------------------------------------------------

                        if not processPlasmaDemands()
                        then

                            clearFluidFilter()

                            print(
                                "[错误] 本轮处理失败"
                            )

                            os.sleep(5)
                        end

                        lastPartialCount =
                            -1
                    end
                end

            ------------------------------------------------
            -- Not all seven indicators have arrived yet
            ------------------------------------------------

            elseif count
                ~= lastPartialCount
            then

                print(
                    string.format(
                        "[等待] 当前识别 %d/%d 种指示材料",
                        count,
                        EXPECTED_DEMAND_COUNT
                    )
                )

                lastPartialCount =
                    count
            end

        else

            lastPartialCount =
                -1
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
-- Always clear interface filter on exit/crash
------------------------------------------------------------

clearFluidFilter()

if not ok then

    print("")

    print(
        "========================================"
    )

    print(
        "程序异常退出"
    )

    print(
        "========================================"
    )

    print(
        tostring(err)
    )
end
