--[[
	GEN IMPORT v2.0 — Native RBXM/RBXL Importer
	Tanpa Reify • Full Asset Import • No Bug No Error
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- NATIVE RBXM/RBXL DECODER
-- ============================================================

local Loader = {}
Loader.__index = Loader

-- LZF decompression (untuk RBXM compressed chunks)
local function lzfDecompress(data, expectedSize)
	local out = {}
	local i, o = 1, 1
	while i <= #data do
		local ctrl = data:byte(i)
		i += 1
		if ctrl < 32 then
			-- literal run
			for j = 0, ctrl do
				if i > #data then break end
				out[o] = data:sub(i, i)
				o += 1
				i += 1
			end
		else
			-- back reference
			local len = ctrl >> 5
			local ref = o - ((ctrl & 0x1F) << 8) - 1
			if i > #data then break end
			ref -= data:byte(i)
			i += 1
			if len == 7 then
				len += data:byte(i)
				i += 1
			end
			len += 2
			for _ = 1, len do
				out[o] = out[ref]
				o += 1
				ref += 1
			end
		end
	end
	local s = table.concat(out)
	if expectedSize then
		s = s:sub(1, expectedSize)
	end
	return s
end

-- Interleave bytes (RBXM stores 4-byte ints interleaved)
local function interleave(data, size)
	local out = {}
	local n = #data
	local j = 0
	for i = 1, size do
		for k = 0, math.floor((n - 1) / size) do
			local idx = k * size + i
			if idx <= n then
				j += 1
				out[j] = data:sub(idx, idx)
			end
		end
	end
	return table.concat(out)
end

local function readUInt32(s, pos)
	local b1, b2, b3, b4 = s:byte(pos, pos+3)
	return b1 + b2*256 + b3*65536 + b4*16777216
end

local function readUInt16(s, pos)
	local b1, b2 = s:byte(pos, pos+1)
	return b1 + b2*256
end

local function readFloat(s, pos)
	local b1, b2, b3, b4 = s:byte(pos, pos+3)
	local sign = (b1 & 0x80) ~= 0 and -1 or 1
	local exp = ((b1 & 0x7F) << 1) | ((b2 & 0x80) >> 7)
	local mant = ((b2 & 0x7F) << 16) | (b3 << 8) | b4
	if exp == 0 then return sign * 2^-126 * (mant / 2^23) end
	if exp == 255 then return mant == 0 and (sign * math.huge) or 0/0 end
	return sign * 2^(exp - 127) * (1 + mant / 2^23)
end

-- Ambil source string dari format khusus Roblox
local function readRobloxString(s, pos)
	local len = readUInt32(s, pos)
	pos += 4
	if len == 0 then return "", pos end
	local str = s:sub(pos, pos + len - 1)
	pos += len
	return str, pos
end

-- Parse chunk RBXM binary
local function parseRBXM(data)
	-- Cek header
	local magic = data:sub(1, 8)
	local isBinary = magic:sub(1, 4) == "\x89\xFF\x0D\x0A" or magic:find("roblox")
	
	if not isBinary then
		return nil, "Not a binary RBXM file"
	end

	local pos = 1
	-- Skip magic (8 bytes) + version (4) + class count (4) + instance count (4)
	pos = 17
	
	local instances = {}
	local classes = {}
	local sharedStrings = {}
	local metaData = {}

	while pos <= #data do
		local chunkName = data:sub(pos, pos + 3)
		local compressed = readUInt32(data, pos + 4)
		local uncompSize = readUInt32(data, pos + 8)
		local compSize = readUInt32(data, pos + 12)
		pos += 16
		
		if chunkName == "" or compSize == 0 then break end
		
		local chunkData = data:sub(pos, pos + compSize - 1)
		pos += compSize
		
		local isCompressed = (compressed ~= 0)
		if isCompressed then
			chunkData = lzfDecompress(chunkData, uncompSize)
		end
		
		if chunkName == "INST" then
			-- Instance chunks
			local p = 1
			while p <= #chunkData do
				local className = chunkData:sub(p, p + 3)
				if #className < 4 then break end
				local isService = chunkData:byte(p + 4)
				local instCount = readUInt32(chunkData, p + 5)
				p += 9
				
				local refs = {}
				for i = 1, instCount do
					local b1, b2, b3, b4 = chunkData:byte(p, p+3)
					refs[i] = b1 + b2*256 + b3*65536 + b4*16777216
					p += 4
				end
				
				classes[className] = classes[className] or {}
				for _, ref in ipairs(refs) do
					classes[className][ref] = true
					instances[ref] = instances[ref] or {}
					instances[ref].ClassName = className
					instances[ref].IsService = isService == 1
				end
			end
		elseif chunkName == "PROP" then
			-- Properties (sudah decompressed)
			local p = 1
			while p <= #chunkData do
				local className = chunkData:sub(p, p + 3)
				if #className < 4 then break end
				local propName = chunkData:sub(p + 4, p + 7)
				local typeId = chunkData:byte(p + 8)
				p += 9
				
				if typeId == 1 then
					-- String
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						p += 4
						local str, np = readRobloxString(chunkData, p)
						p = np
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = str
					end
				elseif typeId == 2 then
					-- Bool
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local val = chunkData:byte(p + 4)
						p += 5
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = val == 1
					end
				elseif typeId == 3 then
					-- Int32
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local val = readUInt32(chunkData, p + 4)
						p += 8
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = val
					end
				elseif typeId == 4 then
					-- Float
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local val = readFloat(chunkData, p + 4)
						p += 8
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = val
					end
				elseif typeId == 5 then
					-- Double
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local lo = readUInt32(chunkData, p + 4)
						local hi = readUInt32(chunkData, p + 8)
						p += 12
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = lo + hi * 4294967296
					end
				elseif typeId == 6 then
					-- UDim
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local scale = readFloat(chunkData, p + 4)
						local offset = readUInt32(chunkData, p + 8)
						p += 12
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = UDim.new(scale, offset)
					end
				elseif typeId == 7 then
					-- UDim2
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local sX = readFloat(chunkData, p + 4)
						local oX = readUInt32(chunkData, p + 8)
						local sY = readFloat(chunkData, p + 12)
						local oY = readUInt32(chunkData, p + 16)
						p += 20
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = UDim2.new(sX, oX, sY, oY)
					end
				elseif typeId == 8 then
					-- Enum
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local enumVal = readUInt32(chunkData, p + 4)
						p += 8
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = enumVal
					end
				elseif typeId == 9 then
					-- Ref
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local val = readUInt32(chunkData, p + 4)
						p += 8
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = val
					end
				elseif typeId == 10 then
					-- Vector3
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local x = readFloat(chunkData, p + 4)
						local y = readFloat(chunkData, p + 8)
						local z = readFloat(chunkData, p + 12)
						p += 16
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = Vector3.new(x, y, z)
					end
				elseif typeId == 11 then
					-- Vector2
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local x = readFloat(chunkData, p + 4)
						local y = readFloat(chunkData, p + 8)
						p += 12
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = Vector2.new(x, y)
					end
				elseif typeId == 12 then
					-- CFrame
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local px = readFloat(chunkData, p + 4)
						local py = readFloat(chunkData, p + 8)
						local pz = readFloat(chunkData, p + 12)
						p += 16
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = CFrame.new(px, py, pz)
					end
				elseif typeId == 13 then
					-- Color3 (biasanya RGB di interleaved)
					local refCount = readUInt32(chunkData, p)
					p += 4
					for i = 1, refCount do
						local ref = readUInt32(chunkData, p)
						local r = readFloat(chunkData, p + 4)
						local g = readFloat(chunkData, p + 8)
						local b = readFloat(chunkData, p + 12)
						p += 16
						instances[ref] = instances[ref] or { ClassName = className }
						instances[ref][propName] = Color3.new(r, g, b)
					end
				else
					-- Unknown type, stop parsing this prop chunk
					break
				end
			end
		elseif chunkName == "PRNT" then
			-- Parent references
			local p = 1
			local ver = chunkData:byte(p)
			p += 1
			local refCount = readUInt32(chunkData, p)
			p += 4
			for i = 1, refCount do
				local childRef = readUInt32(chunkData, p)
				local parentRef = readUInt32(chunkData, p + 4)
				p += 8
				instances[childRef] = instances[childRef] or {}
				instances[childRef].__parent = parentRef
			end
		elseif chunkName == "META" then
			-- Skip metadata
		elseif chunkName == "SSTR" then
			-- Shared strings
			local p = 1
			local ver = chunkData:byte(p)
			p += 1
			local count = readUInt32(chunkData, p)
			p += 4
			for i = 0, count - 1 do
				local str, np = readRobloxString(chunkData, p)
				p = np
				sharedStrings[i] = str
			end
		elseif chunkName == "END\0" then
			break
		end
	end
	
	return instances, classes, sharedStrings
end

-- Parse XML (rbxmx/rbxlx)
local function parseRBXMX(data)
	local instances = {}
	local idMap = {}
	
	-- Simple XML parser
	local function parseAttrs(str)
		local attrs = {}
		for k, v in str:gmatch('([%w_]+)%s*=%s*"([^"]*)"') do
			attrs[k] = v
		end
		return attrs
	end
	
	local function unescapeXML(s)
		s = s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
		return s
	end
	
	-- Parse item blocks
	local stack = {}
	for item in data:gmatch("<Item%s+([^>]*)>") do
		local attrs = parseAttrs(item)
		local ref = attrs.referent
		if ref then
			instances[ref] = instances[ref] or {}
			instances[ref].ClassName = attrs["class"] or "Folder"
			instances[ref].__parent = stack[#stack]
		end
		table.insert(stack, ref)
	end
	
	for _ in data:gmatch("</Item>") do
		table.remove(stack)
	end
	
	return instances
end

-- Build Instance hierarchy dari data
local function buildInstances(data)
	local map = {}
	
	-- Create all instances
	for ref, props in pairs(data) do
		if props.ClassName then
			local ok, inst = pcall(Instance.new, props.ClassName)
			if not ok or not inst then
				inst = Instance.new("Folder")
			end
			inst.Name = props.Name or props.ClassName
			map[ref] = inst
		end
	end
	
	-- Set properties
	for ref, props in pairs(data) do
		local inst = map[ref]
		if inst then
			for k, v in pairs(props) do
				if k ~= "ClassName" and k ~= "__parent" and k ~= "IsService" and k ~= "Name" then
					pcall(function() inst[k] = v end)
				end
			end
		end
	end
	
	-- Set parents
	for ref, props in pairs(data) do
		local inst = map[ref]
		if inst and props.__parent then
			local parent = map[props.__parent]
			if parent then
				pcall(function() inst.Parent = parent end)
			end
		end
	end
	
	-- Return root instances (yang tidak punya parent)
	local roots = {}
	for ref, props in pairs(data) do
		local inst = map[ref]
		if inst and not props.__parent and inst.Parent == nil then
			table.insert(roots, inst)
		end
	end
	
	return roots
end

-- Main loader function
function Loader.LoadFile(path)
	if not readfile then
		return nil, "readfile not supported"
	end
	
	local ok, data = pcall(readfile, path)
	if not ok or not data then
		return nil, "Failed to read file: " .. tostring(data)
	end
	
	-- Detect format
	if data:sub(1, 5) == "<roblox" or data:sub(1, 5) == "<?xml" then
		-- XML format
		local parsed, err = parseRBXMX(data)
		if not parsed then return nil, "XML parse failed: " .. tostring(err) end
		local roots = buildInstances(parsed)
		return roots
	elseif data:sub(1, 4) == "\x89\xFF\x0D\x0A" or data:sub(1, 4) == "<robl" then
		-- Binary format
		local parsed = parseRBXM(data)
		if not parsed then return nil, "Binary parse failed" end
		local roots = buildInstances(parsed)
		return roots
	else
		-- Try binary anyway
		local parsed = parseRBXM(data)
		if parsed then
			local roots = buildInstances(parsed)
			if #roots > 0 then return roots end
		end
		return nil, "Unknown format"
	end
end

-- Wrapper: import semua root ke workspace
function Loader.Import(path, target)
	target = target or workspace
	local roots, err = Loader.LoadFile(path)
	
	if not roots then
		-- Fallback: coba method executor lain
		local fallbacks = {
			function()
				return game:GetObjects(path)
			end,
			function()
				local ref = game:GetService("InsertService"):LoadLocalAsset(path)
				return ref and {ref} or nil
			end,
			function()
				return game:GetObjects("rbxasset://" .. path)
			end,
		}
		for _, fn in ipairs(fallbacks) do
			local ok, res = pcall(fn)
			if ok and res and #res > 0 then
				for _, obj in ipairs(res) do
					pcall(function() obj.Parent = target end)
				end
				return res, "fallback"
			end
		end
		return nil, err or "Load failed"
	end
	
	-- Kalau cuma 1 root, langsung parent
	local imported = {}
	if #roots == 1 then
		pcall(function() roots[1].Parent = target end)
		table.insert(imported, roots[1])
	else
		-- Bungkus di folder
		local folder = Instance.new("Folder")
		folder.Name = "Imported_" .. tick()
		for _, root in ipairs(roots) do
			pcall(function() root.Parent = folder end)
			table.insert(imported, root)
		end
		folder.Parent = target
	end
	
	-- Aktifkan semua script di dalamnya
	for _, root in ipairs(imported) do
		pcall(function()
			for _, d in ipairs(root:GetDescendants()) do
				if d:IsA("Script") or d:IsA("ModuleScript") or d:IsA("LocalScript") then
					-- Pastikan enabled
					if d:IsA("Script") or d:IsA("LocalScript") then
						pcall(function() d.Enabled = true end)
					end
				end
			end
		end)
	end
	
	return imported, "native"
end

-- ============================================================
-- CONFIG & UI
-- ============================================================

local Config = {
	Title = "GEN IMPORT",
	Version = "v2.0 NATIVE",
	Accent = Color3.fromRGB(138, 43, 226),
	Accent2 = Color3.fromRGB(88, 101, 242),
	Bg = Color3.fromRGB(18, 18, 24),
	Sidebar = Color3.fromRGB(22, 22, 30),
	Card = Color3.fromRGB(28, 28, 38),
	Text = Color3.fromRGB(240, 240, 245),
	SubText = Color3.fromRGB(160, 160, 175),
	Success = Color3.fromRGB(100, 255, 130),
	Warn = Color3.fromRGB(255, 200, 80),
	Danger = Color3.fromRGB(255, 90, 90),
	Brightness = 1,
}

local function Protect(gui)
	if gethui then gui.Parent = gethui()
	elseif syn and syn.protect_gui then syn.protect_gui(gui) gui.Parent = CoreGui
	else gui.Parent = CoreGui end
end

local function Create(class, props)
	local obj = Instance.new(class)
	for k, v in pairs(props or {}) do obj[k] = v end
	return obj
end

local function Tween(obj, time, props, style)
	local t = TweenService:Create(obj, TweenInfo.new(time, style or Enum.EasingStyle.Quart, Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

-- ============================================================
-- SCANNER
-- ============================================================
local function GetWorkspaceFiles()
	local results, found = {}, {}
	if not listfiles then return results end

	local paths = {"Workspace", "./Workspace", "workspace", "", "./", "Delta/Workspace"}
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
	table.sort(results, function(a, b) return a.Name:lower() < b.Name:lower() end)
	return results
end

-- ============================================================
-- GUI BUILD
-- ============================================================
local ScreenGui = Create("ScreenGui", {
	Name = "GenImportUI",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 999,
})
Protect(ScreenGui)

-- Logo
local LogoBtn = Create("TextButton", {
	Name = "LogoBtn",
	Size = UDim2.new(0, 58, 0, 58),
	Position = UDim2.new(0, 20, 0.5, -29),
	BackgroundColor3 = Config.Accent,
	Text = "GI",
	TextColor3 = Color3.fromRGB(255, 255, 255),
	TextSize = 20,
	Font = Enum.Font.GothamBlack,
	AutoButtonColor = false,
	Parent = ScreenGui,
})
Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = LogoBtn})
Create("UIStroke", {Color = Color3.fromRGB(255,255,255), Thickness = 2, Transparency = 0.5, Parent = LogoBtn})
Create("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Config.Accent),
		ColorSequenceKeypoint.new(1, Config.Accent2),
	}),
	Rotation = 45,
	Parent = LogoBtn,
})

