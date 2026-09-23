-- Blox Fruits Version 1 local trader.
-- Requires an executor with readfile/loadstring or a runtime ItemIds table.
-- No namecall hooks are used. Trade calls are made directly through the game's remotes.

warn("LocalTrader: script execution started")

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

local function startupNotice(message, isError)
	local playerGui = LocalPlayer and (LocalPlayer:FindFirstChildOfClass("PlayerGui")
		or LocalPlayer:WaitForChild("PlayerGui", 10))
	if not playerGui then
		warn("LocalTrader: " .. message)
		return
	end
	local existing = playerGui:FindFirstChild("LocalTraderStartupNotice")
	if existing then
		existing:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "LocalTraderStartupNotice"
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(520, 70)
	label.Position = UDim2.fromOffset(20, 20)
	label.BackgroundColor3 = isError and Color3.fromRGB(100, 35, 35) or Color3.fromRGB(35, 70, 105)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextWrapped = true
	label.TextSize = 14
	label.Font = Enum.Font.Gotham
	label.Text = message
	label.Parent = gui
	warn("LocalTrader: " .. message)
	return gui
end

local CONFIG = {
	TablePath = {"Map", "Dressrosa", "TradeTable"},
	ItemIdsUrl = "https://raw.githubusercontent.com/korent-cmd/decrypted_fluent/refs/heads/main/itemIds.lua",
	QuantumOnyxUrl = "https://raw.githubusercontent.com/flazhy/QuantumOnyx/refs/heads/main/QuantumOnyx.lua",
	TradingJobId = "",
	HandoffFile = "LocalTrader_V3_Handoff.json",
	HubConfigFile = "LocalTrader_Hub.json",
	HubPollInterval = 3,
	OrderFile = "/sdcard/LocalTrader_Order.json",
	OrderCustomerName = "",
	OrderFruitName = "",
	OrderQuantity = 1,
	TeleportMaxAttempts = 5,
	TeleportRetryDelays = {0, 5, 15, 30, 60},
	FarmLoadMaxAttempts = 3,
	FarmLoadRetryDelays = {0, 10, 30},
	AcceptInterval = 1.5,
	CustomerWaitTimeout = 180,
	TradeStartTimeout = 30,
	CompletionTimeout = 45,
	HubReportMaxAttempts = 5,
	HubReportRetryDelays = {5, 10, 20, 30, 30},
	InventoryRefreshInterval = 2,
	MaxLogLines = 200,
	RetweenInterval = 4,
}

local function readHandoff()
	if type(readfile) ~= "function" or type(HttpService.JSONDecode) ~= "function" then
		return nil, "executor file persistence is unavailable"
	end
	if type(isfile) == "function" and not isfile(CONFIG.HandoffFile) then
		return nil, "handoff file does not exist"
	end
	local ok, contents = pcall(readfile, CONFIG.HandoffFile)
	if not ok or type(contents) ~= "string" or contents == "" then
		return nil, "handoff file could not be read"
	end
	local decodedOk, record = pcall(function()
		return HttpService:JSONDecode(contents)
	end)
	if not decodedOk or type(record) ~= "table" then
		return nil, "handoff file contains invalid JSON"
	end
	return record
end

local function writeHandoff(record)
	if type(writefile) ~= "function" then
		return false, "executor writefile is unavailable"
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(record)
	end)
	if not ok then
		return false, "handoff state could not be encoded"
	end
	local writeOk, writeError = pcall(writefile, CONFIG.HandoffFile, encoded)
	if not writeOk then
		return false, tostring(writeError)
	end
	return true
end

local HubConfig = {
	url = "",
	token = "",
	poll = 3,
}

local function loadHubConfig()
	if type(readfile) ~= "function" then
		return false, "executor readfile is unavailable"
	end
	local ok, contents = pcall(readfile, CONFIG.HubConfigFile)
	if not ok or type(contents) ~= "string" or contents == "" then
		return false, "Hub config file was not found in the executor Workspace"
	end
	local decodedOk, data = pcall(function()
		return HttpService:JSONDecode(contents)
	end)
	if not decodedOk or type(data) ~= "table" then
		return false, "Hub config file contains invalid JSON"
	end
	HubConfig.url = tostring(data.hub_url or data.url or ""):gsub("/$", "")
	HubConfig.token = tostring(data.hub_token or data.token or "")
	HubConfig.poll = math.max(1, tonumber(data.hub_poll_sec or data.poll_sec) or 3)
	HubConfig.mode = tostring(data.mode or "FARMING"):upper()
	HubConfig.accountId = tostring(data.account_id or "")
	return HubConfig.url ~= "" and HubConfig.token ~= "",
		(HubConfig.url ~= "" and HubConfig.token ~= "") and nil or "Hub URL/token missing from Workspace config"
