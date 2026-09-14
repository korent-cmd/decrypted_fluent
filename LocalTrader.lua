-- Blox Fruits Version 1 local trader.
-- Requires an executor with readfile/loadstring or a runtime ItemIds table.
-- No namecall hooks are used. Trade calls are made directly through the game's remotes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
assert(Remotes, "ReplicatedStorage.Remotes was not found")

local TradeEvent = Remotes:WaitForChild("TradeEvent", 15)
local TradeFunction = Remotes:WaitForChild("TradeFunction", 15)
local CommF = Remotes:WaitForChild("CommF_", 15)
assert(TradeEvent and TradeFunction and CommF, "Trade remotes were not found")

local CONFIG = {
	TablePath = {"Map", "Dressrosa", "TradeTable"},
	ItemIdsUrl = "https://raw.githubusercontent.com/korent-cmd/decrypted_fluent/refs/heads/main/itemIds.lua",
	AcceptInterval = 1.5,
	CustomerWaitTimeout = 180,
	TradeStartTimeout = 30,
	CompletionTimeout = 45,
	InventoryRefreshInterval = 2,
}

local state = "IDLE"
local running = false
local session = nil
local latestTradeState = nil
local lastAccept = 0
local lastOfferSignature = nil
local connections = {}

local function disconnectAll()
	for _, connection in ipairs(connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	connections = {}
end

local function connect(signal, callback)
	local connection = signal:Connect(callback)
	connections[#connections + 1] = connection
	return connection
end

local function normalize(value)
	return tostring(value or ""):lower():gsub("[%s%p]+", "")
end

local function loadItemIds()
	if type(_G.ItemIds) == "table" then
		return _G.ItemIds
	end

	if type(loadstring) == "function" and type(game.HttpGet) == "function" then
		local ok, result = pcall(function()
			return loadstring(game:HttpGet(CONFIG.ItemIdsUrl))()
		end)
		if ok and type(result) == "table" then
			return result
		end
	end

	if type(readfile) == "function" and type(loadstring) == "function" then
		local ok, result = pcall(function()
			return loadstring(readfile("itemIds.lua"))()
		end)
		if ok and type(result) == "table" then
			return result
		end
	end

	return nil
end

local ItemIds = loadItemIds()
local itemByName = {}

if ItemIds then
	for id, record in pairs(ItemIds) do
		if type(record) == "table" and record[2] then
			local key = normalize(record[2])
			itemByName[key] = itemByName[key] or {}
			itemByName[key][#itemByName[key] + 1] = {
				id = tonumber(id) or id,
				type = tostring(record[1]),
				name = record[2],
			}
		end
	end
end

local function resolveItemId(name)
	local wanted = normalize(name)
	if wanted == "" then
		return nil, "enter a fruit name"
	end
	if not ItemIds then
		return nil, "itemIds.lua could not be loaded"
	end

	local function physicalMatches(records)
		local matches = {}
		for _, record in ipairs(records or {}) do
			if record.type == "PhysicalFruit" then
				matches[#matches + 1] = record
			end
		end
		return matches
	end

	local exactMatches = physicalMatches(itemByName[wanted])
	if #exactMatches == 1 then
		return exactMatches[1].id
	elseif #exactMatches > 1 then
		return nil, "multiple tradable physical fruits share this name; use an ItemId"
	end

	local matches = {}
	for normalizedName, records in pairs(itemByName) do
		if normalizedName:find(wanted, 1, true) then
			for _, record in ipairs(physicalMatches(records)) do
				matches[#matches + 1] = record
			end
		end
	end
	if #matches == 1 then
		return matches[1].id
	elseif #matches > 1 then
		return nil, "ambiguous tradable fruit name; use the full name or ItemId"
	end
	return nil, "no tradable PhysicalFruit with that name was found"
end

local function itemRecord(itemId)
	local record = ItemIds and ItemIds[itemId]
	if not record then
		record = ItemIds and ItemIds[tonumber(itemId)]
	end
	return record
end

local function isTradablePhysicalFruit(itemId)
	local record = itemRecord(itemId)
	return type(record) == "table" and record[1] == "PhysicalFruit"
end

local function inventoryEntry(items, wantedId)
	for _, item in pairs(items or {}) do
		if tonumber(item.ItemId) == tonumber(wantedId) then
			return item
		end
	end
	return nil
end

local function readInventory()
	local ok, result = pcall(function()
		return CommF:InvokeServer("getTradeInventory")
	end)
	if not ok then
		return nil, "getTradeInventory failed: " .. tostring(result)
	end
	if type(result) ~= "table" or type(result.Items) ~= "table" then
		return nil, "getTradeInventory returned an unexpected shape"
	end
	return result.Items
end

local function getAvailablePhysicalFruits(items)
	local available = {}
	for _, item in pairs(items or {}) do
		local id = tonumber(item.ItemId)
		local record = id and ItemIds and ItemIds[id]
		local tradeType = tostring(item.Type or "")
		local isTradeableType = tradeType == "PhysicalMoveset"
			or tradeType == "SpecialPhysicalFruit"
		if id and record and record[1] == "PhysicalFruit" and isTradeableType
			and (tonumber(item.Amount) or 0) > 0 then
			available[#available + 1] = {
				id = id,
				name = tostring(record[2]),
				amount = tonumber(item.Amount) or 0,
			}
		end
	end
	table.sort(available, function(a, b)
		return a.name:lower() < b.name:lower()
	end)
	return available
end

local function inventoryAmount(items, wantedId)
	local total = 0
	for _, item in pairs(items) do
		if tonumber(item.ItemId) == tonumber(wantedId) then
			total = total + (tonumber(item.Amount) or 0)
		end
	end
	return total
end

local function offerItems(offer)
	return offer and type(offer.Items) == "table" and offer.Items or {}
end

local function countItems(items)
	local count = 0
	for _, item in pairs(items) do
		count = count + (tonumber(item.Amount) or 1)
	end
	return count
end

local function offerHasItem(items, wantedId, requiredAmount)
	local amount = 0
	for _, item in pairs(items) do
		if tonumber(item.ItemId) == tonumber(wantedId) then
			amount = amount + (tonumber(item.Amount) or 0)
		end
	end
	return amount >= requiredAmount
end

local function offerSignature(tradeState)
	if not tradeState or not tradeState.Offer then
		return ""
	end
	local chunks = {}
	for side = 1, 2 do
		for key, item in pairs(offerItems(tradeState.Offer[side])) do
			chunks[#chunks + 1] = string.format("%d:%s:%s:%s", side, tostring(key), tostring(item.Amount), tostring(item.Price))
		end
	end
	table.sort(chunks)
	return table.concat(chunks, "|") .. "|ready=" .. tostring(tradeState.State and tradeState.State.Ready)
end

local function findTable()
	local current = workspace
	for _, name in ipairs(CONFIG.TablePath) do
		current = current and current:FindFirstChild(name)
	end
	return current
end

local function tableSeats()
	local model = findTable()
	if not model then
		return nil, nil
	end
	return model:FindFirstChild("P1"), model:FindFirstChild("P2")
end

local function emptyTradeSeat()
	local p1, p2 = tableSeats()
	if p1 and not p1.Occupant then
		return p1
	end
	if p2 and not p2.Occupant then
		return p2
	end
	return p1 or p2
end

local function tweenToSeat(seat)
	if not seat then
		return false, "trade table seat was not found"
	end
	local character = LocalPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return false, "character root was not found"
	end
	local target = seat.CFrame + Vector3.new(0, 2.5, 0)
	local distance = (rootPart.Position - target.Position).Magnitude
	if distance <= 5 then
		rootPart.CFrame = target
		return true
	end
	local duration = math.clamp(distance / 100, 0.25, 8)
	local tween = game:GetService("TweenService"):Create(
		rootPart,
		TweenInfo.new(duration, Enum.EasingStyle.Linear),
		{CFrame = target}
	)
	tween:Play()
	local completed = false
	tween.Completed:Connect(function()
		completed = true
	end)
	local deadline = os.clock() + duration + 1
	while not completed and os.clock() < deadline and running do
		task.wait()
	end
	return (rootPart.Position - target.Position).Magnitude <= 8
end

local function getLocalSide(tradeState)
	if not tradeState or not tradeState.Trader then
		return nil
	end
	if tonumber(tradeState.Trader[1]) == LocalPlayer.UserId then
		return 1
	elseif tonumber(tradeState.Trader[2]) == LocalPlayer.UserId then
		return 2
	end
	return nil
end

-- -------------------------------------------------------------------------
-- GUI
-- -------------------------------------------------------------------------
local oldGui = LocalPlayer:FindFirstChild("LocalTraderGui")
if oldGui then
	oldGui:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local root = Instance.new("Frame")
root.Size = UDim2.fromOffset(430, 300)
root.Position = UDim2.new(0, 20, 0, 80)
root.BackgroundColor3 = Color3.fromRGB(24, 26, 32)
root.BorderSizePixel = 0
root.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 7)
corner.Parent = root

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 32)
titleBar.BackgroundColor3 = Color3.fromRGB(42, 46, 57)
titleBar.BorderSizePixel = 0
titleBar.Parent = root

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -45, 1, 0)
title.Position = UDim2.fromOffset(10, 0)
title.BackgroundTransparency = 1
title.Text = "Local Trader v1"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.Parent = titleBar

local minimize = Instance.new("TextButton")
minimize.Size = UDim2.fromOffset(28, 24)
minimize.Position = UDim2.new(1, -34, 0, 4)
minimize.Text = "-"
minimize.TextColor3 = Color3.fromRGB(255, 255, 255)
minimize.BackgroundColor3 = Color3.fromRGB(65, 70, 84)
minimize.BorderSizePixel = 0
minimize.Parent = titleBar

local icon = Instance.new("TextButton")
icon.Size = UDim2.fromOffset(48, 48)
icon.Position = root.Position
icon.Text = "LT"
icon.TextColor3 = Color3.fromRGB(255, 255, 255)
icon.Font = Enum.Font.GothamBold
icon.TextSize = 16
icon.BackgroundColor3 = Color3.fromRGB(42, 46, 57)
icon.Visible = false
icon.Parent = gui

local function label(text, position, size)
	local object = Instance.new("TextLabel")
	object.Size = size or UDim2.fromOffset(120, 24)
	object.Position = position
	object.BackgroundTransparency = 1
	object.Text = text
	object.TextColor3 = Color3.fromRGB(210, 215, 225)
	object.Font = Enum.Font.Gotham
	object.TextSize = 12
	object.TextXAlignment = Enum.TextXAlignment.Left
	object.Parent = root
	return object
end

local function textbox(placeholder, position)
	local object = Instance.new("TextBox")
	object.Size = UDim2.fromOffset(270, 25)
	object.Position = position
	object.PlaceholderText = placeholder
	object.Text = ""
	object.ClearTextOnFocus = false
	object.BackgroundColor3 = Color3.fromRGB(32, 35, 43)
	object.TextColor3 = Color3.fromRGB(235, 235, 235)
	object.Font = Enum.Font.Gotham
	object.TextSize = 12
	object.BorderSizePixel = 0
	object.Parent = root
	return object
end

label("Customer username", UDim2.fromOffset(12, 48))
local customerBox = textbox("exact Roblox username", UDim2.fromOffset(140, 47))
label("Requested fruit", UDim2.fromOffset(12, 82))
local fruitBox = textbox("name from itemIds.lua", UDim2.fromOffset(140, 81))
fruitBox:GetPropertyChangedSignal("Text"):Connect(function()
	fruitBox:SetAttribute("SelectedItemId", nil)
end)
local fruitDropdown = Instance.new("ScrollingFrame")
fruitDropdown.Size = UDim2.fromOffset(270, 120)
fruitDropdown.Position = UDim2.fromOffset(140, 107)
fruitDropdown.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
fruitDropdown.BorderSizePixel = 0
fruitDropdown.ScrollBarThickness = 5
fruitDropdown.Visible = false
fruitDropdown.ZIndex = 10
fruitDropdown.Parent = root

local fruitLayout = Instance.new("UIListLayout")
fruitLayout.Padding = UDim.new(0, 2)
fruitLayout.Parent = fruitDropdown

local function clearFruitDropdown()
	for _, child in ipairs(fruitDropdown:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
end

local function populateFruitDropdown(items)
	clearFruitDropdown()
	for _, entry in ipairs(getAvailablePhysicalFruits(items)) do
		local option = Instance.new("TextButton")
		option.Size = UDim2.new(1, -6, 0, 24)
		option.BackgroundColor3 = Color3.fromRGB(45, 50, 62)
		option.BorderSizePixel = 0
		option.TextColor3 = Color3.fromRGB(235, 235, 235)
		option.Font = Enum.Font.Gotham
		option.TextSize = 12
		option.TextXAlignment = Enum.TextXAlignment.Left
		option.Text = string.format("  %s  (x%d)", entry.name, entry.amount)
		option.ZIndex = 11
		option.Activated:Connect(function()
			fruitBox.Text = entry.name
			fruitBox:SetAttribute("SelectedItemId", entry.id)
			fruitDropdown.Visible = false
		end)
		option.Parent = fruitDropdown
	end
	fruitDropdown.CanvasSize = UDim2.fromOffset(0, fruitLayout.AbsoluteContentSize.Y)
	fruitDropdown.Visible = true
end

fruitBox.Activated:Connect(function()
	local inventory = readInventory()
	if type(inventory) == "table" then
		populateFruitDropdown(inventory)
	end
end)

local refreshFruits = Instance.new("TextButton")
refreshFruits.Size = UDim2.fromOffset(26, 25)
refreshFruits.Position = UDim2.fromOffset(384, 81)
refreshFruits.Text = "R"
refreshFruits.TextColor3 = Color3.fromRGB(255, 255, 255)
refreshFruits.Font = Enum.Font.GothamBold
refreshFruits.TextSize = 12
refreshFruits.BackgroundColor3 = Color3.fromRGB(56, 95, 150)
refreshFruits.BorderSizePixel = 0
refreshFruits.Activated:Connect(function()
	local inventory = readInventory()
	if type(inventory) == "table" then
		populateFruitDropdown(inventory)
	end
end)
refreshFruits.Parent = root
label("Quantity", UDim2.fromOffset(12, 116))
local quantityBox = textbox("1", UDim2.fromOffset(140, 115))
quantityBox.Text = "1"

local status = label("Status: IDLE", UDim2.fromOffset(12, 151), UDim2.new(1, -24, 0, 45))
status.TextWrapped = true
status.TextColor3 = Color3.fromRGB(150, 220, 160)

local logBox = Instance.new("TextBox")
logBox.Size = UDim2.new(1, -24, 0, 62)
logBox.Position = UDim2.fromOffset(12, 200)
logBox.BackgroundColor3 = Color3.fromRGB(15, 17, 22)
logBox.TextColor3 = Color3.fromRGB(205, 210, 220)
logBox.Font = Enum.Font.Code
logBox.TextSize = 11
logBox.TextXAlignment = Enum.TextXAlignment.Left
logBox.TextYAlignment = Enum.TextYAlignment.Top
logBox.MultiLine = true
logBox.TextEditable = false
logBox.ClearTextOnFocus = false
logBox.Text = ""
logBox.Parent = root

local logLines = {}
local function writeLog(message)
	logLines[#logLines + 1] = os.date("%H:%M:%S") .. " " .. message
	while #logLines > 5 do
		table.remove(logLines, 1)
	end
	logBox.Text = table.concat(logLines, "\n")
	status.Text = "Status: " .. state .. "\n" .. message
end

local function button(text, position, width, callback)
	local object = Instance.new("TextButton")
	object.Size = UDim2.fromOffset(width, 25)
	object.Position = position
	object.Text = text
	object.TextColor3 = Color3.fromRGB(255, 255, 255)
	object.Font = Enum.Font.Gotham
	object.TextSize = 12
	object.BackgroundColor3 = Color3.fromRGB(56, 95, 150)
	object.BorderSizePixel = 0
	object.Activated:Connect(callback)
	object.Parent = root
	return object
end

local startButton
local function stopTrader(reason)
	running = false
	state = "IDLE"
	latestTradeState = nil
	session = nil
	lastOfferSignature = nil
	disconnectAll()
	if startButton then
		startButton.Text = "Start"
	end
	writeLog(reason or "stopped")
end

local function startTrader()
	if running then
		return
	end
	local targetName = customerBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
	local requestedId = fruitBox:GetAttribute("SelectedItemId")
	local resolveError
	if not requestedId then
		requestedId, resolveError = resolveItemId(fruitBox.Text)
	end
	local quantity = math.max(1, tonumber(quantityBox.Text) or 1)
	if targetName == "" then
		writeLog("enter a customer username")
		return
	end
	if not requestedId then
		writeLog(resolveError)
		return
	end
	local inventory, inventoryError = readInventory()
	if not inventory then
		writeLog(inventoryError)
		return
	end
	local requestedEntry = inventoryEntry(inventory, requestedId)
	local requestedType = requestedEntry and tostring(requestedEntry.Type) or ""
	local inventoryTradeable = requestedType == "PhysicalMoveset"
		or requestedType == "SpecialPhysicalFruit"
	if not isTradablePhysicalFruit(requestedId) or not inventoryTradeable then
		writeLog("selected item is not a tradable PhysicalFruit")
		return
	end
	if inventoryAmount(inventory, requestedId) < quantity then
		writeLog("insufficient requested fruit in inventory")
		return
	end
	populateFruitDropdown(inventory)
	fruitDropdown.Visible = false

	running = true
	state = "WAITING_FOR_CUSTOMER"
	session = {
		customerName = targetName,
		requestedId = requestedId,
		quantity = quantity,
		inventoryBefore = inventoryAmount(inventory, requestedId),
		startedAt = os.clock(),
		addRequested = false,
	}
	startButton.Text = "Stop"
	local seat = emptyTradeSeat()
	if seat then
		state = "TRAVELING_TO_TABLE"
		local moved, moveError = tweenToSeat(seat)
		if not moved then
			stopTrader(moveError or "could not reach trade table")
			return
		end
		state = "WAITING_FOR_CUSTOMER"
	end
	writeLog(string.format("ready: %s x%d (ItemId %s)", fruitBox.Text, quantity, tostring(requestedId)))

	connect(TradeEvent.OnClientEvent, function(eventName, tradeState)
		if not running or not session then
			return
		end
		if type(tradeState) ~= "table" then
			return
		end
		latestTradeState = tradeState

		if eventName == "start" then
			local localSide = getLocalSide(tradeState)
			local otherSide = localSide == 1 and 2 or 1
			local otherId = localSide and tradeState.Trader[otherSide]
			local otherPlayer = otherId and Players:GetPlayerByUserId(otherId)
			if not otherPlayer or otherPlayer.Name:lower() ~= session.customerName:lower() then
				writeLog("wrong customer; canceling session")
				pcall(function() TradeFunction:InvokeServer("cancel") end)
				return
			end
			state = "TRADE_STARTED"
			session.localSide = localSide
			session.startedAt = os.clock()
			writeLog("trade started with " .. otherPlayer.Name)
		elseif eventName == "update_state" then
			if not session.localSide then
				session.localSide = getLocalSide(tradeState)
			end
			local localSide = session.localSide
			local otherSide = localSide == 1 and 2 or 1
			if not localSide then
				return
			end

			local localItems = offerItems(tradeState.Offer[localSide])
			local customerItems = offerItems(tradeState.Offer[otherSide])
			local localHasRequested = offerHasItem(localItems, session.requestedId, session.quantity)
			local signature = offerSignature(tradeState)

			if not localHasRequested and not session.addRequested and tradeState.State.Type == "NotReady" then
				state = "OFFERING_ORDER_ITEM"
				session.addRequested = true
				local ok, result = pcall(function()
					for _ = 1, session.quantity do
						local added = TradeFunction:InvokeServer("addItem", session.requestedId, 1)
						if added == false then
							return false
						end
					end
					return true
				end)
				if not ok then
					session.addRequested = false
					writeLog("addItem failed: " .. tostring(result))
				else
					writeLog("requested fruit add requested")
				end
			elseif localHasRequested and tradeState.State.Type == "NotReady" then
				state = "WAITING_FOR_CUSTOMER_OFFER"
				if countItems(customerItems) > 0 and signature ~= lastOfferSignature
					and os.clock() - lastAccept >= CONFIG.AcceptInterval then
					lastOfferSignature = signature
					lastAccept = os.clock()
					state = "ACCEPTING"
					local ok, result = pcall(function()
						return TradeFunction:InvokeServer("accept")
					end)
					writeLog(ok and "accept requested" or ("accept failed: " .. tostring(result)))
				end
			elseif tradeState.State.Type == "Countdown" then
				state = "COUNTDOWN"
				writeLog("countdown started; leaving table is not allowed")
			elseif tradeState.State.Type == "Processing" then
				state = "PROCESSING"
				writeLog("trade processing")
			end
		elseif eventName == "countdown_cancel" then
			state = "TRADE_STARTED"
			writeLog("countdown canceled; waiting for a stable offer")
		elseif eventName == "leave" then
			if tradeState.State and tradeState.State.Type == "Processing" then
				state = "VERIFYING_INVENTORY"
				local inventoryAfter = readInventory()
				local before = session.inventoryBefore or 0
				local after = type(inventoryAfter) == "table" and inventoryAmount(inventoryAfter, session.requestedId) or nil
				if after and after <= before - session.quantity then
					writeLog("trade completed and requested item is no longer available")
					stopTrader("completed")
				else
					writeLog("processing ended, but inventory verification failed")
					stopTrader("verification failed")
				end
			else
				state = "WAITING_FOR_CUSTOMER"
				latestTradeState = nil
				session.startedAt = os.clock()
				writeLog("customer left; waiting for the customer to sit again")
			end
		end
	end)
end

startButton = button("Start", UDim2.fromOffset(12, 270), 195, startTrader)
button("Stop", UDim2.fromOffset(220, 270), 195, function()
	stopTrader("stopped by user")
end)

RunService.Heartbeat:Connect(function()
	if not running or not session then
		return
	end
	local elapsed = os.clock() - session.startedAt
	if state == "WAITING_FOR_CUSTOMER" and elapsed > CONFIG.CustomerWaitTimeout then
		stopTrader("customer wait timed out")
	elseif state ~= "WAITING_FOR_CUSTOMER" and state ~= "IDLE"
		and state ~= "PROCESSING" and state ~= "VERIFYING_INVENTORY"
		and elapsed > CONFIG.CompletionTimeout then
		stopTrader("trade timed out")
	end
end)

local dragging = false
titleBar.InputBegan:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end
	local startPosition = input.Position
	local origin = root.Position
	local moveConnection
	moveConnection = UserInputService.InputChanged:Connect(function(change)
		if change.UserInputType == Enum.UserInputType.MouseMovement then
			root.Position = UDim2.new(0, origin.X.Offset + change.Position.X - startPosition.X, 0, origin.Y.Offset + change.Position.Y - startPosition.Y)
		end
	end)
	local endConnection
	endConnection = UserInputService.InputEnded:Connect(function(change)
		if change.UserInputType == Enum.UserInputType.MouseButton1 then
			moveConnection:Disconnect()
			endConnection:Disconnect()
		end
	end)
end)

minimize.Activated:Connect(function()
	icon.Position = root.Position
	root.Visible = false
	icon.Visible = true
end)
icon.Activated:Connect(function()
	root.Position = icon.Position
	root.Visible = true
	icon.Visible = false
end)

gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
writeLog("enter customer username and fruit name")