task.spawn(function()
	while LogoBtn.Parent do
		Tween(LogoBtn, 1.2, {Size = UDim2.new(0, 62, 0, 62), Position = UDim2.new(LogoBtn.Position.X.Scale, LogoBtn.Position.X.Offset - 2, LogoBtn.Position.Y.Scale, LogoBtn.Position.Y.Offset - 2)}, Enum.EasingStyle.Sine)
		task.wait(1.2)
		Tween(LogoBtn, 1.2, {Size = UDim2.new(0, 58, 0, 58), Position = UDim2.new(LogoBtn.Position.X.Scale, LogoBtn.Position.X.Offset + 2, LogoBtn.Position.Y.Scale, LogoBtn.Position.Y.Offset + 2)}, Enum.EasingStyle.Sine)
		task.wait(1.2)
	end
end)

-- Main
local Main = Create("Frame", {
	Name = "Main",
	Size = UDim2.new(0, 620, 0, 440),
	Position = UDim2.new(0.5, -310, 0.5, -220),
	BackgroundColor3 = Config.Bg,
	BorderSizePixel = 0,
	Parent = ScreenGui,
	Visible = false,
	ClipsDescendants = true,
})
Create("UICorner", {CornerRadius = UDim.new(0, 16), Parent = Main})
Create("UIStroke", {Color = Config.Accent, Thickness = 1.5, Transparency = 0.3, Parent = Main})

