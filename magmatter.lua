------------------------------------------------------------
-- GTNH God Forge
-- Magmatter Automation
--
-- GTNH 2.9.x / OpenComputers
--
-- Hardware layout:
--
--   DOWN  : Large Input Cache / 大型原料缓存仓
--   SOUTH : AE Matter Condenser / 物质聚合器
--   EAST  : Main AE Fluid Interface
--
-- Magmatter round:
--
--   1 dust + 2 spacetime fluids
--          ↓
--   identify material
--          ↓
--   plasmaNeed = abs(spatial - temporal) * 144
--          ↓
--   destroy ONLY the dust
--          ↓
--   keep the two spacetime fluids
--          ↓
--   supply exact plasma amount
------------------------------------------------------------

local os = require("os")
local component = require("component")
local sides = require("sides")
local term = require("term")
local computer = require("computer")

------------------------------------------------------------
-- Version
------------------------------------------------------------

local VERSION = "MAGMATTER-AUTO 0.1.1"

------------------------------------------------------------
-- Components
------------------------------------------------------------

local trans = component.transposer
local fi = component.fluid_interface
local gtm = component.gt_machine

------------------------------------------------------------
-- Sides
--
-- 与QGP机器采用相同摆法
------------------------------------------------------------

local sideCacheBuffer = sides.down
local sideAEInfusion  = sides.south
local sideInterface   = sides.east

------------------------------------------------------------
-- Parameters
------------------------------------------------------------

-- 两种时空流体差值 × 144
local PLASMA_MULTIPLIER = 144

-- 时间流体数量区间
local TEMPORAL_MIN = 1
local TEMPORAL_MAX = 50

-- 空间流体数量区间
local SPATIAL_MIN = 51
local SPATIAL_MAX = 100

-- 扫描缓存仓流体槽数量
local MAX_FLUID_TANK_SCAN = 16

-- AE crafting plan等待时间
local CRAFT_PLAN_TIMEOUT = 60

-- AE任务结束后等待接口刷新
local CRAFT_DONE_GRACE = 3

-- 日志输出间隔
local STATUS_PRINT_INTERVAL = 5

-- request底层整数上限
local MAX_REQUEST_AMOUNT = 2147483647

------------------------------------------------------------
-- GT Material Mapping
--
-- damage -> plasma material
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
    print("God Forge Magmatter Automation")
    print("========================================")
    print("")
end

------------------------------------------------------------
-- Safe reads
------------------------------------------------------------

