--[[
    AUTO RECONNECT - tự động vào lại game khi bị kick / mất kết nối
    - Phát hiện: bảng lỗi Roblox (ErrorPrompt), ErrorMessageChanged, NetworkClient bị ngắt, teleport lỗi
    - Menu nhỏ gọn: trạng thái, thời gian hoạt động, số lần reconnect, nút Bật/Tắt, kéo thả được
    - Gợi ý: để file này trong thư mục autoexec của executor để nó tự chạy lại sau mỗi lần vào game
]]

if not game:IsLoaded() then game.Loaded:Wait() end

-- Có phải lần chạy này do chính script tự xếp hàng (Auto Execute) không?
local fromQueue = false
pcall(function()
	if getgenv and getgenv().__AR_QUEUED then
		fromQueue = true
		getgenv().__AR_QUEUED = nil
	end
end)

local function getGuiParent()
	if typeof(gethui) == "function" then
		local ok, ui = pcall(gethui)
		if ok and ui then return ui end
	end
	local ok, cg = pcall(function() return game:GetService("CoreGui") end)
	if ok and cg then
		local ok2 = pcall(function() return cg.Name end)
		if ok2 then return cg end
	end
	return game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
end

-- CHỐNG CHẠY TRÙNG: nếu menu đã tồn tại trong game này thì script đang chạy rồi -> tự ngắt.
-- (Menu bị xoá mỗi khi sang game/server mới nên lần vào sau vẫn chạy được bình thường.)
local guiParent = getGuiParent()
if guiParent:FindFirstChild("AutoReconnectUI") then return end

local gui = Instance.new("ScreenGui")
gui.Name = "AutoReconnectUI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
if typeof(syn) == "table" and syn.protect_gui then pcall(syn.protect_gui, gui) end
gui.Parent = guiParent