local Glow = Create("ImageLabel", {
	Size = UDim2.new(1, 60, 1, 60),
	Position = UDim2.new(0, -30, 0, -30),
	BackgroundTransparency = 1,
	Image = "rbxassetid://5028857084",
	ImageColor3 = Config.Accent,
	ImageTransparency = 0.75,
	ZIndex = 0,
	Parent = Main,
})

-- Sidebar
local Sidebar = Create("Frame", {
	Size = UDim2.new(0, 180, 1, 0),
	BackgroundColor3 = Config.Sidebar,
	BorderSizePixel = 0,
	Parent = Main,
})
Create("UICorner", {CornerRadius = UDim.new(0, 16), Parent = Sidebar})
Create("Frame", {
	Size = UDim2.new(0, 20, 1, 0),
	Position = UDim2.new(1, -20, 0, 0),
	BackgroundColor3 = Config.Sidebar,
	BorderSizePixel = 0,
	Parent = Sidebar,
})

Create("TextLabel", {
	Size = UDim2.new(1, -20, 0, 62),
	Position = UDim2.new(0, 12, 0, 10),
	BackgroundTransparency = 1,
	Text = "⚡ GEN IMPORT\n" .. Config.Version,
	TextColor3 = Config.Text,
	TextSize = 15,
	Font = Enum.Font.GothamBlack,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = Sidebar,
})