local function getFluid(side, tank)

    local ok, result =
        pcall(function()

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

local function getItem(side, slot)

    local ok, result =
        pcall(function()

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
-- 外部永远只得到数字。
--
-- 避免之前出现的：
-- attempt to compare number with string
------------------------------------------------------------

local function transferFluidSafe(
    fromSide,
    toSide,
    amount,
    sourceTank
)

    amount =
        math.floor(
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
    -- API调用异常
    --------------------------------------------------------

    if not callOk then

        print(
            "[流体转运异常] "
            .. tostring(a)
        )

        return 0
    end

    --------------------------------------------------------
    -- true, moved
    --------------------------------------------------------

    if a == true then

        local moved =
            tonumber(b)

        if moved then
            return moved
        end

        print(
            "[流体转运失败] "
            .. tostring(b)
        )

        return 0
    end

    --------------------------------------------------------
    -- 直接返回 moved
    --------------------------------------------------------

    if type(a) == "number" then
        return a
    end

    if type(b) == "number" then
        return b
    end

    --------------------------------------------------------
    -- nil/false, reason
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

    amount =
        math.floor(
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
-- Dust -> plasma material name
------------------------------------------------------------

local function getPlasmaName(item)

    if not item then
        return nil
    end

    --------------------------------------------------------
    -- GT++ / MiscUtils
    --
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
    -- GT material mapping
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
-- Remove indicator dust
--
-- 注意：
--
-- 这里只销毁slot 1中的1个材料粉。
--
-- 两种时空流体不动。
------------------------------------------------------------

local function clearIndicatorDust()

    local item =
        getItem(
            sideCacheBuffer,
            1
        )

    if not item then

        print(
            "[错误] 材料粉不存在"
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
-- Scan spacetime fluids
--
-- 不再固定使用 tank 1 / tank 2。
--
-- 扫描所有流体槽：
--
--   1~50   -> 时间流体
--   51~100 -> 空间流体
--
-- 同时排除 plasma。
------------------------------------------------------------

local function getSpacetimeFluids()

    local temporal = nil
    local spatial = nil

    for i = 1,
        MAX_FLUID_TANK_SCAN
    do

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

            ------------------------------------------------
            -- 排除我们自己输入的plasma
            ------------------------------------------------

            if amount > 0
                and not name:match(
                    "^plasma%."
                )
            then

                ------------------------------------------------
                -- 1~50：时间流体
                ------------------------------------------------

                if amount >= TEMPORAL_MIN
                    and amount <= TEMPORAL_MAX
                then

                    temporal = {
                        fluid = fluid,
                        amount = amount,
                        tank = i
                    }

                ------------------------------------------------
                -- 51~100：空间流体
                ------------------------------------------------

                elseif amount >= SPATIAL_MIN
                    and amount <= SPATIAL_MAX
                then

                    spatial = {
                        fluid = fluid,
                        amount = amount,
                        tank = i
                    }
                end
            end
        end
    end

    return temporal, spatial
end

------------------------------------------------------------
-- Read complete Magmatter round
------------------------------------------------------------

local function getRoundInput()

    --------------------------------------------------------
    -- Material indicator dust
    --------------------------------------------------------

    local item =
        getItem(
            sideCacheBuffer,
            1
        )

    if not item then
        return nil
    end

    --------------------------------------------------------
    -- Search the two spacetime fluids dynamically
    --------------------------------------------------------

    local temporal,
        spatial =
        getSpacetimeFluids()

    if not temporal
        or not spatial
    then
        return nil
    end

    --------------------------------------------------------
    -- Resolve material
    --------------------------------------------------------

    local materialName =
        getPlasmaName(item)

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
    -- Plasma requirement
    --------------------------------------------------------

    local required =
        math.abs(
            spatial.amount
            - temporal.amount
        )
        * PLASMA_MULTIPLIER

    return {
        item = item,

        temporalFluid =
            temporal.fluid,

        spatialFluid =
            spatial.fluid,

        temporalAmount =
            temporal.amount,

        spatialAmount =
            spatial.amount,

        temporalTank =
            temporal.tank,

        spatialTank =
            spatial.tank,

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
-- AE crafting request
--
-- amount = 当前真正还缺多少plasma
--
-- 不计算样板倍率。
-- 不计算配方次数。
--
-- 直接request(amount, true)。
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
    -- Query craftable
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
            .. fullName
        )

        return nil
    end

    print(
        "[下单] 找到配方，开始计算..."
    )

    --------------------------------------------------------
    -- Direct request
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
    -- Wait until crafting plan calculation finishes
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
        -- Request canceled
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
        -- Planning finished
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
-- Crafting status
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
    -- isCanceled may also report computing
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
-- Feed exact plasma requirement
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
    -- Set Fluid Interface
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
    -- Exact feeding loop
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
        -- Correct plasma available
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
        -- Fluid Interface still contains previous fluid
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
        -- No target plasma
        ----------------------------------------------------

        else

            ------------------------------------------------
            -- No request yet
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
                -- CPU running
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
                -- Task done
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

                        print(
                            string.format(
                                "[AE] 任务完成后仍缺 %d mB，重新补单",
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

                    -- 不重复下单，避免重复任务
                    os.sleep(1)
                end
            end
        end
    end

    --------------------------------------------------------
    -- Done
    --------------------------------------------------------

    clearPlasmaFilter()

    print(
        fullName
        .. " 输入完成"
    )

    return true
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
    -- Material
    --------------------------------------------------------

    print(
        "材料粉: "
        .. tostring(
            round.item.label
                or round.item.name
        )
    )

    --------------------------------------------------------
    -- Temporal fluid
    --------------------------------------------------------

    print(
        string.format(
            "时间流体: %s × %d mB [tank %d]",
            tostring(
                round.temporalFluid.label
                    or round.temporalFluid.name
            ),
            round.temporalAmount,
            round.temporalTank
        )
    )

    --------------------------------------------------------
    -- Spatial fluid
    --------------------------------------------------------

    print(
        string.format(
            "空间流体: %s × %d mB [tank %d]",
            tostring(
                round.spatialFluid.label
                    or round.spatialFluid.name
            ),
            round.spatialAmount,
            round.spatialTank
        )
    )

    print("")

    --------------------------------------------------------
    -- Requirement
    --------------------------------------------------------

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
    -- Sanity check
    --------------------------------------------------------

    if round.required <= 0 then

        print(
            "[错误] 两种时空流体数量相同"
        )

        print(
            "[错误] Plasma需求计算结果为0"
        )

        return false
    end

    --------------------------------------------------------
    -- Remove ONLY the dust
    --------------------------------------------------------

    if not clearIndicatorDust()
    then

        print(
            "[错误] 材料粉清理失败"
        )

        return false
    end

    os.sleep(0.5)

    --------------------------------------------------------
    -- Feed exact plasma
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
    -- Round finished
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
    -- 不清缓存仓
    -- 不清两个时空流体
    --
    -- 异化器会自行消费。
    --------------------------------------------------------

    return true
end

------------------------------------------------------------
-- Machine enable handling
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

        ----------------------------------------------------
        -- New dust?
        ----------------------------------------------------

        local item =
            getItem(
                sideCacheBuffer,
                1
            )

        if item then

            ------------------------------------------------
            -- Try to read complete round
            ------------------------------------------------

            local round =
                getRoundInput()

            ------------------------------------------------
            -- Complete input
            ------------------------------------------------

            if round
                and not round.error
            then

                ------------------------------------------------
                -- Wait a short moment and confirm again
                ------------------------------------------------

                os.sleep(0.5)

                local confirmed =
                    getRoundInput()

                if confirmed
                    and not confirmed.error
                then

                    ------------------------------------------------
                    -- Make sure values are stable
                    ------------------------------------------------

                    if confirmed.temporalAmount
                        == round.temporalAmount
                        and confirmed.spatialAmount
                            == round.spatialAmount
                        and confirmed.materialName
                            == round.materialName
                    then

                        processRound(
                            confirmed
                        )

                    else

                        print(
                            "[等待] 输入仍在变化，继续等待..."
                        )
                    end
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
            -- Dust exists, fluids not complete
            ------------------------------------------------

            else

                local now =
                    computer.uptime()

                if now
                    - lastWaitingPrint
                    >= STATUS_PRINT_INTERVAL
                then

                    print(
                        "[等待] 材料粉已到，扫描两种时空流体..."
                    )

                    ------------------------------------------------
                    -- 调试显示当前所有流体槽
                    ------------------------------------------------

                    for i = 1,
                        MAX_FLUID_TANK_SCAN
                    do

                        local f =
                            getFluid(
                                sideCacheBuffer,
                                i
                            )

                        if f
                            and toNumber(
                                f.amount
                            ) > 0
                        then

                            print(
                                string.format(
                                    "  tank %d: %s × %d",
                                    i,
                                    tostring(
                                        f.name
                                    ),
                                    toNumber(
                                        f.amount
                                    )
                                )
                            )
                        end
                    end

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
-- Always clear Fluid Interface filter
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