end

local function hubRequest(method, path, body)
	if HubConfig.url == "" or HubConfig.token == "" then
		return nil, "Hub is not configured"
	end
	local url = HubConfig.url .. path
	local headers = {
		["Accept"] = "application/json",
		["Authorization"] = "Bearer " .. HubConfig.token,
	}
	local payload = body and HttpService:JSONEncode(body) or nil

	local env = (type(getgenv) == "function" and getgenv()) or _G
	local requestFn = env.request or env.http_request
	if type(requestFn) ~= "function" then
		local syn = env.syn or rawget(_G, "syn")
		if type(syn) == "table" and type(syn.request) == "function" then
			requestFn = syn.request
		end
	end
	if type(requestFn) == "function" then
		local ok, response = pcall(requestFn, {
			Url = url,
			Method = method,
			Headers = headers,
			Body = payload,
		})
		if not ok then
			return nil, tostring(response)
		end
		local statusCode = tonumber(response and (response.StatusCode or response.status_code)) or 0
		local raw = response and (response.Body or response.body) or ""
		if statusCode ~= 0 and (statusCode < 200 or statusCode >= 300) then
			return nil, "HTTP " .. tostring(statusCode) .. ": " .. tostring(raw):sub(1, 250)
		end
		local decodedOk, decoded = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if not decodedOk then
			return nil, "Hub returned invalid JSON"
		end
		return decoded
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = method,
			Headers = headers,
			Body = payload,
		})
	end)
	if not ok then
		return nil, tostring(response)
	end
	if not response.Success then
		return nil, "HTTP " .. tostring(response.StatusCode) .. ": " .. tostring(response.StatusMessage)
	end
	local decodedOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body or "")
	end)
	if not decodedOk then
		return nil, "Hub returned invalid JSON"
	end
	return decoded
end

local function readExternalOrder()
	local configured, configError = loadHubConfig()
	if not configured then
		warn("LocalTrader: " .. tostring(configError))
		return nil
	end
	if HubConfig.mode ~= "TRADING" then
		return nil
	end

	local ok, contents = pcall(readfile, CONFIG.HubConfigFile)
	if not ok or type(contents) ~= "string" or contents == "" then
		warn("LocalTrader: Workspace Hub config disappeared while reading order")
		return nil
	end
	local decodedOk, data = pcall(function()
		return HttpService:JSONDecode(contents)
	end)
	if not decodedOk or type(data) ~= "table" then
		warn("LocalTrader: Workspace Hub config contains invalid JSON")
		return nil
	end

	local requestId = tostring(data.request_id or "")
	local customer = tostring(data.customer or "")
	local item = tostring(data.item or "")
	local quantity = math.max(1, tonumber(data.quantity) or 1)
	local requestStatus = tostring(data.request_status or "ASSIGNED")
	local accountId = tostring(data.account_id or HubConfig.accountId or "")

	if requestId == "" or customer == "" or item == "" then
		warn(
			"LocalTrader: TRADING mode but order fields are incomplete"
			.. " request=" .. requestId
			.. " customer=" .. customer
			.. " item=" .. item
			.. " quantity=" .. tostring(quantity)
		)
		return nil
	end

	warn(
		"LocalTrader: local order received request=" .. requestId
		.. " customer=" .. customer
		.. " item=" .. item
		.. " quantity=" .. tostring(quantity)
	)

	return {
		version = 5,
		phase = "TRADING_ROUTE",
		status = requestStatus,
		order_id = requestId,
		request_id = requestId,
		customer = customer,
		item = item,
		quantity = quantity,
		account_id = accountId,
	}
end