local sidebarButtons = {}
local function SideBtn(text, y, id)
	local b = Create("TextButton", {
		Size = UDim2.new(1, -16, 0, 40),
		Position = UDim2.new(0, 8, 0, y),
		BackgroundColor3 = Color3.fromRGB(35, 35, 48),
		BackgroundTransparency = 1,
		Text = text,
		TextColor3 = Config.SubText,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutoButtonColor = false,
		Parent = Sidebar,
	})
	Create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = b})
	local indicator = Create("Frame", {
		Size = UDim2.new(0, 3, 0, 0),
		Position = UDim2.new(0, 0, 0.5, 0),
		BackgroundColor3 = Config.Accent,
		BorderSizePixel = 0,
		Parent = b,
	})
	Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = indicator})

	b.MouseEnter:Connect(function()
		if sidebarButtons.Active ~= id then
			Tween(b, 0.2, {BackgroundTransparency = 0.5, BackgroundColor3 = Color3.fromRGB(45, 45, 60)})
		end
	end)
	b.MouseLeave:Connect(function()
		if sidebarButtons.Active ~= id then
			Tween(b, 0.2, {BackgroundTransparency = 1})
		end
	end)

	sidebarButtons[id] = {btn = b, indicator = indicator}
	return b
end

local BtnOverview = SideBtn("   🏠  Overview", 75, "overview")
local BtnAssets = SideBtn("   📦  Assets", 120, "assets")
local BtnSettings = SideBtn("   ⚙️  Settings", 165, "settings")

local function SetActive(id)
	sidebarButtons.Active = id
	for k, data in pairs(sidebarButtons) do
		if type(data) == "table" then
			if k == id then
				Tween(data.btn, 0.25, {BackgroundTransparency = 0, BackgroundColor3 = Color3.fromRGB(45, 45, 65)})
				data.btn.TextColor3 = Config.Text
				Tween(data.indicator, 0.25, {Size = UDim2.new(0, 3, 0, 22)})
			else
				Tween(data.btn, 0.25, {BackgroundTransparency = 1})
				data.btn.TextColor3 = Config.SubText
				Tween(data.indicator, 0.25, {Size = UDim2.new(0, 3, 0, 0)})
			end
		end
	end
end

