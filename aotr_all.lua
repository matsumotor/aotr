-- ═══════════════════════════════════════════════════════════════════
-- AoT Revolution — AUTO (orchestrator full)
-- Feito pra AUTOEXECUTE: roda sozinho a cada join/teleport, auto-roteia
-- por PlaceId. Sai limpo se não for AoT Revolution.
-- ═══════════════════════════════════════════════════════════════════

local TITLE_PID   = 13379208636
local LOBBY_PID   = 14916516914
local MISSION_PID = 13379349730

-- Early bail SILENCIOSO se não for AoT (autoexec roda em qualquer jogo)
do
    local pid = game.PlaceId
    if pid ~= TITLE_PID and pid ~= LOBBY_PID and pid ~= MISSION_PID then
        return
    end
end

-- Espera o jogo carregar (autoexec dispara MUITO cedo)
if not game:IsLoaded() then
    game.Loaded:Wait()
end

if setfpscap then pcall(setfpscap, 20) end

local Players = game:GetService("Players")
local LP = Players.LocalPlayer
while not LP do
    task.wait(0.1)
    LP = Players.LocalPlayer
end
local TS = game:GetService("TeleportService")
local RS = game:GetService("ReplicatedStorage")

local gg = getgenv()

-- Dedupe por instância (autoexec + run manual não duplicam)
if gg.__AOTR_AUTO_LOADED then
    print("[auto] já carregado nesta instância — ignorando re-inject")
    return
end
gg.__AOTR_AUTO_LOADED = true
gg.__AOTR_AUTO_FIRED = false

-- Teleport direto (autoexec re-roda o script na nova instância)
local function armReinjectAndTeleport(placeId)
    TS:Teleport(placeId, LP)
end

local PID = game.PlaceId

-- Espera char carregar (lobby pode demorar)
if not LP.Character then
    print("[auto] aguardando CharacterAdded...")
    LP.CharacterAdded:Wait()
end
local actorWait = LP.Character:WaitForChild("Actor", 10)
if not actorWait then warn("[auto] Actor não apareceu em 10s") end

-- Espera o actor estar RODANDO (existir != estar running pro run_on_actor)
local function waitActorReady(charActor, timeout)
    if not charActor then return false end
    local t0 = tick()
    while tick() - t0 < (timeout or 15) do
        local ok = pcall(run_on_actor, charActor, "local _=1")
        if ok then return true end
        task.wait(0.3)
    end
    return false
end

-- ─── Helpers: leitura de gold + grade + cost-to-next via actor ───
local function readActorState()
    -- Roda sync no actor, retorna {gold, grade, costToNextGrade, levels}
    local charActor
    -- Em missão: workspace.Characters[name].Actor; no lobby: LP.Character.Actor
    if PID == MISSION_PID then
        local Chars = workspace:FindFirstChild("Characters")
        local f = Chars and Chars:FindFirstChild(LP.Name)
        charActor = f and f:FindFirstChild("Actor")
    else
        charActor = LP.Character and LP.Character:FindFirstChild("Actor")
    end
    if not charActor then return nil end
    if not waitActorReady(charActor) then return {err="actor not running"} end

    local b = charActor:FindFirstChild("__AOTR_AUTO_STATE")
    if b then b:Destroy() end
    b = Instance.new("BindableEvent")
    b.Name = "__AOTR_AUTO_STATE"
    b.Parent = charActor

    local result, done = nil, false
    b.Event:Connect(function(d) result = d; done = true end)

    run_on_actor(charActor, [==[
        local LP = game:GetService("Players").LocalPlayer
        -- Resolve actor (mesma lógica do main)
        local actor
        local Chars = workspace:FindFirstChild("Characters")
        if Chars and Chars:FindFirstChild(LP.Name) then
            actor = Chars[LP.Name]:FindFirstChild("Actor")
        else
            actor = LP.Character and LP.Character:FindFirstChild("Actor")
        end
        local b = actor:WaitForChild("__AOTR_AUTO_STATE", 5)

        -- Wallet
        local wallet
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table" then
                local g = rawget(obj, "Gold"); local gm = rawget(obj, "Gems")
                local c = rawget(obj, "Canes"); local s = rawget(obj, "Shards")
                if type(g)=="number" and type(gm)=="number" and c ~= nil and s ~= nil then
                    local cnt = 0; for _ in pairs(obj) do cnt = cnt + 1 end
                    if cnt == 4 then wallet = obj; break end
                end
            end
        end

        -- Levels (8 stats blades)
        local levels
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table" then
                local bd = rawget(obj, "Blade_Durability"); local dmg = rawget(obj, "ODM_Damage"); local cc = rawget(obj, "Crit_Chance")
                if type(bd)=="number" and type(dmg)=="number" and type(cc)=="number" then
                    local cnt = 0; local allOk = true
                    for k, v in pairs(obj) do
                        cnt = cnt + 1
                        if type(v) ~= "number" or v > 20 then allOk = false; break end
                    end
                    if allOk and cnt == 8 then levels = obj; break end
                end
            end
        end

        -- Values (Upgrade_Costs + Difficulty_Potential)
        local values
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table"
               and type(rawget(obj, "Upgrade_Costs")) == "table"
               and type(rawget(obj, "Pot_Tags")) == "table"
               and type(rawget(obj, "Difficulty_Potential")) == "table" then
                values = obj; break
            end
        end

        if not wallet or not levels or not values then
            b:Fire({err="missing wallet/levels/values"})
            return
        end

        -- Calcula grade atual
        local sum, count = 0, 0
        local levelsCopy = {}
        for k, v in pairs(levels) do
            sum = sum + v; count = count + 1
            levelsCopy[k] = v
        end
        local grade = math.floor(sum / count)

        -- Calcula cost-to-next-grade + min upgrades pra justificar trip
        -- Target: sum >= (grade+1) * count → need (grade+1)*count - sum
        local MIN_UPGRADES_PER_TRIP = 5  -- só vai pro lobby se conseguir N+ upgrades
        local targetSum = (grade + 1) * count
        local needForGrade = targetSum - sum
        local needTotal = math.max(needForGrade, MIN_UPGRADES_PER_TRIP)
        local cost = 0
        local working = {}
        for k, v in pairs(levelsCopy) do working[k] = v end

        for _ = 1, needTotal do
            local pick, pickLvl
            for k, v in pairs(working) do
                if v < 15 then
                    if not pickLvl or v < pickLvl then pick = k; pickLvl = v end
                end
            end
            if not pick then cost = -1; break end
            local c = values.Upgrade_Costs[pickLvl + 1]
            if not c then cost = -1; break end
            cost = cost + c
            working[pick] = pickLvl + 1
        end

        -- Calcula max difficulty desbloqueada (pra Missions)
        -- Suporta 2 formatos:
        --   nested: Difficulty_Potential.Missions = [{name,min}, ...]
        --   flat:   Difficulty_Potential = [{name,min}, ...]  (caso atual)
        local maxDiff = "Easy"
        local missionsDiffs

        -- 1) Tenta nested (key "missions")
        for k, v in pairs(values.Difficulty_Potential) do
            if type(k) == "string" and k:lower() == "missions" and type(v) == "table" then
                missionsDiffs = v; break
            end
        end

        -- 2) Fallback: estrutura é flat (entries diretamente {name, minGrade})
        if not missionsDiffs then
            for _, v in pairs(values.Difficulty_Potential) do
                if type(v) == "table" and type(v[1]) == "string" and type(v[2]) == "number" then
                    missionsDiffs = values.Difficulty_Potential
                    break
                end
            end
        end

        if missionsDiffs then
            local best, bestMin
            for _, entry in pairs(missionsDiffs) do
                if type(entry) == "table"
                   and type(entry[1]) == "string"
                   and type(entry[2]) == "number"
                   and entry[2] <= grade then
                    if not bestMin or entry[2] > bestMin then
                        best = entry[1]; bestMin = entry[2]
                    end
                end
            end
            if best then maxDiff = best end
        end

        -- Progression: lê do Modules LOCAL (Cache.Character==LP.Character) direto
        -- de Cache.Data.Slots[slot].Progression (funciona em missão E lobby).
        -- Fallback: getgc cego (último recurso).
        local prog
        do
            -- acha Modules local
            local Modules
            for _, obj in ipairs(getgc(true)) do
                if type(obj) == "table" then
                    local sub = rawget(obj, "Modules"); local cache = rawget(obj, "Cache")
                    if type(sub) == "table" and type(cache) == "table"
                       and rawget(cache, "Character") == LP.Character
                       and type(rawget(sub, "Update")) == "table" then
                        Modules = obj; break
                    end
                end
            end
            -- 1) via Cache.Data.Slots[slot].Progression
            if Modules and Modules.Cache and Modules.Cache.Data then
                local dt = Modules.Cache.Data
                local slot = dt.Slots and dt.Current_Slot and dt.Slots[dt.Current_Slot]
                if slot and slot.Progression then
                    local pr = slot.Progression
                    prog = {Level=pr.Level, XP=pr.XP, Max_XP=pr.Max_XP, Prestige=pr.Prestige}
                end
            end
            -- 2) fallback getgc cego (se o caminho acima falhar)
            if not prog then
                for _, obj in ipairs(getgc(true)) do
                    if type(obj) == "table" then
                        local lvl=rawget(obj,"Level"); local xp=rawget(obj,"XP")
                        local mxp=rawget(obj,"Max_XP"); local prest=rawget(obj,"Prestige")
                        if type(lvl)=="number" and type(xp)=="number" and type(mxp)=="number" and prest~=nil then
                            prog = {Level=lvl, XP=xp, Max_XP=mxp, Prestige=prest}; break
                        end
                    end
                end
            end
        end

        b:Fire({
            gold = wallet.Gold,
            grade = grade,
            tag = values.Pot_Tags[grade] or "?",
            tagNext = values.Pot_Tags[grade+1] or "MAX",
            costToNext = cost,
            maxDifficulty = maxDiff,
            level = prog and prog.Level,
            prestige = prog and prog.Prestige,
            xp = prog and prog.XP,
            maxXp = prog and prog.Max_XP,
        })
    ]==])

    local t = tick()
    while not done and tick() - t < 5 do task.wait(0.05) end
    return result