local function writeExternalOrder(order, phase, status)
	if status ~= "COMPLETED" then
		return true
	end
	if type(order) ~= "table" then
		return false
	end
	local configured = loadHubConfig()
	if not configured then
		return false
	end
	local extra = {
		request_id = tostring(order.request_id or order.order_id or ""),
		customer = tostring(order.customer or ""),
		item = tostring(order.item or ""),
		quantity = tonumber(order.quantity) or 1,
	}
	local data, err = hubRequest("POST", "/api/v1/event", {
		account_id = tostring(order.account_id or ""),
		status = "completed",
		event = "trade_completed",
		extra = extra,
	})
	if not data then
		warn("LocalTrader: failed to report trade completion: " .. tostring(err))
		return false
	end
	warn("LocalTrader: trade completion reported to Hub")
	return data.ok ~= false
end

local function currentServerIsTrading()
	return CONFIG.TradingJobId ~= "" and game.JobId == CONFIG.TradingJobId
end

local teleportInFlight = false
local teleportMode = nil
local teleportAttempt = 0

local function teleportErrorText(result)
	return tostring(result or "unknown teleport error")
end

local function teleportReachedDestination(mode, record)
	if mode == "TRADING" then
		return currentServerIsTrading()
	end
	return type(record) == "table"
		and game.JobId ~= CONFIG.TradingJobId
		and game.JobId ~= record.previousJobId
end

local function retryTeleport(mode, record)
	if teleportInFlight then
		return
	end
	if teleportAttempt >= CONFIG.TeleportMaxAttempts then
		warn("LocalTrader Version 3: " .. mode .. " teleport retry limit reached")
		return
	end
	teleportAttempt = teleportAttempt + 1
	local attempt = teleportAttempt
	local delaySeconds = CONFIG.TeleportRetryDelays[attempt] or 60
	task.delay(delaySeconds, function()
		if type(record) == "table" then
			local latest = readHandoff()
			if type(latest) ~= "table" or latest.phase ~= record.phase or latest.orderId ~= record.orderId then
				return
			end
		end
		local ok, result = pcall(function()
			if mode == "TRADING" then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, CONFIG.TradingJobId, LocalPlayer)
			else
				TeleportService:Teleport(game.PlaceId)
			end
		end)
		if ok then
			teleportInFlight = true
			warn(string.format("LocalTrader Version 3: %s teleport requested (attempt %d)", mode, attempt))
			task.delay(15, function()
				if teleportInFlight and not teleportReachedDestination(mode, record) then
					teleportInFlight = false
					warn("LocalTrader Version 3: teleport did not complete; retrying")
					task.spawn(retryTeleport, mode, record)
				end
			end)
		else
			teleportInFlight = false
			warn("LocalTrader Version 3: " .. mode .. " teleport failed: " .. teleportErrorText(result))
			task.spawn(retryTeleport, mode, record)
		end
	end)
end

local function beginTeleport(mode, record)
	if teleportInFlight then
		return true
	end
	teleportMode = mode
	teleportAttempt = 0
	teleportInFlight = false
	retryTeleport(mode, record)
	return true
end

TeleportService.TeleportInitFailed:Connect(function(player, result)
	if player ~= LocalPlayer or not teleportMode then
		return
	end
	teleportInFlight = false
	warn("LocalTrader Version 3: " .. teleportMode .. " teleport init failed: " .. teleportErrorText(result))
	local record = readHandoff()
	if type(record) == "table" then
		task.spawn(retryTeleport, teleportMode, record)
	else
		task.spawn(retryTeleport, teleportMode)
	end
end)