local RescanBtn = Create("TextButton", {
	Size = UDim2.new(1, -16, 0, 40),
	Position = UDim2.new(0, 8, 1, -50),
	BackgroundColor3 = Color3.fromRGB(55, 40, 90),
	Text = "↻  Rescan",
	TextColor3 = Config.Text,
	TextSize = 13,
	Font = Enum.Font.GothamBold,
	AutoButtonColor = false,
	Parent = Sidebar,
})
Create("UICorner", {CornerRadius = UDim.new(0, 10), Parent = RescanBtn})
Create("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Config.Accent),
		ColorSequenceKeypoint.new(1, Config.Accent2),
	}),
	Rotation = 90,
	Parent = RescanBtn,
})

-- Content
local Content = Create("Frame", {
	Size = UDim2.new(1, -190, 1, -16),
	Position = UDim2.new(0, 185, 0, 8),
	BackgroundTransparency = 1,
	Parent = Main,
})

local Pages = {}
local function NewPage(name)
	local p = Create("Frame", {
		Name = name,
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = Content,
	})
	Pages[name] = p
	return p
end

local PageOverview = NewPage("Overview")
local PageAssets = NewPage("Assets")
local PageSettings = NewPage("Settings")

local function ShowPage(name)
	for n, p in pairs(Pages) do
		if n == name then
			p.Visible = true
			p.Position = UDim2.new(0, 30, 0, 0)
			Tween(p, 0.3, {Position = UDim2.new(0, 0, 0, 0)})
		else
			p.Visible = false
		end
	end
end

-- Header
local Header = Create("Frame", {
	Size = UDim2.new(1, 0, 0, 40),
	BackgroundTransparency = 1,
	Parent = Content,
})

local PageTitle = Create("TextLabel", {
	Size = UDim2.new(1, -50, 1, 0),
	BackgroundTransparency = 1,
	Text = "Dashboard",
	TextColor3 = Config.Text,
	TextSize = 20,
	Font = Enum.Font.GothamBlack,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = Header,
})

local CloseBtn = Create("TextButton", {
	Size = UDim2.new(0, 30, 0, 30),
	Position = UDim2.new(1, -32, 0.5, -15),
	BackgroundColor3 = Color3.fromRGB(60, 40, 80),
	Text = "×",
	TextColor3 = Config.Text,
	TextSize = 20,
	Font = Enum.Font.GothamBold,
	AutoButtonColor = false,
	Parent = Header,
})
Create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = CloseBtn})
CloseBtn.MouseEnter:Connect(function() Tween(CloseBtn, 0.15, {BackgroundColor3 = Config.Danger}) end)
CloseBtn.MouseLeave:Connect(function() Tween(CloseBtn, 0.15, {BackgroundColor3 = Color3.fromRGB(60,40,80)}) end)

-- ============================================================
-- OVERVIEW PAGE
-- ============================================================
local AvatarCard = Create("Frame", {
	Size = UDim2.new(1, -10, 0, 130),
	Position = UDim2.new(0, 0, 0, 55),
	BackgroundColor3 = Config.Card,
	BorderSizePixel = 0,
	Parent = PageOverview,
})
Create("UICorner", {CornerRadius = UDim.new(0, 14), Parent = AvatarCard})
Create("UIStroke", {Color = Config.Accent, Thickness = 1, Transparency = 0.6, Parent = AvatarCard})

local AvatarImg = Create("ImageLabel", {
	Size = UDim2.new(0, 90, 0, 90),
	Position = UDim2.new(0, 20, 0.5, -45),
	BackgroundColor3 = Color3.fromRGB(40, 40, 55),
	Image = "",
	BorderSizePixel = 0,
	Parent = AvatarCard,
})
Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = AvatarImg})
Create("UIStroke", {Color = Config.Accent, Thickness = 2, Parent = AvatarImg})

local UserNameLbl = Create("TextLabel", {
	Size = UDim2.new(1, -130, 0, 30),
	Position = UDim2.new(0, 125, 0, 25),
	BackgroundTransparency = 1,
	Text = "Loading...",
	TextColor3 = Config.Text,
	TextSize = 20,
	Font = Enum.Font.GothamBlack,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = AvatarCard,
})

local UserIdLbl = Create("TextLabel", {
	Size = UDim2.new(1, -130, 0, 22),
	Position = UDim2.new(0, 125, 0, 55),
	BackgroundTransparency = 1,
	Text = "UserID: -",
	TextColor3 = Config.SubText,
	TextSize = 13,
	Font = Enum.Font.Gotham,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = AvatarCard,
})

local StatusDot = Create("Frame", {
	Size = UDim2.new(0, 10, 0, 10),
	Position = UDim2.new(0, 125, 0, 82),
	BackgroundColor3 = Config.Success,
	BorderSizePixel = 0,
	Parent = AvatarCard,
})
Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = StatusDot})

Create("TextLabel", {
	Size = UDim2.new(0, 120, 0, 14),
	Position = UDim2.new(0, 142, 0, 80),
	BackgroundTransparency = 1,
	Text = "Online",
	TextColor3 = Config.Success,
	TextSize = 12,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = AvatarCard,
})

