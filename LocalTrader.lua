-- Blox Fruits Version 1 local trader.
-- Requires an executor with readfile/loadstring or a runtime ItemIds table.
-- No namecall hooks are used. Trade calls are made directly through the game's remotes.
--
-- v1.9: forwards every game Notify (while TRADING) plus TradeEvent names, accept results and
--		addItem failures to the Hub (POST /api/v1/trade-notice) so the real trade-limit rule
--		can be worked out. No hooks. Logging only, no behaviour change.
-- v1.8: a trade can carry at most 4 items per side (the game's own trade-state rules), so an
--        order for more than CONFIG.MaxItemsPerTrade is refused up front and reported to the Hub
--        as worker_error instead of looping forever. Also logs any "Notify" message from the game
--        that mentions "trade" (the trade counter may be shown that way) into the trade log.
-- v1.7: DIAGNOSTICS ONLY (no behaviour change): to learn where the game keeps its "x/5 trades"
--        counter, the trade log now also records (a) any extra fields getTradeInventory returns
--        besides Items, (b) every field of the TradeEvent state when a trade starts, and (c) any
--        on-screen text that looks like "n/5" or sits inside a trade-related GUI. Use Copy Log
--        after a trade and send it back.
-- v1.6: the in-game signal to the Hub (game-ping + inventory report) is only sent while the
--        player is actually in the game: game loaded and a living character with a
--        HumanoidRootPart in the workspace. The ping also carries the Roblox username, which the
--        Hub dashboard shows as the account's name.
-- v1.5: addItem failures are no longer silent. If TradeFunction:InvokeServer("addItem")
--        returns false (or errors), the worker retries up to CONFIG.AddItemMaxAttempts times
--        (CONFIG.AddItemRetryDelay apart), only adding the quantity still missing from the
--        offer, then stops the order with reason "worker_error" instead of idling until the
--        generic stage timeout. The raw value the server returned is now logged.
-- v1.1: daily trash-fruit flush built in (see CONFIG.TrashFlush below).
-- v1.2: tweenToSeat is now lag-tolerant (long deadline, 3 retries, reports distance).
-- v1.4: QuantumOnyx start guard no longer trusts a handoff record written by an EARLIER client
--        process (same JobId after a relaunch used to make it skip the farm script); adds an
--        in-process duplicate guard and logs what was fetched/returned.
-- v1.3: travel gets its own time budget (CONFIG.TravelTimeout) and is exempt from the
--        generic 45s stage timeout; every travel attempt is logged.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- ============================================================================
-- PERSISTENT DEBUG LOG
-- Mirrors every debugLog() call onto an on-screen panel too, since executor
-- console output may not always be visible.
-- ============================================================================
local debugLogBox
local debugLines = {}
local DEBUG_MAX_LINES = 120

local function createDebugGui()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return false
	end

	local old = playerGui:FindFirstChild("LocalTraderDebugGui")
	if old then
		old:Destroy()
	end

	local debugGui = Instance.new("ScreenGui")
	debugGui.Name = "LocalTraderDebugGui"
	debugGui.ResetOnSpawn = false
	debugGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local frame = Instance.new("Frame")
	frame.Name = "DebugFrame"
	frame.Size = UDim2.fromOffset(520, 190)
	frame.Position = UDim2.new(1, -540, 0, 20)
	frame.BackgroundColor3 = Color3.fromRGB(15, 17, 22)
	frame.BorderSizePixel = 0
	frame.Parent = debugGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = frame

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -12, 0, 25)
	title.Position = UDim2.fromOffset(8, 3)
	title.BackgroundTransparency = 1
	title.Text = "LocalTrader diagnostics"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.Parent = frame

	debugLogBox = Instance.new("TextBox")
	debugLogBox.Size = UDim2.new(1, -16, 1, -34)
	debugLogBox.Position = UDim2.fromOffset(8, 29)
	debugLogBox.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	debugLogBox.TextColor3 = Color3.fromRGB(215, 220, 230)
	debugLogBox.Font = Enum.Font.Code
	debugLogBox.TextSize = 11
	debugLogBox.TextXAlignment = Enum.TextXAlignment.Left
	debugLogBox.TextYAlignment = Enum.TextYAlignment.Top
	debugLogBox.TextWrapped = false
	debugLogBox.MultiLine = true
	debugLogBox.TextEditable = false
	debugLogBox.ClearTextOnFocus = false
	debugLogBox.Text = ""
	debugLogBox.Parent = frame

	debugGui.Parent = playerGui
	return true
end

