--[[
	Gen Import v2.0
	Asset Manager + Native RBXM Import (tanpa Reify)
	- Scan Delta/Workspace
	- Import .rbxm / .rbxmx / .rbxl / .rbxlx
	- Pakai game:GetObjects (lebih lengkap asset + script)
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

-- ====================== CONFIG ======================
local Config = {
	Title = "Gen Import",
	Version = "v2.0",
	Accent = Color3.fromRGB(0, 200, 255),
	AccentDark = Color3.fromRGB(0, 140, 180),
	Bg = Color3.fromRGB(12, 14, 20),
	Sidebar = Color3.fromRGB(16, 18, 26),
	Card = Color3.fromRGB(22, 25, 35),
	CardHover = Color3.fromRGB(30, 34, 48),
	Text = Color3.fromRGB(245, 248, 255),
	SubText = Color3.fromRGB(140, 150, 170),
	Success = Color3.fromRGB(80, 220, 140),
	Warning = Color3.fromRGB(255, 190, 70),
	Error = Color3.fromRGB(255, 90, 100),
}

local function Protect(gui)
	if gethui then
		gui.Parent = gethui()
	elseif syn and syn.protect_gui then
		syn.protect_gui(gui)
		gui.Parent = CoreGui
	else
		gui.Parent = CoreGui
	end
end

local function Create(class, props)
	local obj = Instance.new(class)
	for k, v in pairs(props or {}) do
		obj[k] = v
	end
	return obj
end

local function Tween(obj, props, time, style, dir)
	local t = TweenService:Create(
		obj,
		TweenInfo.new(time or 0.25, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out),
		props
	)
	t:Play()
	return t
end

-- ====================== NATIVE IMPORT ======================
local function ImportRBXM(path)
	if not game.GetObjects then
		return nil, "Executor tidak support game:GetObjects"
	end

	local attempts = { path }

	-- Coba lewat temp file (beberapa executor lebih stabil)
	if readfile and writefile then
		local okData, data = pcall(readfile, path)
		if okData and data and #data > 0 then
			local tempName = "gen_import_temp_" .. tostring(math.floor(tick() * 1000)) .. ".rbxm"
			local okWrite = pcall(writefile, tempName, data)
			if okWrite then
				table.insert(attempts, 1, tempName)
			end
		end
	end

	local lastErr
	for _, tryPath in ipairs(attempts) do
		local ok, result = pcall(function()
			return game:GetObjects(tryPath)
		end)

		if ok and result then
			if typeof(result) == "table" and #result > 0 then
				return result, nil
			elseif typeof(result) == "Instance" then
				return { result }, nil
			end
		end
		lastErr = result
	end

	return nil, tostring(lastErr or "GetObjects gagal")
end

local function PlaceModels(models, nameHint)
	local cleanName = (nameHint or "Imported"):gsub("%.[%w]+$", "")
	local root

	if #models == 1 then
		root = models[1]
		pcall(function()
			if root.Name == "" or root.Name == "Model" or root.Name == "Folder" then
				root.Name = cleanName
			end
		end)
		root.Parent = workspace
	else
		root = Instance.new("Folder")
		root.Name = cleanName
		for _, m in ipairs(models) do
			m.Parent = root
		end
		root.Parent = workspace
	end

	return root
end

local function CountScripts(root)
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("LuaSourceContainer") then
			n += 1
		end
	end
	if root:IsA("LuaSourceContainer") then
		n += 1
	end
	return n
end

-- ====================== SCANNER ======================
local function GetWorkspaceFiles()
	local results, found = {}, {}
	if not listfiles then return results end

	local paths = {
		"Workspace", "./Workspace", "workspace",
		"", "./", "Delta/Workspace"
	}

	for _, base in ipairs(paths) do
		local ok, files = pcall(listfiles, base)
		if ok and type(files) == "table" then
			for _, fullPath in ipairs(files) do
				local name = fullPath:match("([^/\\]+)$") or fullPath
				local ext = name:match("%.([%w]+)$")
				if ext then
					ext = ext:lower()
					if (ext == "rbxm" or ext == "rbxl" or ext == "rbxmx" or ext == "rbxlx") and not found[name] then
						found[name] = true
						table.insert(results, {
							Name = name,
							Path = fullPath,
							Ext = ext,
							Type = (ext == "rbxm" or ext == "rbxmx") and "MODEL" or "PLACE"
						})
					end
				end
			end
		end
	end

	table.sort(results, function(a, b)
		return a.Name:lower() < b.Name:lower()
	end)
	return results
end

-- ====================== GUI ======================
local ScreenGui = Create("ScreenGui", {
	Name = "GenImport",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling
})
Protect(ScreenGui)

-- Floating logo (toggle)
local LogoBtn = Create("TextButton", {
	Name = "LogoToggle",
	Size = UDim2.new(0, 52, 0, 52),
	Position = UDim2.new(0, 18, 0.5, -26),
	BackgroundColor3 = Config.Accent,
	Text = "",
	AutoButtonColor = false,
	Parent = ScreenGui
})
Create("UICorner", { CornerRadius = UDim.new(0, 14), Parent = LogoBtn })
Create("UIStroke", {
	Color = Color3.fromRGB(255, 255, 255),
	Thickness = 1.5,
	Transparency = 0.7,
	Parent = LogoBtn
})

Create("TextLabel", {
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundTransparency = 1,
	Text = "G",
	TextColor3 = Color3.fromRGB(10, 12, 18),
	TextSize = 26,
	Font = Enum.Font.GothamBlack,
	Parent = LogoBtn
})

local LogoGlow = Create("Frame", {
	Size = UDim2.new(1, 16, 1, 16),
	Position = UDim2.new(0, -8, 0, -8),
	BackgroundColor3 = Config.Accent,
	BackgroundTransparency = 0.75,
	ZIndex = 0,
	Parent = LogoBtn
})
Create("UICorner", { CornerRadius = UDim.new(0, 18), Parent = LogoGlow })

LogoBtn.MouseEnter:Connect(function()
	Tween(LogoBtn, { BackgroundColor3 = Config.AccentDark }, 0.2)
	Tween(LogoGlow, { BackgroundTransparency = 0.55 }, 0.2)
end)
LogoBtn.MouseLeave:Connect(function()
	Tween(LogoBtn, { BackgroundColor3 = Config.Accent }, 0.2)
	Tween(LogoGlow, { BackgroundTransparency = 0.75 }, 0.2)
end)

-- Main window
local Main = Create("Frame", {
	Name = "Main",
	Size = UDim2.new(0, 540, 0, 420),
	Position = UDim2.new(0.5, -270, 0.5, -210),
	BackgroundColor3 = Config.Bg,
	BorderSizePixel = 0,
	Visible = true,
	Parent = ScreenGui
})
Create("UICorner", { CornerRadius = UDim.new(0, 16), Parent = Main })
Create("UIStroke", { Color = Config.Accent, Thickness = 1.2, Transparency = 0.35, Parent = Main })

-- Sidebar
local Sidebar = Create("Frame", {
	Size = UDim2.new(0, 160, 1, 0),
	BackgroundColor3 = Config.Sidebar,
	BorderSizePixel = 0,
	Parent = Main
})
Create("UICorner", { CornerRadius = UDim.new(0, 16), Parent = Sidebar })
Create("Frame", {
	Size = UDim2.new(0, 20, 1, 0),
	Position = UDim2.new(1, -20, 0, 0),
	BackgroundColor3 = Config.Sidebar,
	BorderSizePixel = 0,
	Parent = Sidebar
})

Create("TextLabel", {
	Size = UDim2.new(1, -16, 0, 50),
	Position = UDim2.new(0, 12, 0, 12),
	BackgroundTransparency = 1,
	Text = Config.Title .. "\n" .. Config.Version,
	TextColor3 = Config.Text,
	TextSize = 14,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = Sidebar
})

local function SideBtn(text, y, active)
	local b = Create("TextButton", {
		Size = UDim2.new(1, -16, 0, 36),
		Position = UDim2.new(0, 8, 0, y),
		BackgroundColor3 = active and Config.Accent or Config.Card,
		Text = text,
		TextColor3 = active and Color3.fromRGB(10, 12, 18) or Config.Text,
		TextSize = 13,
		Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutoButtonColor = false,
		Parent = Sidebar
	})
	Create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = b })
	return b