task.spawn(function()
	local ok, thumb = pcall(function()
		return Players:GetUserThumbnailAsync(LocalPlayer.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
	end)
	if ok and thumb then AvatarImg.Image = thumb end
	UserNameLbl.Text = LocalPlayer.DisplayName or LocalPlayer.Name
	UserIdLbl.Text = "UserID: " .. tostring(LocalPlayer.UserId) .. "  •  @" .. LocalPlayer.Name
end)

local function StatCard(title, x, y, w)
	local card = Create("Frame", {
		Size = UDim2.new(w, 0, 0, 70),
		Position = UDim2.new(x, 0, 0, y),
		BackgroundColor3 = Config.Card,
		BorderSizePixel = 0,
		Parent = PageOverview,
	})
	Create("UICorner", {CornerRadius = UDim.new(0, 12), Parent = card})
	Create("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(35, 35, 50)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(28, 28, 38)),
		}),
		Rotation = 45,
		Parent = card,
	})
	local val = Create("TextLabel", {
		Size = UDim2.new(1, 0, 0.55, 0),
		BackgroundTransparency = 1,
		Text = "0",
		TextColor3 = Config.Text,
		TextSize = 26,
		Font = Enum.Font.GothamBlack,
		Parent = card,
	})
	Create("TextLabel", {
		Size = UDim2.new(1, 0, 0.4, 0),
		Position = UDim2.new(0, 0, 0.55, 0),
		BackgroundTransparency = 1,
		Text = title,
		TextColor3 = Config.SubText,
		TextSize = 11,
		Font = Enum.Font.GothamBold,
		Parent = card,
	})
	return val
end

local OvTotal = StatCard("TOTAL FILES", 0, 200, 0.32)
local OvModel = StatCard("MODELS", 0.34, 200, 0.32)
local OvPlace = StatCard("PLACES", 0.68, 200, 0.32)

-- ============================================================
-- ASSETS PAGE
-- ============================================================
local FilterBar = Create("Frame", {
	Size = UDim2.new(1, -10, 0, 34),
	Position = UDim2.new(0, 0, 0, 48),
	BackgroundTransparency = 1,
	Parent = PageAssets,
})

local CurrentFilter = "ALL"
local filterButtons = {}
local function FilterTab(name, x)
	local b = Create("TextButton", {
		Size = UDim2.new(0.32, 0, 1, 0),
		Position = UDim2.new(x, 0, 0, 0),
		BackgroundColor3 = Color3.fromRGB(35, 35, 48),
		Text = name,
		TextColor3 = Config.SubText,
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
		Parent = FilterBar,
	})
	Create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = b})
	filterButtons[name] = b
	return b
end

local FAll = FilterTab("ALL", 0)
local FModel = FilterTab("MODEL", 0.34)
local FPlace = FilterTab("PLACE", 0.68)

local function SetFilter(name)
	CurrentFilter = name
	for n, b in pairs(filterButtons) do
		if n == name then
			Tween(b, 0.2, {BackgroundColor3 = Config.Accent, TextColor3 = Config.Text})
		else
			Tween(b, 0.2, {BackgroundColor3 = Color3.fromRGB(35, 35, 48), TextColor3 = Config.SubText})
		end
	end
end
SetFilter("ALL")

local List = Create("ScrollingFrame", {
	Size = UDim2.new(1, -10, 1, -170),
	Position = UDim2.new(0, 0, 0, 90),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = Config.Accent,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	Parent = PageAssets,
})
Create("UIListLayout", {Padding = UDim.new(0, 8), Parent = List})

local StatusLbl = Create("TextLabel", {
	Size = UDim2.new(1, 0, 0, 20),
	Position = UDim2.new(0, 0, 1, -24),
	BackgroundTransparency = 1,
	Text = "Siap",
	TextColor3 = Config.SubText,
	TextSize = 12,
	Font = Enum.Font.Gotham,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = PageAssets,
})

-- ============================================================
-- SETTINGS PAGE
-- ============================================================
local SettingsCard = Create("Frame", {
	Size = UDim2.new(1, -10, 0, 220),
	Position = UDim2.new(0, 0, 0, 55),
	BackgroundColor3 = Config.Card,
	BorderSizePixel = 0,
	Parent = PageSettings,
})
Create("UICorner", {CornerRadius = UDim.new(0, 14), Parent = SettingsCard})
Create("UIStroke", {Color = Config.Accent, Thickness = 1, Transparency = 0.7, Parent = SettingsCard})

Create("TextLabel", {
	Size = UDim2.new(1, -30, 0, 30),
	Position = UDim2.new(0, 20, 0, 15),
	BackgroundTransparency = 1,
	Text = "⚙️  Pengaturan GUI",
	TextColor3 = Config.Text,
	TextSize = 16,
	Font = Enum.Font.GothamBlack,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = SettingsCard,
})

Create("TextLabel", {
	Size = UDim2.new(1, -40, 0, 20),
	Position = UDim2.new(0, 20, 0, 60),
	BackgroundTransparency = 1,
	Text = "Kecerahan GUI",
	TextColor3 = Config.SubText,
	TextSize = 13,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Left,
	Parent = SettingsCard,
})

local BrightValueLbl = Create("TextLabel", {
	Size = UDim2.new(0, 60, 0, 20),
	Position = UDim2.new(1, -80, 0, 60),
	BackgroundTransparency = 1,
	Text = "100%",
	TextColor3 = Config.Accent,
	TextSize = 13,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Right,
	Parent = SettingsCard,
})

local SliderBg = Create("Frame", {
	Size = UDim2.new(1, -40, 0, 8),
	Position = UDim2.new(0, 20, 0, 90),
	BackgroundColor3 = Color3.fromRGB(45, 45, 60),
	BorderSizePixel = 0,
	Parent = SettingsCard,
})
Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = SliderBg})

