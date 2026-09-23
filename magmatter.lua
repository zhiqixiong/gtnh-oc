------------------------------------------------------------
-- GTNH God Forge
-- Magmatter Automation
--
-- GTNH 2.9.x / OpenComputers
--
-- 工作流程：
--
--   1. 等待缓存仓出现：
--        - 1 个材料粉
--        - 2 种时空流体
--
--   2. 根据两种流体数量计算 plasma 需求：
--
--        abs(fluidA - fluidB) * 144
--
--   3. 粉只作为材料种类指示物，送入物质聚合器
--
--   4. 两种时空流体留在缓存仓，不清除
--
--   5. 从 AE 精确抽取所需 plasma
--
--   6. AE 不足时直接：
--
--        request(remaining, true)
--
--      样板倍率由 AE 自己处理
------------------------------------------------------------

local os = require("os")
local component = require("component")
local sides = require("sides")
local term = require("term")
local computer = require("computer")

------------------------------------------------------------
-- Version
------------------------------------------------------------

local VERSION = "MAGMATTER-AUTO 0.1.0"

------------------------------------------------------------
-- Components
------------------------------------------------------------

local trans = component.transposer
local fi = component.fluid_interface
local gtm = component.gt_machine

------------------------------------------------------------
-- Transposer sides
--
-- 当前按照你提供的磁物质源码
------------------------------------------------------------

-- 大型原料缓存仓
local sideCacheBuffer = sides.down

-- AE物质聚合器
-- 只负责销毁材料粉
local sideAEInfusion = sides.south

-- 主网 Fluid Interface
-- 用于选择和抽取目标 plasma
local sideInterface = sides.east

------------------------------------------------------------
-- Parameters
------------------------------------------------------------

-- 两种时空流体差值 -> plasma
local PLASMA_MULTIPLIER = 144

-- AE crafting plan 最大等待时间
local CRAFT_PLAN_TIMEOUT = 60

-- AE任务结束以后给接口的刷新时间
local CRAFT_DONE_GRACE = 3

-- 日志输出间隔
local STATUS_PRINT_INTERVAL = 5

-- request底层数量上限
local MAX_REQUEST_AMOUNT = 2147483647

------------------------------------------------------------
-- GT Material Mapping
--
-- damage -> plasma material name
------------------------------------------------------------

local GTMaterial = {
    [2129] = "Neutronium",          -- 中子
    [0]    = "Draconium",           -- 龙
    [2976] = "DraconiumAwakened",   -- 觉醒龙
    [2978] = "Ichorium",            -- 灵宝
    [2982] = "CosmicNeutronium",    -- 黑中子
    [2984] = "Flerovium_GT5U",      -- 鈇
    [2397] = "Infinity",            -- 无尽
    [2329] = "Tritanium",           -- 三钛
    [2395] = "Bedrockium"           -- 基岩
}

------------------------------------------------------------
-- Basic helpers
------------------------------------------------------------

local function toNumber(value)
    return tonumber(value) or 0
end

local function clearScreen()
    term.clear()
    term.setCursor(1, 1)

    print("========================================")
    print(VERSION)
    print("God Forge Magmatter Automation")
    print("========================================")
    print("")
end

------------------------------------------------------------
-- Safe fluid read
------------------------------------------------------------

local function getFluid(side, tank)
    local ok, result = pcall(function()
        return trans.getFluidInTank(
            side,
            tank
        )
    end)

    if not ok then
        return nil
    end

    return result
end

------------------------------------------------------------
-- Safe item read
------------------------------------------------------------

local function getItem(side, slot)
    local ok, result = pcall(function()
        return trans.getStackInSlot(
            side,
            slot
        )
    end)

    if not ok then
        return nil
    end

    return result
end

------------------------------------------------------------
-- Safe fluid transfer
--
-- 防止：
--
--   attempt to compare number with string
--
-- transferFluid失败时可能把错误信息作为返回值。
-- 本函数对外永远只返回数字。
------------------------------------------------------------

