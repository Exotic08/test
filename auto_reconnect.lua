--[[
    AUTO RECONNECT - tự động vào lại game khi bị kick / mất kết nối
    - Phát hiện: bảng lỗi Roblox (ErrorPrompt), ErrorMessageChanged, NetworkClient bị ngắt, teleport lỗi
    - Menu nhỏ gọn: trạng thái, thời gian hoạt động, số lần reconnect, nút Bật/Tắt, kéo thả được
    - Gợi ý: để file này trong thư mục autoexec của executor để nó tự chạy lại sau mỗi lần vào game
]]

if getgenv and getgenv().__AUTO_RECONNECT_LOADED then return end
if getgenv then getgenv().__AUTO_RECONNECT_LOADED = true end

---------------------------------------------------------------------
-- CẤU HÌNH
---------------------------------------------------------------------
local CONFIG = {
	RejoinDelay = 3,      -- giây chờ trước khi vào lại
	RetryInterval = 10,   -- giây giữa các lần thử nếu thất bại
	SameServer = true,    -- ưu tiên vào lại đúng server cũ (JobId); sau vài lần fail sẽ vào server bất kỳ
	SameServerTries = 2,  -- số lần thử server cũ trước khi chuyển sang server bất kỳ
	Keybind = Enum.KeyCode.RightControl, -- phím ẩn/hiện menu
}

---------------------------------------------------------------------
-- DỊCH VỤ
---------------------------------------------------------------------
local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local GuiService = game:GetService("GuiService")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
while not player do
	task.wait()
	player = Players.LocalPlayer
end

local PLACE_ID = game.PlaceId
local JOB_ID = game.JobId

---------------------------------------------------------------------
-- TRẠNG THÁI
---------------------------------------------------------------------
local enabled = true
local rejoining = false
local rejoinCount = 0
local startTime = os.clock()

local setStatus -- khai báo trước, gán sau khi tạo UI

---------------------------------------------------------------------
-- GIAO DIỆN
---------------------------------------------------------------------
local function getGuiParent()
	if typeof(gethui) == "function" then
		local ok, ui = pcall(gethui)
		if ok and ui then return ui end
	end
	local ok = pcall(function() return CoreGui.Name end)
	if ok then return CoreGui end
	return player:WaitForChild("PlayerGui")
end

local gui = Instance.new("ScreenGui")
gui.Name = "AutoReconnectUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
if typeof(syn) == "table" and syn.protect_gui then pcall(syn.protect_gui, gui) end
gui.Parent = getGuiParent()

local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(200, 74)
frame.Position = UDim2.new(0, 12, 0, 12)
frame.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
frame.BorderSizePixel = 0
frame.Active = true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local stroke = Instance.new("UIStroke", frame)
stroke.Color = Color3.fromRGB(60, 60, 75)
stroke.Thickness = 1

local dot = Instance.new("Frame")
dot.Size = UDim2.fromOffset(10, 10)
dot.Position = UDim2.fromOffset(10, 11)
dot.BackgroundColor3 = Color3.fromRGB(70, 220, 110)
dot.BorderSizePixel = 0
dot.Parent = frame
Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(26, 4)
title.Size = UDim2.new(1, -34, 0, 22)
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(235, 235, 245)
title.Text = "Auto Reconnect"
title.Parent = frame

local statusLabel = Instance.new("TextLabel")
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.fromOffset(10, 26)
statusLabel.Size = UDim2.new(1, -20, 0, 16)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.TextColor3 = Color3.fromRGB(70, 220, 110)
statusLabel.Text = "Đang hoạt động"
statusLabel.Parent = frame

local infoLabel = Instance.new("TextLabel")
infoLabel.BackgroundTransparency = 1
infoLabel.Position = UDim2.fromOffset(10, 42)
infoLabel.Size = UDim2.new(1, -66, 0, 16)
infoLabel.Font = Enum.Font.Gotham
infoLabel.TextSize = 11
infoLabel.TextXAlignment = Enum.TextXAlignment.Left
infoLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
infoLabel.Text = "00:00:00 • Rejoin: 0"
infoLabel.Parent = frame

local toggle = Instance.new("TextButton")
toggle.Size = UDim2.fromOffset(46, 20)
toggle.Position = UDim2.new(1, -54, 0, 42)
toggle.BackgroundColor3 = Color3.fromRGB(70, 220, 110)
toggle.BorderSizePixel = 0
toggle.AutoButtonColor = false
toggle.Font = Enum.Font.GothamBold
toggle.TextSize = 11
toggle.TextColor3 = Color3.fromRGB(15, 15, 20)
toggle.Text = "BẬT"
toggle.Parent = frame
Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 5)

