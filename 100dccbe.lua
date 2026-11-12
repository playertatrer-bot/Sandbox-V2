-- Murder Mystery 2 Hub (place 142823291, measured on PlaceVersion 1462)
-- Delta compatible. Rerun to reload. Settings carry over between reloads.
--
-- Measured on 1462: Remotes.Gameplay.GetCurrentPlayerData (RemoteFunction) returns
-- {[name] = {Role, Dead, Kills, Coins, DeadTime}}; RoundStart(timer, data); PlayerDataChanged(data);
-- CoinCollected(coinType, current, max, {Value}); coins are Coin_Server parts in <Map>.CoinContainer
-- with a TouchInterest and a Collected attribute once taken; lobby spawns are Lobby.Spawns.
-- Also measured: weapons are Tools named Knife / Gun in the Backpack; the dropped gun is a Part named
-- GunDrop inside the map; a gun picker-upper keeps Role=Innocent until the server sets Role=Hero;
-- Gun.Shoot is a RemoteEvent (see fireAt); Knife swings via Tool:Activate() then Events.HandleTouched (see stab).
-- Live-tested: Kill all (5 kills in 0.8s), TP + shoot (killed the murderer from 65 studs),
-- auto grab + auto shoot (gun picked up on drop, murderer killed from 16 studs 0.6s later).

local genv = (getgenv and getgenv()) or _G
if genv.MM2Hub and genv.MM2Hub.Destroy then pcall(genv.MM2Hub.Destroy) end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RS = game:GetService("ReplicatedStorage")

local LP = Players.LocalPlayer
local GP = RS:WaitForChild("Remotes"):WaitForChild("Gameplay")

