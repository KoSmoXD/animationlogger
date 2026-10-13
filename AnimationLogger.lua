-- Animation Logger | KoSmoXD
-- Client-side animation inspector for player characters and NPCs.
-- Captures Animator.AnimationPlayed and already-playing tracks.
-- Client-visible animations only. No remote execution, game changes, or per-frame loops.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UIS = game:GetService("UserInputService")
local MarketplaceService = game:GetService("MarketplaceService")
local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[Animation Logger] Run this in a client context.")
    return
end

local environment = _G
if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)
    if ok and type(result) == "table" then environment = result end
end
if type(environment.KoSmoAnimationLogger) == "table" and
   type(environment.KoSmoAnimationLogger.shutdown) == "function" then
    pcall(environment.KoSmoAnimationLogger.shutdown)
end

local MAX_HISTORY = 300
local MAX_VISIBLE = 70
-- Each animation asset ID is looked up at most once in this session.
-- Metadata requests run asynchronously and are spaced to avoid bursts.
local assetNameCache = {}
local lookupQueue = {}
local queuedIds = {}
local resolvingNames = false
local history = {}
local filterMode = "All"
local query = ""
local running = false
local closed = false
local watchGeneration = 0
local watching = {}
local worldConnection = nil
local guiConnections = {}
local recentTracks = setmetatable({}, {__mode = "k"})
local refreshQueued = false
local rowPool = {}
local filterButtons = {}

local function connect(signal, callback)
    local c = signal:Connect(callback)
    table.insert(guiConnections, c)
    return c
end

local function new(class, parent, props)
    local v = Instance.new(class)
    for key, val in pairs(props or {}) do v[key] = val end
    v.Parent = parent
    return v
end

local function corner(parent, r)
    new("UICorner", parent, {CornerRadius = UDim.new(0, r)})
end

local colors = {
    panel = Color3.fromRGB(20, 24, 32),
    header = Color3.fromRGB(29, 35, 46),
    control = Color3.fromRGB(41, 49, 63),
    highlight = Color3.fromRGB(68, 117, 216),
    row = Color3.fromRGB(30, 37, 49),
    text = Color3.fromRGB(241, 245, 251),
    muted = Color3.fromRGB(165, 179, 197),
}

local parent
if type(gethui) == "function" then
    local ok, result = pcall(gethui)
    if ok and typeof(result) == "Instance" then parent = result end
end
if not parent then
    local ok = pcall(function()
        local core = game:GetService("CoreGui")
        local test = Instance.new("Folder")
        test.Parent = core
        test:Destroy()
        parent = core
    end)
    if not ok then parent = nil end
end
parent = parent or LocalPlayer:WaitForChild("PlayerGui")