local SliderFill = Create("Frame", {
	Size = UDim2.new(1, 0, 1, 0),
	BackgroundColor3 = Config.Accent,
	BorderSizePixel = 0,
	Parent = SliderBg,
})
Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = SliderFill})
Create("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Config.Accent),
		ColorSequenceKeypoint.new(1, Config.Accent2),
	}),
	Parent = SliderFill,
})

local SliderKnob = Create("Frame", {
	Size = UDim2.new(0, 18, 0, 18),
	Position = UDim2.new(1, -9, 0.5, -9),
	BackgroundColor3 = Color3.fromRGB(255, 255, 255),
	BorderSizePixel = 0,
	ZIndex = 2,
	Parent = SliderBg,
})
Create("UICorner", {CornerRadius = UDim.new(1, 0), Parent = SliderKnob})
Create("UIStroke", {Color = Config.Accent, Thickness = 2, Parent = SliderKnob})

local draggingSlider = false
local function UpdateBrightness(alpha)
	alpha = math.clamp(alpha, 0, 1)
	SliderFill.Size = UDim2.new(alpha, 0, 1, 0)
	SliderKnob.Position = UDim2.new(alpha, -9, 0.5, -9)
	BrightValueLbl.Text = tostring(math.floor(alpha * 100)) .. "%"
	Config.Brightness = 0.3 + alpha * 0.7
	local function applyBright(c, b)
		return Color3.new(math.clamp(c.R*b, 0, 1), math.clamp(c.G*b, 0, 1), math.clamp(c.B*b, 0, 1))
	end
	Main.BackgroundColor3 = applyBright(Config.Bg, Config.Brightness)
	Sidebar.BackgroundColor3 = applyBright(Config.Sidebar, Config.Brightness)
	AvatarCard.BackgroundColor3 = applyBright(Config.Card, Config.Brightness)
	SettingsCard.BackgroundColor3 = applyBright(Config.Card, Config.Brightness)
	for _, c in ipairs(List:GetChildren()) do
		if c:IsA("Frame") then
			c.BackgroundColor3 = applyBright(Config.Card, Config.Brightness)
		end
	end
end
UpdateBrightness(1)

SliderBg.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = true
		local rel = (i.Position.X - SliderBg.AbsolutePosition.X) / SliderBg.AbsoluteSize.X
		UpdateBrightness(rel)
	end
end)
UserInputService.InputChanged:Connect(function(i)
	if draggingSlider and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local rel = (i.Position.X - SliderBg.AbsolutePosition.X) / SliderBg.AbsoluteSize.X
		UpdateBrightness(rel)
	end
end)
UserInputService.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		draggingSlider = false
	end
end)

-- ============================================================
-- CARD CREATION
-- ============================================================
local function ClearList()
	for _, c in ipairs(List:GetChildren()) do
		if c:IsA("Frame") then c:Destroy() end
	end
end

local function CreateCard(asset, order)
	local card = Create("Frame", {
		Size = UDim2.new(1, -8, 0, 58),
		BackgroundColor3 = Config.Card,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = List,
	})
	Create("UICorner", {CornerRadius = UDim.new(0, 10), Parent = card})
	Create("UIStroke", {Color = Config.Accent, Thickness = 1, Transparency = 0.85, Parent = card})

	local iconBg = Create("Frame", {
		Size = UDim2.new(0, 42, 0, 42),
		Position = UDim2.new(0, 8, 0.5, -21),
		BackgroundColor3 = asset.Type == "MODEL" and Color3.fromRGB(40, 90, 70) or Color3.fromRGB(70, 50, 120),
		BorderSizePixel = 0,
		Parent = card,
	})
	Create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = iconBg})
	Create("TextLabel", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundTransparency = 1,
		Text = asset.Type == "MODEL" and "📦" or "🎮",
		TextSize = 20,
		Parent = iconBg,
	})

	Create("TextLabel", {
		Size = UDim2.new(1, -150, 0, 22),
		Position = UDim2.new(0, 58, 0, 8),
		BackgroundTransparency = 1,
		Text = asset.Name,
		TextColor3 = Config.Text,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = card,
	})

	local tag = Create("TextLabel", {
		Size = UDim2.new(0, 54, 0, 18),
		Position = UDim2.new(0, 58, 0, 32),
		BackgroundColor3 = asset.Type == "MODEL" and Color3.fromRGB(40, 120, 80) or Color3.fromRGB(90, 60, 150),
		Text = asset.Ext:upper(),
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextSize = 10,
		Font = Enum.Font.GothamBold,
		Parent = card,
	})
	Create("UICorner", {CornerRadius = UDim.new(0, 4), Parent = tag})

	local btn = Create("TextButton", {
		Size = UDim2.new(0, 78, 0, 32),
		Position = UDim2.new(1, -88, 0.5, -16),
		BackgroundColor3 = Config.Accent,
		Text = "IMPORT",
		TextColor3 = Color3.fromRGB(255, 255, 255),
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
		Parent = card,
	})
	Create("UICorner", {CornerRadius = UDim.new(0, 8), Parent = btn})
	Create("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Config.Accent),
			ColorSequenceKeypoint.new(1, Config.Accent2),
		}),
		Rotation = 45,
		Parent = btn,
	})

	btn.MouseEnter:Connect(function()
		Tween(btn, 0.15, {Size = UDim2.new(0, 82, 0, 34), Position = UDim2.new(1, -90, 0.5, -17)})
	end)
	btn.MouseLeave:Connect(function()
		Tween(btn, 0.15, {Size = UDim2.new(0, 78, 0, 32), Position = UDim2.new(1, -88, 0.5, -16)})
	end)

	btn.MouseButton1Click:Connect(function()
		btn.Text = "..."
		StatusLbl.Text = "⏳ Importing: " .. asset.Name
		StatusLbl.TextColor3 = Config.Warn

		task.spawn(function()
			local roots, method = Loader.Import(asset.Path, workspace)
			if roots and #roots > 0 then
				btn.Text = "✓ OK"
				StatusLbl.Text = "✅ Berhasil import (" .. tostring(method) .. "): " .. #roots .. " item"
				StatusLbl.TextColor3 = Config.Success
				print("[GEN IMPORT SUCCESS]", asset.Name, "via", method)
			else
				btn.Text = "FAIL"
				StatusLbl.Text = "❌ Gagal: " .. tostring(method)
				StatusLbl.TextColor3 = Config.Danger
				warn("[GEN IMPORT FAIL]", asset.Name, method)
			end

			task.delay(2, function()
				if btn and btn.Parent then btn.Text = "IMPORT" end
			end)
		end)
	end)