local GREEN = Color3.fromRGB(70, 220, 110)
local RED = Color3.fromRGB(235, 80, 80)
local YELLOW = Color3.fromRGB(245, 190, 60)

local function paint(color)
	TweenService:Create(dot, TweenInfo.new(0.2), { BackgroundColor3 = color }):Play()
	statusLabel.TextColor3 = color
end

setStatus = function(text, color)
	statusLabel.Text = text
	paint(color or GREEN)
end

-- Kéo thả menu
do
	local dragging, dragStart, startPos
	frame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = frame.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

-- Ẩn/hiện menu bằng phím
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == CONFIG.Keybind then
		frame.Visible = not frame.Visible
	end
end)

-- Cập nhật thời gian hoạt động
task.spawn(function()
	while gui.Parent do
		local t = math.floor(os.clock() - startTime)
		infoLabel.Text = string.format("%02d:%02d:%02d • Rejoin: %d",
			t // 3600, (t % 3600) // 60, t % 60, rejoinCount)
		task.wait(1)
	end
end)

---------------------------------------------------------------------
-- LOGIC RECONNECT
---------------------------------------------------------------------
local function tryRejoin(attempt)
	local ok, err = pcall(function()
		if CONFIG.SameServer and JOB_ID ~= "" and attempt <= CONFIG.SameServerTries then
			TeleportService:TeleportToPlaceInstance(PLACE_ID, JOB_ID, player)
		else
			TeleportService:Teleport(PLACE_ID, player)
		end
	end)
	return ok, err
end

local function rejoin(reason)
	if not enabled or rejoining then return end
	rejoining = true
	rejoinCount += 1

	local shortReason = tostring(reason or "Mất kết nối")
	if #shortReason > 28 then shortReason = shortReason:sub(1, 28) .. "…" end

	setStatus("Mất kết nối: " .. shortReason, RED)
	task.wait(CONFIG.RejoinDelay)

	local attempt = 0
	while enabled do
		attempt += 1
		setStatus("Đang vào lại... (lần " .. attempt .. ")", YELLOW)
		tryRejoin(attempt)
		-- Nếu teleport thành công thì script này sẽ bị huỷ cùng game cũ.
		-- Còn chạy được tới đây nghĩa là chưa thành công -> chờ rồi thử lại.
		task.wait(CONFIG.RetryInterval)
	end

	rejoining = false
	setStatus("Đã tắt", RED)
end

-- 1) Bảng lỗi của Roblox (kick, mất kết nối, lỗi server...)
local function hookPrompt()
	local ok, overlay = pcall(function()
		return CoreGui:WaitForChild("RobloxPromptGui", 15):WaitForChild("promptOverlay", 15)
	end)
	if not ok or not overlay then return end

	local function check(child)
		if child.Name == "ErrorPrompt" then
			local msg = "Bị kick / lỗi kết nối"
			pcall(function()
				local label = child:FindFirstChild("MessageArea", true)
				label = label and label:FindFirstChild("ErrorFrame", true)
				label = label and label:FindFirstChild("ErrorMessage", true)
				if label and label.Text ~= "" then msg = label.Text end
			end)
			task.spawn(rejoin, msg)
		end
	end

	overlay.ChildAdded:Connect(check)
	for _, c in ipairs(overlay:GetChildren()) do check(c) end
end
task.spawn(hookPrompt)

-- 2) Thông báo lỗi từ GuiService
GuiService.ErrorMessageChanged:Connect(function(msg)
	if msg and msg ~= "" then
		task.spawn(rejoin, msg)
	end
end)

-- 3) Client bị ngắt khỏi mạng
pcall(function()
	game:GetService("NetworkClient").ChildRemoved:Connect(function()
		task.spawn(rejoin, "Mất kết nối mạng")
	end)
end)

-- 4) Teleport thất bại -> thử lại
TeleportService.TeleportInitFailed:Connect(function(_, result, errMsg)
	if enabled and rejoining then
		setStatus("Teleport lỗi: " .. tostring(result), RED)
	end
end)

---------------------------------------------------------------------
-- NÚT BẬT / TẮT
---------------------------------------------------------------------
toggle.MouseButton1Click:Connect(function()
	enabled = not enabled
	if enabled then
		toggle.Text = "BẬT"
		toggle.BackgroundColor3 = GREEN
		setStatus("Đang hoạt động", GREEN)
	else
		toggle.Text = "TẮT"
		toggle.BackgroundColor3 = RED
		setStatus("Đã tắt", RED)
	end
end)

setStatus("Đang hoạt động", GREEN)