local gui = new("ScreenGui", parent, {
    Name = "KoSmoAnimationLogger",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 950,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(800, 600)
local windowWidth = math.max(290, math.min(490, viewport.X - 20))
local windowHeight = math.max(270, math.min(445, viewport.Y - 30))
local window = new("Frame", gui, {
    Name = "Window",
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    Size = UDim2.fromOffset(windowWidth, windowHeight),
    BackgroundColor3 = colors.panel,
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Active = true,
})
corner(window, 10)
new("UIStroke", window, {Color = colors.highlight, Thickness = 1, Transparency = 0.4})

local header = new("Frame", window, {
    Name = "DragHeader",
    Size = UDim2.new(1, 0, 0, 39),
    BackgroundColor3 = colors.header,
    BorderSizePixel = 0,
    Active = true,
})
new("TextLabel", header, {
    Size = UDim2.new(1, -94, 1, 0),
    Position = UDim2.fromOffset(12, 0),
    BackgroundTransparency = 1,
    Text = "ANIMATION LOGGER",
    TextColor3 = colors.text,
    TextSize = 16,
    TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.GothamBold,
})

local function button(parentInstance, label, pos, size)
    local b = new("TextButton", parentInstance, {
        Text = label,
        Position = pos,
        Size = size,
        BorderSizePixel = 0,
        AutoButtonColor = true,
        BackgroundColor3 = colors.control,
        TextColor3 = colors.text,
        TextSize = 12,
        Font = Enum.Font.GothamMedium,
    })
    corner(b, 6)
    return b
end

local minimizeButton = button(header, "_", UDim2.new(1, -78, 0, 6), UDim2.fromOffset(32, 27))
local closeButton = button(header, "X", UDim2.new(1, -42, 0, 6), UDim2.fromOffset(32, 27))

local content = new("Frame", window, {
    Name = "Content",
    Position = UDim2.fromOffset(0, 39),
    Size = UDim2.new(1, 0, 1, -39),
    BackgroundTransparency = 1,
})
local toolbar = new("Frame", content, {
    Position = UDim2.new(0, 9, 0, 9),
    Size = UDim2.new(1, -18, 0, 30),
    BackgroundTransparency = 1,
})
local recordingButton = button(toolbar, "Pause", UDim2.fromScale(0, 0), UDim2.new(0.25, -3, 1, 0))
local clearButton = button(toolbar, "Clear", UDim2.new(0.25, 2, 0, 0), UDim2.new(0.25, -4, 1, 0))
local copyAllButton = button(toolbar, "Copy All", UDim2.new(0.5, 2, 0, 0), UDim2.new(0.25, -4, 1, 0))
local saveButton = button(toolbar, "Save .txt", UDim2.new(0.75, 2, 0, 0), UDim2.new(0.25, -2, 1, 0))

local filterBar = new("Frame", content, {
    Position = UDim2.new(0, 9, 0, 47),
    Size = UDim2.new(1, -18, 0, 27),
    BackgroundTransparency = 1,
})
for i, name in ipairs({"All", "Players", "NPCs"}) do
    filterButtons[name] = button(filterBar, name,
        UDim2.new((i - 1) / 3, 2, 0, 0),
        UDim2.new(1 / 3, -4, 1, 0))
end

local search = new("TextBox", content, {
    Position = UDim2.new(0, 9, 0, 82),
    Size = UDim2.new(1, -18, 0, 27),
    BackgroundColor3 = colors.control,
    TextColor3 = colors.text,
    PlaceholderColor3 = colors.muted,
    PlaceholderText = "Search character, animation or asset ID...",
    ClearTextOnFocus = false,
    Text = "",
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
    Font = Enum.Font.Gotham,
    BorderSizePixel = 0,
})
corner(search, 6)
new("UIPadding", search, {PaddingLeft = UDim.new(0, 9), PaddingRight = UDim.new(0, 9)})

local status = new("TextLabel", content, {
    Position = UDim2.new(0, 10, 0, 115),
    Size = UDim2.new(1, -20, 0, 22),
    BackgroundTransparency = 1,
    Text = "Starting...",
    TextColor3 = colors.muted,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextSize = 12,
    Font = Enum.Font.Gotham,
})
local scroll = new("ScrollingFrame", content, {
    Name = "Results",
    Position = UDim2.new(0, 9, 0, 141),
    Size = UDim2.new(1, -18, 1, -150),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    ScrollBarImageColor3 = colors.highlight,
    CanvasSize = UDim2.fromOffset(0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
})
new("UIListLayout", scroll, {
    Padding = UDim.new(0, 4),
    FillDirection = Enum.FillDirection.Vertical,
    SortOrder = Enum.SortOrder.LayoutOrder,
})
local function setStatus(message)
    status.Text = message
end

local function copyText(value)
    if type(setclipboard) == "function" then
        local ok = pcall(setclipboard, value)
        if ok then setStatus("Copied to clipboard."); return end
    end
    search.Text = value
    search:CaptureFocus()
    setStatus("Clipboard unavailable; select the text in Search to copy.")
end

local function formatEntry(entry)
    return string.format("[%s] [%s] %s | %s | %s | %s",
        entry.time, entry.category, entry.character, entry.name, entry.id, entry.source)
end

local function makeRow(i)
    local panel = new("Frame", scroll, {
        Name = "Log" .. i,
        Size = UDim2.new(1, -6, 0, 64),
        LayoutOrder = i,
        BackgroundColor3 = colors.row,
        BorderSizePixel = 0,
    })
    corner(panel, 6)
    local title = new("TextLabel", panel, {
        Position = UDim2.fromOffset(8, 3),
        Size = UDim2.new(1, -101, 0, 20),
        BackgroundTransparency = 1,
        Text = "",
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = colors.text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    local detail = new("TextLabel", panel, {
        Position = UDim2.fromOffset(8, 24),
        Size = UDim2.new(1, -101, 0, 18),
        BackgroundTransparency = 1,
        Text = "",
        Font = Enum.Font.GothamMedium,
        TextSize = 11,
        TextColor3 = colors.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    local meta = new("TextLabel", panel, {
        Position = UDim2.fromOffset(8, 43),
        Size = UDim2.new(1, -101, 0, 17),
        BackgroundTransparency = 1,
        Text = "",
        Font = Enum.Font.Code,
        TextSize = 11,
        TextColor3 = colors.muted,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    })
    local copyName = button(panel, "Copy Name",
        UDim2.new(1, -88, 0, 4), UDim2.fromOffset(80, 26))
    local copyId = button(panel, "Copy ID",
        UDim2.new(1, -88, 0, 34), UDim2.fromOffset(80, 26))
    local row = {panel = panel, title = title, detail = detail, meta = meta, entry = nil}
    connect(copyName.Activated, function()
        if row.entry then copyText(row.entry.name) end
    end)
    connect(copyId.Activated, function()
        if row.entry then copyText(row.entry.id) end
    end)
    return row
end

local function matches(entry)
    if filterMode ~= "All" and entry.category ~= filterMode then return false end
    if query == "" then return true end
    local haystack = (entry.character .. " " .. entry.name .. " " .. entry.id .. " " .. entry.category):lower()
    return haystack:find(query, 1, true) ~= nil
end

local function render()
    if closed then return end
    for name, btn in pairs(filterButtons) do
        btn.BackgroundColor3 = name == filterMode and colors.highlight or colors.control
    end
    recordingButton.Text = running and "Pause" or "Start"
    recordingButton.BackgroundColor3 = running and colors.highlight or colors.control
    local displayed = 0
    for _, entry in ipairs(history) do
        if matches(entry) then
            displayed += 1
            if displayed > MAX_VISIBLE then break end
            if not rowPool[displayed] then rowPool[displayed] = makeRow(displayed) end
            local row = rowPool[displayed]
            row.entry = entry
            row.title.Text = entry.name
            row.detail.Text = "[" .. entry.category .. "] " .. entry.character
            row.meta.Text = "ID: " .. entry.id .. " | " .. entry.time .. " (" .. entry.source .. ")"
            row.panel.Visible = true
        end
    end
    local shown = math.min(displayed, MAX_VISIBLE)
    for i = shown + 1, #rowPool do
        rowPool[i].panel.Visible = false
        rowPool[i].entry = nil
    end
    if #history == 0 then
        setStatus((running and "Recording" or "Paused") .. " | no animations logged yet")
    else
        setStatus(string.format("%s | %d logged | showing up to %d",
            running and "Recording" or "Paused", #history, MAX_VISIBLE))
    end
end

local function scheduleRender()
    if refreshQueued or closed then return end
    refreshQueued = true
    task.defer(function()
        refreshQueued = false
        if not closed then render() end
    end)
end

-- Resolve the name listed on the Roblox animation asset page.
-- GetProductInfoAsync can reject private/deleted/restricted assets, so
-- retain the local Animation/AnimationTrack name if lookup fails.
local function queueAssetName(id)
    if closed or not id:match("^%d+$") or assetNameCache[id] ~= nil or queuedIds[id] then return end
    if #lookupQueue >= MAX_HISTORY then return end
    queuedIds[id] = true
    table.insert(lookupQueue, id)
    if resolvingNames then return end
    resolvingNames = true
    task.spawn(function()
        while not closed and #lookupQueue > 0 do
            local nextId = table.remove(lookupQueue, 1)
            queuedIds[nextId] = nil
            local ok, info = pcall(function()
                return MarketplaceService:GetProductInfoAsync(tonumber(nextId), Enum.InfoType.Asset)
            end)
            if closed then break end
            local resolved = ok and type(info) == "table"
                and type(info.Name) == "string" and info.Name ~= "" and info.Name or false
            assetNameCache[nextId] = resolved
            if resolved then
                for _, entry in ipairs(history) do
                    if entry.id == nextId then entry.name = resolved end
                end
                scheduleRender()
            end
            task.wait(0.8)
        end
        resolvingNames = false
    end)
end

local function findCharacter(animator)
    local holder = animator.Parent
    local model
    if holder and (holder:IsA("Humanoid") or holder:IsA("AnimationController")) then
        model = holder.Parent
    else
        model = animator:FindFirstAncestorOfClass("Model")
    end
    if model and not model:IsA("Model") then
        model = animator:FindFirstAncestorOfClass("Model")
    end
    local player = model and Players:GetPlayerFromCharacter(model)
    return (player and player.DisplayName or (model and model.Name or "Unknown")),
        (player and "Players" or "NPCs")
end

local function recordTrack(animator, track, source)
    if closed or not running then return end
    if typeof(track) ~= "Instance" or not track:IsA("AnimationTrack") then return end
    local now = os.clock()
    if recentTracks[track] and now - recentTracks[track] < 0.4 then return end
    recentTracks[track] = now
    local ok, animation = pcall(function() return track.Animation end)
    if not ok then animation = nil end
    local asset = animation and animation.AnimationId or ""
    local id = tostring(asset):match("%d+") or tostring(asset)
    if id == "" then id = "Unknown ID" end
    local fallbackName = (animation and animation.Name) or track.Name or "Unknown animation"
    if fallbackName == "" then fallbackName = "Unknown animation" end
    local knownName = assetNameCache[id]
    local name = (type(knownName) == "string" and knownName) or tostring(fallbackName)
    local character, category = findCharacter(animator)
    table.insert(history, 1, {
        time = os.date("%H:%M:%S"),
        character = tostring(character),
        category = category,
        name = tostring(name),
        id = id,
        source = source,
    })
    if #history > MAX_HISTORY then table.remove(history) end
    queueAssetName(id)
    scheduleRender()
end

local function removeAnimator(animator)
    local c = watching[animator]
    if not c then return end
    watching[animator] = nil
    for _, conn in ipairs(c) do conn:Disconnect() end
end

local function watchAnimator(animator)
    if not running or closed or watching[animator] or
       not animator:IsDescendantOf(Workspace) then return end
    local subscriptions = {}
    watching[animator] = subscriptions
    subscriptions[#subscriptions + 1] = animator.AnimationPlayed:Connect(function(track)
        recordTrack(animator, track, "played")
    end)
    subscriptions[#subscriptions + 1] = animator.AncestryChanged:Connect(function()
        if not animator:IsDescendantOf(Workspace) then removeAnimator(animator) end
    end)
    local ok, tracks = pcall(function() return animator:GetPlayingAnimationTracks() end)
    if ok and type(tracks) == "table" then
        for _, track in ipairs(tracks) do recordTrack(animator, track, "already playing") end
    end
end

local function stop()
    running = false
    watchGeneration += 1
    if worldConnection then worldConnection:Disconnect(); worldConnection = nil end
    for animator in pairs(watching) do removeAnimator(animator) end
    scheduleRender()
end

local function start()
    if closed or running then return end
    running = true
    watchGeneration += 1
    local generation = watchGeneration
    worldConnection = Workspace.DescendantAdded:Connect(function(instance)
        if instance:IsA("Animator") then watchAnimator(instance) end
    end)
    task.spawn(function()
        local descendants = Workspace:GetDescendants()
        for i, instance in ipairs(descendants) do
            if closed or not running or generation ~= watchGeneration then return end
            if instance:IsA("Animator") then watchAnimator(instance) end
            if i % 300 == 0 then task.wait() end
        end
    end)
    scheduleRender()
end

local function shutdown()
    if closed then return end
    stop()
    closed = true
    for _, connection in ipairs(guiConnections) do connection:Disconnect() end
    table.clear(guiConnections)
    gui:Destroy()
    if environment.KoSmoAnimationLogger and
        environment.KoSmoAnimationLogger.shutdown == shutdown then
        environment.KoSmoAnimationLogger = nil
    end
end

environment.KoSmoAnimationLogger = {shutdown = shutdown, getLogs = function()
    return table.clone(history)
end}

connect(recordingButton.Activated, function()
    if running then stop() else start() end
end)
connect(clearButton.Activated, function()
    table.clear(history)
    table.clear(recentTracks)
    scroll.CanvasPosition = Vector2.zero
    scheduleRender()
end)
connect(copyAllButton.Activated, function()
    local lines = {}
    for i = #history, 1, -1 do
        local entry = history[i]
        if matches(entry) then lines[#lines + 1] = formatEntry(entry) end
    end
    if #lines == 0 then setStatus("No matching animations to copy."); return end
    copyText(table.concat(lines, "\n"))
end)
connect(saveButton.Activated, function()
    if type(writefile) ~= "function" then
        setStatus("Save requires an executor with writefile support.")
        return
    end
    local lines = {"Animation Logger | " .. os.date("%Y-%m-%d %H:%M:%S")}
    for i = #history, 1, -1 do
        local entry = history[i]
        if matches(entry) then lines[#lines + 1] = formatEntry(entry) end
    end
    local filename = "AnimationLogger_" .. os.date("%Y%m%d_%H%M%S") .. ".txt"
    local ok, err = pcall(writefile, filename, table.concat(lines, "\n"))
    if ok then setStatus("Saved " .. filename) else setStatus("Save failed: " .. tostring(err)) end
end)
for name, btn in pairs(filterButtons) do
    connect(btn.Activated, function()
        filterMode = name
        scroll.CanvasPosition = Vector2.zero
        scheduleRender()
    end)
end
connect(search:GetPropertyChangedSignal("Text"), function()
    query = search.Text:lower()
    scroll.CanvasPosition = Vector2.zero
    scheduleRender()
end)

local minimized = false
connect(minimizeButton.Activated, function()
    minimized = not minimized
    content.Visible = not minimized
    window.Size = UDim2.fromOffset(windowWidth, minimized and 39 or windowHeight)
    minimizeButton.Text = minimized and "+" or "_"
end)
connect(closeButton.Activated, shutdown)

-- Mouse and touch draggable header.
local dragging, dragStart, origin = false, nil, nil
connect(header.InputBegan, function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 and
       input.UserInputType ~= Enum.UserInputType.Touch then return end
    dragging = true
    dragStart = input.Position
    origin = window.Position
    local ended
    ended = input.Changed:Connect(function()
        if input.UserInputState == Enum.UserInputState.End then
            dragging = false
            ended:Disconnect()
        end
    end)
end)
connect(UIS.InputChanged, function(input)
    if not dragging then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement and
       input.UserInputType ~= Enum.UserInputType.Touch then return end
    local offset = input.Position - dragStart
    window.Position = UDim2.new(
        origin.X.Scale, origin.X.Offset + offset.X,
        origin.Y.Scale, origin.Y.Offset + offset.Y)
end)

start()
print("[Animation Logger] Running. Watching client-visible player and NPC animations.")