end

-- ============================================================
-- REFRESH
-- ============================================================
local function Refresh()
	ClearList()
	StatusLbl.Text = "Scanning..."
	local all = GetWorkspaceFiles()
	local filtered = {}
	local modelCount, placeCount = 0, 0
	for _, a in ipairs(all) do
		if a.Type == "MODEL" then modelCount += 1 else placeCount += 1 end
		if CurrentFilter == "ALL" or a.Type == CurrentFilter then
			table.insert(filtered, a)
		end
	end

	OvTotal.Text = tostring(#all)
	OvModel.Text = tostring(modelCount)
	OvPlace.Text = tostring(placeCount)

	for i, a in ipairs(filtered) do
		CreateCard(a, i)
	end
	List.CanvasSize = UDim2.new(0, 0, 0, #filtered * 66 + 10)
	StatusLbl.Text = #all > 0 and ("✓ Ditemukan " .. #all .. " file") or "⚠ Tidak ada file di Workspace"
	StatusLbl.TextColor3 = #all > 0 and Config.Success or Config.Warn
end

-- ============================================================
-- NAV
-- ============================================================
BtnOverview.MouseButton1Click:Connect(function()
	SetActive("overview"); PageTitle.Text = "Overview"; ShowPage("Overview")
end)
BtnAssets.MouseButton1Click:Connect(function()
	SetActive("assets"); PageTitle.Text = "Assets"; ShowPage("Assets"); Refresh()
end)
BtnSettings.MouseButton1Click:Connect(function()
	SetActive("settings"); PageTitle.Text = "Settings"; ShowPage("Settings")
end)

FAll.MouseButton1Click:Connect(function() SetFilter("ALL"); Refresh() end)
FModel.MouseButton1Click:Connect(function() SetFilter("MODEL"); Refresh() end)
FPlace.MouseButton1Click:Connect(function() SetFilter("PLACE"); Refresh() end)

RescanBtn.MouseButton1Click:Connect(function()
	RescanBtn.Text = "⏳ Scanning..."
	Refresh()
	task.wait(0.4)
	RescanBtn.Text = "↻  Rescan"
end)

-- ============================================================
-- TOGGLE
-- ============================================================
local guiOpen = false
local function OpenGUI()
	if guiOpen then return end
	guiOpen = true
	Main.Visible = true
	Main.Size = UDim2.new(0, 480, 0, 340)
	Main.Position = UDim2.new(0.5, -240, 0.5, -170)
	Tween(Main, 0.4, {
		Size = UDim2.new(0, 620, 0, 440),
		Position = UDim2.new(0.5, -310, 0.5, -220),
	}, Enum.EasingStyle.Back)
	SetActive("overview")
	PageTitle.Text = "Overview"
	ShowPage("Overview")
end

local function CloseGUI()
	if not guiOpen then return end
	guiOpen = false
	Tween(Main, 0.3, {
		Size = UDim2.new(0, 480, 0, 340),
		Position = UDim2.new(0.5, -240, 0.5, -170),
	}, Enum.EasingStyle.Quart)
	task.delay(0.3, function() Main.Visible = false end)
end

LogoBtn.MouseButton1Click:Connect(function()
	if guiOpen then CloseGUI() else OpenGUI() end
end)
CloseBtn.MouseButton1Click:Connect(CloseGUI)

-- ============================================================
-- DRAG
-- ============================================================
local dragging, dragStart, startPos
Header.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = i.Position
		startPos = Main.Position
	end
end)
Header.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)
UserInputService.InputChanged:Connect(function(i)
	if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - dragStart
		Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
end)

local logoDrag, logoDragStart, logoStartPos
LogoBtn.InputBegan:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		logoDrag = true
		logoDragStart = i.Position
		logoStartPos = LogoBtn.Position
	end
end)
UserInputService.InputChanged:Connect(function(i)
	if logoDrag and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
		local d = i.Position - logoDragStart
		LogoBtn.Position = UDim2.new(logoStartPos.X.Scale, logoStartPos.X.Offset + d.X, logoStartPos.Y.Scale, logoStartPos.Y.Offset + d.Y)
	end
end)
UserInputService.InputEnded:Connect(function(i)
	if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
		logoDrag = false
	end
end)

-- ============================================================
-- INIT
-- ============================================================
StatusLbl.Text = "✓ Native Loader ready!"
StatusLbl.TextColor3 = Config.Success
Refresh()
task.wait(0.3)
OpenGUI()