end

-- ─── doPrestige: handshake Talents → Prestige (best-effort + log) ──
-- Roda no actor. Pega primeira memória oferecida em cada etapa.
-- Retorna {ok, prestigeAntes, prestigeDepois, log}
local function doPrestige()
    local charActor = LP.Character and LP.Character:FindFirstChild("Actor")
    if not charActor then return {err="no actor"} end
    if not waitActorReady(charActor) then return {err="actor not running"} end
    local b = charActor:FindFirstChild("__AOTR_PRESTIGE_DO")
    if b then b:Destroy() end
    b = Instance.new("BindableEvent")
    b.Name = "__AOTR_PRESTIGE_DO"
    b.Parent = charActor
    local result, done = nil, false
    b.Event:Connect(function(d) result = d; done = true end)

    run_on_actor(charActor, [==[
        local LP = game:GetService("Players").LocalPlayer
        local GET = game:GetService("ReplicatedStorage").Assets.Remotes.GET
        local actor
        local Chars = workspace:FindFirstChild("Characters")
        if Chars and Chars:FindFirstChild(LP.Name) then actor = Chars[LP.Name].Actor else actor = LP.Character.Actor end
        local b = actor:WaitForChild("__AOTR_PRESTIGE_DO", 5)
        local log = {}
        local function L(s) table.insert(log, s) end

        -- serializa pra log
        local function ser(v, d)
            d = d or 0
            if d > 4 then return "<deep>" end
            if type(v) == "table" then
                local p = {}
                for k, val in pairs(v) do table.insert(p, "["..tostring(k).."]="..ser(val, d+1)) end
                return "{"..table.concat(p, ",").."}"
            elseif type(v) == "string" then return '"'..v..'"'
            else return tostring(v) end
        end

        -- acha Modules
        local Modules
        for _, obj in ipairs(getgc(true)) do
            if type(obj)=="table" then
                local sub=rawget(obj,"Modules"); local cache=rawget(obj,"Cache")
                if type(sub)=="table" and type(cache)=="table" and type(rawget(sub,"Update"))=="table" then
                    Modules = obj; break
                end
            end
        end
        if not Modules then b:Fire({err="no Modules", log=log}) return end

        -- Get_Data seguro (espera os dados do player carregarem)
        local function safeData()
            for _ = 1, 40 do
                local ok, _, dt = pcall(function() return Modules.Modules.Update.Get_Data(Modules, true) end)
                if ok and dt ~= nil then return dt end
                task.wait(0.25)
            end
            return nil
        end

        -- prestige antes
        local function getPrestige()
            local data = safeData()
            return data and data.Progression and data.Progression.Prestige, data
        end
        local pBefore, dataBefore = getPrestige()
        L("Prestige antes = "..tostring(pBefore))

        -- Helper: mapeia ID de talento -> Tag (nome usado na Selection)
        -- Memories.Talents = {Offense=..., Defense=..., Support=...}, cada [id]={Tag=...}
        local Mem = Modules.Modules.Memories
        local function talentTag(id)
            if not Mem or type(Mem.Talents) ~= "table" then return nil end
            for _, cat in ipairs({"Offense","Defense","Support"}) do
                local C = Mem.Talents[cat]
                if type(C) == "table" then
                    -- tenta acesso direto e por tostring (id pode ser number ou string)
                    local info = C[id] or C[tonumber(id)] or C[tostring(id)]
                    if type(info) == "table" and info.Tag then return info.Tag end
                    for k, v in pairs(C) do
                        if tostring(k) == tostring(id) and type(v) == "table" and v.Tag then return v.Tag end
                    end
                end
            end
            return nil
        end

        -- Etapa 1: Talents invoke (retorna IDs oferecidos)
        local ok1, r1, opts, r3 = pcall(function() return GET:InvokeServer("S_Equipment", "Talents") end)
        L("Talents invoke ok="..tostring(ok1).." opts="..ser(opts))

        -- pega o Tag do 1o talento oferecido
        local talentName
        if type(opts) == "table" then
            for _, id in pairs(opts) do
                talentName = talentTag(id)
                if talentName then break end
            end
        end

        -- Selection: Boosts fixo "EXP Boost" (ajuda no level), Talents = nome mapeado
        local selection = { Boosts = "EXP Boost", Talents = talentName }
        L("Selection montada = "..ser(selection))
        if not talentName then
            L("ERRO: nao mapeou talento (opts="..ser(opts)..") — abortando")
            b:Fire({ok=false, err="talent map fail", log=log}) return
        end

        -- Etapa 2: Prestige invoke
        local ok2, pr1 = pcall(function() return GET:InvokeServer("S_Equipment", "Prestige", selection) end)
        L("Prestige invoke ok="..tostring(ok2).." ret="..(type(pr1)=="table" and "table(Data)" or ser(pr1)))

        task.wait(1)
        local pAfter = getPrestige()
        L("Prestige depois = "..tostring(pAfter))

        b:Fire({
            ok = (pAfter ~= nil and pBefore ~= nil and pAfter > pBefore),
            pBefore = pBefore, pAfter = pAfter, log = log,
        })
    ]==])

    local t = tick()
    while not done and tick() - t < 15 do task.wait(0.1) end
    return result or {err="timeout"}
end

-- ─── doClaimQuests: claima todas as quests completas ──────────────
-- Remote: Invoke("Functions","Quest", Tag, Q_code). Roda no actor.
local function doClaimQuests()
    local charActor = LP.Character and LP.Character:FindFirstChild("Actor")
    if not charActor then return {err="no actor"} end
    if not waitActorReady(charActor) then return {err="actor not running"} end
    local b = charActor:FindFirstChild("__AOTR_CLAIM")
    if b then b:Destroy() end
    b = Instance.new("BindableEvent")
    b.Name = "__AOTR_CLAIM"
    b.Parent = charActor
    local result, done = nil, false
    b.Event:Connect(function(d) result = d; done = true end)

    run_on_actor(charActor, [==[
        local LP = game:GetService("Players").LocalPlayer
        local GET = game:GetService("ReplicatedStorage").Assets.Remotes.GET
        local actor
        local Chars = workspace:FindFirstChild("Characters")
        if Chars and Chars:FindFirstChild(LP.Name) then actor = Chars[LP.Name].Actor else actor = LP.Character.Actor end
        local b = actor:WaitForChild("__AOTR_CLAIM", 5)

        local Modules
        for _, obj in ipairs(getgc(true)) do
            if type(obj)=="table" then
                local sub=rawget(obj,"Modules"); local cache=rawget(obj,"Cache")
                if type(sub)=="table" and type(cache)=="table" and type(rawget(sub,"Update"))=="table" then Modules=obj; break end
            end
        end
        if not Modules then b:Fire({err="no Modules"}) return end

        -- mapa categoria -> Q code
        local CAT = { Main="Q_1", Side="Q_2", Spears="Q_2.1", Daily="Q_4", Weekly="Q_5" }
        local claimed = 0
        local tried = 0
        -- só vale tentar se: não-claimada E (sem Amount conhecido OU já completou)
        local function worthTrying(q)
            if type(q) ~= "table" or not q.Tag or q.Rewarded == true then return false end
            if type(q.Amount) == "number" and type(q.Current) == "number" then
                return q.Current >= q.Amount  -- pula incompletas (com Amount conhecido)
            end
            return true  -- sem Amount no data (Main/Side): tenta
        end
        local function tryClaim(tag, code)
            if not tag or not code then return end
            tried = tried + 1
            local ok, v3, v4, v5 = pcall(function() return GET:InvokeServer("Functions","Quest", tag, code) end)
            if ok and v3 ~= nil and v5 ~= nil then claimed = claimed + 1 end
            task.wait(0.03)
        end

        -- Get_Data seguro (espera os dados carregarem após teleport)
        local data
        for _ = 1, 40 do
            local ok, _, dt = pcall(function() return Modules.Modules.Update.Get_Data(Modules, true) end)
            if ok and dt ~= nil then data = dt; break end
            task.wait(0.25)
        end
        if not data or type(data.Quests) ~= "table" then b:Fire({err="no Quests data (timeout)"}) return end

        for catName, code in pairs(CAT) do
            local quests = data.Quests[catName]
            if type(quests) == "table" then
                for _, q in pairs(quests) do
                    if worthTrying(q) then tryClaim(q.Tag, code) end
                end
            end
        end

        -- 2) Battlepass (por semana): Week_N -> Q_7.0N
        local bp = data.Quests.Battlepass
        if type(bp) == "table" then
            for weekKey, quests in pairs(bp) do
                local n = tostring(weekKey):match("Week_(%d+)")
                if n and type(quests) == "table" then
                    local code = "Q_7." .. (tonumber(n) < 10 and ("0"..n) or n)
                    for _, q in pairs(quests) do
                        if worthTrying(q) then tryClaim(q.Tag, code) end
                    end
                end
            end
        end

        b:Fire({ok=true, claimed=claimed})
    ]==])

    local t = tick()
    while not done and tick() - t < 30 do task.wait(0.1) end
    return result or {err="timeout"}
end


-- ╔══════════════════════════════════════════════════════════════╗
-- ║  MÓDULOS EMBUTIDOS (gerados por build_combined.js — NÃO EDITAR ║
-- ║  AQUI; edite os arquivos originais e rode o build de novo)     ║
-- ╚══════════════════════════════════════════════════════════════╝

local function runCombat()
-- ═══════════════════════════════════════════════════════════════════
-- AoT Revolution — Combat Standalone
-- Rode DENTRO da missão (PlaceId 13379349730)
-- ═══════════════════════════════════════════════════════════════════