---------------------------------------------------------------------
-- CẤU HÌNH
---------------------------------------------------------------------
local CONFIG = {
	RejoinDelay = 3,      -- giây chờ trước khi vào lại
	RetryInterval = 10,   -- giây giữa các lần thử nếu thất bại
	SameServer = true,    -- ưu tiên vào lại đúng server cũ (JobId); sau vài lần fail sẽ vào server bất kỳ
	SameServerTries = 2,  -- số lần thử server cũ trước khi chuyển sang server bất kỳ
	Keybind = Enum.KeyCode.RightControl, -- phím ẩn/hiện menu
	SaveFile = "AutoReconnect_data.json", -- file lưu số lần reconnect thành công (giữ qua các lần vào lại)
	-- Link loadstring: dùng để tự chạy lại script sau khi vào lại game (qua queue_on_teleport).
	-- Nếu bạn để script trong thư mục autoexec thì không cần, nhưng để cũng không sao.
	ScriptURL = "https://raw.githubusercontent.com/Exotic08/test/refs/heads/main/auto_reconnect.lua",
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
-- LƯU DỮ LIỆU (giữ số lần thành công qua các lần vào lại game)
---------------------------------------------------------------------
local HttpService = game:GetService("HttpService")
local canSave = typeof(writefile) == "function" and typeof(readfile) == "function"
	and typeof(isfile) == "function"

local data = { success = 0, last = 0, pending = false, pendingAt = 0, webhook = "", autoExec = true }

local function loadData()
	if not canSave then return end
	pcall(function()
		if isfile(CONFIG.SaveFile) then
			local decoded = HttpService:JSONDecode(readfile(CONFIG.SaveFile))
			if type(decoded) == "table" then
				data.success = tonumber(decoded.success) or 0
				data.last = tonumber(decoded.last) or 0
				data.pending = decoded.pending == true
				data.pendingAt = tonumber(decoded.pendingAt) or 0
				data.webhook = type(decoded.webhook) == "string" and decoded.webhook or ""
				if decoded.autoExec ~= nil then data.autoExec = decoded.autoExec == true end
			end
		end
	end)
end

local function saveData()
	if not canSave then return end
	pcall(function()
		writefile(CONFIG.SaveFile, HttpService:JSONEncode(data))
	end)
end

local queued = false
local function queueSelf()
	-- Xếp hàng để script tự chạy lại sau lần teleport/vào lại game kế tiếp.
	-- Chỉ xếp hàng 1 lần mỗi phiên để tránh chạy trùng.
	if queued then return end
	if typeof(queue_on_teleport) == "function" and CONFIG.ScriptURL ~= "" then
		local ok = pcall(queue_on_teleport,
			'pcall(function() getgenv().__AR_QUEUED = true end) '
			.. 'loadstring(game:HttpGet("' .. CONFIG.ScriptURL .. '"))()')
		if ok then queued = true end
	end
end

---------------------------------------------------------------------
-- WEBHOOK DISCORD
---------------------------------------------------------------------
local httpRequest = (typeof(request) == "function" and request)
	or (typeof(http_request) == "function" and http_request)
	or (syn and syn.request)
	or (fluxus and fluxus.request)

local function isValidWebhook(url)
	if type(url) ~= "string" then return false end
	return url:match("^https://[%w%.]*discord%.com/api/webhooks/%d+/[%w_%-]+") ~= nil
		or url:match("^https://[%w%.]*discordapp%.com/api/webhooks/%d+/[%w_%-]+") ~= nil
end

local gameName
local function getGameName()
	if gameName then return gameName end
	local ok, info = pcall(function()
		return game:GetService("MarketplaceService"):GetProductInfo(PLACE_ID)
	end)
	gameName = (ok and info and info.Name) or ("PlaceId " .. tostring(PLACE_ID))
	return gameName
end

-- kind: "success" | "offline" | "test"
local function sendWebhook(kind, extra)
	local url = data.webhook
	if not httpRequest or not isValidWebhook(url) then return end

	task.spawn(function()
		local online = kind ~= "offline"
		local titles = {
			success = "✅ Đã reconnect thành công",
			offline = "⚠️ Mất kết nối",
			test = "🔔 Webhook đã kết nối",
		}
		local fields = {
			{ name = "Trạng thái", value = online and "🟢 Online" or "🔴 Offline", inline = true },
			{ name = "Tài khoản", value = player.Name, inline = true },
			{ name = "Game", value = getGameName(), inline = false },
			{ name = "Reconnect thành công", value = tostring(data.success), inline = true },
		}
		if extra and extra ~= "" then
			table.insert(fields, { name = "Chi tiết", value = tostring(extra), inline = false })
		end

		local ok, body = pcall(function()
			return HttpService:JSONEncode({
				username = "Auto Reconnect",
				embeds = {{
					title = titles[kind] or titles.test,
					color = online and 3066993 or 15158332,
					fields = fields,
					timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
				}},
			})
		end)
		if not ok then return end

		pcall(httpRequest, {
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)
end

loadData()

-- Nếu lần chạy này do hàng đợi tự xếp mà Auto Execute đã bị tắt (và không phải đang chờ
-- xác nhận reconnect) thì tự ngắt, vòng lặp tự chạy dừng lại ở đây.
do
	local pendingValid = data.pending and (os.time() - data.pendingAt) <= 600
	if fromQueue and not data.autoExec and not pendingValid then
		gui:Destroy()
		return
	end
end

---------------------------------------------------------------------
-- GIAO DIỆN
---------------------------------------------------------------------
-- (gui đã được tạo ở đầu file để chống chạy trùng)
local frame = Instance.new("Frame")
frame.Name = "Main"
frame.Size = UDim2.fromOffset(210, 162)
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
title.Size = UDim2.new(1, -100, 0, 22)
title.Font = Enum.Font.GothamBold
title.TextSize = 13
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(235, 235, 245)
title.Text = "Auto Reconnect"
title.Parent = frame

local presenceLabel = Instance.new("TextLabel")
presenceLabel.BackgroundTransparency = 1
presenceLabel.Position = UDim2.new(1, -78, 0, 4)
presenceLabel.Size = UDim2.fromOffset(70, 22)
presenceLabel.Font = Enum.Font.GothamBold
presenceLabel.TextSize = 12
presenceLabel.TextXAlignment = Enum.TextXAlignment.Right
presenceLabel.Parent = frame

local function setPresence(online)
	presenceLabel.Text = online and "● Online" or "● Offline"
	presenceLabel.TextColor3 = online and Color3.fromRGB(70, 220, 110) or Color3.fromRGB(235, 80, 80)
end
setPresence(true)

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
infoLabel.Text = "00:00:00"
infoLabel.Parent = frame

local successLabel = Instance.new("TextLabel")
successLabel.BackgroundTransparency = 1
successLabel.Position = UDim2.fromOffset(10, 62)
successLabel.Size = UDim2.new(1, -20, 0, 16)
successLabel.Font = Enum.Font.GothamBold
successLabel.TextSize = 12
successLabel.TextXAlignment = Enum.TextXAlignment.Left
successLabel.TextColor3 = Color3.fromRGB(235, 235, 245)
successLabel.Text = "✔ Reconnect thành công: 0"
successLabel.Parent = frame

local lastLabel = Instance.new("TextLabel")
lastLabel.BackgroundTransparency = 1
lastLabel.Position = UDim2.fromOffset(10, 79)
lastLabel.Size = UDim2.new(1, -20, 0, 16)
lastLabel.Font = Enum.Font.Gotham
lastLabel.TextSize = 11
lastLabel.TextXAlignment = Enum.TextXAlignment.Left
lastLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
lastLabel.Text = "Lần cuối: chưa có"
lastLabel.Parent = frame

local function refreshSuccess()
	successLabel.Text = "✔ Reconnect thành công: " .. data.success
	if data.last > 0 then
		lastLabel.Text = "Lần cuối: " .. os.date("%H:%M:%S %d/%m", data.last)
	else
		lastLabel.Text = "Lần cuối: chưa có"
	end
end
refreshSuccess()

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

-- Ô nhập webhook + nút Lưu
local BLUE = Color3.fromRGB(88, 101, 242)

local webhookBox = Instance.new("TextBox")
webhookBox.Size = UDim2.new(1, -78, 0, 24)
webhookBox.Position = UDim2.fromOffset(10, 100)
webhookBox.BackgroundColor3 = Color3.fromRGB(36, 36, 46)
webhookBox.BorderSizePixel = 0
webhookBox.ClearTextOnFocus = false
webhookBox.ClipsDescendants = true
webhookBox.Font = Enum.Font.Gotham
webhookBox.TextSize = 11
webhookBox.TextXAlignment = Enum.TextXAlignment.Left
webhookBox.TextColor3 = Color3.fromRGB(220, 220, 235)
webhookBox.PlaceholderText = "Dán webhook Discord..."
webhookBox.PlaceholderColor3 = Color3.fromRGB(110, 110, 130)
webhookBox.Text = data.webhook
webhookBox.Parent = frame
Instance.new("UICorner", webhookBox).CornerRadius = UDim.new(0, 5)
local boxPad = Instance.new("UIPadding", webhookBox)
boxPad.PaddingLeft = UDim.new(0, 6)
boxPad.PaddingRight = UDim.new(0, 6)

local saveBtn = Instance.new("TextButton")
saveBtn.Size = UDim2.fromOffset(58, 24)
saveBtn.Position = UDim2.new(1, -68, 0, 100)
saveBtn.BackgroundColor3 = BLUE
saveBtn.BorderSizePixel = 0
saveBtn.AutoButtonColor = false
saveBtn.Font = Enum.Font.GothamBold
saveBtn.TextSize = 11
saveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
saveBtn.Text = "Lưu"
saveBtn.Parent = frame
Instance.new("UICorner", saveBtn).CornerRadius = UDim.new(0, 5)

local function flashSave(text, color)
	saveBtn.Text = text
	saveBtn.BackgroundColor3 = color
	task.delay(1.5, function()
		saveBtn.Text = "Lưu"
		saveBtn.BackgroundColor3 = BLUE
	end)
end

saveBtn.MouseButton1Click:Connect(function()
	local url = (webhookBox.Text:gsub("%s+", ""))

	if url == "" then
		data.webhook = ""
		saveData()
		flashSave("Đã xoá", YELLOW)
		return
	end

	if not isValidWebhook(url) then
		flashSave("Sai link", RED)
		return
	end

	data.webhook = url
	saveData()
	flashSave("Đã lưu", GREEN)
	sendWebhook("test", "Webhook đã được lưu. Từ giờ mỗi lần reconnect sẽ có thông báo.")
end)

-- Auto Execute: tự chạy lại script ở lần vào game kế tiếp
local autoLabel = Instance.new("TextLabel")
autoLabel.BackgroundTransparency = 1
autoLabel.Position = UDim2.fromOffset(10, 132)
autoLabel.Size = UDim2.new(1, -76, 0, 22)
autoLabel.Font = Enum.Font.Gotham
autoLabel.TextSize = 12
autoLabel.TextXAlignment = Enum.TextXAlignment.Left
autoLabel.TextColor3 = Color3.fromRGB(200, 200, 215)
autoLabel.Text = "Auto Execute"
autoLabel.Parent = frame

local autoBtn = Instance.new("TextButton")
autoBtn.Size = UDim2.fromOffset(46, 20)
autoBtn.Position = UDim2.new(1, -56, 0, 133)
autoBtn.BorderSizePixel = 0
autoBtn.AutoButtonColor = false
autoBtn.Font = Enum.Font.GothamBold
autoBtn.TextSize = 11
autoBtn.TextColor3 = Color3.fromRGB(15, 15, 20)
autoBtn.Parent = frame
Instance.new("UICorner", autoBtn).CornerRadius = UDim.new(0, 5)

local function refreshAutoBtn()
	autoBtn.Text = data.autoExec and "BẬT" or "TẮT"
	autoBtn.BackgroundColor3 = data.autoExec and GREEN or RED
end
refreshAutoBtn()

autoBtn.MouseButton1Click:Connect(function()
	data.autoExec = not data.autoExec
	saveData()
	refreshAutoBtn()
	if data.autoExec then
		queueSelf()
	end
end)

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
		infoLabel.Text = string.format("Online: %02d:%02d:%02d",
			t // 3600, (t % 3600) // 60, t % 60)
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
	setPresence(false)

	-- Đánh dấu "đang chờ vào lại": nếu script chạy lại ở game mới thì tính là thành công
	data.pending = true
	data.pendingAt = os.time()
	saveData()
	queueSelf()
	sendWebhook("offline", tostring(reason or "Mất kết nối"))

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
		-- Người dùng chủ động tắt -> không tính lần vào lại tiếp theo là reconnect
		data.pending = false
		saveData()
	end
end)

---------------------------------------------------------------------
-- KHỞI ĐỘNG: kiểm tra có phải vừa reconnect thành công không
---------------------------------------------------------------------
local PENDING_TIMEOUT = 600 -- quá 10 phút thì bỏ qua (vd: tắt game rồi mở lại sau)

if data.pending and (os.time() - data.pendingAt) <= PENDING_TIMEOUT then
	data.success += 1
	data.last = os.time()
	data.pending = false
	saveData()
	refreshSuccess()
	setStatus("Reconnect thành công!", GREEN)
	setPresence(true)
	sendWebhook("success", "Đã vào lại game sau khi mất kết nối.")
	task.delay(6, function()
		if enabled and not rejoining then
			setStatus("Đang hoạt động", GREEN)
		end
	end)
else
	if data.pending then
		data.pending = false
		saveData()
	end
	setStatus("Đang hoạt động", GREEN)
end

if not canSave then
	lastLabel.Text = "Executor không hỗ trợ lưu file"
elseif typeof(queue_on_teleport) ~= "function" then
	lastLabel.Text = "Executor thiếu queue_on_teleport"
end

-- AUTO EXECUTE: xếp hàng ngay khi script chạy, và xếp lại mỗi lần teleport (nếu chưa xếp)
if data.autoExec then
	queueSelf()
end
player.OnTeleport:Connect(function()
	if data.autoExec then
		queueSelf()
	end
end)