end

SideBtn("  ■  Overview", 70, false)
SideBtn("  📁  Assets", 112, true)
SideBtn("  ⚙  Settings", 154, false)

local RescanBtn = Create("TextButton", {
	Size = UDim2.new(1, -16, 0, 38),
	Position = UDim2.new(0, 8, 1, -55),
	BackgroundColor3 = Color3.fromRGB(0, 90, 120),
	Text = "↻  Rescan Assets",
	TextColor3 = Config.Text,
	TextSize = 13,
	Font = Enum.Font.GothamBold,
	AutoButtonColor = false,
	Parent = Sidebar
})
Create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = RescanBtn })

-- Content
local Content = Create("Frame", {
	Size = UDim2.new(1, -172, 1, -16),
	Position = UDim2.new(0, 168, 0, 8),
	BackgroundTransparency = 1,
	Parent = Main
})

Create("TextLabel", {
	Size = UDim2.new(1, -40, 0, 28),
	BackgroundTransparency = 1,
	Text = "Dashboard",
	TextColor3 = Config.Text,
	TextSize = 18,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = Content
})

local CloseBtn = Create("TextButton", {
	Size = UDim2.new(0, 28, 0, 28),
	Position = UDim2.new(1, -28, 0, 0),
	BackgroundColor3 = Color3.fromRGB(40, 50, 70),
	Text = "×",
	TextColor3 = Config.Text,
	TextSize = 18,
	Font = Enum.Font.GothamBold,
	AutoButtonColor = false,
	Parent = Content
})
Create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = CloseBtn })