local LP = game:GetService("Players").LocalPlayer
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local MISSION_PLACE_ID = 13379349730
local LOBBY_PLACE_ID   = 14916516914

if game.PlaceId ~= MISSION_PLACE_ID then
    warn("[combat] Rode dentro da missão (PlaceId esperado: " .. MISSION_PLACE_ID .. ")")
    return
end

-- ─── Cleanup conexões antigas (re-execução) ──────────────────────
local gg = getgenv()
for _, name in ipairs({"__AOTR_HOVER_CONN", "__AOTR_VIS_CONN", "__AOTR_GODMODE_CONN"}) do
    if gg[name] then
        pcall(function() gg[name]:Disconnect() end)
        gg[name] = nil
    end
end

-- ─── Tunáveis ─────────────────────────────────────────────────────
local SAFE_HEIGHT       = 800    -- Y absoluto do safespot (subi mais — fora do raycast de grab)
local ATTACK_OFFSET_Y   = 400    -- studs ACIMA do nape (anti-grab; longe das mãos)
local ATTACK_DELAY      = 0.02   -- entre Slash e Register (mínimo viável)
local FARM_DELAY        = 0.05   -- entre slashes
local AOE_RADIUS        = 120    -- studs: acerta TODOS os titans num raio (com 1 slash)
local AOE_MAX_TARGETS   = 6      -- cap pra não derrubar server
local REGISTER_VELOCITY = 250
local REGISTER_TIME_DIFF = 0.1
local IDLE_WAIT         = 0.5
local RELOAD_DELAY      = 0.8
local RELOAD_AT_SEGMENTS = 0     -- recarrega só quando blade VAZIA (broken>=7) — max strikes por blade
local FULL_REFILL_WAIT  = 3.0    -- segundos pra animação Full_Reload completar

-- ─── Camera lock: ancora num ponto fixo (respawn) ─────────────────
local function getOrCreateCamAnchor()
    -- Limpa âncora antiga
    local old = workspace:FindFirstChild("__AOTR_CAM_ANCHOR")
    if old then return old end

    -- Posição base = posição atual do char (= respawn point)
    local char = LP.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local pos = hrp and hrp.Position or Vector3.new(0, 100, 0)

    local anchor = Instance.new("Part")
    anchor.Name = "__AOTR_CAM_ANCHOR"
    anchor.Anchored = true
    anchor.CanCollide = false
    anchor.CanQuery = false
    anchor.CanTouch = false
    anchor.Transparency = 1
    anchor.Size = Vector3.new(1, 1, 1)
    anchor.CFrame = CFrame.new(pos)
    anchor.Parent = workspace
    return anchor
end
local camAnchor = getOrCreateCamAnchor()

-- ─── Tela limpa + lock câmera Scriptable em CFrame fixo ──────────
-- Calcula um CFrame de vista fixa olhando pro anchor (3rd person)
local function getLockCFrame()
    if not camAnchor or not camAnchor.Parent then return nil end
    local p = camAnchor.Position
    -- Vista a 30 studs atrás, 15 acima, olhando pro anchor
    return CFrame.new(p + Vector3.new(0, 15, 30), p)
end
local lockedCFrame = getLockCFrame()

local function ensureVisible()
    local cam = workspace.CurrentCamera
    -- Força Scriptable + CFrame fixo
    if lockedCFrame then
        if cam.CameraType ~= Enum.CameraType.Scriptable then
            cam.CameraType = Enum.CameraType.Scriptable
        end
        cam.CFrame = lockedCFrame
        cam.Focus = lockedCFrame
    end
    local cc = Lighting:FindFirstChild("ColorCorrection")
    if cc then
        if cc.Contrast ~= cc.Contrast then cc.Contrast = 0 end
        if cc.Saturation ~= cc.Saturation then cc.Saturation = 0 end
        if cc.Brightness ~= cc.Brightness then cc.Brightness = 0 end
        local tc = cc.TintColor
        if tc.R ~= tc.R or tc.G ~= tc.G or tc.B ~= tc.B then
            cc.TintColor = Color3.new(1, 1, 1)
        end
    end
    local blur = Lighting:FindFirstChild("Blinded")
    if blur and blur:IsA("BlurEffect") and blur.Enabled then
        blur.Enabled = false
        blur.Size = 0
    end
end
ensureVisible()
-- Heartbeat só pra tela limpa (cor/blur)
gg.__AOTR_VIS_CONN = RunService.Heartbeat:Connect(function()
    pcall(function()
        local cc = Lighting:FindFirstChild("ColorCorrection")
        if cc then
            if cc.Contrast ~= cc.Contrast then cc.Contrast = 0 end
            if cc.Saturation ~= cc.Saturation then cc.Saturation = 0 end
            if cc.Brightness ~= cc.Brightness then cc.Brightness = 0 end
            local tc = cc.TintColor
            if tc.R ~= tc.R or tc.G ~= tc.G or tc.B ~= tc.B then
                cc.TintColor = Color3.new(1, 1, 1)
            end
        end
        local blur = Lighting:FindFirstChild("Blinded")
        if blur and blur:IsA("BlurEffect") and blur.Enabled then
            blur.Enabled = false
            blur.Size = 0
        end
    end)
end)

-- BindToRenderStep: roda DEPOIS do game (prioridade > Camera=200)
pcall(function() RunService:UnbindFromRenderStep("AOTR_CAM_LOCK") end)
RunService:BindToRenderStep("AOTR_CAM_LOCK", Enum.RenderPriority.Camera.Value + 100, function()
    if not lockedCFrame then return end
    local cam = workspace.CurrentCamera
    if cam.CameraType ~= Enum.CameraType.Scriptable then
        cam.CameraType = Enum.CameraType.Scriptable
    end
    cam.CFrame = lockedCFrame
    cam.Focus = lockedCFrame
end)

-- Quando respawnar, recria âncora na nova posição do respawn
LP.CharacterAdded:Connect(function(char)
    char:WaitForChild("HumanoidRootPart", 5)
    task.wait(0.3)
    if camAnchor then camAnchor:Destroy() end
    camAnchor = getOrCreateCamAnchor()
    lockedCFrame = getLockCFrame()
end)

-- ─── God Mode ─────────────────────────────────────────────────────
-- Suporta bypass via attribute __AOTR_SKIP_GOD no char (actor pode setar)
local function applyGodMode(char)
    if not char then return end
    local hum = char:WaitForChild("Humanoid", 5)
    if not hum then return end
    hum.BreakJointsOnDeath = false
    hum.MaxHealth = math.huge
    hum.Health = math.huge
    hum:GetPropertyChangedSignal("Health"):Connect(function()
        if char:GetAttribute("__AOTR_SKIP_GOD") then return end
        if hum.Health < hum.MaxHealth then hum.Health = hum.MaxHealth end
    end)
    hum:GetPropertyChangedSignal("MaxHealth"):Connect(function()
        if hum.MaxHealth ~= math.huge then
            hum.MaxHealth = math.huge
            hum.Health = math.huge
        end
    end)
end
if LP.Character then applyGodMode(LP.Character) end
LP.CharacterAdded:Connect(applyGodMode)

-- ─── Anti-hook em 3 camadas ──────────────────────────────────────
-- Camada 1 (PRIMARY): HRP.CanTouch=false → player não dispara Touched, server nunca grab
-- Camada 2: força CanTouch=false em Hitboxes.Detect.* dos titans (defesa redundante)
-- Camada 3: pré-emptive Ragdoll reset

-- Camada 1: HRP CanTouch
-- Usa attribute "__AOTR_HRP_LOCKED" como sentinel; quando true, força CanTouch=false.
-- O refill desliga temporariamente esse flag pra deixar o jogo registrar a zona.
local function lockHRP(char)
    local hrp = char:WaitForChild("HumanoidRootPart", 5)
    if not hrp then return end
    char:SetAttribute("__AOTR_HRP_LOCKED", true)
    pcall(function() hrp.CanTouch = false end)
    local conn = hrp:GetPropertyChangedSignal("CanTouch"):Connect(function()
        if not char:GetAttribute("__AOTR_HRP_LOCKED") then return end
        if hrp.CanTouch then pcall(function() hrp.CanTouch = false end) end
    end)
    if gg.__AOTR_HRP_CONN then pcall(function() gg.__AOTR_HRP_CONN:Disconnect() end) end
    gg.__AOTR_HRP_CONN = conn
end
if LP.Character then lockHRP(LP.Character) end
LP.CharacterAdded:Connect(lockHRP)

-- Camada 2: neutraliza grab hitboxes (Hitboxes.Detect)
local function neutralizeTitan(t)
    local hb = t:WaitForChild("Hitboxes", 3)
    if not hb then return end
    -- Detect = pasta com grab/punch/foot/etc hitboxes
    for _, child in ipairs(hb:GetChildren()) do
        if child.Name ~= "Hit" then
            for _, p in ipairs(child:GetDescendants()) do
                if p:IsA("BasePart") then
                    pcall(function() p.CanTouch = false end)
                end
            end
            if child:IsA("BasePart") then
                pcall(function() child.CanTouch = false end)
            end
        end
    end
end