local function createConfiguredOrder()
	local customerName = tostring(CONFIG.OrderCustomerName or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local fruitName = tostring(CONFIG.OrderFruitName or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local quantity = math.max(1, tonumber(CONFIG.OrderQuantity) or 1)
	if customerName == "" or fruitName == "" then
		return nil
	end
	return {
		version = 3,
		phase = "ORDER_PENDING",
		orderId = HttpService:GenerateGUID(false),
		customerName = customerName,
		requestedFruitName = fruitName,
		quantity = quantity,
		tradingJobId = CONFIG.TradingJobId,
		createdAt = os.time(),
	}
end

local function ensureConfiguredOrder()
	local existing = readHandoff()
	if type(existing) == "table"
		and (existing.phase == "ORDER_PENDING" or existing.phase == "FARMING" or existing.phase == "TRADING") then
		return existing
	end
	local configured = createConfiguredOrder()
	if not configured then
		return nil
	end
	local saved, saveError = writeHandoff(configured)
	if not saved then
		warn("LocalTrader Version 3: could not save configured order: " .. tostring(saveError))
		return nil
	end
	return configured
end

local function loadQuantumOnyx()
	local record = readHandoff()
	if type(record) ~= "table" or record.phase ~= "FARMING" then
		warn("LocalTrader Version 3: no FARMING handoff is pending")
		return
	end
	if record.loadJobId == game.JobId and record.farmStatus == "LOAD_EXECUTED" then
		warn("LocalTrader Version 3: QuantumOnyx already executed for this JobId")
		return
	end

	local attempt = (record.loadJobId == game.JobId and tonumber(record.loadAttempt)) or 0
	if attempt >= CONFIG.FarmLoadMaxAttempts then
		warn("LocalTrader Version 3: QuantumOnyx retry limit reached for this JobId")
		return
	end
	attempt = attempt + 1
	local delaySeconds = CONFIG.FarmLoadRetryDelays[attempt] or 30
	task.delay(delaySeconds, function()
		local latest = readHandoff()
		if type(latest) ~= "table" or latest.phase ~= "FARMING" then
			return
		end
		latest.loadJobId = game.JobId
		latest.loadAttempt = attempt
		latest.lastLoadAttemptAt = os.time()
		writeHandoff(latest)

		local ok, result = pcall(function()
			local source = game:HttpGet(CONFIG.QuantumOnyxUrl)
			local chunk = loadstring(source)
			assert(type(chunk) == "function", "QuantumOnyx did not compile")
			return chunk()
		end)
		if ok then
			latest.phase = "FARMING"
			latest.farmStatus = "LOAD_EXECUTED"
			latest.farmLoadedAt = os.time()
			writeHandoff(latest)
			warn("LocalTrader Version 3: QuantumOnyx load executed; farming status is assumed active")
		elseif attempt < CONFIG.FarmLoadMaxAttempts then
			warn("LocalTrader Version 3: QuantumOnyx load failed; retrying: " .. tostring(result))
			task.spawn(loadQuantumOnyx)
		else
			latest.farmStatus = "LOAD_FAILED"
			latest.lastError = tostring(result)
			writeHandoff(latest)
			warn("LocalTrader Version 3: QuantumOnyx load failed after retries: " .. tostring(result))
		end
	end)
end

local function handoffToFarming(sessionData)
	if sessionData and sessionData.externalOrder then
		warn("LocalTrader: Hub completion acknowledged; watchdog will relaunch farming")
		return true
	end
	local record = {
		version = 3,
		phase = "FARMING",
		farmStatus = "PENDING",
		orderId = sessionData.orderId or sessionData.order_id or HttpService:GenerateGUID(false),
		tradingJobId = CONFIG.TradingJobId,
		previousJobId = game.JobId,
		customerName = sessionData.customerName,
		requestedId = sessionData.requestedId,
		quantity = sessionData.quantity,
		tradeSessionId = sessionData.id,
		createdAt = os.time(),
		loadJobId = nil,
		loadAttempt = 0,
	}
	local saved, saveError = writeHandoff(record)
	if not saved then
		return false, "could not persist farming handoff: " .. tostring(saveError)
	end
	beginTeleport("FARMING", record)
	return true
end

local function reportStartupConfiguration()
	local configured, configError = loadHubConfig()
	if not configured then
		startupNotice("Hub connection is not available. " .. tostring(configError), true)
		return false
	end
	startupNotice("Hub connection loaded from this clone's Workspace (mode: " .. HubConfig.mode .. ").", false)
	return true
end

if not reportStartupConfiguration() then
	return
end

local startupOrder = readExternalOrder()
if startupOrder then
	startupNotice(
		"Hub order loaded: " .. tostring(startupOrder.item)
		.. " x" .. tostring(startupOrder.quantity)
		.. " -> " .. tostring(startupOrder.customer),
		false
	)
else
	warn("LocalTrader: no active Hub order at startup")
end

local startupNoticeGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	and LocalPlayer.PlayerGui:FindFirstChild("LocalTraderStartupNotice")
if startupNoticeGui then
	startupNoticeGui:Destroy()
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
assert(Remotes, "ReplicatedStorage.Remotes was not found")

local TradeEvent = Remotes:WaitForChild("TradeEvent", 15)
local TradeFunction = Remotes:WaitForChild("TradeFunction", 15)
local CommF = Remotes:WaitForChild("CommF_", 15)
assert(TradeEvent and TradeFunction and CommF, "Trade remotes were not found")

local state = "IDLE"
local running = false
local session = nil
local latestTradeState = nil
local lastAccept = 0
local lastOfferSignature = nil
local lastLoggedOfferSignature = nil
local connections = {}
local logLines = {}
local sessionSequence = 0

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

local function offerSummary(items)
	local parts = {}
	for _, item in pairs(items or {}) do
		parts[#parts + 1] = string.format("%s x%s [%s]", tostring(item.ItemId), tostring(item.Amount), tostring(item.Type))
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "empty"
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

local function isSeatedAtTradeTable()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or not humanoid.Sit then
		return false
	end
	local p1, p2 = tableSeats()
	return (p1 and p1.Occupant == humanoid) or (p2 and p2.Occupant == humanoid) or false
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

local function jumpOutOfTrade()
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not rootPart then
		return false
	end
	pcall(function()
		local seat = humanoid.SeatPart
		local escapeCFrame
		if seat then
			escapeCFrame = seat.CFrame * CFrame.new(0, 3, 10)
		else
			local p1, p2 = tableSeats()
			local tablePart = p1 or p2
			if tablePart then
				escapeCFrame = tablePart.CFrame * CFrame.new(0, 3, 10)
			end
		end
		humanoid.Jump = true
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		local releaseDeadline = os.clock() + 1
		while humanoid.SeatPart and os.clock() < releaseDeadline do
			task.wait()
		end
		if humanoid.SeatPart then
			humanoid.Sit = false
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			task.wait()
		end
		if escapeCFrame then
			local distance = (rootPart.Position - escapeCFrame.Position).Magnitude
			local tween = game:GetService("TweenService"):Create(
				rootPart,
				TweenInfo.new(math.clamp(distance / 35, 0.25, 1), Enum.EasingStyle.Linear),
				{CFrame = escapeCFrame}
			)
			tween:Play()
			tween.Completed:Wait()
		end
	end)
	return true
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

local oldGui = LocalPlayer:FindFirstChild("LocalTraderGui")
if oldGui then
	oldGui:Destroy()
end

local gui = Instance.new("ScreenGui")
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local root = Instance.new("Frame")
root.Size = UDim2.fromOffset(430, 370)
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

fruitBox.Focused:Connect(function()
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

local function writeLog(message)
	logLines[#logLines + 1] = os.date("%H:%M:%S") .. " " .. message
	while #logLines > CONFIG.MaxLogLines do
		table.remove(logLines, 1)
	end
	logBox.Text = table.concat(logLines, "\n")
	status.Text = "Status: " .. state .. "\n" .. message
end

local function setState(nextState, message)
	local previous = state
	state = nextState
	if session then
		session.stageStartedAt = os.clock()
	end
	if previous ~= nextState or message then
		writeLog(string.format("state %s -> %s%s", previous, nextState, message and (": " .. message) or ""))
	end
end

local function copyLog()
	local text = table.concat(logLines, "\n")
	if text == "" then
		writeLog("log is empty")
		return
	end
	local copied = false
	if type(setclipboard) == "function" then
		copied = pcall(setclipboard, text)
	end
	if not copied and type(clipboard) == "table" and type(clipboard.set) == "function" then
		copied = pcall(clipboard.set, text)
	end
	writeLog(copied and "copied full log" or "clipboard API unavailable")
end

local function button(text, position, width, callback, color)
	local object = Instance.new("TextButton")
	object.Size = UDim2.fromOffset(width, 25)
	object.Position = position
	object.Text = text
	object.TextColor3 = Color3.fromRGB(255, 255, 255)
	object.Font = Enum.Font.Gotham
	object.TextSize = 12
	object.BackgroundColor3 = color or Color3.fromRGB(56, 95, 150)
	object.BorderSizePixel = 0
	object.Activated:Connect(callback)
	object.Parent = root
	return object
end

local startButton
local function stopTrader(reason)
	local stoppedSessionId = session and session.id
	local stoppedOrderId = session and session.orderId
	local completed = session and session.completed
	running = false
	state = "IDLE"
	latestTradeState = nil
	session = nil
	lastOfferSignature = nil
	lastLoggedOfferSignature = nil
	disconnectAll()
	if startButton then
		startButton.Text = "Start"
	end
	if stoppedOrderId and not completed then
		local order = readHandoff()
		if type(order) == "table" and order.orderId == stoppedOrderId and order.phase == "TRADING" then
			order.phase = "ORDER_PENDING"
			order.lastFailure = reason or "trader stopped"
			order.lastFailureAt = os.time()
			writeHandoff(order)
		end
	end
	writeLog(string.format("%s%s", reason or "stopped", stoppedSessionId and (" [session " .. tostring(stoppedSessionId) .. "]") or ""))
end

-- Reports a completed trade to the Hub with a bounded number of retries.
-- IMPORTANT: this always finishes by handing off to farming, even if every
-- retry fails. The in-game trade has already happened at this point (items
-- already exchanged) - the account must not get stuck waiting on a single
-- network call. A failed report just means the Hub won't have a completion
-- record for this specific trade; it does not mean the trade didn't happen.
local function reportCompletionWithRetry(sess)
	task.spawn(function()
		local attempt = 0
		local reported = false
		while attempt < CONFIG.HubReportMaxAttempts do
			attempt = attempt + 1
			reported = writeExternalOrder(sess.externalOrder, "FARMING", "COMPLETED")
			if reported then
				break
			end
			if attempt < CONFIG.HubReportMaxAttempts then
				local delaySeconds = CONFIG.HubReportRetryDelays[attempt] or 30
				writeLog(string.format(
					"Hub completion report failed (attempt %d/%d); retrying in %ds",
					attempt, CONFIG.HubReportMaxAttempts, delaySeconds
				))
				task.wait(delaySeconds)
			end
		end

		if reported then
			writeLog("Hub completion report succeeded (attempt " .. attempt .. ")")
		else
			writeLog(
				"Hub completion report failed after " .. CONFIG.HubReportMaxAttempts
				.. " attempts; proceeding with farming handoff anyway so this "
				.. "account doesn't get stuck. The Hub will not have a "
				.. "completion record for this specific trade."
			)
		end

		local handedOff, handoffError = handoffToFarming(sess)
		if handedOff then
			writeLog("trade verified; joining a farming server")
			stopTrader("completed; farming handoff started")
		else
			writeLog(handoffError)
			stopTrader("completed, but farming handoff failed")
		end
	end)
end

local function startTrader(orderData)
	if running then
		return
	end
	if type(orderData) == "table" then
		customerBox.Text = tostring(orderData.customerName or orderData.customer or "")
		fruitBox.Text = tostring(orderData.requestedFruitName or orderData.fruitName or orderData.item or "")
		fruitBox:SetAttribute("SelectedItemId", orderData.requestedId)
		quantityBox.Text = tostring(math.max(1, tonumber(orderData.quantity) or 1))
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
	sessionSequence = sessionSequence + 1
	state = "WAITING_FOR_CUSTOMER"
	session = {
		id = sessionSequence,
		orderId = type(orderData) == "table" and (orderData.orderId or orderData.order_id) or nil,
		customerName = targetName,
		requestedId = requestedId,
		quantity = quantity,
		inventoryBefore = inventoryAmount(inventory, requestedId),
		startedAt = os.clock(),
		stageStartedAt = os.clock(),
		addRequested = false,
		lastRetween = 0,
		externalOrder = type(orderData) == "table" and orderData or nil,
	}
	if type(orderData) == "table" then
		orderData.phase = "TRADING"
		orderData.startedAt = os.time()
		orderData.tradingJobId = CONFIG.TradingJobId
		orderData.requestedId = requestedId
		orderData.requestedFruitName = fruitBox.Text
		if orderData.order_id or orderData.orderId then
			writeExternalOrder(orderData, "TRADING", "IN_PROGRESS")
		end
		local saved, saveError = writeHandoff(orderData)
		if not saved then
			writeLog("could not persist active order: " .. tostring(saveError))
			running = false
			session = nil
			return
		end
	end
	startButton.Text = "Stop"
	local seat = emptyTradeSeat()
	if seat then
		setState("TRAVELING_TO_TABLE")
		local moved, moveError = tweenToSeat(seat)
		if not moved then
			stopTrader(moveError or "could not reach trade table")
			return
		end
		session.lastRetween = os.clock()
		setState("WAITING_FOR_CUSTOMER")
	end
	writeLog(string.format("ready: %s x%d (ItemId %s, catalog=%s, inventory=%s)",
		fruitBox.Text, quantity, tostring(requestedId), tostring(itemRecord(requestedId) and itemRecord(requestedId)[1]), tostring(requestedType)))
	if isSeatedAtTradeTable() then
		writeLog("session " .. tostring(session.id) .. " started; worker seated")
	else
		writeLog("session " .. tostring(session.id) .. " started; worker reached table and is waiting to sit")
	end

	connect(TradeEvent.OnClientEvent, function(eventName, tradeState)
		if not running or not session then
			return
		end
		if type(tradeState) ~= "table" then
			return
		end
		if session.ignoreTrade then
			if eventName == "leave" then
				session.ignoreTrade = false
				session.localSide = nil
				session.addRequested = false
				lastOfferSignature = nil
				lastLoggedOfferSignature = nil
				latestTradeState = nil
				setState("WAITING_FOR_CUSTOMER", "unwanted trade ended")
				session.startedAt = os.clock()
				writeLog("unwanted trade ended; continuing to wait for the assigned customer")
			end
			return
		end
		latestTradeState = tradeState

		if eventName == "start" then
			local localSide = getLocalSide(tradeState)
			local otherSide = localSide == 1 and 2 or 1
			local otherId = localSide and tradeState.Trader[otherSide]
			local otherPlayer = otherId and Players:GetPlayerByUserId(otherId)
			if not otherPlayer or otherPlayer.Name:lower() ~= session.customerName:lower() then
				session.ignoreTrade = true
				setState("WAITING_FOR_CUSTOMER", "wrong customer; jumping out")
				latestTradeState = nil
				session.startedAt = os.clock()
				writeLog("wrong customer; jumping out and continuing to wait")
				jumpOutOfTrade()
				return
			end
			setState("TRADE_STARTED")
			session.localSide = localSide
			session.startedAt = os.clock()
			writeLog(string.format("trade started with %s (UserId %s, localSide=%d)", otherPlayer.Name, tostring(otherId), localSide))
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
			if signature ~= lastLoggedOfferSignature then
				lastLoggedOfferSignature = signature
				writeLog(string.format("offers: worker={%s}; customer={%s}; ready=%s/%s; state=%s",
					offerSummary(localItems), offerSummary(customerItems),
					tostring(tradeState.State.Ready[localSide]), tostring(tradeState.State.Ready[otherSide]),
					tostring(tradeState.State.Type)))
			end

			if not localHasRequested and not session.addRequested and tradeState.State.Type == "NotReady" then
				setState("OFFERING_ORDER_ITEM")
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
				setState("WAITING_FOR_CUSTOMER_OFFER")
				if countItems(customerItems) > 0
					and tradeState.State.Ready[localSide] ~= true
					and os.clock() - lastAccept >= CONFIG.AcceptInterval then
					lastOfferSignature = signature
					lastAccept = os.clock()
					setState("ACCEPTING")
					local ok, result = pcall(function()
						return TradeFunction:InvokeServer("accept")
					end)
					writeLog(ok and "accept requested" or ("accept failed: " .. tostring(result)))
				end
			elseif tradeState.State.Type == "Countdown" then
				setState("COUNTDOWN")
				writeLog("countdown started; leaving table is not allowed")
			elseif tradeState.State.Type == "Processing" then
				setState("PROCESSING")
				writeLog("trade processing")
			end
		elseif eventName == "countdown_cancel" then
			setState("TRADE_STARTED")
			writeLog("countdown canceled; waiting for a stable offer")
		elseif eventName == "leave" then
			if tradeState.State and tradeState.State.Type == "Processing" then
				setState("VERIFYING_INVENTORY")
				local inventoryAfter = readInventory()
				local before = session.inventoryBefore or 0
				local after = type(inventoryAfter) == "table" and inventoryAmount(inventoryAfter, session.requestedId) or nil
				if after and after <= before - session.quantity then
					writeLog("trade completed and requested item is no longer available")
					setState("COOLDOWN", "trade verified; preparing farming handoff")
					session.completed = true
					if session.externalOrder then
						setState("VERIFYING_INVENTORY", "reporting completion to Hub")
						reportCompletionWithRetry(session)
						return
					end
					local handedOff, handoffError = handoffToFarming(session)
					if handedOff then
						writeLog("trade verified; joining a farming server")
						stopTrader("completed; farming handoff started")
					else
						writeLog(handoffError)
						stopTrader("completed, but farming handoff failed")
					end
				else
					writeLog("processing ended, but inventory verification failed")
					stopTrader("verification failed")
				end
			else
				setState("WAITING_FOR_CUSTOMER", "customer left")
				latestTradeState = nil
				session.startedAt = os.clock()
				session.addRequested = false
				session.localSide = nil
				lastOfferSignature = nil
				lastLoggedOfferSignature = nil
				writeLog("customer left; waiting for the customer to sit again")
			end
		end
	end)
end

local function retryTrader()
	if running then
		stopTrader("retry requested")
		task.wait(0.2)
	end
	startTrader()
end

startButton = button("Start", UDim2.fromOffset(12, 270), 195, startTrader)
button("Stop", UDim2.fromOffset(220, 270), 195, function()
	stopTrader("stopped by user")
end)
button("Retry", UDim2.fromOffset(12, 300), 128, retryTrader, Color3.fromRGB(120, 95, 50))
button("Copy Log", UDim2.fromOffset(149, 300), 128, copyLog, Color3.fromRGB(65, 105, 145))
button("Clear Log", UDim2.fromOffset(286, 300), 129, function()
	logLines = {}
	logBox.Text = ""
	writeLog("log cleared")
end, Color3.fromRGB(90, 65, 90))

local function retweenToTableIfNeeded()
	if not running or not session or session.ignoreTrade or state ~= "WAITING_FOR_CUSTOMER" then
		return
	end
	if os.clock() - session.lastRetween < CONFIG.RetweenInterval then
		return
	end
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Sit then
		return
	end
	local p1, p2 = tableSeats()
	local targetSeat = (p1 and not p1.Occupant and p1) or (p2 and not p2.Occupant and p2)
	if not targetSeat then
		return
	end
	session.lastRetween = os.clock()
	setState("TRAVELING_TO_TABLE")
	local moved, errorMessage = tweenToSeat(targetSeat)
	if moved then
		setState("WAITING_FOR_CUSTOMER", "re-tween complete")
		writeLog("re-tweened to trade table")
	else
		setState("WAITING_FOR_CUSTOMER", "re-tween failed")
		writeLog("re-tween failed: " .. tostring(errorMessage))
	end
end

RunService.Heartbeat:Connect(function()
	if not running or not session then
		return
	end
	retweenToTableIfNeeded()
	local elapsed = os.clock() - (session.stageStartedAt or session.startedAt)
	if state == "WAITING_FOR_CUSTOMER" and elapsed > CONFIG.CustomerWaitTimeout then
		setState("TIMEOUT")
		stopTrader("customer arrival timeout")
	elseif state == "TRADE_STARTED" and elapsed > CONFIG.TradeStartTimeout then
		setState("TIMEOUT")
		stopTrader("trade offer timeout")
	elseif state ~= "WAITING_FOR_CUSTOMER" and state ~= "IDLE"
		and state ~= "PROCESSING" and state ~= "VERIFYING_INVENTORY"
		and state ~= "TIMEOUT" and elapsed > CONFIG.CompletionTimeout then
		setState("TIMEOUT")
		stopTrader("stage timeout: " .. state)
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
local pendingTradingOrder = startupOrder
if pendingTradingOrder then
	writeLog("Hub order found; starting automatically")
	task.defer(startTrader, pendingTradingOrder)
else
	writeLog("waiting for Hub order; manual Start remains available")
end

task.spawn(function()
	while true do
		task.wait(HubConfig.poll or CONFIG.HubPollInterval)
		if not running then
			local order = readExternalOrder()
			if order then
				writeLog("Hub order received; starting automatically")
				task.defer(startTrader, order)
			end
		end
	end
end)