local function StatCard(title, x)
	local card = Create("Frame", {
		Size = UDim2.new(0.48, 0, 0, 64),
		Position = UDim2.new(x, 0, 0, 38),
		BackgroundColor3 = Config.Card,
		BorderSizePixel = 0,
		Parent = Content
	})
	Create("UICorner", { CornerRadius = UDim.new(0, 10), Parent = card })
	local val = Create("TextLabel", {
		Size = UDim2.new(1, 0, 0.55, 0),
		BackgroundTransparency = 1,
		Text = "0",
		TextColor3 = Config.Text,
		TextSize = 22,
		Font = Enum.Font.GothamBold,
		Parent = card
	})
	Create("TextLabel", {
		Size = UDim2.new(1, 0, 0.4, 0),
		Position = UDim2.new(0, 0, 0.55, 0),
		BackgroundTransparency = 1,
		Text = title,
		TextColor3 = Config.SubText,
		TextSize = 11,
		Font = Enum.Font.Gotham,
		Parent = card
	})
	return val
end

local TotalLbl = StatCard("TOTAL ASSETS", 0)
local ReadyLbl = StatCard("ASSET READY", 0.52)

local CurrentFilter = "ALL"
local function Tab(name, x)
	local b = Create("TextButton", {
		Size = UDim2.new(0.31, 0, 0, 32),
		Position = UDim2.new(x, 0, 0, 112),
		BackgroundColor3 = name == "ALL" and Config.Accent or Config.Card,
		Text = name,
		TextColor3 = name == "ALL" and Color3.fromRGB(10, 12, 18) or Config.Text,
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
		Parent = Content
	})
	Create("UICorner", { CornerRadius = UDim.new(0, 8), Parent = b })
	return b
end

local TabAll = Tab("ALL", 0)
local TabModel = Tab("MODEL", 0.345)
local TabPlace = Tab("PLACE", 0.69)

local function SetTab(active)
	local map = {
		ALL = TabAll,
		MODEL = TabModel,
		PLACE = TabPlace
	}
	for name, btn in pairs(map) do
		if name == active then
			btn.BackgroundColor3 = Config.Accent
			btn.TextColor3 = Color3.fromRGB(10, 12, 18)
		else
			btn.BackgroundColor3 = Config.Card
			btn.TextColor3 = Config.Text
		end
	end
end

local List = Create("ScrollingFrame", {
	Size = UDim2.new(1, 0, 1, -165),
	Position = UDim2.new(0, 0, 0, 155),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = Config.Accent,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	Parent = Content
})
Create("UIListLayout", { Padding = UDim.new(0, 8), Parent = List })

local StatusLbl = Create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 22),
	Position = UDim2.new(0, 0, 1, -24),
	BackgroundTransparency = 1,
	Text = "Siap",
	TextColor3 = Config.SubText,
	TextSize = 12,
	Font = Enum.Font.Gotham,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextWrapped = true,
	Parent = Content
})

-- ====================== LOGIC ======================
local function ClearList()
	for _, c in ipairs(List:GetChildren()) do
		if c:IsA("Frame") then c:Destroy() end
	end
end