local function transferFluidSafe(
    fromSide,
    toSide,
    amount,
    sourceTank
)
    amount = math.floor(
        toNumber(amount)
    )

    if amount <= 0 then
        return 0
    end

    local callOk, a, b =
        pcall(function()

            return trans.transferFluid(
                fromSide,
                toSide,
                amount,
                sourceTank
            )
        end)

    --------------------------------------------------------
    -- Lua/API调用本身异常
    --------------------------------------------------------

    if not callOk then
        print(
            "[流体转运异常] "
            .. tostring(a)
        )

        return 0
    end

    --------------------------------------------------------
    -- 常见格式：
    -- true, moved
    --------------------------------------------------------

    if a == true then
        if type(b) == "number" then
            return b
        end

        print(
            "[流体转运失败] "
            .. tostring(b)
        )

        return 0
    end

    --------------------------------------------------------
    -- 兼容直接返回 moved
    --------------------------------------------------------

    if type(a) == "number" then
        return a
    end

    if type(b) == "number" then
        return b
    end

    --------------------------------------------------------
    -- nil/false + reason
    --------------------------------------------------------

    if b ~= nil then
        print(
            "[流体转运失败] "
            .. tostring(b)
        )
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
    amount = math.floor(
        toNumber(amount)
    )

    if amount <= 0 then
        return 0
    end

    local callOk, a, b =
        pcall(function()

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

    if type(b) == "number" then
        return b
    end

    if b ~= nil then
        print(
            "[物品转运失败] "
            .. tostring(b)
        )
    end

    return 0
end

------------------------------------------------------------
-- Resolve dust -> plasma material
------------------------------------------------------------

local function getPlasmaName(item)

    if not item then
        return nil
    end

    --------------------------------------------------------
    -- GT++ / MiscUtils dust
    --
    -- 例如：
    -- miscutils:itemDustHypogen
    -- ->
    -- hypogen
    --------------------------------------------------------

    if item.name
        and item.name:find(
            "miscutils:itemDust",
            1,
            true
        )
    then

        local mat =
            item.name:match(
                "^miscutils:itemDust(.+)$"
            )

        if mat
            and mat ~= ""
        then
            return string.lower(mat)
        end
    end

    --------------------------------------------------------
    -- GT mapped material
    --------------------------------------------------------

    local damage =
        tonumber(item.damage)

    local mat =
        GTMaterial[damage]

    if mat then
        return string.lower(mat)
    end

    return nil
end

------------------------------------------------------------
-- Fluid Interface filter
------------------------------------------------------------

local function setPlasmaFilter(
    materialName
)
    local fullName =
        "plasma."
        .. materialName

    local ok, err =
        pcall(function()

            fi.setFluidInterfaceConfiguration(
                0,
                {
                    name = fullName
                }
            )
        end)

    if not ok then
        print(
            "[接口] 设置过滤器失败: "
            .. fullName
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

local function clearPlasmaFilter()
    pcall(function()

        fi.setFluidInterfaceConfiguration(
            0
        )
    end)
end

------------------------------------------------------------
-- Remove material indicator dust
--
-- 注意：
--
-- 这里只清 SLOT 1 的 1 个材料粉。
--
-- 两个时空流体绝对不清。
------------------------------------------------------------

local function clearIndicatorDust()

    local item =
        getItem(
            sideCacheBuffer,
            1
        )

    if not item then
        print(
            "[错误] 材料粉已经不存在"
        )

        return false
    end

    local moved =
        transferItemSafe(
            sideCacheBuffer,
            sideAEInfusion,
            1,
            1
        )

    if moved < 1 then
        print(
            "[错误] 无法清理材料粉: "
            .. tostring(
                item.label
                    or item.name
            )
        )

        return false
    end

    print(
        "已清理材料指示粉: "
        .. tostring(
            item.label
                or item.name
        )
    )

    return true
end

------------------------------------------------------------
-- AE crafting request
--
-- amount：
--   当前真正还缺多少 plasma
--
-- 直接 request(amount)
--
-- 不识别样板倍率
-- 不计算配方次数
------------------------------------------------------------

local function requestPlasmaSynthesis(
    materialName,
    amount
)
    amount =
        math.floor(
            tonumber(amount)
            or 0
        )

    if amount <= 0 then
        return nil
    end

    if amount
        > MAX_REQUEST_AMOUNT
    then
        amount =
            MAX_REQUEST_AMOUNT
    end

    local fullName =
        "plasma."
        .. materialName

    print(
        "[下单] 查找: "
        .. fullName
        .. " × "
        .. tostring(amount)
        .. " mB"
    )

    --------------------------------------------------------
    -- 查询AE craftable
    --------------------------------------------------------

    local ok, craftables =
        pcall(function()

            return fi.getCraftables({
                name = fullName
            })
        end)

    if not ok then
        print(
            "[下单] 查询失败: "
            .. tostring(craftables)
        )

        return nil
    end

    if type(craftables)
        ~= "table"
        or not craftables[1]
    then
        print(
            "[下单] 未找到配方: "
            .. fullName
        )

        return nil
    end

    print(
        "[下单] 找到配方，开始计算..."
    )

    --------------------------------------------------------
    -- 直接请求最终目标量
    --------------------------------------------------------

    local reqOk, status =
        pcall(function()

            return craftables[1].request(
                amount,
                true
            )
        end)

    if not reqOk then
        print(
            "[下单] request异常: "
            .. tostring(status)
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
    -- 等待 AE crafting plan 计算完成
    --------------------------------------------------------

    for i = 1,
        CRAFT_PLAN_TIMEOUT
    do

        local okDone,
            done,
            doneInfo =
            pcall(function()

                return status.isDone()
            end)

        local okCancel,
            canceled,
            cancelInfo =
            pcall(function()

                return status.isCanceled()
            end)

        ----------------------------------------------------
        -- Cancelled
        ----------------------------------------------------

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

        ----------------------------------------------------
        -- AE still calculating
        ----------------------------------------------------

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
        -- 已退出 computing 阶段
        ----------------------------------------------------

        if not computing then

            if okDone
                and done
            then
                print(
                    "[下单] 任务已快速完成: "
                    .. fullName
                )

            else
                print(
                    "[下单] 已真正提交到CPU: "
                    .. fullName
                    .. " × "
                    .. tostring(amount)
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
-- Get current crafting state
------------------------------------------------------------

local function getCraftState(
    status
)
    if not status then
        return "none"
    end

    --------------------------------------------------------
    -- canceled
    --------------------------------------------------------

    local okCancel,
        canceled,
        cancelInfo =
        pcall(function()

            return status.isCanceled()
        end)

    if okCancel
        and canceled
    then
        return
            "canceled",
            cancelInfo
    end

    --------------------------------------------------------
    -- done / computing / running
    --------------------------------------------------------

    local okDone,
        done,
        doneInfo =
        pcall(function()

            return status.isDone()
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

    --------------------------------------------------------
    -- isCanceled也可能返回computing
    --------------------------------------------------------

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
-- Feed exact plasma amount
------------------------------------------------------------

local function feedPlasma(
    materialName,
    requiredAmount
)
    requiredAmount =
        math.floor(
            toNumber(
                requiredAmount
            )
        )

    if requiredAmount <= 0 then
        print(
            "[错误] Plasma需求量为0"
        )

        return false
    end

    local fullName =
        "plasma."
        .. materialName

    --------------------------------------------------------
    -- Select Fluid Interface target
    --------------------------------------------------------

    if not setPlasmaFilter(
        materialName
    )
    then
        return false
    end

    os.sleep(0.5)

    local remaining =
        requiredAmount

    local craftStatus =
        nil

    local craftDoneAt =
        nil

    local lastStatusPrint =
        0

    --------------------------------------------------------
    -- Feed until exact amount reached
    --------------------------------------------------------

    while remaining > 0 do

        local tank =
            getFluid(
                sideInterface,
                1
            )

        local available = 0
        local fluidName = nil

        if tank then
            available =
                toNumber(
                    tank.amount
                )

            fluidName =
                tank.name
        end

        ----------------------------------------------------
        -- Correct target plasma available
        ----------------------------------------------------

        if available > 0
            and fluidName
                == fullName
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
                        "已输入 %d mB，剩余 %d mB",
                        moved,
                        remaining
                    )
                )

                os.sleep(0.1)

            else

                os.sleep(0.5)
            end

        ----------------------------------------------------
        -- Interface still contains wrong/previous fluid
        ----------------------------------------------------

        elseif available > 0
            and fluidName
            and fluidName
                ~= fullName
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
                    .. fullName
                )

                lastStatusPrint =
                    now
            end

            os.sleep(0.5)

        ----------------------------------------------------
        -- No target plasma currently available
        ----------------------------------------------------

        else

            ------------------------------------------------
            -- No AE request yet
            ------------------------------------------------

            if not craftStatus then

                print(
                    "接口无目标流体，尝试下单..."
                )

                craftStatus =
                    requestPlasmaSynthesis(
                        materialName,
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
                -- Planning
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
                -- Crafting
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
                -- Done
                --------------------------------------------

                elseif state
                    == "done"
                then

                    if not craftDoneAt then
                        craftDoneAt =
                            now

                        print(
                            "[AE] 合成完成，等待接口刷新..."
                        )
                    end

                    if now
                        - craftDoneAt
                        >= CRAFT_DONE_GRACE
                    then

                        ------------------------------------------------
                        -- 任务做完但仍缺流体
                        -- 按新的remaining重新请求
                        ------------------------------------------------

                        print(
                            string.format(
                                "[AE] 仍缺 %d mB，重新补单",
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
                        "[AE] 任务取消: "
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

                    -- unknown不重复下单
                    os.sleep(1)
                end
            end
        end
    end

    --------------------------------------------------------
    -- Exact amount delivered
    --------------------------------------------------------

    clearPlasmaFilter()

    print(
        fullName
        .. " 输入完成"
    )

    return true
end

------------------------------------------------------------
-- Check whether a complete new round exists
------------------------------------------------------------

local function getRoundInput()

    local item =
        getItem(
            sideCacheBuffer,
            1
        )

    if not item then
        return nil
    end

    local fluidA =
        getFluid(
            sideCacheBuffer,
            1
        )

    local fluidB =
        getFluid(
            sideCacheBuffer,
            2
        )

    --------------------------------------------------------
    -- 材料粉已经来了，但两个流体尚未全部到齐
    --------------------------------------------------------

    if not fluidA
        or not fluidB
    then
        return nil
    end

    local amountA =
        toNumber(
            fluidA.amount
        )

    local amountB =
        toNumber(
            fluidB.amount
        )

    if amountA <= 0
        or amountB <= 0
    then
        return nil
    end

    --------------------------------------------------------
    -- Resolve target material
    --------------------------------------------------------

    local materialName =
        getPlasmaName(
            item
        )

    if not materialName then

        return {
            error =
                "未知材料粉: "
                .. tostring(
                    item.label
                        or item.name
                )
                .. " damage="
                .. tostring(
                    item.damage
                )
        }
    end

    --------------------------------------------------------
    -- Calculate plasma requirement
    --------------------------------------------------------

    local required =
        math.abs(
            amountA
            - amountB
        )
        * PLASMA_MULTIPLIER

    return {
        item = item,

        fluidA = fluidA,
        fluidB = fluidB,

        amountA = amountA,
        amountB = amountB,

        materialName =
            materialName,

        plasmaName =
            "plasma."
            .. materialName,

        required =
            required
    }
end

------------------------------------------------------------
-- Process one Magmatter round
------------------------------------------------------------

local function processRound(round)

    clearScreen()

    print(
        "=== 检测到新的磁物质配方 ==="
    )

    print("")

    --------------------------------------------------------
    -- Print indicator information
    --------------------------------------------------------

    print(
        "材料粉: "
        .. tostring(
            round.item.label
                or round.item.name
        )
    )

    print(
        string.format(
            "流体A: %s × %d",
            tostring(
                round.fluidA.label
                    or round.fluidA.name
            ),
            round.amountA
        )
    )

    print(
        string.format(
            "流体B: %s × %d",
            tostring(
                round.fluidB.label
                    or round.fluidB.name
            ),
            round.amountB
        )
    )

    print("")

    print(
        "目标流体: "
        .. round.plasmaName
    )

    print(
        "需求量: "
        .. tostring(
            round.required
        )
        .. " mB"
    )

    print("")

    --------------------------------------------------------
    -- Protect against impossible zero requirement
    --------------------------------------------------------

    if round.required <= 0 then

        print(
            "[错误] 两种流体数量相同，计算出的Plasma需求为0"
        )

        return false
    end

    --------------------------------------------------------
    -- IMPORTANT:
    --
    -- 这里只销毁1个材料粉。
    --
    -- 两种时空流体必须留在缓存仓里。
    --------------------------------------------------------

    if not clearIndicatorDust() then

        print(
            "[错误] 材料粉清理失败"
        )

        return false
    end

    os.sleep(0.5)

    --------------------------------------------------------
    -- Feed exact plasma amount
    --------------------------------------------------------

    if not feedPlasma(
        round.materialName,
        round.required
    )
    then

        print(
            "[错误] Plasma输入失败"
        )

        return false
    end

    --------------------------------------------------------
    -- Round complete
    --------------------------------------------------------

    print("")

    print(
        "========================================"
    )

    print(
        "本轮磁物质输入完成"
    )

    print(
        "保留两种时空流体，等待异化器运行"
    )

    print(
        "========================================"
    )

    print("")

    --------------------------------------------------------
    -- 这里：
    --
    -- 不清缓存仓
    -- 不清两个流体
    -- 不等待progress
    --
    -- 下一轮由新的材料粉作为触发条件。
    --------------------------------------------------------

    return true
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

    if not ok
        or allowed
    then
        return
    end

    print(
        "机器已关闭，等待启动..."
    )

    while true do

        os.sleep(5)

        local ok2, state =
            pcall(function()

                return gtm.isWorkAllowed()
            end)

        if ok2
            and state
        then

            print(
                "机器已启动"
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

    if not fi then
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
        "缓存仓方向 : WEST"
    )

    print(
        "物质聚合器 : SOUTH"
    )

    print(
        "Fluid接口  : DOWN"
    )

    print("")

    print(
        "等待新的磁物质材料指示..."
    )

    print("")

    local lastWaitingPrint =
        0

    --------------------------------------------------------
    -- Main loop
    --------------------------------------------------------

    while true do

        waitIfMachineDisabled()

        local item =
            getItem(
                sideCacheBuffer,
                1
            )

        ----------------------------------------------------
        -- Dust appeared -> potential new round
        ----------------------------------------------------

        if item then

            local round =
                getRoundInput()

            ------------------------------------------------
            -- Full round ready
            ------------------------------------------------

            if round
                and not round.error
            then

                ------------------------------------------------
                -- 等0.5秒，再读取一次
                -- 避免输出正在变化时抢跑
                ------------------------------------------------

                os.sleep(0.5)

                local confirmed =
                    getRoundInput()

                if confirmed
                    and not confirmed.error
                then

                    processRound(
                        confirmed
                    )
                end

            ------------------------------------------------
            -- Unknown material
            ------------------------------------------------

            elseif round
                and round.error
            then

                print(
                    "[严重] "
                    .. tostring(
                        round.error
                    )
                )

                print(
                    "程序停止，避免输入错误Plasma。"
                )

                clearPlasmaFilter()

                return

            ------------------------------------------------
            -- Dust arrived but fluids not ready
            ------------------------------------------------

            else

                local now =
                    computer.uptime()

                if now
                    - lastWaitingPrint
                    >= STATUS_PRINT_INTERVAL
                then

                    print(
                        "[等待] 材料粉已到，等待两种时空流体..."
                    )

                    lastWaitingPrint =
                        now
                end
            end
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
-- Always clear Fluid Interface filter on exit
------------------------------------------------------------

clearPlasmaFilter()

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