local conns = {}
local alive = true
local function bind(sig, fn) local c = sig:Connect(fn) conns[#conns + 1] = c return c end

local S = {
	ESP = false, ESPNames = true, GunESP = true, CoinESP = false, RoleToast = true,
	CoinFarm = false, FarmSpeed = 25, AvoidHostile = true, AvoidRange = 25, LobbyWhenFull = false,
	SpeedOn = false, WalkSpeed = 24, JumpOn = false, JumpPower = 70,
	Noclip = false, Fly = false, FlySpeed = 50, InfJump = false,
	KnifeAura = false, AuraRange = 15, Capture = false, AutoGrabGun = false,
	AutoShoot = false, ShootRange = 120, ShootDelay = 1.5, ShotLeadMs = 100,
	AntiAFK = true,
}
if type(genv.MM2Saved) == "table" then
	for k, v in pairs(genv.MM2Saved) do if S[k] ~= nil and type(S[k]) == type(v) then S[k] = v end end
end

-- round state -------------------------------------------------------------------

local Data = {}
local bag = {cur = 0, max = nil}
local lastRoleKey

local function setData(d)
	if type(d) == "table" then Data = d end
end

local function refreshData()
	local ok, d = pcall(function() return GP.GetCurrentPlayerData:InvokeServer() end)
	if ok then setData(d) end
end

local function charOf(p) return p and p.Character end
local function hrpOf(p) local c = charOf(p) return c and c:FindFirstChild("HumanoidRootPart") end
local function humOf(p) local c = charOf(p) return c and c:FindFirstChildOfClass("Humanoid") end

local function findTool(p, name)
	local c = charOf(p)
	local t = c and c:FindFirstChild(name)
	if t and t:IsA("Tool") then return t end
	local bp = p:FindFirstChildOfClass("Backpack")
	t = bp and bp:FindFirstChild(name)
	if t and t:IsA("Tool") then return t end
end

local function roleOf(p)
	local d = Data[p.Name]
	local r = type(d) == "table" and d.Role or nil
	-- whoever picks up the dropped gun keeps Role=Innocent in the round data
	if (r == nil or r == "Innocent") and findTool(p, "Gun") then return r and "Hero" or "Sheriff" end
	if r then return r end
	if findTool(p, "Knife") then return "Murderer" end
end

local function isDead(p)
	local d = Data[p.Name]
	if type(d) == "table" and d.Dead then return true end
	local h = humOf(p)
	return not h or h.Health <= 0
end

local function inRound(p) return type(Data[p.Name]) == "table" and not isDead(p) end

local HOSTILE_TO = {Survivor = {Zombie = true}}
local DEFAULT_HOSTILE = {Murderer = true}
local function isHostile(p)
	if p == LP then return false end
	local mine = roleOf(LP)
	local set = HOSTILE_TO[mine] or DEFAULT_HOSTILE
	return set[roleOf(p) or ""] == true
end

local function currentMap()
	for _, c in ipairs(workspace:GetChildren()) do
		if c:IsA("Model") and c.Name ~= "Lobby" and c:FindFirstChild("CoinContainer") then return c end
	end
end

local function findGunDrop()
	local m = currentMap()
	local g = (m and m:FindFirstChild("GunDrop", true)) or workspace:FindFirstChild("GunDrop")
	if g and g:IsA("BasePart") then return g end
end

local function bagFull() return bag.max ~= nil and bag.cur >= bag.max end

-- gui root -----------------------------------------------------------------

local parent = (gethui and gethui()) or game:GetService("CoreGui")
local okParent = pcall(function() local t = Instance.new("Folder") t.Parent = parent t:Destroy() end)
if not okParent then parent = LP:WaitForChild("PlayerGui") end

local gui = Instance.new("ScreenGui")
gui.Name = "MM2Hub"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.DisplayOrder = 999
gui.Parent = parent

local espFolder = Instance.new("Folder")
espFolder.Name = "ESP"
espFolder.Parent = gui

local C = {
	bg = Color3.fromRGB(14, 12, 16),
	panel = Color3.fromRGB(24, 20, 27),
	row = Color3.fromRGB(33, 28, 37),
	stroke = Color3.fromRGB(62, 48, 66),
	text = Color3.fromRGB(240, 235, 242),
	sub = Color3.fromRGB(160, 145, 168),
	accent = Color3.fromRGB(230, 40, 70),
	accent2 = Color3.fromRGB(255, 120, 60),
	off = Color3.fromRGB(62, 54, 70),
	go = Color3.fromRGB(220, 40, 70),
	go2 = Color3.fromRGB(255, 110, 60),
}

local ROLE_COLOR = {
	Murderer = Color3.fromRGB(255, 45, 60),
	Sheriff = Color3.fromRGB(40, 140, 255),
	Hero = Color3.fromRGB(255, 210, 40),
	Innocent = Color3.fromRGB(60, 220, 110),
	Survivor = Color3.fromRGB(60, 220, 110),
	Zombie = Color3.fromRGB(170, 70, 255),
}
local UNKNOWN_COLOR = Color3.fromRGB(180, 180, 180)

local function new(class, props, kids)
	local i = Instance.new(class)
	for k, v in pairs(props or {}) do i[k] = v end
	for _, k in ipairs(kids or {}) do k.Parent = i end
	return i
end
local function corner(r) return new("UICorner", {CornerRadius = UDim.new(0, r)}) end
local function stroke(col, th) return new("UIStroke", {Color = col or C.stroke, Thickness = th or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}) end
local function tween(o, t, props, style)
	local tw = TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local cam = workspace.CurrentCamera
local uiScale = new("UIScale", {Scale = math.clamp(cam.ViewportSize.Y / 430, 0.72, 1.1)})
uiScale.Parent = gui

local function makeDrag(handle, target)
	local dragging, startPos, startInput
	bind(handle.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging, startPos, startInput = true, target.Position, i.Position
			local c
			c = i.Changed:Connect(function()
				if i.UserInputState == Enum.UserInputState.End then dragging = false c:Disconnect() end
			end)
		end
	end)
	bind(UIS.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = (i.Position - startInput) / uiScale.Scale
			target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

local main = new("Frame", {
	Name = "Main", Size = UDim2.fromOffset(400, 290), Position = UDim2.new(0.5, -200, 0.5, -145),
	BackgroundColor3 = C.bg, BorderSizePixel = 0, ClipsDescendants = true, Parent = gui,
}, {corner(12), stroke(C.stroke, 1)})
new("UIGradient", {Color = ColorSequence.new(Color3.fromRGB(24, 16, 22), Color3.fromRGB(12, 10, 14)), Rotation = 90, Parent = main})

local top = new("Frame", {Size = UDim2.new(1, 0, 0, 38), BackgroundTransparency = 1, Parent = main})
local dot = new("Frame", {Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(14, 15), BackgroundColor3 = C.accent, Parent = top}, {corner(4)})
new("UIGradient", {Color = ColorSequence.new(C.accent, C.accent2), Parent = dot})
new("TextLabel", {
	Text = "MM2 Hub", Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.text,
	BackgroundTransparency = 1, Position = UDim2.fromOffset(30, 0), Size = UDim2.new(0, 120, 1, 0),
	TextXAlignment = Enum.TextXAlignment.Left, Parent = top,
})
local roleTag = new("TextLabel", {
	Text = "Lobby", Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.sub,
	BackgroundColor3 = C.row, Position = UDim2.new(1, -176, 0, 9), Size = UDim2.fromOffset(126, 20), Parent = top,
}, {corner(10)})
local closeBtn = new("TextButton", {
	Text = "-", Font = Enum.Font.GothamBold, TextSize = 18, TextColor3 = C.sub, AutoButtonColor = false,
	BackgroundColor3 = C.row, Position = UDim2.new(1, -40, 0, 7), Size = UDim2.fromOffset(26, 24), Parent = top,
}, {corner(8)})
makeDrag(top, main)
new("Frame", {Size = UDim2.new(1, -24, 0, 1), Position = UDim2.fromOffset(12, 38), BackgroundColor3 = C.stroke, BorderSizePixel = 0, Parent = main})

local sideBar = new("Frame", {
	Size = UDim2.new(0, 92, 1, -52), Position = UDim2.fromOffset(10, 46), BackgroundColor3 = C.panel, Parent = main,
}, {corner(10), new("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}), new("UIPadding", {PaddingTop = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6)})})

local pages = new("Frame", {
	Size = UDim2.new(1, -120, 1, -52), Position = UDim2.fromOffset(110, 46), BackgroundTransparency = 1, ClipsDescendants = true, Parent = main,
})

local tabs, current = {}, nil
local function selectTab(t)
	if current == t then return end
	for _, o in pairs(tabs) do
		local isOn = o == t
		tween(o.btn, 0.25, {BackgroundTransparency = isOn and 0 or 1, TextColor3 = isOn and C.text or C.sub})
		tween(o.bar, 0.25, {Size = UDim2.fromOffset(3, isOn and 16 or 0)})
		if isOn then
			o.page.Visible = true
			o.page.Position = UDim2.fromOffset(0, 14)
			o.page.GroupTransparency = 1
			tween(o.page, 0.3, {Position = UDim2.fromOffset(0, 0), GroupTransparency = 0})
		else
			o.page.Visible = false
		end
	end
	current = t
end

local function Tab(name, order)
	local btn = new("TextButton", {
		Text = name, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.sub, AutoButtonColor = false,
		BackgroundColor3 = C.row, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = order, Parent = sideBar,
	}, {corner(8)})
	local bar = new("Frame", {Size = UDim2.fromOffset(3, 0), Position = UDim2.new(0, 0, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), BackgroundColor3 = C.accent, BorderSizePixel = 0, Parent = btn}, {corner(2)})
	local page = new("CanvasGroup", {Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false, Parent = pages})
	local scroll = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 2,
		ScrollBarImageColor3 = C.accent, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = page,
	}, {new("UIListLayout", {Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder}), new("UIPadding", {PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6)})})
	local t = {btn = btn, bar = bar, page = page, list = scroll, n = 0}
	tabs[name] = t
	bind(btn.MouseButton1Click, function() selectTab(t) end)
	return t
end

local function Section(tab, text)
	tab.n = tab.n + 1
	new("TextLabel", {
		Text = string.upper(text), Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.accent,
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = tab.n, Parent = tab.list,
	})
end

local function Label(tab, text, h)
	tab.n = tab.n + 1
	return new("TextLabel", {
		Text = text, Font = Enum.Font.GothamMedium, TextSize = 11, TextColor3 = C.sub, TextWrapped = true,
		BackgroundColor3 = C.panel, Size = UDim2.new(1, 0, 0, h or 34), TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = tab.n, Parent = tab.list,
	}, {corner(8), new("UIPadding", {PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10)})})
end

local function Button(tab, text, cb, container)
	local b = new("TextButton", {
		Text = text, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.text, AutoButtonColor = false,
		BackgroundColor3 = C.go, Size = UDim2.new(1, 0, 0, 34), Parent = container or tab.list,
	}, {corner(8)})
	if not container then tab.n = tab.n + 1 b.LayoutOrder = tab.n end
	new("UIGradient", {Color = ColorSequence.new(C.go, C.go2), Rotation = 0, Parent = b})
	local sc = new("UIScale", {Parent = b})
	bind(b.MouseButton1Click, function()
		sc.Scale = 0.94
		tween(sc, 0.25, {Scale = 1}, Enum.EasingStyle.Back)
		task.spawn(cb)
	end)
	return b
end

local toggleRenders = {}
local function setToggle(key, v)
	S[key] = v
	for _, r in ipairs(toggleRenders[key] or {}) do r(true) end
end

local function Toggle(tab, text, key, cb)
	tab.n = tab.n + 1
	local row = new("TextButton", {
		Text = "", AutoButtonColor = false, BackgroundColor3 = C.row, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = tab.n, Parent = tab.list,
	}, {corner(8)})
	new("TextLabel", {
		Text = text, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.text, BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -60, 1, 0), TextXAlignment = Enum.TextXAlignment.Left, Parent = row,
	})
	local sw = new("Frame", {Size = UDim2.fromOffset(36, 18), Position = UDim2.new(1, -46, 0.5, -9), BackgroundColor3 = C.off, Parent = row}, {corner(9)})
	local knob = new("Frame", {Size = UDim2.fromOffset(14, 14), Position = UDim2.fromOffset(2, 2), BackgroundColor3 = C.text, Parent = sw}, {corner(7)})
	local function render(anim)
		local isOn = S[key]
		local t = anim and 0.25 or 0
		tween(sw, t, {BackgroundColor3 = isOn and C.accent or C.off})
		tween(knob, t, {Position = UDim2.fromOffset(isOn and 20 or 2, 2)}, Enum.EasingStyle.Back)
	end
	render(false)
	toggleRenders[key] = toggleRenders[key] or {}
	table.insert(toggleRenders[key], render)
	bind(row.MouseButton1Click, function()
		setToggle(key, not S[key])
		if cb then task.spawn(cb, S[key]) end
	end)
	if cb and S[key] then task.spawn(cb, true) end