local function CreateCard(asset, order)
	local card = Create("Frame", {
		Size = UDim2.new(1, -6, 0, 54),
		BackgroundColor3 = Config.Card,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = List
	})
	Create("UICorner", { CornerRadius = UDim.new(0, 10), Parent = card })

	Create("TextLabel", {
		Size = UDim2.new(0, 40, 1, 0),
		BackgroundTransparency = 1,
		Text = asset.Type == "MODEL" and "📦" or "🎮",
		TextSize = 18,
		Parent = card
	})

	Create("TextLabel", {
		Size = UDim2.new(1, -140, 0, 22),
		Position = UDim2.new(0, 42, 0, 7),
		BackgroundTransparency = 1,
		Text = asset.Name,
		TextColor3 = Config.Text,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = card
	})

	local tag = Create("TextLabel", {
		Size = UDim2.new(0, 52, 0, 18),
		Position = UDim2.new(0, 42, 0, 29),
		BackgroundColor3 = asset.Type == "MODEL" and Color3.fromRGB(30, 120, 90) or Color3.fromRGB(50, 80, 140),
		Text = asset.Ext:upper(),
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 10,
		Font = Enum.Font.GothamBold,
		Parent = card
	})
	Create("UICorner", { CornerRadius = UDim.new(0, 4), Parent = tag })

	local btn = Create("TextButton", {
		Size = UDim2.new(0, 72, 0, 30),
		Position = UDim2.new(1, -82, 0.5, -15),
		BackgroundColor3 = Config.Accent,
		Text = "IMPORT",
		TextColor3 = Color3.fromRGB(10, 12, 18),
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
		Parent = card
	})
	Create("UICorner", { CornerRadius = UDim.new(0, 6), Parent = btn })

	btn.MouseButton1Click:Connect(function()
		btn.Text = "..."
		StatusLbl.Text = "Importing: " .. asset.Name
		StatusLbl.TextColor3 = Config.Warning

		task.spawn(function()
			local models, err = ImportRBXM(asset.Path)

			if models then
				local placed = PlaceModels(models, asset.Name)
				local scriptCount = CountScripts(placed)

				btn.Text = "OK"
				StatusLbl.Text = string.format("Berhasil! Script: %d | Cek Workspace", scriptCount)
				StatusLbl.TextColor3 = Config.Success
				print("[Gen Import] OK:", asset.Name, "| Scripts:", scriptCount)
			else
				btn.Text = "FAIL"
				StatusLbl.Text = "Gagal: " .. tostring(err)
				StatusLbl.TextColor3 = Config.Error
				warn("[Gen Import] FAIL:", err)
			end

			task.delay(2.2, function()
				if btn then btn.Text = "IMPORT" end
			end)
		end)
	end)
end

local function Refresh()
	ClearList()
	StatusLbl.Text = "Scanning..."
	StatusLbl.TextColor3 = Config.SubText

	local all = GetWorkspaceFiles()
	local filtered = {}
	for _, a in ipairs(all) do
		if CurrentFilter == "ALL" or a.Type == CurrentFilter then
			table.insert(filtered, a)
		end
	end

	TotalLbl.Text = tostring(#all)
	ReadyLbl.Text = tostring(#filtered)

	for i, a in ipairs(filtered) do
		CreateCard(a, i)
	end

	List.CanvasSize = UDim2.new(0, 0, 0, #filtered * 62 + 10)
	StatusLbl.Text = #all > 0 and ("Ditemukan " .. #all .. " file") or "Tidak ada file di Workspace"
	StatusLbl.TextColor3 = #all > 0 and Config.Success or Config.Warning
end

-- Events
TabAll.MouseButton1Click:Connect(function()
	CurrentFilter = "ALL"
	SetTab("ALL")
	Refresh()
end)
TabModel.MouseButton1Click:Connect(function()
	CurrentFilter = "MODEL"
	SetTab("MODEL")
	Refresh()
end)
TabPlace.MouseButton1Click:Connect(function()
	CurrentFilter = "PLACE"
	SetTab("PLACE")
	Refresh()
end)

RescanBtn.MouseButton1Click:Connect(function()
	RescanBtn.Text = "Scanning..."
	Refresh()
	RescanBtn.Text = "↻  Rescan Assets"
end)

local guiOpen = true
local function ToggleGui()
	guiOpen = not guiOpen
	Main.Visible = guiOpen
end

LogoBtn.MouseButton1Click:Connect(ToggleGui)
CloseBtn.MouseButton1Click:Connect(function()
	Main.Visible = false
	guiOpen = false
end)

-- Drag main
local dragging, dragStart, startPos
Main.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = Main.Position
	end
end)
Main.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - dragStart
		Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)

-- Drag logo
local logoDrag, logoStart, logoPos
LogoBtn.InputBegan:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		logoDrag = true
		logoStart = input.Position
		logoPos = LogoBtn.Position
	end
end)
LogoBtn.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		logoDrag = false
	end
end)
UserInputService.InputChanged:Connect(function(input)
	if logoDrag and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local d = input.Position - logoStart
		LogoBtn.Position = UDim2.new(logoPos.X.Scale, logoPos.X.Offset + d.X, logoPos.Y.Scale, logoPos.Y.Offset + d.Y)
	end
end)

-- Init
if game.GetObjects then
	StatusLbl.Text = "Native GetObjects siap!"
	StatusLbl.TextColor3 = Config.Success
else
	StatusLbl.Text = "Peringatan: GetObjects tidak tersedia di executor ini"
	StatusLbl.TextColor3 = Config.Warning
end

Refresh()
print("[Gen Import v2] Native importer loaded")