local function setupAntihook()
    -- Espera workspace.Titans existir (logo após teleport pra missão pode demorar)
    local titans = workspace:FindFirstChild("Titans")
    if not titans then
        task.spawn(function()
            titans = workspace:WaitForChild("Titans", 30)
            if titans then setupAntihook() end
        end)
        return
    end
    local count = 0
    for _, t in ipairs(titans:GetChildren()) do
        count = count + 1
        task.spawn(function() pcall(neutralizeTitan, t) end)
    end
    print("[combat] Anti-hook ativo, " .. count .. " titans neutralizados + HRP CanTouch=false")
    if gg.__AOTR_TITAN_CONN then pcall(function() gg.__AOTR_TITAN_CONN:Disconnect() end) end
    gg.__AOTR_TITAN_CONN = titans.ChildAdded:Connect(function(t)
        task.wait(1.0)  -- aumentei pra Hitboxes carregar
        pcall(neutralizeTitan, t)
    end)
    -- Heartbeat de reforço a cada 0.5s
    if gg.__AOTR_TITAN_LOOP then pcall(function() gg.__AOTR_TITAN_LOOP:Disconnect() end) end
    local lastSweep = 0
    gg.__AOTR_TITAN_LOOP = RunService.Heartbeat:Connect(function()
        local now = tick()
        if now - lastSweep < 0.5 then return end
        lastSweep = now
        for _, t in ipairs(titans:GetChildren()) do
            task.spawn(function() pcall(neutralizeTitan, t) end)
        end
    end)
end
setupAntihook()

-- Camada 3: Ragdoll attribute kill switch
-- O handler do jogo faz task.wait() antes de ler o atributo. Se a gente resetar pra nil
-- imediatamente no AttributeChangedSignal, o handler do jogo lê nil e dá bail.
local function setupCharRagdollEscape(char)
    local conn = char:GetAttributeChangedSignal("Ragdoll"):Connect(function()
        if char:GetAttribute("Ragdoll") ~= nil then
            pcall(function() char:SetAttribute("Ragdoll", nil) end)
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then
                hrp.CFrame = CFrame.new(hrp.Position.X, SAFE_HEIGHT, hrp.Position.Z)
                hrp.AssemblyLinearVelocity = Vector3.new(0,0,0)
                hrp.AssemblyAngularVelocity = Vector3.new(0,0,0)
            end
            print("[combat] Ragdoll bloqueado")
        end
    end)
    if gg.__AOTR_RAGDOLL_CONN then pcall(function() gg.__AOTR_RAGDOLL_CONN:Disconnect() end) end
    gg.__AOTR_RAGDOLL_CONN = conn
end
if LP.Character then setupCharRagdollEscape(LP.Character) end
LP.CharacterAdded:Connect(setupCharRagdollEscape)

-- ─── Actor (espera carregar — pode demorar logo após teleport) ───
print("[combat] Aguardando char + actor carregar...")
local Characters = workspace:WaitForChild("Characters", 15)
if not Characters then warn("[combat] workspace.Characters não apareceu") return end
local charModel = Characters:WaitForChild(LP.Name, 15)
if not charModel then warn("[combat] charModel não apareceu") return end
local charActor = charModel:WaitForChild("Actor", 15)
if not charActor then warn("[combat] Actor não apareceu") return end

-- BindableEvent: actor pede teleport pro lobby → main thread teleporta
-- (autoexec re-roda o auto na nova instância — sem precisar de queue)
local teleportReq = charActor:FindFirstChild("__AOTR_TELEPORT_REQ")
if teleportReq then teleportReq:Destroy() end
teleportReq = Instance.new("BindableEvent")
teleportReq.Name = "__AOTR_TELEPORT_REQ"
teleportReq.Parent = charActor
teleportReq.Event:Connect(function(targetPid)
    targetPid = targetPid or LOBBY_PLACE_ID
    game:GetService("TeleportService"):Teleport(targetPid, LP)
end)

print("[combat] Iniciando AOE auto-attack...")