end

local function Slider(tab, text, key, min, max, step, fmt, cb)
	tab.n = tab.n + 1
	local row = new("Frame", {BackgroundColor3 = C.row, Size = UDim2.new(1, 0, 0, 46), LayoutOrder = tab.n, Parent = tab.list}, {corner(8)})
	new("TextLabel", {
		Text = text, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.text, BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -80, 0, 18), TextXAlignment = Enum.TextXAlignment.Left, Parent = row,
	})
	local val = new("TextLabel", {
		Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.accent2, BackgroundTransparency = 1,
		Position = UDim2.new(1, -70, 0, 4), Size = UDim2.fromOffset(60, 18), TextXAlignment = Enum.TextXAlignment.Right, Parent = row,
	})
	local trackF = new("Frame", {Size = UDim2.new(1, -20, 0, 6), Position = UDim2.fromOffset(10, 30), BackgroundColor3 = C.off, Parent = row}, {corner(3)})
	local fill = new("Frame", {Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.accent, BorderSizePixel = 0, Parent = trackF}, {corner(3)})
	new("UIGradient", {Color = ColorSequence.new(C.accent, C.accent2), Parent = fill})
	local knob = new("Frame", {Size = UDim2.fromOffset(12, 12), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), BackgroundColor3 = C.text, Parent = trackF}, {corner(6)})
	local function set(v, anim)
		v = math.clamp(math.floor((v - min) / step + 0.5) * step + min, min, max)
		S[key] = v
		local a = (v - min) / (max - min)
		local t = anim and 0.12 or 0
		tween(fill, t, {Size = UDim2.fromScale(a, 1)})
		tween(knob, t, {Position = UDim2.fromScale(a, 0.5)})
		val.Text = string.format(fmt, v)
		if cb then cb(v) end
	end
	set(S[key], false)
	local held = false
	local function fromX(x)
		local a = math.clamp((x - trackF.AbsolutePosition.X) / trackF.AbsoluteSize.X, 0, 1)
		set(min + a * (max - min), true)
	end
	local hit = new("TextButton", {Text = "", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 22), Parent = row})
	bind(hit.InputBegan, function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			held = true
			fromX(i.Position.X)
			tween(knob, 0.15, {Size = UDim2.fromOffset(16, 16)})
		end
	end)
	bind(UIS.InputChanged, function(i)
		if held and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then fromX(i.Position.X) end
	end)
	bind(UIS.InputEnded, function(i)
		if held and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
			held = false
			tween(knob, 0.15, {Size = UDim2.fromOffset(12, 12)})
		end
	end)
end

local toastHolder = new("Frame", {
	Size = UDim2.fromOffset(250, 220), Position = UDim2.new(1, -260, 1, -230), BackgroundTransparency = 1, Parent = gui,
}, {new("UIListLayout", {Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder})})
local function toast(msg, col)
	local f = new("Frame", {Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = C.panel, BackgroundTransparency = 1, Parent = toastHolder}, {corner(8)})
	local s = stroke(col or C.accent, 1) s.Transparency = 1 s.Parent = f
	local l = new("TextLabel", {
		Text = msg, Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.text, TextTransparency = 1, BackgroundTransparency = 1,
		TextWrapped = true, Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 0), TextXAlignment = Enum.TextXAlignment.Left, Parent = f,
	})
	tween(f, 0.3, {BackgroundTransparency = 0}) tween(l, 0.3, {TextTransparency = 0}) tween(s, 0.3, {Transparency = 0.3})
	task.delay(3, function()
		tween(f, 0.4, {BackgroundTransparency = 1}) tween(l, 0.4, {TextTransparency = 1}) tween(s, 0.4, {Transparency = 1})
		task.wait(0.45) f:Destroy()
	end)
end

local fab = new("TextButton", {
	Text = "MM2", Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.text, AutoButtonColor = false,
	BackgroundColor3 = C.accent, Size = UDim2.fromOffset(46, 46), Position = UDim2.new(0, 16, 0.5, -23), Visible = false, Parent = gui,
}, {corner(23), stroke(C.accent2, 1.5)})
new("UIGradient", {Color = ColorSequence.new(C.accent, C.accent2), Rotation = 45, Parent = fab})
makeDrag(fab, fab)

local open = true
local fullSize = main.Size
local function setOpen(v)
	open = v
	if v then
		main.Visible = true
		main.Size = UDim2.fromOffset(fullSize.X.Offset, 0)
		tween(main, 0.35, {Size = fullSize})
		fab.Visible = false
	else
		tween(main, 0.25, {Size = UDim2.fromOffset(fullSize.X.Offset, 0)}).Completed:Wait()
		if not open then main.Visible = false fab.Visible = true fab.Size = UDim2.fromOffset(0, 0) tween(fab, 0.3, {Size = UDim2.fromOffset(46, 46)}, Enum.EasingStyle.Back) end
	end
end
local fabMoved
bind(fab.InputBegan, function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then fabMoved = fab.Position end end)
bind(fab.MouseButton1Click, function() if fabMoved == fab.Position then setOpen(true) end end)
bind(closeBtn.MouseButton1Click, function() task.spawn(setOpen, false) end)
bind(UIS.InputBegan, function(i, gp) if not gp and i.KeyCode == Enum.KeyCode.RightShift then task.spawn(setOpen, not open) end end)

-- round events -------------------------------------------------------------------

local function rolesSummary()
	local m, s = {}, {}
	for _, p in ipairs(Players:GetPlayers()) do
		local r = roleOf(p)
		if r == "Murderer" then table.insert(m, p.Name) elseif r == "Sheriff" or r == "Hero" then table.insert(s, p.Name) end
	end
	return m, s
end