-- IMPORTANT: never reassign the global warn (or any other standard global).
-- QuantumOnyx's "stop skidding" refusal is almost certainly an anti-tamper
-- check for exactly that kind of hook. debugLog() below calls the real,
-- untouched global warn() for console visibility, but never assigns over it.
local function debugLog(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	local line = os.date("%H:%M:%S") .. " " .. table.concat(parts, " ")
	debugLines[#debugLines + 1] = line
	while #debugLines > DEBUG_MAX_LINES do
		table.remove(debugLines, 1)
	end
	if debugLogBox and debugLogBox.Parent then
		debugLogBox.Text = table.concat(debugLines, "\n")
	end
	warn(...)
end

createDebugGui()
debugLog("LocalTrader: script execution started")

local function startupNotice(message, isError)
	local playerGui = LocalPlayer and (LocalPlayer:FindFirstChildOfClass("PlayerGui")
		or LocalPlayer:WaitForChild("PlayerGui", 10))
	if not playerGui then
		debugLog("LocalTrader: " .. message)
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
	debugLog("LocalTrader: " .. message)
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
	CustomerWaitTimeout = 600,    -- 10 minutes: no customer by then = order failed (refund)
	TradeStartTimeout = 30,
	CompletionTimeout = 45,
	HubReportMaxAttempts = 5,
	HubReportRetryDelays = {5, 10, 20, 30, 30},
	InventoryRefreshInterval = 2,
	MaxLogLines = 200,
	RetweenInterval = 4,
	TravelTimeout = 90,           -- total seconds allowed to reach the trade table
	AddItemMaxAttempts = 4,       -- v1.5: tries to put the requested fruit in the offer
	AddItemRetryDelay = 1.5,      -- v1.5: seconds between those tries
	MaxItemsPerTrade = 4,         -- v1.8: game rule: at most 4 units per side in one trade
}

-- ============================================================================
-- DAILY TRASH FLUSH SETTINGS  (the only thing you need to edit)
--
-- How it works: once per trade-day (the day rolls over at 23:59 UTC+8, the
-- same reset as Blox Fruits' daily trade limit) this account, while in
-- FARMING mode, equips each fruit on the trash list below and then resets its
-- character, which destroys the fruit.
--
-- IMPORTANT: the flush NEVER runs alongside the farm script. It runs as its own
-- step at the START of a farming session: when the game boots in FARMING mode
-- and a flush is due, LocalTrader flushes FIRST and only then loads
-- QuantumOnyx. The watchdog rejoins the game on its normal timer, so a flush
-- due at the day rollover happens at the next rejoin. Trading accounts are
-- never flushed (the flush simply waits for a farming boot).
--
-- It ships in TEST MODE: Enabled = true, DryRun = true. In test mode it only
-- writes "would flush X" lines to the log and deletes NOTHING.
-- When the log looks right, change   DryRun = true   to   DryRun = false.
-- ============================================================================
CONFIG.TrashFlush = {
	Enabled = true,               -- false = feature fully off
	DryRun = false,                -- true = only log, never delete. Set to false to go live.
	MaxRunSeconds = 900,          -- hard time cap; after this the farm script loads anyway
	PeriodHours = 8,              -- v1.9: flush once per this many hours (24 = the old once-a-day behaviour)
	MaxAttemptsPerDay = 3,        -- failed runs allowed per flush period before giving up until the next period
	MaxPerRun = 40,               -- safety cap: fruits flushed in one daily run
	EquipTimeout = 6,             -- seconds to wait for the equip to register
	ResetDeathTimeout = 3,        -- seconds to wait to see if a reset method actually killed the character
	RespawnTimeout = 30,          -- seconds to wait for the new character after dying
	SettleDelay = 5,              -- seconds after respawn before the first verification check
	VerifyTimeout = 20,           -- keep re-checking this long for the game's data to catch up
	VerifyInterval = 2,           -- seconds between those re-checks
	PauseBetweenFruits = 4,       -- pause after each successful flush before starting the next
	MaxConsecutiveFailures = 3,   -- stop for this session after this many failures in a row
	StateFile = "LocalTrader_Flush.json", -- remembers which day was already flushed
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

-- Orders this client has already finished with (completed, failed, timed out
-- or stopped). Without this, the poll loop at the bottom would see the same
-- order still sitting in the config file and immediately start it again.
local abandonedOrders = {}

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
		if statusCode == 0 and raw == "" then
			-- Some executors' request() returns a response object with
			-- StatusCode=0 and an empty body on a connection-level failure
			-- (Hub not reachable) instead of raising an error.
			return nil, "Hub unreachable (connection failed - is hub.py running and is the Hub URL/port correct?)"
		end
		if statusCode ~= 0 and (statusCode < 200 or statusCode >= 300) then
			return nil, "HTTP " .. tostring(statusCode) .. ": " .. tostring(raw):sub(1, 250)
		end
		local decodedOk, decoded = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if not decodedOk then
			return nil, "Hub returned invalid JSON (status=" .. tostring(statusCode) .. ", body=" .. tostring(raw):sub(1, 150) .. ")"
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
		return nil, "Hub returned invalid JSON (status=" .. tostring(response.StatusCode) .. ", body=" .. tostring(response.Body or ""):sub(1, 150) .. ")"
	end
	return decoded
end

local function readExternalOrder()
	local configured, configError = loadHubConfig()
	if not configured then
		debugLog("LocalTrader: " .. tostring(configError))
		return nil
	end
	if HubConfig.mode ~= "TRADING" then
		return nil
	end

	local ok, contents = pcall(readfile, CONFIG.HubConfigFile)
	if not ok or type(contents) ~= "string" or contents == "" then
		debugLog("LocalTrader: Workspace Hub config disappeared while reading order")
		return nil
	end
	local decodedOk, data = pcall(function()
		return HttpService:JSONDecode(contents)
	end)
	if not decodedOk or type(data) ~= "table" then
		debugLog("LocalTrader: Workspace Hub config contains invalid JSON")
		return nil
	end

	local requestId = tostring(data.request_id or "")
	local customer = tostring(data.customer or "")
	local item = tostring(data.item or "")
	local quantity = math.max(1, tonumber(data.quantity) or 1)
	local requestStatus = tostring(data.request_status or "ASSIGNED")
	local accountId = tostring(data.account_id or HubConfig.accountId or "")

	if requestId ~= "" and abandonedOrders[requestId] then
		return nil
	end

	if requestId == "" or customer == "" or item == "" then
		debugLog(
			"LocalTrader: TRADING mode but order fields are incomplete"
			.. " request=" .. requestId
			.. " customer=" .. customer
			.. " item=" .. item
			.. " quantity=" .. tostring(quantity)
		)
		return nil
	end

	debugLog(
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
		debugLog("LocalTrader: failed to report trade completion: " .. tostring(err))
		return false
	end
	debugLog("LocalTrader: trade completion reported to Hub")
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
		debugLog("LocalTrader Version 3: " .. mode .. " teleport retry limit reached")
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
			debugLog(string.format("LocalTrader Version 3: %s teleport requested (attempt %d)", mode, attempt))
			task.delay(15, function()
				if teleportInFlight and not teleportReachedDestination(mode, record) then
					teleportInFlight = false
					debugLog("LocalTrader Version 3: teleport did not complete; retrying")
					task.spawn(retryTeleport, mode, record)
				end
			end)
		else
			teleportInFlight = false
			debugLog("LocalTrader Version 3: " .. mode .. " teleport failed: " .. teleportErrorText(result))
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
	debugLog("LocalTrader Version 3: " .. teleportMode .. " teleport init failed: " .. teleportErrorText(result))
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
		debugLog("LocalTrader Version 3: could not save configured order: " .. tostring(saveError))
		return nil
	end
	return configured
end

-- v1.4: when did THIS Roblox client session start (unix seconds)? time() counts seconds
-- since the client joined the current server, so os.time() - time() is the join moment.
-- A handoff record written BEFORE that moment belongs to an earlier client process and
-- must not be trusted: rw.py force-stops and relaunches the clone, and Roblox can put the
-- new process into the SAME server (same game.JobId). The old guard keyed only on JobId,
-- so it read "LOAD_EXECUTED for this JobId", skipped the farm script, and the freshly
-- launched client sat idle.
local SESSION_STARTED_AT = (function()
	local ok, up = pcall(function()
		return time()
	end)
	up = ok and tonumber(up) or 0
	return os.time() - math.floor(up)
end)()

local function quantumOnyxEnv()
	return (type(getgenv) == "function" and getgenv()) or _G
end

local function handoffStamp(record)
	return math.max(tonumber(record.lastLoadAttemptAt) or 0, tonumber(record.farmLoadedAt) or 0)
end

local function loadQuantumOnyx()
	local env = quantumOnyxEnv()
	-- In-process duplicate guard (the script being executed twice in one client session).
	if env.__LocalTraderQuantumOnyxJob == game.JobId then
		debugLog("LocalTrader: QuantumOnyx was already started in this client session (JobId "
			.. tostring(game.JobId) .. "); skipping duplicate start")
		return
	end

	local record = readHandoff()
	if type(record) ~= "table" or record.phase ~= "FARMING" then
		debugLog("LocalTrader Version 3: no FARMING handoff is pending")
		return
	end

	local sameJob = record.loadJobId == game.JobId
	local stamp = handoffStamp(record)
	local fromThisSession = sameJob and stamp >= SESSION_STARTED_AT - 10
	if sameJob and not fromThisSession and record.farmStatus == "LOAD_EXECUTED" then
		debugLog(string.format(
			"LocalTrader: handoff says LOAD_EXECUTED for this JobId, but it was written %ds before this client session started (an earlier process); loading QuantumOnyx again",
			SESSION_STARTED_AT - stamp
		))
	end
	if fromThisSession and record.farmStatus == "LOAD_EXECUTED" then
		debugLog("LocalTrader Version 3: QuantumOnyx already executed in this client session for this JobId")
		return
	end

	local attempt = (fromThisSession and tonumber(record.loadAttempt)) or 0
	if attempt >= CONFIG.FarmLoadMaxAttempts then
		debugLog("LocalTrader Version 3: QuantumOnyx retry limit reached for this client session")
		return
	end
	attempt = attempt + 1
	local delaySeconds = CONFIG.FarmLoadRetryDelays[attempt] or 30
	task.delay(delaySeconds, function()
		local latest = readHandoff()
		if type(latest) ~= "table" or latest.phase ~= "FARMING" then
			return
		end
		if env.__LocalTraderQuantumOnyxJob == game.JobId then
			return -- another copy of this script started it while we waited
		end
		env.__LocalTraderQuantumOnyxJob = game.JobId
		latest.loadJobId = game.JobId
		latest.loadAttempt = attempt
		latest.lastLoadAttemptAt = os.time()
		latest.farmStatus = "LOADING"
		writeHandoff(latest)

		local startedClock = os.clock()
		local ok, result = xpcall(function()
			local source = game:HttpGet(CONFIG.QuantumOnyxUrl)
			debugLog(string.format("LocalTrader: QuantumOnyx source fetched: %d bytes in %.1fs",
				#tostring(source), os.clock() - startedClock))
			assert(type(source) == "string" and #source > 200,
				"QuantumOnyx download looks empty or truncated (" .. tostring(type(source) == "string" and #source or source) .. ")")
			local chunk, compileError = loadstring(source)
			assert(type(chunk) == "function", "QuantumOnyx did not compile: " .. tostring(compileError))
			return chunk()
		end, function(err)
			return tostring(err)
		end)
		if ok then
			latest.phase = "FARMING"
			latest.farmStatus = "LOAD_EXECUTED"
			latest.farmLoadedAt = os.time()
			writeHandoff(latest)
			debugLog(string.format(
				"LocalTrader Version 3: QuantumOnyx chunk returned after %.1fs (returned: %s). This does NOT prove the farm is running.",
				os.clock() - startedClock, tostring(result)
			))
		else
			env.__LocalTraderQuantumOnyxJob = nil -- allow a retry
			latest.lastError = tostring(result)
			if attempt < CONFIG.FarmLoadMaxAttempts then
				latest.farmStatus = "LOAD_RETRYING"
				writeHandoff(latest)
				debugLog("LocalTrader Version 3: QuantumOnyx load failed; retrying: " .. tostring(result))
				task.spawn(loadQuantumOnyx)
			else
				latest.farmStatus = "LOAD_FAILED"
				writeHandoff(latest)
				debugLog("LocalTrader Version 3: QuantumOnyx load failed after retries: " .. tostring(result))
			end
		end
	end)
end

local function handoffToFarming(sessionData)
	if sessionData and sessionData.externalOrder then
		debugLog("LocalTrader: Hub completion acknowledged; watchdog will relaunch farming")
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

-- Fetched here, before the FARMING/TRADING mode gate below, because
-- inventory reporting and the daily flush (used by both modes) need CommF.
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 15)
assert(Remotes, "ReplicatedStorage.Remotes was not found")
local CommF = Remotes:WaitForChild("CommF_", 15)
assert(CommF, "CommF_ remote was not found")

-- ============================================================================
-- TEAM SELECTION
-- Blox Fruits needs a team chosen before the inventory can be read and before
-- a reset works. This was previously only in the TRADING path; it now lives
-- up here so the inventory reports and the daily flush can use it too.
--
-- graceSeconds: how long to wait for something else (the farm script) to pick
-- a team on its own before this picks Pirates. 0 = pick immediately.
-- ============================================================================
local teamSelectionInFlight = false

local function ensureTeam(graceSeconds)
	if LocalPlayer.Team then
		return true
	end

	if teamSelectionInFlight then
		local waitDeadline = os.clock() + 90
		while teamSelectionInFlight and os.clock() < waitDeadline do
			task.wait(0.5)
		end
		return LocalPlayer.Team ~= nil
	end

	if graceSeconds and graceSeconds > 0 then
		debugLog("LocalTrader: no team yet; giving the farm script " .. tostring(graceSeconds) .. "s to pick one")
		local graceDeadline = os.clock() + graceSeconds
		while os.clock() < graceDeadline do
			if LocalPlayer.Team then
				debugLog("LocalTrader: team appeared on its own: " .. tostring(LocalPlayer.Team.Name))
				return true
			end
			task.wait(1)
		end
	end

	teamSelectionInFlight = true
	local result = false
	local ok, err = pcall(function()
		debugLog("LocalTrader: no team selected; waiting for DataLoaded")
		local dataLoaded = LocalPlayer:FindFirstChild("DataLoaded")
		if not dataLoaded then
			dataLoaded = LocalPlayer:WaitForChild("DataLoaded", 45)
		end
		if not dataLoaded then
			debugLog("LocalTrader: DataLoaded did not appear; cannot select team")
			return
		end

		local function trySetTeam(remoteCommand)
			local callOk, callResult = pcall(function()
				return CommF:InvokeServer(remoteCommand, "Pirates")
			end)
			debugLog(string.format(
				"LocalTrader: team request %s Pirates -> ok=%s result=%s",
				remoteCommand,
				tostring(callOk),
				tostring(callResult)
			))
			return callOk
		end

		-- Current Blox Fruits scripts commonly use SetTeam2. Keep SetTeam as a
		-- compatibility fallback because older versions/scripts used that command.
		if not trySetTeam("SetTeam2") then
			debugLog("LocalTrader: SetTeam2 failed; trying SetTeam")
			trySetTeam("SetTeam")
		end

		local deadline = os.clock() + 15
		while os.clock() < deadline do
			if LocalPlayer.Team then
				debugLog("LocalTrader: team selected: " .. tostring(LocalPlayer.Team.Name))
				break
			end
			task.wait(0.25)
		end

		if not LocalPlayer.Team then
			debugLog("LocalTrader: team selection did not register after 15s")
			return
		end

		-- Selecting a team can respawn the character. Wait for the new
		-- character before anything else touches the game.
		local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
		if character then
			debugLog("LocalTrader: character ready after team selection")
			result = true
		end
	end)
	teamSelectionInFlight = false
	if not ok then
		debugLog("LocalTrader: team selection error: " .. tostring(err))
		return false
	end
	return result
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

-- v1.7: every top-level field of the last getTradeInventory answer except Items (diagnostics)
local lastInventoryMeta = ""

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
	local meta = {}
	for key, value in pairs(result) do
		if key ~= "Items" then
			meta[#meta + 1] = tostring(key) .. "=" .. (type(value) == "table" and "{...}" or tostring(value):sub(1, 40))
		end
	end
	table.sort(meta)
	lastInventoryMeta = table.concat(meta, ", ")
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

-- Reports current tradable-fruit inventory to the Hub so make-order can scan
-- across accounts and pick one that actually has the requested item. Only
-- sends when Hub is configured; silently does nothing otherwise.
--
-- getTradeInventory needs a chosen team, and appears to be trade-table-context
-- dependent, so "can't read it right now" is an expected, frequent condition
-- here. Skip messages are throttled to avoid spamming the log.
local lastInventorySkipWarnAt = 0
local INVENTORY_SKIP_WARN_INTERVAL = 120

-- v1.6: "the player is actually playing" = the game finished loading and the
-- player has a living character in the world. Only then does the Hub get a
-- signal, so a Roblox client that is open but stuck on the join / loading
-- screen no longer looks online.
local function characterIsLoaded()
	if not game:IsLoaded() then
		return false
	end
	local character = LocalPlayer.Character
	if not character or not character:IsDescendantOf(workspace) then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil
		and humanoid.Health > 0
		and character:FindFirstChild("HumanoidRootPart") ~= nil
end

local function reportInventoryToHub()
	if HubConfig.url == "" or HubConfig.token == "" or HubConfig.accountId == "" then
		return
	end

	-- Not in a game yet (loading screen, dead, between servers): send nothing,
	-- so the Hub's in-game timer runs out and the account stops showing online.
	if not characterIsLoaded() then
		return
	end

	-- Tell the Hub the game itself is alive and playing, even if the
	-- inventory below can't be read right now. The Roblox username lets the
	-- dashboard show which account is in which package.
	hubRequest("POST", "/api/v1/game-ping", {
		account_id = HubConfig.accountId,
		username = LocalPlayer.Name,
	})

	-- No team yet = the inventory can't be read. In farming the farm script
	-- picks the team itself, so just wait for it rather than forcing one.
	if not LocalPlayer.Team then
		return
	end

	local inventory, err = readInventory()
	if not inventory then
		if os.clock() - lastInventorySkipWarnAt >= INVENTORY_SKIP_WARN_INTERVAL then
			lastInventorySkipWarnAt = os.clock()
			debugLog("LocalTrader: inventory report skipped (repeats suppressed for "
				.. INVENTORY_SKIP_WARN_INTERVAL .. "s): " .. tostring(err))
		end
		return
	end
	local available = getAvailablePhysicalFruits(inventory)
	local data, reqErr = hubRequest("POST", "/api/v1/inventory", {
		account_id = HubConfig.accountId,
		items = available,
	})
	if not data then
		debugLog("LocalTrader: inventory report failed: " .. tostring(reqErr))
	end
end

-- Started here (before the mode gate) so it keeps running even when the mode
-- gate below returns for FARMING - task.spawn detaches into its own thread
-- immediately, independent of the parent script chunk reaching `return`.
task.spawn(function()
	while true do
		task.wait(HubConfig.poll or CONFIG.HubPollInterval)
		reportInventoryToHub()
	end
end)

-- ============================================================================
-- TRASH FRUITS + DAILY FLUSH
--
-- Explicit name list (names must match the "X-X" format
-- getAvailablePhysicalFruits() reports, e.g. "Light-Light").
-- Edit this list to change which fruits get flushed.
-- ============================================================================

CONFIG.TrashFruitNames = {
	"Blade-Blade", "Bomb-Bomb", "Creation-Creation", "Dark-Dark", "Diamond-Diamond",
	"Eagle-Eagle", "Flame-Flame", "Ghost-Ghost", "Ice-Ice", "Light-Light", "Love-Love",
	"Magma-Magma", "Phoenix-Phoenix", "Quake-Quake", "Rocket-Rocket", "Rubber-Rubber",
	"Sand-Sand", "Smoke-Smoke", "Sound-Sound", "Spider-Spider", "Spike-Spike",
	"Spin-Spin", "Spring-Spring",
}

local trashFruitLookup = {}
for _, name in ipairs(CONFIG.TrashFruitNames) do
	trashFruitLookup[name] = true
end

-- Blocks (with a timeout) until LocalPlayer.Character exists.
local function waitForCharacterReady(timeoutSeconds)
	if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
		return true
	end
	local deadline = os.clock() + (timeoutSeconds or 20)
	while os.clock() < deadline do
		if LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Humanoid") then
			return true
		end
		task.wait(0.5)
	end
	return false
end

-- Returns candidates, errorMessage - errorMessage is nil on success, even if
-- candidates is empty (that's a legitimate "nothing to flag" result).
local function scanTrashCandidates()
	if not waitForCharacterReady(20) then
		return nil, "character was not ready within 20s"
	end
	if not LocalPlayer.Team then
		return nil, "no team selected yet (inventory is unavailable)"
	end

	local inventory, err = readInventory()
	if not inventory then
		return nil, "could not read inventory: " .. tostring(err)
	end

	local available = getAvailablePhysicalFruits(inventory)
	local candidates = {}
	for _, entry in ipairs(available) do
		if trashFruitLookup[entry.name] then
			candidates[#candidates + 1] = {
				name = entry.name,
				amount = entry.amount,
			}
		end
	end
	return candidates, nil
end

local function reportTrashCandidates()
	local candidates, err = scanTrashCandidates()
	if err then
		debugLog("LocalTrader: trash scan failed: " .. err)
		return
	end
	if #candidates == 0 then
		debugLog("LocalTrader: trash scan (dry run) - no junk fruits found")
		return
	end
	debugLog(string.format("LocalTrader: trash scan (dry run) - %d junk fruit(s) found, none touched:", #candidates))
	for _, c in ipairs(candidates) do
		debugLog(string.format("  - %s x%d", c.name, c.amount))
	end
end

-- ---- trade-day clock --------------------------------------------------------
-- The trade day rolls over at 23:59 UTC+8 = 15:59 UTC. Returns the unix time
-- of the most recent rollover.
local function currentTradeDayBoundary()
	-- v1.9: the flush period is CONFIG.TrashFlush.PeriodHours (default 8) instead of a whole day. Period
	-- boundaries are aligned to the 23:59 UTC+8 (15:59 UTC) rollover, so with 8 hours they fall at
	-- 15:59, 23:59 and 07:59 UTC.
	local now = os.time()
	local period = math.max(1, tonumber(CONFIG.TrashFlush.PeriodHours) or 24) * 3600
	local dayStart = now - (now % 86400) -- today 00:00 UTC
	local anchor = dayStart + 15 * 3600 + 59 * 60
	return anchor + math.floor((now - anchor) / period) * period
end

local function readFlushState()
	if type(readfile) ~= "function" then
		return { lastBoundary = 0 }
	end
	if type(isfile) == "function" and not isfile(CONFIG.TrashFlush.StateFile) then
		return { lastBoundary = 0 }
	end
	local ok, contents = pcall(readfile, CONFIG.TrashFlush.StateFile)
	if not ok or type(contents) ~= "string" or contents == "" then
		return { lastBoundary = 0 }
	end
	local decodedOk, data = pcall(function()
		return HttpService:JSONDecode(contents)
	end)
	if not decodedOk or type(data) ~= "table" then
		return { lastBoundary = 0 }
	end
	data.lastBoundary = tonumber(data.lastBoundary) or 0
	return data
end

local function writeFlushState(state)
	if type(writefile) ~= "function" then
		return false
	end
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(state)
	end)
	if not ok then
		return false
	end
	return pcall(writefile, CONFIG.TrashFlush.StateFile, encoded)
end

-- ---- fruit name / equipped detection -----------------------------------------
local fruitNameSet = {}
if ItemIds then
	for _, rec in pairs(ItemIds) do
		if type(rec) == "table" and rec[1] == "PhysicalFruit" and rec[2] then
			fruitNameSet[tostring(rec[2])] = true
		end
	end
end

-- Equipping a fruit makes the game send this to the client (seen in the sniffer):
--   CommE: "ItemRemoved", "<Fruit-Fruit>", "stored", <id>
--   CommE: "Notify", "Fruit added to backpack."
-- A passive listener on it is used as a second confirmation signal.
local function sendTradeNotice(text)
	text = tostring(text)
	-- TRADING accounts forward everything; farming accounts only notices that mention "trade"
	if HubConfig.mode ~= "TRADING" and not text:lower():find("trade") then
		return
	end
	if HubConfig.url == "" or HubConfig.token == "" or HubConfig.accountId == "" then
		return
	end
	task.spawn(function()
		pcall(hubRequest, "POST", "/api/v1/trade-notice", {
			account_id = HubConfig.accountId,
			text = text:sub(1, 300),
			client_ts = os.time(),
		})
	end)
end
local lastEquipEvent = { name = nil, at = 0 }
local tradeNoticeSink = nil -- v1.8: set to writeLog once the trade log exists
do
	local commE = Remotes:FindFirstChild("CommE")
	if commE and commE:IsA("RemoteEvent") then
		commE.OnClientEvent:Connect(function(kind, name, where)
			if kind == "ItemRemoved" and where == "stored" then
				lastEquipEvent = { name = tostring(name), at = os.clock() }
			elseif kind == "Notify" and type(name) == "string" and (sendTradeNotice(name) or true) and name:lower():find("trade") then
				-- v1.8 diagnostics: the game may announce the trade counter / limit this way
				if tradeNoticeSink then
					tradeNoticeSink("game notice: " .. name)
				else
					debugLog("LocalTrader: game notice: " .. name)
				end
			end
		end)
	end
end

-- Returns the name of the fruit currently equipped/held, or nil.
local function getEquippedFruitName()
	local data = LocalPlayer:FindFirstChild("Data")
	local df = data and data:FindFirstChild("DevilFruit")
	if df and df:IsA("ValueBase") then
		local v = tostring(df.Value or "")
		if v ~= "" then
			return v
		end
	end
	for _, container in ipairs({ LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack") }) do
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and fruitNameSet[child.Name] then
					return child.Name
				end
			end
		end
	end
	return nil
end

local function storedAmountOf(items, fruitName)
	for _, entry in ipairs(getAvailablePhysicalFruits(items)) do
		if entry.name == fruitName then
			return entry.amount
		end
	end
	return 0
end

-- ---- character reset ---------------------------------------------------------
-- Tries local reset methods in order of how reliably they replicate to the
-- server, and stops at the first one that actually kills the character.
-- Returns ok, methodNameOrReason.
local function resetCharacter()
	local cfg = CONFIG.TrashFlush
	local oldChar = LocalPlayer.Character
	local humanoid = oldChar and oldChar:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return false, "no humanoid to reset"
	end

	local methods = {
		{ "ChangeState(Dead)", function()
			humanoid:ChangeState(Enum.HumanoidStateType.Dead)
		end },
		{ "BreakJoints", function()
			oldChar:BreakJoints()
		end },
		{ "destroy Head", function()
			local head = oldChar:FindFirstChild("Head")
			if head then
				head:Destroy()
			end
		end },
		{ "Health=0", function()
			humanoid.Health = 0
		end },
	}

	for _, method in ipairs(methods) do
		local methodName, run = method[1], method[2]
		local ok, err = pcall(run)
		debugLog(string.format("LocalTrader: reset via %s -> ok=%s %s", methodName, tostring(ok), ok and "" or tostring(err)))

		-- did that actually kill the character?
		local died = false
		local deathDeadline = os.clock() + cfg.ResetDeathTimeout
		while os.clock() < deathDeadline do
			if LocalPlayer.Character ~= oldChar then
				died = true
				break
			end
			if not humanoid.Parent or not oldChar.Parent
				or humanoid.Health <= 0
				or humanoid:GetState() == Enum.HumanoidStateType.Dead then
				died = true
				break
			end
			task.wait(0.2)
		end

		if died then
			local respawnDeadline = os.clock() + cfg.RespawnTimeout
			while os.clock() < respawnDeadline do
				local c = LocalPlayer.Character
				if c and c ~= oldChar and c:FindFirstChildOfClass("Humanoid") then
					return true, methodName
				end
				task.wait(0.5)
			end
			return false, "character died via " .. methodName .. " but did not respawn in time"
		end
		debugLog("LocalTrader: " .. methodName .. " did not kill the character; trying the next method")
	end
	return false, "no reset method worked"
end

-- ---- flush one fruit ---------------------------------------------------------
-- Equip one trash fruit, then reset so it is destroyed. Returns ok, reason.
local function flushOne(fruitName)
	local cfg = CONFIG.TrashFlush

	local invBefore, invErr = readInventory()
	if not invBefore then
		return false, "inventory unreadable: " .. tostring(invErr)
	end
	local before = storedAmountOf(invBefore, fruitName)
	if before <= 0 then
		return false, "fruit no longer in inventory"
	end

	-- 1) equip
	lastEquipEvent = { name = nil, at = 0 }
	local okCall, result = pcall(function()
		return CommF:InvokeServer("LoadFruit", fruitName)
	end)
	debugLog(string.format("LocalTrader: flush LoadFruit %s -> ok=%s result=%s",
		fruitName, tostring(okCall), tostring(result)))
	if not okCall then
		return false, "LoadFruit call errored"
	end

	local confirmed = false
	local deadline = os.clock() + cfg.EquipTimeout
	while os.clock() < deadline do
		if getEquippedFruitName() == fruitName
			or (lastEquipEvent.name == fruitName and os.clock() - lastEquipEvent.at < cfg.EquipTimeout) then
			confirmed = true
			break
		end
		task.wait(0.25)
	end
	if not confirmed then
		return false, "equip was not confirmed (no Data/Tool/CommE signal)"
	end
	debugLog("LocalTrader: flush equip confirmed for " .. fruitName)

	-- 2) reset
	local resetOk, resetInfo = resetCharacter()
	if not resetOk then
		return false, "reset failed: " .. tostring(resetInfo)
	end
	debugLog("LocalTrader: character reset worked via " .. tostring(resetInfo))
	waitForCharacterReady(20)
	task.wait(cfg.SettleDelay)

	-- 3) verify it is really gone: not equipped, and not back in storage.
	-- Right after a respawn the game's inventory / equipped-fruit data can lag
	-- behind for a few seconds, so keep re-checking until it catches up
	-- instead of trusting a single immediate read.
	local verifyDeadline = os.clock() + cfg.VerifyTimeout
	local lastProblem = "could not verify"
	while true do
		local stillEquipped = (getEquippedFruitName() == fruitName)
		local invAfter = readInventory()
		if stillEquipped then
			lastProblem = "fruit still equipped after reset"
		elseif not invAfter then
			lastProblem = "could not re-read inventory to verify"
		else
			local after = storedAmountOf(invAfter, fruitName)
			if after < before then
				return true
			end
			lastProblem = string.format("fruit still in storage (before=%d after=%d)", before, after)
		end
		if os.clock() >= verifyDeadline then
			break
		end
		task.wait(cfg.VerifyInterval)
	end
	return false, lastProblem .. " even after " .. tostring(cfg.VerifyTimeout) .. "s of re-checking"
end

-- ---- the daily run -----------------------------------------------------------
local flushRunning = false
local flushFailures = 0
local flushDryRunLogged = false
local lastFlushSkipLogAt = 0

local function modeIsFarming()
	local configured = loadHubConfig()
	if not configured then
		return false
	end
	return HubConfig.mode == "FARMING"
end

local function runDailyFlush(boundary)
	local cfg = CONFIG.TrashFlush

	if not ensureTeam(0) then
		debugLog("LocalTrader: daily flush postponed - no team selected")
		return
	end

	local candidates, err = scanTrashCandidates()
	if err then
		debugLog("LocalTrader: daily flush scan failed: " .. err)
		return
	end

	if cfg.DryRun then
		flushDryRunLogged = true
		if #candidates == 0 then
			debugLog("LocalTrader: [DRY RUN] daily flush due - no trash fruits found")
		else
			debugLog(string.format("LocalTrader: [DRY RUN] daily flush due - would flush %d kind(s):", #candidates))
			for _, c in ipairs(candidates) do
				debugLog(string.format("  [DRY RUN] would flush %s x%d", c.name, c.amount))
			end
			debugLog("LocalTrader: [DRY RUN] nothing was deleted. Set DryRun = false in CONFIG.TrashFlush to go live.")
		end
		return
	end

	if #candidates == 0 then
		debugLog("LocalTrader: daily flush - no trash fruits found; day marked done")
		writeFlushState({ lastBoundary = boundary, flushed = 0, at = os.time() })
		return
	end

	-- v1.9: no 'equipped fruit' guard. The moveset in use lives in player data and survives resets.

	debugLog("LocalTrader: DAILY FLUSH STARTING (farm script has not been loaded yet)")
	local flushed = 0
	local finished = false
	local runStartedAt = os.clock()
	while flushed < cfg.MaxPerRun do
		if os.clock() - runStartedAt > cfg.MaxRunSeconds then
			debugLog("LocalTrader: daily flush hit the time cap; loading the farm script, will continue at the next rejoin")
			break
		end
		-- stop immediately if the Hub has assigned this account a trade
		if not modeIsFarming() then
			debugLog("LocalTrader: daily flush paused - account is no longer in FARMING mode")
			break
		end

		local list, scanErr = scanTrashCandidates()
		if scanErr then
			debugLog("LocalTrader: daily flush scan failed mid-run: " .. scanErr)
			break
		end
		if #list == 0 then
			finished = true
			break
		end

		local target = list[1]
		debugLog(string.format("LocalTrader: flushing %s (%d trash kind(s) left)", target.name, #list))
		local ok, reason = flushOne(target.name)
		if ok then
			flushFailures = 0
			flushed = flushed + 1
			debugLog("LocalTrader: flushed " .. target.name .. " (verified gone)")
			task.wait(cfg.PauseBetweenFruits)
		else
			flushFailures = flushFailures + 1
			debugLog(string.format("LocalTrader: flush of %s FAILED (%d/%d): %s",
				target.name, flushFailures, cfg.MaxConsecutiveFailures, tostring(reason)))
			break
		end
	end

	if finished then
		writeFlushState({ lastBoundary = boundary, flushed = flushed, at = os.time() })
		debugLog(string.format("LocalTrader: DAILY FLUSH COMPLETE - %d fruit(s) destroyed; next flush after the next day rollover", flushed))
	elseif flushed >= cfg.MaxPerRun then
		debugLog("LocalTrader: daily flush hit the MaxPerRun cap; will continue next cycle")
	end
end

-- Called ONCE per farming boot, BEFORE the farm script is loaded. Returns when
-- the flush is done / not needed / failed, so the caller can then load
-- QuantumOnyx. It never throws and never blocks farming forever.
local function runFlushBeforeFarm()
	local cfg = CONFIG.TrashFlush
	if not cfg.Enabled then
		return
	end
	-- Trading accounts are never touched.
	if not modeIsFarming() then
		return
	end

	local boundary = currentTradeDayBoundary()
	local state = readFlushState()
	if state.lastBoundary >= boundary then
		return -- already flushed this trade-day
	end

	local attempts = (state.attemptBoundary == boundary) and (tonumber(state.attempts) or 0) or 0
	if not cfg.DryRun and attempts >= cfg.MaxAttemptsPerDay then
		debugLog("LocalTrader: daily flush gave up for today after " .. attempts .. " attempts")
		return
	end

	-- let the game finish loading before touching anything
	task.wait(10)
	if not cfg.DryRun then
		writeFlushState({
			lastBoundary = state.lastBoundary,
			attemptBoundary = boundary,
			attempts = attempts + 1,
			at = os.time(),
		})
	end

	flushRunning = true
	local ok, e = pcall(runDailyFlush, boundary)
	flushRunning = false
	if not ok then
		debugLog("LocalTrader: daily flush error: " .. tostring(e))
	end
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

-- FARMING mode is intentionally passive here: LocalTrader does not build the
-- trading GUI or touch trade remotes. It only restores QuantumOnyx farming
-- (the daily flush loop above keeps running in the background).
if HubConfig.mode == "FARMING" then
	debugLog("LocalTrader: mode=FARMING; skipping trading initialization")
	local farmingRecord = readHandoff()
	if type(farmingRecord) ~= "table" or farmingRecord.phase ~= "FARMING" then
		farmingRecord = {
			version = 3,
			phase = "FARMING",
			farmStatus = "PENDING",
			orderId = HttpService:GenerateGUID(false),
			tradingJobId = CONFIG.TradingJobId,
			previousJobId = game.JobId,
			createdAt = os.time(),
			loadJobId = nil,
			loadAttempt = 0,
		}
		local saved, saveError = writeHandoff(farmingRecord)
		if saved then
			debugLog("LocalTrader: created FARMING handoff")
		else
			debugLog("LocalTrader: could not create FARMING handoff: " .. tostring(saveError))
		end
	else
		debugLog("LocalTrader: existing handoff phase=" .. tostring(farmingRecord.phase)
			.. ", farmStatus=" .. tostring(farmingRecord.farmStatus)
			.. ", recordJobId=" .. tostring(farmingRecord.loadJobId)
			.. ", thisJobId=" .. tostring(game.JobId)
			.. ", recordAgeVsSessionStart=" .. tostring(handoffStamp(farmingRecord) - SESSION_STARTED_AT) .. "s")
	end
	-- Flush (if due) FIRST, then start the farm script, so the two can never
	-- interfere with each other.
	task.defer(function()
		local ok, e = pcall(runFlushBeforeFarm)
		if not ok then
			debugLog("LocalTrader: pre-farm flush error: " .. tostring(e))
		end
		loadQuantumOnyx()
	end)
	return
end

if HubConfig.mode ~= "TRADING" then
	debugLog("LocalTrader: unknown mode=" .. tostring(HubConfig.mode) .. "; stopping safely")
	return
end

debugLog("LocalTrader: mode=TRADING; initializing trading system")

-- Blox Fruits requires the player to belong to a team before the trading
-- system can operate (ensureTeam is defined near the top of this file).
if not ensureTeam(0) then
	debugLog("LocalTrader: TRADING startup stopped: team selection failed")
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
	debugLog("LocalTrader: no active Hub order at startup")
end

local startupNoticeGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	and LocalPlayer.PlayerGui:FindFirstChild("LocalTraderStartupNotice")
if startupNoticeGui then
	startupNoticeGui:Destroy()
end

local TradeEvent = Remotes:WaitForChild("TradeEvent", 15)
local TradeFunction = Remotes:WaitForChild("TradeFunction", 15)
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

-- Reuses the single ItemIds catalog already loaded above instead of fetching
-- it a second time. A single shared table can't diverge from itself.
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

-- v1.5: how many copies of wantedId are currently in an offer.
local function offerAmount(items, wantedId)
	local amount = 0
	for _, item in pairs(items) do
		if tonumber(item.ItemId) == tonumber(wantedId) then
			amount = amount + (tonumber(item.Amount) or 0)
		end
	end
	return amount
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

-- v1.3: time-budgeted travel. The old version gave the tween only duration+1s
-- (v1.0) or 3 attempts (v1.2), and the Heartbeat loop additionally killed any
-- stage after 45s. Now: waits for the character, keeps retrying from wherever
-- it currently is until `budgetSeconds` (default CONFIG.TravelTimeout) runs
-- out, logs every attempt, and reports the real distance on failure.
local function tweenToSeat(seat, budgetSeconds)
	if not seat then
		return false, "trade table seat was not found"
	end
	if not waitForCharacterReady(30) then
		return false, "character was not ready within 30s"
	end

	local TweenService = game:GetService("TweenService")
	local startedAt = os.clock()
	local budget = budgetSeconds or CONFIG.TravelTimeout
	local lastDistance = math.huge
	local attempt = 0

	while os.clock() - startedAt < budget and running do
		attempt = attempt + 1
		local character = LocalPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart")
		if rootPart then
			local target = seat.CFrame + Vector3.new(0, 2.5, 0)
			local distance = (rootPart.Position - target.Position).Magnitude
			if distance <= 5 then
				rootPart.CFrame = target
				return true
			end

			local duration = math.clamp(distance / 100, 0.25, 8)
			local tween = TweenService:Create(
				rootPart,
				TweenInfo.new(duration, Enum.EasingStyle.Linear),
				{CFrame = target}
			)
			local completed = false
			tween.Completed:Connect(function()
				completed = true
			end)
			tween:Play()

			-- generous per-attempt deadline: lag on a busy phone can stretch a tween a lot
			local deadline = os.clock() + duration + 20
			while not completed and os.clock() < deadline and running do
				task.wait(0.1)
			end
			if not completed then
				tween:Cancel()
			end
			task.wait(0.5)

			if LocalPlayer.Character == character and rootPart.Parent then
				lastDistance = (rootPart.Position - target.Position).Magnitude
				if lastDistance <= 8 then
					return true
				end
			end
			debugLog(string.format(
				"LocalTrader: travel attempt %d at %.0fs: started %.0f studs out, now %.1f away (tween %s)",
				attempt, os.clock() - startedAt, distance, lastDistance,
				completed and "finished" or "timed out"
			))
		else
			task.wait(1)
		end
		task.wait(2)
	end

	return false, string.format(
		"could not reach trade table after %.0fs (last distance %.1f studs, %d attempts)",
		os.clock() - startedAt, lastDistance, attempt
	)
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

tradeNoticeSink = writeLog

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

-- Tells the Hub an order ended WITHOUT completing, so it can release this
-- account back to farming and, when the sale needs it, queue a refund. Bounded
-- retries; the Hub also expires stuck orders on its own, so a lost report can
-- never strand the account forever.
local function reportFailureToHub(sess, code, message)
	if not sess or not sess.externalOrder or sess.completed or sess.failureReported then
		return
	end
	sess.failureReported = true
	local order = sess.externalOrder
	task.spawn(function()
		for attempt = 1, CONFIG.HubReportMaxAttempts do
			local data, err = hubRequest("POST", "/api/v1/event", {
				account_id = tostring(order.account_id or HubConfig.accountId or ""),
				status = "failed",
				event = "trade_failed",
				extra = {
					request_id = tostring(order.request_id or order.order_id or ""),
					reason = code,
					message = tostring(message or ""),
				},
			})
			if data and data.ok ~= false then
				debugLog("LocalTrader: order failure reported to Hub (" .. tostring(code) .. ")")
				return
			end
			debugLog(string.format("LocalTrader: failure report attempt %d/%d failed: %s",
				attempt, CONFIG.HubReportMaxAttempts, tostring(err)))
			task.wait(CONFIG.HubReportRetryDelays[attempt] or 30)
		end
		debugLog("LocalTrader: could not report the failure to the Hub; it will expire the order itself")
	end)
end

local startButton
local function stopTrader(reason, failureCode)
	local stoppedSession = session
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

	if stoppedSession and stoppedSession.externalOrder then
		local rid = tostring(stoppedSession.externalOrder.request_id or stoppedSession.externalOrder.order_id or "")
		if rid ~= "" then
			abandonedOrders[rid] = true
		end
		if failureCode and not stoppedSession.completed then
			reportFailureToHub(stoppedSession, failureCode, reason)
		end
	end
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

-- v1.5: put the requested fruit into the worker's offer, tolerating failures.
-- Called from the update_state handler, and again by itself (after
-- CONFIG.AddItemRetryDelay) whenever the server refuses the add. It only adds the
-- quantity still MISSING from the latest offer, so a partial add followed by a
-- retry can never overshoot. After CONFIG.AddItemMaxAttempts failed tries the
-- order is stopped with reason "worker_error" (reported to the Hub) instead of
-- idling until the generic stage timeout.
local function attemptAddRequested(sess)
	if not running or session ~= sess or sess.ignoreTrade or sess.addRequested then
		return
	end
	local ts = latestTradeState
	local side = sess.localSide
	if not ts or not side or type(ts.State) ~= "table" or ts.State.Type ~= "NotReady" or type(ts.Offer) ~= "table" then
		return
	end
	local inOffer = offerAmount(offerItems(ts.Offer[side]), sess.requestedId)
	local missing = sess.quantity - inOffer
	if missing <= 0 then
		return
	end

	setState("OFFERING_ORDER_ITEM")
	sess.addRequested = true
	sess.addAttempts = (sess.addAttempts or 0) + 1
	local attemptNumber = sess.addAttempts

	local lastReturn = nil
	local ok, result = pcall(function()
		for _ = 1, missing do
			local added = TradeFunction:InvokeServer("addItem", sess.requestedId, 1)
			lastReturn = added
			if added == false then
				return false
			end
		end
		return true
	end)

	if ok and result == true then
		writeLog(string.format("requested fruit add requested (attempt %d, server returned %s)",
			attemptNumber, tostring(lastReturn)))
		return
	end

	-- failed: the call errored, or the server answered false
	sess.addRequested = false
	local why = ok and ("server returned " .. tostring(lastReturn)) or tostring(result)
	sendTradeNotice("[addItem] failed: " .. why)
	writeLog(string.format("addItem failed (attempt %d/%d): %s",
		attemptNumber, CONFIG.AddItemMaxAttempts, why))
	if attemptNumber >= CONFIG.AddItemMaxAttempts then
		stopTrader("could not add the requested fruit after " .. tostring(CONFIG.AddItemMaxAttempts)
			.. " attempts (" .. why .. ")", "worker_error")
		return
	end
	task.delay(CONFIG.AddItemRetryDelay, function()
		attemptAddRequested(sess)
	end)
end

-- v1.7 diagnostics: where does the game keep the "x/5 trades" counter?
local function describeFields(tbl)
	if type(tbl) ~= "table" then
		return tostring(tbl)
	end
	local parts = {}
	for key, value in pairs(tbl) do
		parts[#parts + 1] = tostring(key) .. "=" .. (type(value) == "table" and "{...}" or tostring(value):sub(1, 40))
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

local function scanTradeCounterLabels(reason)
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	local hits = 0
	for _, object in ipairs(playerGui:GetDescendants()) do
		if hits >= 12 then
			break
		end
		if object:IsA("TextLabel") or object:IsA("TextButton") then
			local text = object.Text
			if type(text) == "string" and #text <= 60 and text:find("%d") then
				local path = object:GetFullName()
				if text:find("%d+%s*/%s*5") or path:lower():find("trade") then
					hits = hits + 1
					writeLog(string.format("counter? [%s] %s = %q", reason, path, text))
				end
			end
		end
	end
	if hits == 0 then
		writeLog("counter? [" .. reason .. "] no matching text found in PlayerGui")
	end
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
	if quantity > CONFIG.MaxItemsPerTrade then
		local why = string.format("a trade can carry at most %d items; order asks for %d", CONFIG.MaxItemsPerTrade, quantity)
		writeLog(why)
		if type(orderData) == "table" then
			local rid = tostring(orderData.request_id or orderData.order_id or "")
			if rid ~= "" then
				abandonedOrders[rid] = true
			end
			reportFailureToHub({ externalOrder = orderData }, "worker_error", why)
		end
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
		addAttempts = 0,
		lastRetween = 0,
		customerWaitSince = os.clock(),
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
			stopTrader(moveError or "could not reach trade table", "worker_error")
			return
		end
		session.lastRetween = os.clock()
		setState("WAITING_FOR_CUSTOMER")
	end
	writeLog(string.format("ready: %s x%d (ItemId %s, catalog=%s, inventory=%s)",
		fruitBox.Text, quantity, tostring(requestedId), tostring(itemRecord(requestedId) and itemRecord(requestedId)[1]), tostring(requestedType)))
	writeLog("inventory extra fields: " .. (lastInventoryMeta ~= "" and lastInventoryMeta or "(none besides Items)"))
	if isSeatedAtTradeTable() then
		writeLog("session " .. tostring(session.id) .. " started; worker seated")
	else
		writeLog("session " .. tostring(session.id) .. " started; worker reached table and is waiting to sit")
	end

	connect(TradeEvent.OnClientEvent, function(eventName, tradeState)
		sendTradeNotice("[TradeEvent] " .. tostring(eventName) .. " type="
			.. tostring(type(tradeState) == "table" and type(tradeState.State) == "table" and tradeState.State.Type or "-"))
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
				session.addAttempts = 0
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
			writeLog("trade state fields: " .. describeFields(tradeState) .. " | State: " .. describeFields(tradeState.State))
			task.delay(1.5, function()
				scanTradeCounterLabels("trade start")
			end)
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
				-- v1.5: tolerant add with retries (see attemptAddRequested above)
				attemptAddRequested(session)
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
					sendTradeNotice("[accept] ok=" .. tostring(ok) .. " result=" .. tostring(result))
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
					stopTrader("verification failed", "verification_failed")
				end
			else
				setState("WAITING_FOR_CUSTOMER", "customer left")
				session.customerWaitSince = os.clock()
				latestTradeState = nil
				session.startedAt = os.clock()
				session.addRequested = false
				session.addAttempts = 0
				session.localSide = nil
				lastOfferSignature = nil
				lastLoggedOfferSignature = nil
				writeLog("customer left; waiting for the customer to sit again")
			end
		end
	end)
end

local function retryTrader()
	-- Retry must keep driving the SAME hub order (not silently drop it).
	local retryOrder = session and session.externalOrder
	if running then
		stopTrader("retry requested")
		task.wait(0.2)
	end
	if retryOrder then
		local rid = tostring(retryOrder.request_id or retryOrder.order_id or "")
		if rid ~= "" then
			abandonedOrders[rid] = nil
		end
		startTrader(retryOrder)
	else
		startTrader()
	end
end

startButton = button("Start", UDim2.fromOffset(12, 270), 195, startTrader)
button("Stop", UDim2.fromOffset(220, 270), 195, function()
	stopTrader("stopped by user", "stopped_manually")
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
	local moved, errorMessage = tweenToSeat(targetSeat, 20)
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
	local waitedForCustomer = os.clock() - (session.customerWaitSince or session.startedAt)
	if state == "WAITING_FOR_CUSTOMER" and waitedForCustomer > CONFIG.CustomerWaitTimeout then
		setState("TIMEOUT")
		stopTrader("customer did not arrive within " .. tostring(CONFIG.CustomerWaitTimeout) .. "s", "customer_no_show")
	elseif state == "TRADE_STARTED" and elapsed > CONFIG.TradeStartTimeout then
		setState("TIMEOUT")
		stopTrader("trade offer timeout", "trade_timeout")
	elseif state ~= "WAITING_FOR_CUSTOMER" and state ~= "IDLE"
		and state ~= "PROCESSING" and state ~= "VERIFYING_INVENTORY"
		and state ~= "TRAVELING_TO_TABLE"
		and state ~= "TIMEOUT" and elapsed > CONFIG.CompletionTimeout then
		setState("TIMEOUT")
		stopTrader("stage timeout: " .. state, "stage_timeout")
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