-- ─── Loop no actor ────────────────────────────────────────────────
run_on_actor(charActor, string.format([[
    local LP = game:GetService("Players").LocalPlayer
    local rs = game:GetService("ReplicatedStorage")
    local POST = rs.Assets.Remotes.POST

    local MISSION_PID = %d
    local LOBBY_PID = %d
    local SAFE_HEIGHT = %d
    local ATTACK_OFFSET_Y = %d
    local ATTACK_DELAY = %f
    local FARM_DELAY = %f
    local AOE_RADIUS = %d
    local AOE_MAX_TARGETS = %d
    local REGISTER_VELOCITY = %d
    local REGISTER_TIME_DIFF = %f
    local IDLE_WAIT = %f
    local RELOAD_DELAY = %f
    local RELOAD_AT_SEGMENTS = %d
    local FULL_REFILL_WAIT = %f

    -- Acha Modules master (com retry — dados podem demorar após teleport)
    local function findModulesOnce()
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table" then
                local sub = rawget(obj, "Modules"); local cache = rawget(obj, "Cache")
                if type(sub) == "table" and type(cache) == "table"
                   and rawget(cache, "Character") == LP.Character then
                    return obj
                end
            end
        end
    end
    local Modules
    local t0 = tick()
    while not Modules and tick() - t0 < 20 do
        Modules = findModulesOnce()
        if not Modules then task.wait(0.5) end
    end
    if not Modules then print("[combat-actor] ERRO: sem Modules (20s timeout)"); return end
    local Blades = Modules.Modules.Blades
    print("[combat-actor] Modules viva. AOE_RADIUS=" .. AOE_RADIUS .. " AOE_MAX=" .. AOE_MAX_TARGETS)

    -- Re-acha Modules na getgc (chamado em watchdog quando ref fica stale)
    local function refindModules()
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table" then
                local sub = rawget(obj, "Modules"); local cache = rawget(obj, "Cache")
                if type(sub) == "table" and type(cache) == "table"
                   and rawget(cache, "Character") == LP.Character then
                    Modules = obj
                    Blades = Modules.Modules.Blades
                    print("[combat-actor] Modules re-found")
                    return true
                end
            end
        end
        return false
    end

    -- ── CAMERA LOCK: bloqueia Camera.Tween do jogo via Dialogue.Tween=true ──
    -- (na decompile: Camera.Tween retorna se Dialogue.Tween==true)
    if Modules.Modules.Dialogue then
        Modules.Modules.Dialogue.Tween = true
        print("[combat-actor] Dialogue.Tween=true (camera bloqueada)")
        -- Reforça periodicamente caso algo resete
        task.spawn(function()
            while game.PlaceId == MISSION_PID do
                if Modules.Modules.Dialogue.Tween ~= true then
                    Modules.Modules.Dialogue.Tween = true
                end
                task.wait(0.1)
            end
        end)
    end

    local function getHRP()
        local char = LP.Character
        return char and char:FindFirstChild("HumanoidRootPart")
    end

    -- Pega TODOS os titans vivos dentro do raio do "anchor" (centro do AOE)
    local function getTargetsInRange(anchorPos, radius, maxCount)
        local list = {}
        local titansFolder = workspace:FindFirstChild("Titans")
        if not titansFolder then return list end  -- entre waves / transição: sem titans
        for _, t in ipairs(titansFolder:GetChildren()) do
            local h = t:FindFirstChildOfClass("Humanoid")
            local hb = t:FindFirstChild("Hitboxes")
            local nape = hb and hb:FindFirstChild("Hit") and hb.Hit:FindFirstChild("Nape")
            if h and h.Health > 0 and nape then
                local d = (nape.Position - anchorPos).Magnitude
                if d <= radius then
                    table.insert(list, {nape=nape, hum=h, dist=d})
                end
            end
        end
        table.sort(list, function(a, b) return a.dist < b.dist end)
        if #list > maxCount then
            for i = #list, maxCount + 1, -1 do table.remove(list, i) end
        end
        return list
    end

    -- Pega o titan mais próximo (pra ancorar o AOE em cima dele)
    local function getAnchorTitan()
        local hrp = getHRP()
        if not hrp then return nil end
        local list = getTargetsInRange(hrp.Position, math.huge, 1)
        return list[1]
    end

    -- Detector REAL: conta segmentos quebrados no rig (verdade do servidor)
    local function brokenSegments()
        local rig = Modules.Modules.ODMG.Rig(Modules, LP.Character)
        if not rig then return 0 end
        local lh = rig:FindFirstChild("LeftHand")
        if not lh then return 0 end
        local n = 0
        for i = 1, 7 do
            local seg = lh:FindFirstChild("Blade_" .. i)
            if seg and seg:GetAttribute("Broken") then n = n + 1 end
        end
        return n
    end

    local function needsReload()
        -- Recarrega quando >= (7 - RELOAD_AT_SEGMENTS) segmentos estão quebrados
        return brokenSegments() >= (7 - RELOAD_AT_SEGMENTS)
    end

    local function isRagdolled()
        local char = LP.Character
        return char and char:GetAttribute("Ragdoll") ~= nil
    end

    -- Lê Sets (X/3) da UI
    local function getSetsCount()
        local ok, txt = pcall(function()
            return LP.PlayerGui.Interface.HUD.Main.Top["7"].Blades.Sets.Text
        end)
        if not ok or type(txt) ~= "string" then return nil end
        local n = tonumber(txt:match("^(%%d+)"))
        return n
    end

    local function needsFullRefill()
        local s = getSetsCount()
        if s == nil or s > 0 then return false end
        -- Só vai pra estação se também não tiver blade utilizável
        return brokenSegments() >= 7
    end

    -- Acha a Refill part mais próxima nas Props.HQ
    local function getNearestRefillStation()
        local hrp = getHRP()
        if not hrp then return nil end
        local HQ = workspace.Unclimbable and workspace.Unclimbable.Props and workspace.Unclimbable.Props:FindFirstChild("HQ")
        if not HQ then return nil end
        local best, bestDist
        for _, child in ipairs(HQ:GetChildren()) do
            local refill = child:FindFirstChild("Refill")
            if refill and refill:IsA("BasePart") then
                local d = (refill.Position - hrp.Position).Magnitude
                if not bestDist or d < bestDist then
                    best = refill; bestDist = d
                end
            end
        end
        return best
    end

    -- Refill completo na estação (Branch B do ODMG.Reload)
    -- Fix: TP DENTRO do refill (não acima) e MANTÉM anchored o tempo todo.
    -- Sem isso, gravidade puxa o char pra fora -> TouchEnded -> Refill_Station=nil ->
    -- ODMG.Reload cai em Branch A (quick) em vez de B (full).
    local function doFullRefill()
        local refill = getNearestRefillStation()
        if not refill then return false, "no station" end
        local hrp = getHRP()
        if not hrp then return false, "no HRP" end
        local char = LP.Character
        if not char then return false, "no char" end

        -- PAUSA antihook: HRP.CanTouch precisa ser true pro Touched da Refill propagar
        char:SetAttribute("__AOTR_HRP_LOCKED", false)
        pcall(function() hrp.CanTouch = true end)

        -- TP DENTRO do refill part (centro), zera velocidade
        hrp.CFrame = CFrame.new(refill.Position)
        hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)

        -- Anchora pra ficar dentro o tempo todo (não cair = não dispara TouchEnded)
        local wasAnchored = hrp.Anchored
        hrp.Anchored = true

        -- Aguarda Touched propagar e Refill_Station ser setado pelo jogo
        task.wait(0.8)

        -- Backup: força Refill_Station caso Touched ainda não tenha rodado
        Modules.Modules.Zones.Refill_Station = refill

        local vars = Modules.Cache and Modules.Cache.Variables
        if vars then
            vars.Reload = false
            vars.Full_Reload = false
            if type(vars.Poses) == "table" then
                vars.Poses[1] = "Idle"
            else
                vars.Poses = {"Idle"}
            end
        end
        Modules.Invoked = false
        Modules.Skill = nil

        -- Chama Reload com HRP AINDA ANCHORED (animação Tasks usa Humanoid joints, não HRP)
        local ok, err = pcall(Modules.Modules.ODMG.Reload, Modules)

        -- Espera animação Full_Reload completar
        task.wait(2.0)

        -- Restaura
        hrp.Anchored = wasAnchored
        char:SetAttribute("__AOTR_HRP_LOCKED", true)
        pcall(function() hrp.CanTouch = false end)

        return ok, err
    end

    local function doReload()
        local vars = Modules.Cache and Modules.Cache.Variables
        if vars then
            -- Reset agressivo: limpa TODOS os flags que ODMG.Reload checa pra bail
            vars.Reload = false
            vars.Full_Reload = false
            vars.Stunned = false
            vars.Knockback = nil
            vars.Sky_Dive = false
            if vars.Sliding then vars.Sliding.State = false end
            if vars.Hook_Break then vars.Hook_Break.Hooking = false end
            if type(vars.Poses) == "table" then
                vars.Poses[1] = "Idle"
            else
                vars.Poses = {"Idle"}
            end
        end
        Modules.Active = true
        Modules.Invoked = false
        Modules.Skill = nil
        -- Limpa atributo Ragdoll do char (caso tenha sobrado)
        if LP.Character then
            pcall(function() LP.Character:SetAttribute("Ragdoll", nil) end)
        end
        local ok, err = pcall(Modules.Modules.ODMG.Reload, Modules)
        return ok, err
    end

    local function gotoSafe()
        local hrp = getHRP()
        if not hrp then return end
        hrp.CFrame = CFrame.new(hrp.Position.X, SAFE_HEIGHT, hrp.Position.Z)
    end

    -- AOE: 1 Slash + N Registers (1 por nape de cada titan próximo)
    local function aoeStrike(anchor)
        local hrp = getHRP()
        if not hrp then return end
        Modules.Active = true

        -- TP para a posição do anchor (acima do nape)
        local strikePos = anchor.nape.Position + Vector3.new(0, ATTACK_OFFSET_Y, 0)
        hrp.CFrame = CFrame.new(strikePos)

        -- Pega todos os titans dentro do AOE_RADIUS a partir do anchor
        local targets = getTargetsInRange(anchor.nape.Position, AOE_RADIUS, AOE_MAX_TARGETS)
        if #targets == 0 then return end

        -- Dispara 1 Slash + N Registers
        POST:FireServer("Attacks", "Slash", true)
        task.wait(ATTACK_DELAY)
        for _, tgt in ipairs(targets) do
            if tgt.nape.Parent then
                POST:FireServer("Hitboxes", "Register", tgt.nape, REGISTER_VELOCITY, REGISTER_TIME_DIFF)
            end
        end

        -- TP IMEDIATO pra safespot (evita ficar exposto)
        hrp.CFrame = CFrame.new(strikePos.X, SAFE_HEIGHT, strikePos.Z)
    end

    local reloadFailStreak = 0
    local lastProgress = tick()
    local lastTitanCount = 0
    local watchdogStreak = 0
    local lastBigKill = tick()  -- timestamp do último "kill volume" (>= 3 titans num minuto)
    local killsLastMin = {}  -- timestamps de cada kill (pra calcular rate)
    local totalKills = 0     -- contador total de kills na missão
    local strikesCount = 0   -- contador de AOE strikes

    -- Status logger: a cada 8s mostra kills/titans/strikes (diagnostico)
    -- (concatenacao simples, sem format, pra nao conflitar com o template)
    task.spawn(function()
        while game.PlaceId == MISSION_PID do
            local titans = workspace:FindFirstChild("Titans")
            local alive = titans and #titans:GetChildren() or 0
            print("[combat-status] kills=" .. totalKills .. " strikes=" .. strikesCount
                .. " titans_vivos=" .. alive .. " sets=" .. tostring(getSetsCount()))
            task.wait(8)
        end
    end)

    while game.PlaceId == MISSION_PID do
        -- HARD LIMIT: 90s sem kill com volume → força lobby
        if tick() - lastBigKill > 90 then
            print("[combat-actor] HARD LIMIT 90s sem kill volume — teleport lobby")
            local req = workspace.Characters[LP.Name].Actor:FindFirstChild("__AOTR_TELEPORT_REQ")
            if req then req:Fire(LOBBY_PID) end
            task.wait(5); return
        end

        if tick() - lastProgress > 25 then
            watchdogStreak = watchdogStreak + 1
            print("[combat-actor] WATCHDOG #" .. watchdogStreak .. " — 25s sem progresso")

            if watchdogStreak >= 3 then
                print("[combat-actor] WATCHDOG 3x — teleport pro lobby")
                local req = workspace.Characters[LP.Name].Actor:FindFirstChild("__AOTR_TELEPORT_REQ")
                if req then req:Fire(LOBBY_PID) end
                task.wait(5)
                return
            elseif watchdogStreak >= 2 then
                -- Força respawn (Health=0 com God bypass)
                print("[combat-actor] WATCHDOG 2x — força respawn")
                local char = LP.Character
                if char then
                    char:SetAttribute("__AOTR_SKIP_GOD", true)
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum then
                        hum.BreakJointsOnDeath = true
                        hum.Health = 0
                    end
                    -- espera novo char
                    LP.CharacterAdded:Wait()
                    task.wait(2)
                    -- nova ref do char tem god restaurado pelo applyGodMode no main
                    -- refind Modules pq char mudou
                    refindModules()
                end
                lastProgress = tick()
                reloadFailStreak = 0
                continue
            end

            -- 1x: refill + reset agressivo
            refindModules()
            Modules.Active = true
            local vars = Modules.Cache and Modules.Cache.Variables
            if vars then
                vars.Reload = false; vars.Full_Reload = false
                vars.Stunned = false; vars.Knockback = nil
                vars.Sky_Dive = false
            end
            pcall(function() LP.Character:SetAttribute("Ragdoll", nil) end)
            doFullRefill()
            task.wait(FULL_REFILL_WAIT)
            lastProgress = tick()
            reloadFailStreak = 0
            continue
        end

        -- Tracking de progresso
        local titans = workspace:FindFirstChild("Titans")
        local nowTitans = titans and #titans:GetChildren() or 0
        if nowTitans < lastTitanCount then
            local killedThisTick = lastTitanCount - nowTitans
            totalKills = totalKills + killedThisTick
            lastProgress = tick()
            -- registra timestamps de cada kill
            for _ = 1, killedThisTick do
                table.insert(killsLastMin, tick())
            end
            -- limpa kills > 60s
            local now = tick()
            while #killsLastMin > 0 and now - killsLastMin[1] > 60 do
                table.remove(killsLastMin, 1)
            end
            -- "Kill volume" = >= 3 kills nos últimos 60s
            if #killsLastMin >= 3 then
                lastBigKill = tick()
                watchdogStreak = 0  -- só zera watchdog se RATE é ok
            end
        end
        lastTitanCount = nowTitans

        local hrp = getHRP()
        if not hrp then
            LP.CharacterAdded:Wait()
            task.wait(0.5)
            continue
        end

        -- PRIORIDADE: se sets=0/3, full refill na estação ANTES de qualquer coisa
        if needsFullRefill() then
            local before = getSetsCount()
            print("[combat-actor] FULL REFILL (sets=" .. tostring(before) .. "/3)")
            local ok, err = doFullRefill()
            if not ok then print("[combat-actor] FullRefill err: " .. tostring(err)) end
            -- Espera animação completar e sets voltarem
            local t0 = tick()
            while tick() - t0 < FULL_REFILL_WAIT do
                if (getSetsCount() or 0) >= 3 then break end
                task.wait(0.2)
            end
            print("[combat-actor] Pós-refill sets=" .. tostring(getSetsCount()) .. "/3")
            if (getSetsCount() or 0) >= 3 then lastProgress = tick() end
            -- Reseta flags pra animação não travar próxima ação
            local vars = Modules.Cache and Modules.Cache.Variables
            if vars then vars.Full_Reload = false end
            continue
        end

        if needsReload() then
            -- Se reload travou 2x seguidas, escala pra FULL REFILL (sabemos q funciona)
            if reloadFailStreak >= 2 then
                print("[combat-actor] Reload travado " .. reloadFailStreak .. "x — forçando FULL REFILL")
                local ok = doFullRefill()
                if not ok then print("[combat-actor] FullRefill (emergência) falhou") end
                task.wait(FULL_REFILL_WAIT)
                if brokenSegments() < 6 then
                    reloadFailStreak = 0
                    print("[combat-actor] Full refill ressuscitou — broken=" .. brokenSegments())
                end
                local vars = Modules.Cache and Modules.Cache.Variables
                if vars then vars.Full_Reload = false end
                continue
            end

            gotoSafe()
            local waited = 0
            while isRagdolled() and waited < 3 do
                task.wait(0.2); waited = waited + 0.2
            end

            local hrp = getHRP()
            local wasAnchored = false
            if hrp then
                hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
                hrp.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
                wasAnchored = hrp.Anchored
                hrp.Anchored = true
            end

            local broken = brokenSegments()
            print("[combat-actor] Reload (broken=" .. broken .. "/7 ragdoll=" .. tostring(isRagdolled()) .. ")")
            local ok, err = doReload()
            if not ok then print("[combat-actor] Reload err: " .. tostring(err)) end
            local t0 = tick()
            while tick() - t0 < 3 do
                local stillBroken = brokenSegments()
                if stillBroken < 6 then break end
                task.wait(0.2)
            end

            if hrp then hrp.Anchored = wasAnchored end

            local postBroken = brokenSegments()
            print("[combat-actor] Pós-reload: broken=" .. postBroken .. "/7")
            if postBroken >= 6 then
                reloadFailStreak = reloadFailStreak + 1
            else
                reloadFailStreak = 0
                lastProgress = tick()
                watchdogStreak = 0
            end
            task.wait(RELOAD_DELAY)
            continue
        end

        local anchor = getAnchorTitan()
        if not anchor then
            gotoSafe()
            task.wait(IDLE_WAIT)
            continue
        end

        aoeStrike(anchor)
        strikesCount = strikesCount + 1
        task.wait(FARM_DELAY)
    end
    print("[combat-actor] Missão encerrada")
]], MISSION_PLACE_ID, LOBBY_PLACE_ID, SAFE_HEIGHT, ATTACK_OFFSET_Y, ATTACK_DELAY, FARM_DELAY,
    AOE_RADIUS, AOE_MAX_TARGETS, REGISTER_VELOCITY, REGISTER_TIME_DIFF,
    IDLE_WAIT, RELOAD_DELAY, RELOAD_AT_SEGMENTS, FULL_REFILL_WAIT))