local function announceRoles()
	if not S.RoleToast then return end
	local m, s = rolesSummary()
	local key = table.concat(m, ",") .. "|" .. table.concat(s, ",")
	if key == lastRoleKey or (#m == 0 and #s == 0) then return end
	lastRoleKey = key
	if #m > 0 then toast("Murderer: " .. table.concat(m, ", "), ROLE_COLOR.Murderer) end
	if #s > 0 then toast("Sheriff/Hero: " .. table.concat(s, ", "), ROLE_COLOR.Sheriff) end
end

bind(GP.PlayerDataChanged.OnClientEvent, function(d) setData(d) announceRoles() end)
bind(GP.RoundStart.OnClientEvent, function(_, d)
	setData(d)
	bag.cur, bag.max = 0, nil
	lastRoleKey = nil
	announceRoles()
end)
bind(GP.CoinCollected.OnClientEvent, function(_, cur, max)
	if type(cur) == "number" then bag.cur = cur end
	if type(max) == "number" then bag.max = max end
end)
bind(GP.CoinsStarted.OnClientEvent, function(info)
	if type(info) ~= "table" then return end
	for _, c in pairs(info) do
		if type(c) == "table" and type(c.CollectionLimit) == "number" then
			bag.max = c.CollectionLimit
			if type(c.CollectedAmount) == "number" then bag.cur = c.CollectedAmount end
		end
	end
end)
bind(GP.GameOver.OnClientEvent, function() bag.cur, bag.max = 0, nil end)
task.spawn(function()
	refreshData()
	announceRoles()
	while alive do
		task.wait(8)
		if alive then refreshData() end
	end
end)

-- movement -------------------------------------------------------------------

local farming = false
local savedCollide = setmetatable({}, {__mode = "k"})
local baseWalk, baseJump

local function applyCollide()
	local c = LP.Character
	if not c then return end
	local want = S.Noclip or S.Fly or farming
	for _, p in ipairs(c:GetDescendants()) do
		if p:IsA("BasePart") then
			if want then
				if savedCollide[p] == nil then savedCollide[p] = p.CanCollide end
				p.CanCollide = false
			elseif savedCollide[p] ~= nil then
				p.CanCollide = savedCollide[p]
				savedCollide[p] = nil
			end
		end
	end
end
bind(RunService.Stepped, applyCollide)

bind(RunService.Heartbeat, function()
	local h = humOf(LP)
	if not h then return end
	if S.SpeedOn then
		baseWalk = baseWalk or h.WalkSpeed
		if h.WalkSpeed ~= S.WalkSpeed then h.WalkSpeed = S.WalkSpeed end
	elseif baseWalk then
		h.WalkSpeed = baseWalk
		baseWalk = nil
	end
	if S.JumpOn then
		baseJump = baseJump or h.JumpPower
		h.UseJumpPower = true
		if h.JumpPower ~= S.JumpPower then h.JumpPower = S.JumpPower end
	elseif baseJump then
		h.JumpPower = baseJump
		baseJump = nil
	end
end)

bind(UIS.JumpRequest, function()
	if not S.InfJump then return end
	local h = humOf(LP)
	if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
end)

local flyLV, flyAtt
local function stopFly()
	if flyLV then flyLV:Destroy() flyLV = nil end
	if flyAtt then flyAtt:Destroy() flyAtt = nil end
end
bind(RunService.Heartbeat, function()
	if not S.Fly then if flyLV then stopFly() end return end
	local hrp, h = hrpOf(LP), humOf(LP)
	if not hrp or not h then return end
	if not flyLV or flyLV.Parent ~= hrp then
		stopFly()
		flyAtt = new("Attachment", {Name = "MM2FlyAtt", Parent = hrp})
		flyLV = new("LinearVelocity", {
			Name = "MM2Fly", Attachment0 = flyAtt, MaxForce = math.huge,
			VelocityConstraintMode = Enum.VelocityConstraintMode.Vector, RelativeTo = Enum.ActuatorRelativeTo.World, Parent = hrp,
		})
	end
	local cf = cam.CFrame
	local md = h.MoveDirection
	local dir = Vector3.zero
	if md.Magnitude > 0.05 then
		local fwd = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		local right = Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
		if fwd.Magnitude > 0 then fwd = fwd.Unit end
		if right.Magnitude > 0 then right = right.Unit end
		dir = cf.LookVector * md:Dot(fwd) + cf.RightVector * md:Dot(right)
		if dir.Magnitude > 0 then dir = dir.Unit end
	end
	if UIS:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.yAxis end
	if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir - Vector3.yAxis end
	flyLV.VectorVelocity = dir * S.FlySpeed
end)

local function tpTo(cf)
	local hrp = hrpOf(LP)
	if not hrp then return false end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.CFrame = cf
	return true
end

local function lobbyCF()
	local sp = workspace:FindFirstChild("Lobby") and workspace.Lobby:FindFirstChild("Spawns")
	local list = sp and sp:GetChildren() or {}
	local pick = #list > 0 and list[math.random(1, #list)]
	if pick and pick:IsA("BasePart") then return pick.CFrame + Vector3.new(0, 4, 0) end
end

local function mapCF()
	local m = currentMap()
	local sp = m and m:FindFirstChild("Spawns")
	local list = sp and sp:GetChildren() or {}
	local pick = #list > 0 and list[math.random(1, #list)]
	if pick and pick:IsA("BasePart") then return pick.CFrame + Vector3.new(0, 4, 0) end
end

-- coin farm ------------------------------------------------------------------

-- teleporting actions pause the farm, otherwise its tween drags the character back mid-action
local busy = 0
local farmTween
local function beginAction()
	busy += 1
	if farmTween then farmTween:Cancel() end
end
local function endAction() busy = math.max(busy - 1, 0) end
local function teleportTo(cf)
	beginAction()
	local ok = tpTo(cf)
	endAction()
	return ok
end
local function asAction(fn, ...)
	beginAction()
	local ok, err = pcall(fn, ...)
	endAction()
	if not ok then warn("[MM2Hub] " .. tostring(err)) end
end

local function hostileNear(pos, range)
	for _, p in ipairs(Players:GetPlayers()) do
		if isHostile(p) and not isDead(p) then
			local h = hrpOf(p)
			if h and (h.Position - pos).Magnitude < range then return true end
		end
	end
	return false
end

local function pickCoin(from)
	local m = currentMap()
	local cc = m and m:FindFirstChild("CoinContainer")
	if not cc then return end
	local best, bd
	for _, c in ipairs(cc:GetChildren()) do
		if c.Name == "Coin_Server" and c:IsA("BasePart") and not c:GetAttribute("Collected") and c:FindFirstChildOfClass("TouchTransmitter") then
			if not (S.AvoidHostile and hostileNear(c.Position, S.AvoidRange)) then
				local d = (c.Position - from).Magnitude
				if not bd or d < bd then best, bd = c, d end
			end
		end
	end
	return best, bd
end

local function canFarm()
	return alive and S.CoinFarm and busy == 0 and inRound(LP) and not bagFull() and hrpOf(LP) ~= nil
end

local leftForLobby = false
task.spawn(function()
	while alive do
		if canFarm() then
			leftForLobby = false
			local hrp = hrpOf(LP)
			local coin, dist = pickCoin(hrp.Position)
			if coin and dist > 300 then
				-- far away (lobby or off-map): hop to a map spawn instead of crawling there
				local cf = mapCF()
				if cf then tpTo(cf) task.wait(0.3) end
				coin, dist = pickCoin(hrp.Position)
			end
			if coin then
				farming = true
				local tw = TweenService:Create(hrp, TweenInfo.new(math.max(dist / S.FarmSpeed, 0.05), Enum.EasingStyle.Linear), {CFrame = coin.CFrame})
				farmTween = tw
				tw:Play()
				local t0 = os.clock()
				while tw.PlaybackState == Enum.PlaybackState.Playing do
					if not canFarm() or coin.Parent == nil or coin:GetAttribute("Collected") or os.clock() - t0 > 15 then tw:Cancel() break end
					hrp.AssemblyLinearVelocity = Vector3.zero
					task.wait()
				end
				farmTween = nil
				task.wait(0.15)
			else
				farming = false
				task.wait(0.4)
			end
		else
			farming = false
			if S.CoinFarm and S.LobbyWhenFull and bagFull() and inRound(LP) and not leftForLobby then
				leftForLobby = true
				local cf = lobbyCF()
				if cf then tpTo(cf) toast("Bag full, sent you to the lobby") end
			end
			task.wait(0.3)
		end
	end
	farming = false
end)

-- combat (knife side untested on 1462) -------------------------------------------

local function equip(tool)
	local h = humOf(LP)
	if not (tool and h) then return false end
	if tool.Parent ~= LP.Character then h:EquipTool(tool) task.wait(0.15) end
	return tool.Parent == LP.Character
end

local function targets()
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and inRound(p) and hrpOf(p) then table.insert(out, p) end
	end
	return out
end

-- KnifeClient (1462): Tool.Activated swings (works on touch too) and fires Events.KnifeStabbed with a
-- 0.85s cooldown; for ~1s after a swing every part the Handle touches goes to Events.HandleTouched:FireServer(part).
local KNIFE_COOLDOWN = 0.9
local lastSwing = -10

local function stab(p, knife, timeout)
	local events = knife:FindFirstChild("Events")
	local touched = events and events:FindFirstChild("HandleTouched")
	local t0 = os.clock()
	while alive and os.clock() - t0 < timeout and not isDead(p) do
		local th = hrpOf(p)
		if not th or knife.Parent ~= LP.Character then break end
		tpTo(th.CFrame * CFrame.new(0, 0, 1.6))
		if os.clock() - lastSwing >= KNIFE_COOLDOWN then
			knife:Activate()
			lastSwing = os.clock()
		end
		if touched and os.clock() - lastSwing < 0.8 then touched:FireServer(th) end
		task.wait(0.1)
	end
	return isDead(p)
end

local function killAll()
	local knife = findTool(LP, "Knife")
	if not knife then toast("No Knife: you're not the murderer") return end
	if not equip(knife) then toast("Couldn't equip the Knife") return end
	local back = hrpOf(LP) and hrpOf(LP).CFrame
	local killed = 0
	asAction(function()
		for _, p in ipairs(targets()) do
			if stab(p, knife, 1.5) then killed += 1 end
		end
	end)
	if back then tpTo(back) end
	toast(("Kill all: %d killed"):format(killed))
end

local auraBusy = false
bind(RunService.Heartbeat, function()
	if not S.KnifeAura or auraBusy then return end
	local knife = findTool(LP, "Knife")
	local me = hrpOf(LP)
	if not knife or not me then return end
	for _, p in ipairs(targets()) do
		local th = hrpOf(p)
		if th and (th.Position - me.Position).Magnitude <= S.AuraRange then
			auraBusy = true
			task.spawn(function()
				if equip(knife) then asAction(stab, p, knife, 1.2) end
				auraBusy = false
			end)
			return
		end
	end
end)

local function murdererTarget()
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP and roleOf(p) == "Murderer" and not isDead(p) and hrpOf(p) then return p end
	end
end

-- GunClient (1462) fires Gun.Shoot:FireServer(HRP.GunRaycastAttachment.WorldCFrame, CFrame.new(targetPos))
-- and ignores Tool.Activated on touch devices, so the remote is called directly.
local function aimPoint(p)
	local c = charOf(p)
	local part = c and (c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso") or c:FindFirstChild("HumanoidRootPart"))
	return part and part.Position
end

-- Mirrors WeaponService.WeaponRaycast (1462): ignores your character and parts tagged "WeaponPassthrough",
-- passes through parts with Transparency exactly 1, and stops on everything else, including visible
-- non-collidable decor and other players (a bystander in the way would take the bullet).
local CollectionService = game:GetService("CollectionService")
local function hasLOS(from, to, targetChar)
	local ignore = {LP.Character}
	for _, t in ipairs(CollectionService:GetTagged("WeaponPassthrough")) do ignore[#ignore + 1] = t end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	for _ = 1, 32 do
		params.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(from, to - from, params)
		if not hit then return true end
		local inst = hit.Instance
		if targetChar and inst:IsDescendantOf(targetChar) then return true end
		if inst.Transparency == 1 then
			ignore[#ignore + 1] = inst
		else
			return false, inst
		end
	end
	return false
end

local shootStatus = "idle"
local lastShot, lastAutoCheck = 0, 0
local shooting = false

-- Other players are drawn ~2x ping plus interpolation in the past; at 17 studs/s that put a running murderer
-- 2.5-4 studs ahead of the torso we aimed at (two misses at 18m and 25m). Lead = 2*ping + ShotLeadMs (uncalibrated).
local function leadTime()
	local ok, ping = pcall(function() return LP:GetNetworkPing() end)
	ping = (ok and type(ping) == "number") and ping or 0.1
	return math.clamp(2 * ping + S.ShotLeadMs / 1000, 0, 0.6)
end

-- AssemblyLinearVelocity of other players is unreliable on the client (read 3 for a player moving 15),
-- so speed comes from where the root part actually was ~0.15s ago.
local posTrack = setmetatable({}, {__mode = "k"})
bind(RunService.Heartbeat, function()
	local now = os.clock()
	for _, p in ipairs(Players:GetPlayers()) do
		local th = p ~= LP and hrpOf(p)
		if th then
			local list = posTrack[p] or {}
			posTrack[p] = list
			list[#list + 1] = {t = now, pos = th.Position}
			while #list > 2 and now - list[1].t > 0.3 do table.remove(list, 1) end
		else
			posTrack[p] = nil
		end
	end
end)

local function trackedVelocity(p)
	local list = posTrack[p]
	if not list or #list < 2 then return Vector3.zero end
	local newest = list[#list]
	local oldest = list[1]
	for i = #list, 1, -1 do
		if newest.t - list[i].t >= 0.15 then oldest = list[i] break end
	end
	local dt = newest.t - oldest.t
	if dt < 0.05 then return Vector3.zero end
	local v = (newest.pos - oldest.pos) / dt
	v = Vector3.new(v.X, 0, v.Z)
	return v.Magnitude > 60 and Vector3.zero or v
end

local function leadPoint(p)
	local target = aimPoint(p)
	if not target then return nil, 0 end
	local v = trackedVelocity(p)
	local t = leadTime()
	return target + v * t, v.Magnitude, t
end

local function faceTarget(p)
	local me, target = hrpOf(LP), aimPoint(p)
	if not (me and target) then return 0 end
	local flat = Vector3.new(target.X, me.Position.Y, target.Z)
	if (flat - me.Position).Magnitude < 0.5 then return 0 end
	local before = math.deg(math.acos(math.clamp(me.CFrame.LookVector:Dot((flat - me.Position).Unit), -1, 1)))
	me.CFrame = CFrame.lookAt(me.Position, flat)
	return before
end

local lastShotInfo = ""
local shotTurn
local function fireAt(p)
	local gun = findTool(LP, "Gun")
	local me = hrpOf(LP)
	local att = me and me:FindFirstChild("GunRaycastAttachment")
	if not (gun and att and aimPoint(p)) then return false, "missing gun or target" end
	if not equip(gun) then return false, "couldn't equip the Gun" end
	local shoot = gun:FindFirstChild("Shoot")
	if not (shoot and shoot:IsA("RemoteEvent")) then return false, "Gun.Shoot remote missing" end
	local target, speed, t = leadPoint(p)
	if not target then return false, "lost the target" end
	shoot:FireServer(att.WorldCFrame, CFrame.new(target))
	lastShot = os.clock()
	lastShotInfo = ("speed %d, lead %dms"):format(math.floor(speed or 0), math.floor((t or 0) * 1000))
	if shotTurn then lastShotInfo = lastShotInfo .. (", turned %d"):format(math.floor(shotTurn)) shotTurn = nil end
	return true
end

local function waitKill(p, timeout)
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		if isDead(p) then return true end
		task.wait(0.1)
	end
	return isDead(p)
end

local shotHistory = {}
local function reportShot(p, how)
	local killed = waitKill(p, 1.5)
	shootStatus = (killed and "killed " or "missed ") .. p.Name .. " (" .. how .. ", " .. lastShotInfo .. ")"
	shotHistory[#shotHistory + 1] = shootStatus
	if #shotHistory > 20 then table.remove(shotHistory, 1) end
	toast(killed and ("Killed murderer " .. p.Name) or ("Shot missed " .. p.Name), killed and ROLE_COLOR.Innocent or ROLE_COLOR.Murderer)
end

-- spots around the murderer in the murderer's own frame (+Z is behind); first one with a clear shot wins
local SHOOT_SPOTS = {
	CFrame.new(0, 1, 9), CFrame.new(-9, 1, 0), CFrame.new(9, 1, 0),
	CFrame.new(0, 1, -9), CFrame.new(0, 9, 6),
}

local function pickSpot(m)
	local th, target = hrpOf(m), aimPoint(m)
	if not (th and target) then return nil end
	for _, off in ipairs(SHOOT_SPOTS) do
		if hasLOS((th.CFrame * off).Position, target, charOf(m)) then return off end
	end
	return SHOOT_SPOTS[1]
end

local function holdSpot(m, off, duration)
	local t0 = os.clock()
	repeat
		local th, me, target = hrpOf(m), hrpOf(LP), aimPoint(m)
		if not (th and me and target) then return false end
		me.AssemblyLinearVelocity = Vector3.zero
		me.CFrame = CFrame.lookAt((th.CFrame * off).Position, target)
		RunService.Heartbeat:Wait()
	until os.clock() - t0 >= duration
	return true
end

local function tpShootMurderer()
	if shooting then return end
	local gun = findTool(LP, "Gun")
	if not gun then toast("No Gun: you're not the sheriff/hero") return end
	local m = murdererTarget()
	if not m then toast("No murderer found") return end
	local me = hrpOf(LP)
	if not me then return end
	shooting = true
	beginAction()
	local back = me.CFrame
	local ok, why = pcall(function()
		if not equip(gun) then error("couldn't equip the Gun", 0) end
		local off = pickSpot(m)
		if not off then error("murderer has no character", 0) end
		-- stay on the spot long enough for the server to see you there before and after the shot
		if not holdSpot(m, off, 0.25) then error("lost the murderer", 0) end
		local fired, err = fireAt(m)
		if not fired then error(err, 0) end
		holdSpot(m, off, 0.15)
	end)
	tpTo(back)
	shooting = false
	endAction()
	if ok then reportShot(m, "tp shot") else shootStatus = "tp shot failed: " .. tostring(why) toast("Can't shoot: " .. tostring(why)) end
end

bind(RunService.Heartbeat, function()
	if not S.AutoShoot or shooting then return end
	local now = os.clock()
	if now - lastAutoCheck < 0.1 or now - lastShot < S.ShootDelay then return end
	lastAutoCheck = now
	if not findTool(LP, "Gun") then shootStatus = "auto: no Gun" return end
	if not inRound(LP) then shootStatus = "auto: not in a round" return end
	local m = murdererTarget()
	local me, th = hrpOf(LP), m and hrpOf(m)
	if not (me and th) then shootStatus = "auto: no murderer found" return end
	local dist = math.floor((th.Position - me.Position).Magnitude)
	if dist > S.ShootRange then shootStatus = ("auto: murderer %dm away"):format(dist) return end
	local att = me:FindFirstChild("GunRaycastAttachment")
	local target = aimPoint(m)
	if not target then shootStatus = "auto: murderer has no torso" return end
	local clear, blocker = hasLOS(att and att.WorldPosition or me.Position, target, charOf(m))
	if not clear then shootStatus = "auto: blocked by " .. (blocker and blocker.Name or "?") return end
	shooting = true
	task.spawn(function()
		-- stop the farm tween and stand still briefly so the server has your real position as the shot origin
		local moving = farmTween ~= nil
		beginAction()
		local hrp = hrpOf(LP)
		if hrp then hrp.AssemblyLinearVelocity = Vector3.zero end
		-- GunRaycastAttachment sits 3.45 studs in front of the root (1462); point blank the ray starts inside
		-- the murderer and misses (seen at 2m), so step back to 7 studs first
		local th = hrpOf(m)
		if hrp and th then
			local away = Vector3.new(hrp.Position.X - th.Position.X, 0, hrp.Position.Z - th.Position.Z)
			if away.Magnitude < 6 then
				if away.Magnitude < 0.1 then away = -th.CFrame.LookVector end
				local spot = Vector3.new(th.Position.X, hrp.Position.Y, th.Position.Z) + away.Unit * 7
				tpTo(CFrame.lookAt(spot, Vector3.new(th.Position.X, spot.Y, th.Position.Z)))
				moving = true
			end
		end
		local turned = faceTarget(m)
		if moving or turned > 20 then task.wait(0.15) end
		faceTarget(m)
		shotTurn = turned
		local fired, err = false, "lost line of sight"
		local me2, t2 = hrpOf(LP), aimPoint(m)
		local att2 = me2 and me2:FindFirstChild("GunRaycastAttachment")
		if t2 and hasLOS(att2 and att2.WorldPosition or me2.Position, t2, charOf(m)) then fired, err = fireAt(m) end
		if fired then task.wait(0.1) end
		endAction()
		shooting = false
		if fired then reportShot(m, ("auto %dm"):format(dist)) else shootStatus = "auto: " .. tostring(err) end
	end)
end)

local function grabGun()
	local g = findGunDrop()
	if not g then toast("No dropped gun found") return end
	local me = hrpOf(LP)
	if not me then return end
	local back = me.CFrame
	asAction(function()
		tpTo(g.CFrame)
		task.wait(0.35)
	end)
	tpTo(back)
	toast(findTool(LP, "Gun") and "Got the gun" or "Touched the gun drop, no Gun in backpack yet")
end

local grabbing = false
local function tryAutoGrab()
	if not S.AutoGrabGun or grabbing or not inRound(LP) or roleOf(LP) == "Murderer" or findTool(LP, "Gun") or not findGunDrop() then return end
	grabbing = true
	pcall(grabGun)
	task.wait(1)
	grabbing = false
end
-- react the moment the drop spawns; the poll below only covers drops that existed before load
bind(workspace.DescendantAdded, function(d)
	if d.Name == "GunDrop" and S.AutoGrabGun then task.defer(tryAutoGrab) end
end)
task.spawn(function()
	while alive do
		task.wait(0.3)
		tryAutoGrab()
	end
end)

-- remote capture: logs what the Knife/Gun send so their remotes can be measured -----------

genv.MM2Capture = genv.MM2Capture or {}
local capLog = genv.MM2Capture
local function installCapture()
	if genv.MM2CaptureHooked then return true end
	if not (hookmetamethod and getnamecallmethod and newcclosure and checkcaller) then return false end
	local old
	old = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
		local m = getnamecallmethod()
		if genv.MM2CaptureOn and (m == "FireServer" or m == "InvokeServer") and not checkcaller() then
			local scr = getcallingscript and getcallingscript() or nil
			capLog[#capLog + 1] = {remote = self, method = m, args = table.pack(...), script = scr, t = os.clock()}
			if #capLog > 150 then table.remove(capLog, 1) end
		end
		return old(self, ...)
	end))
	genv.MM2CaptureHooked = true
	return true
end

local function ser(v, d)
	d = d or 0
	local t = typeof(v)
	if t == "table" then
		if d > 1 then return "{...}" end
		local s, n = {}, 0
		for k, x in pairs(v) do
			n += 1
			if n > 10 then s[#s + 1] = "..." break end
			s[#s + 1] = tostring(k) .. "=" .. ser(x, d + 1)
		end
		return "{" .. table.concat(s, ",") .. "}"
	elseif t == "Instance" then
		return v:GetFullName()
	elseif t == "Vector3" or t == "CFrame" then
		return t .. "(" .. tostring(v) .. ")"
	end
	return tostring(v)
end

local function dumpCapture()
	local n = 0
	for _, e in ipairs(capLog) do
		local scr = e.script and e.script:GetFullName() or "?"
		local rn = e.remote and e.remote:GetFullName() or "?"
		if scr:find("Knife") or scr:find("Gun") or rn:find("Knife") or rn:find("Gun") or rn:find("Shoot") or rn:find("Throw") or rn:find("Stab") then
			local a = {}
			for i = 1, e.args.n do a[i] = ser(e.args[i]) end
			print(("[MM2CAP] %.1f %s:%s from %s args(%s)"):format(e.t, rn, e.method, scr, table.concat(a, ", ")))
			n += 1
		end
	end
	toast(("Printed %d weapon calls to console"):format(n))
end

-- esp ---------------------------------------------------------------------------

local espObjs = {}
local function clearEsp(p)
	local o = espObjs[p]
	if o then
		if o.hl then o.hl:Destroy() end
		if o.bb then o.bb:Destroy() end
		espObjs[p] = nil
	end
end

local gunMark
local coinMarks = {}

local function updateEsp()
	local me = hrpOf(LP)
	for _, p in ipairs(Players:GetPlayers()) do
		local c = p.Character
		local head = c and c:FindFirstChild("Head")
		local show = S.ESP and p ~= LP and c and head and not isDead(p)
		if not show then
			clearEsp(p)
		else
			local o = espObjs[p]
			if not o or o.char ~= c then
				clearEsp(p)
				o = {char = c}
				o.hl = new("Highlight", {Adornee = c, FillTransparency = 0.6, OutlineTransparency = 0, DepthMode = Enum.HighlightDepthMode.AlwaysOnTop, Parent = espFolder})
				o.bb = new("BillboardGui", {Adornee = head, Size = UDim2.fromOffset(180, 34), StudsOffset = Vector3.new(0, 2.6, 0), AlwaysOnTop = true, Parent = espFolder})
				o.lbl = new("TextLabel", {
					BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Font = Enum.Font.GothamBold, TextSize = 13,
					TextStrokeTransparency = 0.4, TextColor3 = C.text, Parent = o.bb,
				})
				espObjs[p] = o
			end
			local r = roleOf(p)
			local col = ROLE_COLOR[r or ""] or UNKNOWN_COLOR
			o.hl.FillColor, o.hl.OutlineColor = col, col
			o.lbl.TextColor3 = col
			o.bb.Enabled = S.ESPNames
			local dist = me and math.floor((head.Position - me.Position).Magnitude) or 0
			o.lbl.Text = ("%s\n%s · %dm"):format(p.DisplayName, r or "?", dist)
		end
	end
	for p in pairs(espObjs) do if p.Parent ~= Players then clearEsp(p) end end

	local g = S.GunESP and findGunDrop()
	if g then
		if not gunMark or gunMark.Adornee ~= g then
			if gunMark then gunMark:Destroy() end
			gunMark = new("BillboardGui", {Adornee = g, Size = UDim2.fromOffset(90, 26), AlwaysOnTop = true, Parent = espFolder}, {
				new("TextLabel", {Text = "GUN", BackgroundColor3 = ROLE_COLOR.Sheriff, Size = UDim2.fromScale(1, 1), Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.text}, {corner(6)}),
			})
		end
	elseif gunMark then
		gunMark:Destroy() gunMark = nil
	end

	local m = S.CoinESP and currentMap()
	local cc = m and m:FindFirstChild("CoinContainer")
	local seen = {}
	if cc then
		for _, coin in ipairs(cc:GetChildren()) do
			if coin.Name == "Coin_Server" and not coin:GetAttribute("Collected") then
				seen[coin] = true
				if not coinMarks[coin] then
					coinMarks[coin] = new("BillboardGui", {Adornee = coin, Size = UDim2.fromOffset(8, 8), AlwaysOnTop = true, Parent = espFolder}, {
						new("Frame", {BackgroundColor3 = Color3.fromRGB(255, 205, 40), Size = UDim2.fromScale(1, 1)}, {corner(4)}),
					})
				end
			end
		end
	end
	for coin, mk in pairs(coinMarks) do
		if not seen[coin] then mk:Destroy() coinMarks[coin] = nil end
	end
end

task.spawn(function()
	while alive do
		pcall(updateEsp)
		local r = roleOf(LP)
		local txt = r or "Lobby"
		if isDead(LP) and r then txt = r .. " (dead)" end
		if bag.max then txt = ("%s · %d/%d"):format(txt, bag.cur, bag.max) end
		roleTag.Text = txt
		roleTag.TextColor3 = ROLE_COLOR[r or ""] or C.sub
		task.wait(0.25)
	end
end)

-- anti afk -------------------------------------------------------------------

local VU = game:GetService("VirtualUser")
bind(LP.Idled, function()
	if not S.AntiAFK then return end
	pcall(function() VU:CaptureController() VU:ClickButton2(Vector2.new()) end)
end)

-- pages -------------------------------------------------------------------------

local tESP = Tab("Visuals", 1)
Section(tESP, "Players")
Toggle(tESP, "Role ESP", "ESP")
Toggle(tESP, "Names + role + distance", "ESPNames")
Toggle(tESP, "Announce murderer / sheriff", "RoleToast", function(v) if v then lastRoleKey = nil announceRoles() end end)
local rolesLbl = Label(tESP, "Murderer: ?  ·  Sheriff: ?", 40)
Section(tESP, "World")
Toggle(tESP, "Dropped gun marker", "GunESP")
Toggle(tESP, "Coin markers", "CoinESP")
task.spawn(function()
	while alive do
		local m, s = rolesSummary()
		rolesLbl.Text = ("Murderer: %s\nSheriff/Hero: %s"):format(#m > 0 and table.concat(m, ", ") or "-", #s > 0 and table.concat(s, ", ") or "-")
		task.wait(0.5)
	end
end)

local tFarm = Tab("Farm", 2)
Section(tFarm, "Coins")
Toggle(tFarm, "Coin autofarm", "CoinFarm", function(v) if not v then farming = false end end)
Slider(tFarm, "Farm speed (studs/s)", "FarmSpeed", 10, 60, 1, "%d")
Toggle(tFarm, "Skip coins near killer", "AvoidHostile")
Slider(tFarm, "Killer avoid radius", "AvoidRange", 10, 60, 1, "%d")
Toggle(tFarm, "Go to lobby when bag full", "LobbyWhenFull")
local bagLbl = Label(tFarm, "Bag: -")
task.spawn(function()
	while alive do
		bagLbl.Text = bag.max and ("Bag: %d / %d%s"):format(bag.cur, bag.max, bagFull() and "  (full)" or "") or "Bag: waiting for first coin"
		task.wait(0.3)
	end
end)

local tCombat = Tab("Combat", 3)
Label(tCombat, "All live-tested on 1462. Aim lead is tuned from few shots: raise Extra aim lead if moving targets get missed.", 40)
Section(tCombat, "Murderer")
Button(tCombat, "Kill all", killAll)
Toggle(tCombat, "Knife aura", "KnifeAura")
Slider(tCombat, "Aura range", "AuraRange", 5, 40, 1, "%d")
Section(tCombat, "Sheriff")
Button(tCombat, "TP to murderer + shoot + TP back", tpShootMurderer)
Toggle(tCombat, "Auto shoot murderer (in sight)", "AutoShoot")
Slider(tCombat, "Auto shoot range", "ShootRange", 20, 300, 10, "%d")
Slider(tCombat, "Extra aim lead (ms)", "ShotLeadMs", 0, 300, 10, "%d")
local shootLbl = Label(tCombat, "Shot: idle", 34)
task.spawn(function()
	while alive do
		shootLbl.Text = "Shot: " .. shootStatus
		task.wait(0.25)
	end
end)
Button(tCombat, "Grab dropped gun", grabGun)
Toggle(tCombat, "Auto grab dropped gun", "AutoGrabGun")
Section(tCombat, "Measure weapons")
Toggle(tCombat, "Capture weapon remotes", "Capture", function(v)
	if v and not installCapture() then toast("Executor lacks hookmetamethod") setToggle("Capture", false) return end
	genv.MM2CaptureOn = v
end)
Button(tCombat, "Print captured calls", dumpCapture)

local tPlayer = Tab("Player", 4)
Section(tPlayer, "Movement")
Toggle(tPlayer, "Walk speed", "SpeedOn")
Slider(tPlayer, "Speed", "WalkSpeed", 16, 100, 1, "%d")
Toggle(tPlayer, "Jump power", "JumpOn")
Slider(tPlayer, "Jump", "JumpPower", 50, 200, 5, "%d")
Toggle(tPlayer, "Infinite jump", "InfJump")
Toggle(tPlayer, "Noclip", "Noclip")
Toggle(tPlayer, "Fly (aim with camera)", "Fly")
Slider(tPlayer, "Fly speed", "FlySpeed", 10, 150, 5, "%d")

local tTP = Tab("Teleport", 5)
Section(tTP, "Places")
Button(tTP, "Lobby", function() local cf = lobbyCF() if cf then teleportTo(cf) else toast("Lobby spawns not found") end end)
Button(tTP, "Map", function() local cf = mapCF() if cf then teleportTo(cf) else toast("No map loaded") end end)
Button(tTP, "Dropped gun", function()
	local g = findGunDrop()
	if g then teleportTo(g.CFrame + Vector3.new(0, 3, 0)) else toast("No dropped gun found") end
end)
Section(tTP, "Players")
tTP.n = tTP.n + 1
local plist = new("Frame", {
	BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = tTP.n, Parent = tTP.list,
}, {new("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.Name})})
local function rebuildPlayers()
	for _, c in ipairs(plist:GetChildren()) do if c:IsA("GuiObject") then c:Destroy() end end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LP then
			local b = Button(tTP, p.DisplayName, function()
				local th = hrpOf(p)
				if th then teleportTo(th.CFrame * CFrame.new(0, 0, 3)) else toast(p.Name .. " has no character") end
			end, plist)
			b.Name = p.Name
			b.TextSize = 12
			b.Size = UDim2.new(1, 0, 0, 28)
		end
	end
end
rebuildPlayers()
bind(Players.PlayerAdded, rebuildPlayers)
bind(Players.PlayerRemoving, function() task.defer(rebuildPlayers) end)

local tMisc = Tab("Misc", 6)
Section(tMisc, "Utility")
Toggle(tMisc, "Anti AFK", "AntiAFK")
Button(tMisc, "Refresh roles now", function() refreshData() lastRoleKey = nil announceRoles() end)
Button(tMisc, "Unload hub", function() genv.MM2Hub.Destroy() end)
Label(tMisc, "RightShift or the minus button hides the hub.", 34)

selectTab(tESP)

-- teardown -------------------------------------------------------------------

genv.MM2Hub = {
	Destroy = function()
		alive = false
		genv.MM2Saved = table.clone(S)
		genv.MM2CaptureOn = false
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		stopFly()
		farming = false
		S.Noclip, S.Fly = false, false
		pcall(applyCollide)
		local h = humOf(LP)
		if h then
			if baseWalk then h.WalkSpeed = baseWalk end
			if baseJump then h.JumpPower = baseJump end
		end
		gui:Destroy()
	end,
	State = S,
	Data = function() return Data end,
	Bag = bag,
	Combat = {
		hasLOS = hasLOS, pickSpot = pickSpot, murderer = murdererTarget, tpShoot = tpShootMurderer,
		grabGun = grabGun, killAll = killAll, status = function() return shootStatus end,
		busy = function() return busy end, shots = shotHistory, velocity = trackedVelocity,
	},
}

toast("MM2 Hub loaded")