print("[combat] Auto-attack ativo. AOE + anti-grab + reload + full refill.")

end

local function runUpgrades()
-- ═══════════════════════════════════════════════════════════════════
-- AoT Revolution — Upgrades Standalone
-- Rode no LOBBY (PlaceId 14916516914)
-- Gasta gold subindo upgrades de Blades até esgotar.
-- ═══════════════════════════════════════════════════════════════════

local LP = game:GetService("Players").LocalPlayer
local LOBBY_PLACE_ID = 14916516914

if game.PlaceId ~= LOBBY_PLACE_ID then
    warn("[upgrades] Rode no lobby (PlaceId esperado: " .. LOBBY_PLACE_ID .. ")")
    return
end

-- ─── Tunáveis ─────────────────────────────────────────────────────
local WEAPON          = "Blades"  -- ou "Spears"
local PRINT_PROGRESS  = true
local MAX_ITERATIONS  = 50         -- safety cap

-- ─── Pega actor do char no lobby ─────────────────────────────────
local charActor = LP.Character and LP.Character:FindFirstChild("Actor")
if not charActor then
    warn("[upgrades] Actor do char não encontrado — entrou no lobby?")
    return
end

print("[upgrades] Iniciando auto-upgrade de " .. WEAPON .. "...")

-- ─── Bridge actor → main pra retornar resultado ──────────────────
local bridge = charActor:FindFirstChild("__AOTR_UPG_RESULT")
if bridge then bridge:Destroy() end
bridge = Instance.new("BindableEvent")
bridge.Name = "__AOTR_UPG_RESULT"
bridge.Parent = charActor

bridge.Event:Connect(function(data)
    if data.err then
        warn("[upgrades] ERRO: " .. tostring(data.err))
        return
    end
    print(string.format(
        "[upgrades] DONE: Grade %s (%s) → %s (%s) | Gold: %d → %d (gasto %d) | %d upgrades em %d chamadas",
        tostring(data.gradeBefore), tostring(data.tagBefore),
        tostring(data.gradeAfter), tostring(data.tagAfter),
        data.goldBefore, data.goldAfter, data.goldBefore - data.goldAfter,
        data.totalUpgrades, data.calls
    ))
    if data.log then
        for _, line in ipairs(data.log) do print("  " .. line) end
    end
end)

-- ─── Loop no actor ────────────────────────────────────────────────
run_on_actor(charActor, string.format([==[
    local WEAPON = "%s"
    local PRINT_PROGRESS = %s
    local MAX_ITERATIONS = %d

    local LP = game:GetService("Players").LocalPlayer
    local GET = game:GetService("ReplicatedStorage").Assets.Remotes.GET
    local actor = LP.Character.Actor
    local bridge = actor:WaitForChild("__AOTR_UPG_RESULT", 5)

    -- Acha wallet (4 keys exatas: Gold/Gems/Canes/Shards)
    local function findWallet()
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table" then
                local g = rawget(obj, "Gold"); local gm = rawget(obj, "Gems")
                local c = rawget(obj, "Canes"); local s = rawget(obj, "Shards")
                if type(g)=="number" and type(gm)=="number" and c ~= nil and s ~= nil then
                    local cnt = 0; for _ in pairs(obj) do cnt = cnt + 1 end
                    if cnt == 4 then return obj end
                end
            end
        end
    end

    -- Acha a tabela de levels (8 stats blades, todos numéricos <= 15)
    -- Filtra por ter Blade_Durability + ODM_Damage + Crit_Chance
    local function findLevels()
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table" then
                local bd = rawget(obj, "Blade_Durability")
                local dmg = rawget(obj, "ODM_Damage")
                local cc = rawget(obj, "Crit_Chance")
                if type(bd)=="number" and type(dmg)=="number" and type(cc)=="number" then
                    local cnt = 0; local allOk = true
                    for k, v in pairs(obj) do
                        cnt = cnt + 1
                        if type(v) ~= "number" or v > 20 then allOk = false; break end
                    end
                    if allOk and cnt == 8 then return obj end
                end
            end
        end
    end

    -- Acha Values module (Upgrade_Costs + Pot_Tags)
    local function findValues()
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table"
               and type(rawget(obj, "Upgrade_Costs")) == "table"
               and type(rawget(obj, "Pot_Tags")) == "table" then
                return obj
            end
        end
    end

    -- Espera com retry — dados podem demorar a aparecer no getgc após teleport pro lobby
    local function waitFor(fn, timeoutSec)
        local t0 = tick()
        while tick() - t0 < timeoutSec do
            local r = fn()
            if r then return r end
            task.wait(0.5)
        end
    end

    local wallet = waitFor(findWallet, 15)
    local levels = waitFor(findLevels, 15)
    local values = waitFor(findValues, 15)
    if not wallet then bridge:Fire({err="wallet not found (15s timeout)"}) return end
    if not levels then bridge:Fire({err="levels not found (15s timeout)"}) return end
    if not values then bridge:Fire({err="Values not found (15s timeout)"}) return end

    local COSTS = values.Upgrade_Costs
    local TAGS  = values.Pot_Tags

    -- Stat names em ordem (mesmas chaves de Upgrades.Blades)
    local STAT_NAMES = {
        "Blade_Durability","ODM_Damage","ODM_Gas","ODM_Range","ODM_Speed",
        "ODM_Control","Crit_Chance","Crit_Damage",
    }
    if WEAPON == "Spears" then
        STAT_NAMES = {
            "Blast_Radius","TS_Damage","TS_Gas","TS_Range","TS_Speed",
            "TS_Control","Crit_Chance","Crit_Damage",
        }
    end

    local function gradeOf()
        local sum = 0; local count = 0
        for _, name in ipairs(STAT_NAMES) do
            local v = levels[name]
            if v then sum = sum + v; count = count + 1 end
        end
        if count == 0 then return 0 end
        return math.floor(sum / count)
    end

    local function tag(grade) return TAGS[grade] or "?" end

    -- Custo do PRÓXIMO upgrade do stat mais barato (= menor level)
    local function cheapestNextCost()
        local minLvl
        for _, name in ipairs(STAT_NAMES) do
            local lvl = levels[name]
            if lvl and lvl < 15 then
                if not minLvl or lvl < minLvl then minLvl = lvl end
            end
        end
        if not minLvl then return nil end  -- tudo maxed
        local c = COSTS[minLvl + 1]
        if WEAPON == "Spears" then c = math.ceil(c * 1.25) end
        return c
    end

    -- Snapshot inicial
    local goldBefore = wallet.Gold
    local gradeBefore = gradeOf()
    local levelsBefore = {}
    for _, n in ipairs(STAT_NAMES) do levelsBefore[n] = levels[n] end

    local log = {}
    local calls = 0
    local totalUpgrades = 0

    for iter = 1, MAX_ITERATIONS do
        local cost = cheapestNextCost()
        if not cost then
            table.insert(log, "Iter " .. iter .. ": tudo MAXED")
            break
        end
        if wallet.Gold < cost then
            table.insert(log, "Iter " .. iter .. ": gold=" .. wallet.Gold .. " < cheapest cost=" .. cost .. " STOP")
            break
        end

        -- Monta lista sorted ASC por level (igual o jogo faz)
        local tbl = {}
        for _, n in ipairs(STAT_NAMES) do
            if levels[n] < 15 then table.insert(tbl, n) end
        end
        table.sort(tbl, function(a, b) return levels[a] < levels[b] end)

        calls = calls + 1
        local goldPre = wallet.Gold

        -- Chamada remota
        local ok, ret = pcall(function() return GET:InvokeServer("S_Equipment", "Upgrade", tbl) end)
        if not ok then
            table.insert(log, "Iter " .. iter .. ": pcall err " .. tostring(ret))
            break
        end
        if ret == nil then
            table.insert(log, "Iter " .. iter .. ": server returned nil (not enough gold)")
            break
        end

        task.wait(0.3)

        -- Re-acha levels (Cache.Data é REPLACED pelo server após Upgrade — nossa ref vira stale)
        local freshLevels = findLevels()
        if freshLevels then levels = freshLevels end
        -- Idem wallet (mesma chance de ser substituída)
        local freshWallet = findWallet()
        if freshWallet then wallet = freshWallet end

        -- Conta quantos stats subiram nesta iteração
        local upsThis = 0
        for _, n in ipairs(STAT_NAMES) do
            if levels[n] > (levelsBefore[n] or 0) then
                upsThis = upsThis + (levels[n] - (levelsBefore[n] or 0))
                levelsBefore[n] = levels[n]
            end
        end
        totalUpgrades = totalUpgrades + upsThis

        if PRINT_PROGRESS then
            table.insert(log, "Iter " .. iter .. ": +" .. upsThis .. " upgrades, gold " .. goldPre .. " -> " .. wallet.Gold .. ", grade=" .. tag(gradeOf()))
        end

        -- Sanidade: se nada subiu nesta iteração (server aceitou mas não progrediu), aborta
        if upsThis == 0 then
            table.insert(log, "Iter " .. iter .. ": server aceitou mas nada subiu, STOP")
            break
        end
    end

    local gradeAfter = gradeOf()
    -- Reset levelsBefore pra snapshot real
    local levelsAfter = {}
    for _, n in ipairs(STAT_NAMES) do levelsAfter[n] = levels[n] end

    -- Adiciona breakdown final
    table.insert(log, "Final levels:")
    for _, n in ipairs(STAT_NAMES) do
        table.insert(log, "  " .. n .. " = " .. tostring(levelsAfter[n]))
    end

    bridge:Fire({
        gradeBefore = gradeBefore,
        gradeAfter = gradeAfter,
        tagBefore = tag(gradeBefore),
        tagAfter = tag(gradeAfter),
        goldBefore = goldBefore,
        goldAfter = wallet.Gold,
        totalUpgrades = totalUpgrades,
        calls = calls,
        log = log,
    })
]==], WEAPON, tostring(PRINT_PROGRESS), MAX_ITERATIONS))

end

local function runStartMission()
-- ═══════════════════════════════════════════════════════════════════
-- AoT Revolution — Start Mission Standalone
-- Rode no LOBBY (PlaceId 14916516914)
-- Detecta sua grade, escolhe a maior dificuldade liberada, e entra.
-- ═══════════════════════════════════════════════════════════════════

local LP = game:GetService("Players").LocalPlayer
local LOBBY_PLACE_ID = 14916516914

if game.PlaceId ~= LOBBY_PLACE_ID then
    warn("[start] Rode no lobby (PlaceId esperado: " .. LOBBY_PLACE_ID .. ")")
    return
end

-- ─── Tunáveis ─────────────────────────────────────────────────────
local MAP       = "Shiganshina"  -- ver tabela: Trost, Forest, Outskirts, Utgard, Docks, Stohess, Chapel
local OBJECTIVE = "Skirmish"     -- Skirmish funciona em TODOS os mapas
local TYPE      = "Missions"     -- Missions / Raids / Waves
local WEAPON    = "Blades"       -- pra calcular grade

-- ─── Bridge actor → main ─────────────────────────────────────────
local charActor = LP.Character and LP.Character:FindFirstChild("Actor")
if not charActor then
    warn("[start] Actor não achado — você está no lobby mesmo?")
    return
end

local bridge = charActor:FindFirstChild("__AOTR_START_RESULT")
if bridge then bridge:Destroy() end
bridge = Instance.new("BindableEvent")
bridge.Name = "__AOTR_START_RESULT"
bridge.Parent = charActor

bridge.Event:Connect(function(data)
    if data.err then
        warn("[start] ERRO: " .. tostring(data.err))
        return
    end
    print(string.format("[start] Grade=%d (%s) → Difficulty=%s | %s + %s + %s",
        data.grade, data.tag, data.difficulty, data.type, data.name, data.objective))
    print(string.format("[start] Modifiers: %d ON, %d OFF, %d falharam",
        data.modOn or 0, data.modOff or 0, data.modFail or 0))
    print(string.format("[start] Create ret=%s, Start ret=%s. Teleportando...",
        tostring(data.createRet), tostring(data.startRet)))
end)

-- ─── Loop no actor ────────────────────────────────────────────────
run_on_actor(charActor, string.format([==[
    local MAP = "%s"
    local OBJECTIVE = "%s"
    local TYPE = "%s"
    local WEAPON = "%s"

    local LP = game:GetService("Players").LocalPlayer
    local GET = game:GetService("ReplicatedStorage").Assets.Remotes.GET
    local actor = LP.Character.Actor
    local bridge = actor:WaitForChild("__AOTR_START_RESULT", 5)

    -- Acha tabela de levels (8 stats)
    local function findLevels()
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table" then
                local bd = rawget(obj, "Blade_Durability")
                local dmg = rawget(obj, "ODM_Damage")
                local cc = rawget(obj, "Crit_Chance")
                if type(bd)=="number" and type(dmg)=="number" and type(cc)=="number" then
                    local cnt = 0; local allOk = true
                    for k, v in pairs(obj) do
                        cnt = cnt + 1
                        if type(v) ~= "number" or v > 20 then allOk = false; break end
                    end
                    if allOk and cnt == 8 then return obj end
                end
            end
        end
    end

    -- Values module (Difficulty_Potential + Pot_Tags)
    local function findValues()
        for _, obj in ipairs(getgc(true)) do
            if type(obj) == "table"
               and type(rawget(obj, "Difficulty_Potential")) == "table"
               and type(rawget(obj, "Pot_Tags")) == "table" then
                return obj
            end
        end
    end

    -- Espera com retry — dados podem demorar a aparecer no getgc após teleport
    local function waitFor(fn, timeoutSec)
        local t0 = tick()
        while tick() - t0 < timeoutSec do
            local r = fn()
            if r then return r end
            task.wait(0.5)
        end
    end

    local levels = waitFor(findLevels, 15)
    local values = waitFor(findValues, 15)
    if not levels then bridge:Fire({err="levels not found (15s)"}) return end
    if not values then bridge:Fire({err="values not found (15s)"}) return end

    -- Calcula grade atual (média dos 8 levels, floor)
    local sum, count = 0, 0
    for _, v in pairs(levels) do sum = sum + v; count = count + 1 end
    local grade = math.floor(sum / count)
    local tag = values.Pot_Tags[grade] or "?"

    -- Acha a maior difficulty liberada pra esse TYPE
    -- Suporta nested (Difficulty_Potential.Missions) E flat (Difficulty_Potential direto = array)
    local diffs = values.Difficulty_Potential[TYPE]
    if not diffs or type(diffs) ~= "table" then
        -- Fallback: estrutura flat
        local first = values.Difficulty_Potential[1] or values.Difficulty_Potential["1"]
        if type(first) == "table" and type(first[1]) == "string" then
            diffs = values.Difficulty_Potential
        end
    end
    if not diffs then bridge:Fire({err="no diffs found"}) return end

    -- Itera por pairs (keys podem ser strings ou números) procurando maior minGrade ≤ grade
    local chosen, chosenMin
    for _, entry in pairs(diffs) do
        if type(entry) == "table"
           and type(entry[1]) == "string"
           and type(entry[2]) == "number"
           and entry[2] <= grade then
            if not chosenMin or entry[2] > chosenMin then
                chosen = entry[1]; chosenMin = entry[2]
            end
        end
    end
    if not chosen then bridge:Fire({err="no difficulty unlocked for grade " .. grade}) return end

    -- Monta payload
    local payload = {
        Name = MAP,
        Difficulty = chosen,
        Type = TYPE,
        Objective = OBJECTIVE,
    }

    -- Create
    local ok1, createRet = pcall(function() return GET:InvokeServer("S_Missions", "Create", payload) end)
    if not ok1 then bridge:Fire({err="Create pcall: " .. tostring(createRet)}) return end
    if createRet == nil then bridge:Fire({err="Create returned nil"}) return end

    task.wait(0.5)

    -- ─── Modifiers: ativa positivos, desativa negativos ───────────────
    local ENABLE = {
        "No Perks", "No Skills", "No Memories",
        "Injury Prone", "Chronic Injuries", "Fog", "Time Trial",
    }
    local DISABLE = { "Nightmare", "Oddball", "Boring", "Simple", "Glass Cannon" }

    local function setMod(tag, wantOn)
        local ret
        for _ = 1, 2 do
            local ok, r = pcall(function() return GET:InvokeServer("S_Missions", "Modify", tag) end)
            if not ok or r == nil then return false end
            ret = r
            if ret == wantOn then return true end
        end
        return ret == wantOn
    end

    local modOn, modOff, modFail = 0, 0, 0
    for _, tag in ipairs(ENABLE) do
        if setMod(tag, true) then modOn = modOn + 1 else modFail = modFail + 1 end
    end
    for _, tag in ipairs(DISABLE) do
        if setMod(tag, false) then modOff = modOff + 1 else modFail = modFail + 1 end
    end

    task.wait(0.3)

    -- Start
    local ok2, startRet = pcall(function() return GET:InvokeServer("S_Missions", "Start") end)
    if not ok2 then bridge:Fire({err="Start pcall: " .. tostring(startRet)}) return end

    bridge:Fire({
        grade = grade,
        tag = tag,
        difficulty = chosen,
        type = TYPE,
        name = MAP,
        objective = OBJECTIVE,
        createRet = tostring(createRet),
        startRet = tostring(startRet),
        modOn = modOn,
        modOff = modOff,
        modFail = modFail,
    })
]==], MAP, OBJECTIVE, TYPE, WEAPON))

print("[start] Disparado. Aguarde teleport...")

end

-- ─── Roteamento ──────────────────────────────────────────────────
if PID == TITLE_PID then
    print("[auto] Title screen — teleportando pro lobby")
    armReinjectAndTeleport(LOBBY_PID)
    return

elseif PID == LOBBY_PID then
    -- PRESTÍGIO tem prioridade: se veio pra prestigiar, faz isso e nada mais
    if gg.__AOTR_DO_PRESTIGE then
        gg.__AOTR_DO_PRESTIGE = false
        print("[auto] Lobby — tentando AUTO-PRESTIGE...")
        task.wait(2)  -- deixa o lobby/data carregar
        local pr = doPrestige()
        print("[auto] ── PRESTIGE resultado ──")
        if pr.log then for _, l in ipairs(pr.log) do print("[auto]   " .. l) end end
        if pr.ok then
            print("[auto] PRESTIGE OK! " .. tostring(pr.pBefore) .. " → " .. tostring(pr.pAfter))
        else
            warn("[auto] PRESTIGE falhou/incerto (err=" .. tostring(pr.err) .. "). Veja o log acima.")
            warn("[auto] Auto-loop PARADO — faça o prestige manual e me mande o log.")
            return  -- para pra não loopar; o log mostra a estrutura real pra ajustar
        end
        task.wait(2)
        -- depois de prestigiar, segue o fluxo normal (upgrades+start_mission)
    end

    -- 0) claima quests completas (só as completas; rápido)
    local cl = doClaimQuests()
    if cl.ok and cl.claimed > 0 then
        print("[auto] Quests claimadas: " .. tostring(cl.claimed))
    end

    -- 1) upgrades (gasta gold). Quando maxed, retorna rápido.
    local ok1 = pcall(function()
        runUpgrades()
    end)
    if not ok1 then warn("[auto] upgrades falhou") end

    -- 2) start_mission (detecta grade + modifiers + Create + Start)
    print("[auto] Iniciando missão...")
    local ok2 = pcall(function()
        runStartMission()
    end)
    if not ok2 then warn("[auto] start_mission falhou") end
    -- queue_on_teleport vai reinjetar quando chegar na missão
    return

elseif PID == MISSION_PID then
    print("[auto] Missão — iniciando combat")
    -- 1) combat
    local ok = pcall(function()
        runCombat()
    end)
    if not ok then warn("[auto] combat falhou") end

    -- 2) Watcher do Rewards UI (card de fim de missão)
    local Interface = LP:WaitForChild("PlayerGui"):WaitForChild("Interface", 30)
    if not Interface then warn("[auto] Interface não encontrada") return end
    local Rewards = Interface:WaitForChild("Rewards", 30)
    if not Rewards then warn("[auto] Rewards UI não encontrada") return end

    local function onMissionEnd()
        if gg.__AOTR_AUTO_FIRED then return end
        gg.__AOTR_AUTO_FIRED = true

        task.wait(2)  -- deixa o card aparecer/animar completo

        local state = readActorState()
        if not state then
            warn("[auto] Não consegui ler state — indo pro lobby por segurança")
            armReinjectAndTeleport(LOBBY_PID)
            return
        end
        if state.err then
            warn("[auto] state err: " .. tostring(state.err) .. " — indo pro lobby")
            armReinjectAndTeleport(LOBBY_PID)
            return
        end

        -- Requisitos de prestígio (tabela do jogo)
        -- {prestige_alvo, level_necessario, exp_total_necessario}
        local PRESTIGE_REQS = {
            {1, 100, 1952500},
            {2, 125, 3429553},
            {3, 150, 5265320},
            {4, 175, 7334070},
            {5, 200, 11673242},
        }
        local curPrestige = state.prestige or 0
        local curLevel = state.level or 0
        -- Acha o requisito do próximo prestígio
        local nextPrestigeLevel, nextPrestigeXp
        for _, req in ipairs(PRESTIGE_REQS) do
            if req[1] == curPrestige + 1 then
                nextPrestigeLevel = req[2]
                nextPrestigeXp = req[3]
                break
            end
        end
        -- PRESTIGE pronto quando: atingiu o level máximo (cap) E a barra de XP encheu.
        -- (a barra XP/Max_XP no level-cap reflete exatamente o XP que falta pro ENLIST)
        local xpFull = state.xp ~= nil and state.maxXp ~= nil and state.xp >= state.maxXp
        local canPrestige = nextPrestigeLevel ~= nil
            and curLevel >= nextPrestigeLevel
            and xpFull

        print("[auto] ╔══════════ FIM DE MISSAO ══════════╗")
        print(string.format("[auto]   Gold: %d  |  Grade: %d (%s)", state.gold, state.grade, state.tag))
        print(string.format("[auto]   Prestige: %d  |  Level: %d/%s (XP %s/%s)",
            curPrestige, curLevel, tostring(nextPrestigeLevel or "MAX"),
            tostring(state.xp), tostring(state.maxXp)))
        print(string.format("[auto]   Custo p/ próxima grade: %d", state.costToNext))

        local decision
        if canPrestige then
            decision = "PRESTIGE disponivel (lvl " .. curLevel .. " + XP cheio)"
        elseif nextPrestigeLevel and curLevel >= nextPrestigeLevel and not xpFull then
            local falta = (state.maxXp or 0) - (state.xp or 0)
            decision = "RETRY (level MAX, faltam " .. falta .. " XP pro ENLIST)"
        elseif state.costToNext > 0 and state.gold >= state.costToNext then
            decision = "LOBBY (vai upgradar)"
        else
            decision = "RETRY (farmando XP" .. (state.costToNext == -1 and ", grade MAX" or "") .. ")"
        end
        print("[auto]   Decisão: " .. decision)
        print("[auto] ╚════════════════════════════════════╝")

        -- PRESTÍGIO: se atingiu level+XP. Prestige só funciona no LOBBY.
        -- Marca flag e teleporta pro lobby; a rotina do lobby executa doPrestige().
        if canPrestige then
            print("[auto] >>> PRONTO PRA PRESTIGE <<< (lvl " .. curLevel .. ") → lobby")
            gg.__AOTR_DO_PRESTIGE = true
            armReinjectAndTeleport(LOBBY_PID)
            return
        end

        if state.costToNext > 0 and state.gold >= state.costToNext then
            armReinjectAndTeleport(LOBBY_PID)
        else
            -- Não dá pra upgrade: RETRY no lugar (Create+Start, sem ir pro lobby)
            local chosen = state.maxDifficulty or "Normal"
            if state.costToNext == -1 then
                print("[auto] Grade MAX — retry " .. chosen)
            else
                print(string.format("[auto] Gold insuficiente (%d < %d) — retry %s",
                    state.gold, state.costToNext, chosen))
            end

            -- Reset sentinel Rewards.Retrying via actor (senão Retry bail silencioso)
            local resetCharActor
            local Chars = workspace:FindFirstChild("Characters")
            local f = Chars and Chars:FindFirstChild(LP.Name)
            resetCharActor = f and f:FindFirstChild("Actor")
            if resetCharActor then
                run_on_actor(resetCharActor, [[
                    for _, obj in ipairs(getgc(true)) do
                        if type(obj) == "table" and rawget(obj, "Retrying") ~= nil then
                            -- Heurística: Rewards module tem Retrying + Rewarded
                            if rawget(obj, "Rewarded") ~= nil then
                                obj.Retrying = false; break
                            end
                        end
                    end
                ]])
                task.wait(0.1)
            end

            -- O Retry real é Functions.Retry com arg "Add" (não S_Missions.Retry)
            local GET = RS.Assets.Remotes.GET
            local okRetry, retRetry = pcall(function()
                return GET:InvokeServer("Functions", "Retry", "Add")
            end)
            print("[auto] Functions.Retry ok=" .. tostring(okRetry) .. " ret=" .. tostring(retRetry))

            -- Se Retry não funcionou em 5s, tenta Create + Modifiers + Start
            task.wait(5)
            if game.PlaceId == MISSION_PID then
                pcall(function()
                    GET:InvokeServer("S_Missions", "Create", {
                        Name = "Shiganshina",
                        Difficulty = chosen,
                        Type = "Missions",
                        Objective = "Skirmish",
                    })
                    task.wait(0.5)

                    -- Modifiers (mesma config do start_mission)
                    local ENABLE = {
                        "No Perks", "No Skills", "No Memories",
                        "Injury Prone", "Chronic Injuries", "Fog", "Time Trial",
                    }
                    local DISABLE = { "Nightmare", "Oddball", "Boring", "Simple", "Glass Cannon" }
                    local function setMod(tag, wantOn)
                        local ret
                        for _ = 1, 2 do
                            local ok, r = pcall(function() return GET:InvokeServer("S_Missions", "Modify", tag) end)
                            if not ok or r == nil then return end
                            ret = r
                            if ret == wantOn then return end
                        end
                    end
                    for _, tag in ipairs(ENABLE) do setMod(tag, true) end
                    for _, tag in ipairs(DISABLE) do setMod(tag, false) end

                    task.wait(0.3)
                    GET:InvokeServer("S_Missions", "Start")
                end)
                task.wait(5)
            end

            -- Última tentativa: ir pro lobby (vai chamar start_mission de lá)
            if game.PlaceId == MISSION_PID then
                warn("[auto] Retry sem efeito — fallback teleport lobby")
                armReinjectAndTeleport(LOBBY_PID)
            end
        end
    end

    -- Dispara se já estiver visível (re-injetado após o card subir)
    if Rewards.Visible then
        task.spawn(onMissionEnd)
    end
    Rewards:GetPropertyChangedSignal("Visible"):Connect(function()
        if Rewards.Visible then task.spawn(onMissionEnd) end
    end)
    return
end

warn("[auto] PlaceId não reconhecido: " .. PID)
