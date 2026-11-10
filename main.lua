local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local Bulk = WidgetContainer:extend{ name = "bulkprogresssync", is_doc_only = false }
local active_job
local last_result

local function message(text)
    UIManager:show(InfoMessage:new{
        text = text, timeout = 12, dismissable = true, show_icon = false,
        width_factor = 0.8, honor_silent_mode = false,
    })
end

local function syncSettings()
    local path = DataStorage:getSettingsDir() .. "/kosync.lua"
    if lfs.attributes(path, "mode") == "file" or lfs.attributes(path .. ".old", "mode") == "file" then
        return LuaSettings:open(path):readSetting("settings")
    end
    return G_reader_settings:readSetting("kosync")
end

local function validHeader(value)
    return type(value) == "string" and value:match("%S") and not value:find("%c")
end

function Bulk:init()
    if self.ui.document then return end
    self.ui.menu:registerToMainMenu(self)
end

local function checkProgressSyncClient()
    -- Inspect the module without importing it or running a sync request.
    local loaded = package.loaded.KOSyncClient
    if type(loaded) == "table" and type(loaded.update_progress) == "function" then
        local source = debug.getinfo(loaded.update_progress, "S").source
        message(_("Progress Sync client currently loaded") .. "\n" .. source:gsub("^@", ""))
        return
    end
    for pattern in package.path:gmatch("[^;]+") do
        local path = pattern:gsub("%?", "KOSyncClient")
        local file = io.open(path, "rb")
        if file then
            file:close()
            message(_("First Progress Sync client on KOReader's search path") .. "\n" .. path)
            return
        end
    end
    message(_("No Progress Sync client was found. Check that the built-in Progress sync plugin is enabled."))
end

function Bulk:libraryFolder()
    local chooser = self.ui.file_chooser
    return G_reader_settings:readSetting("kobulksync_library")
        or G_reader_settings:readSetting("kobatchsync_library") -- Legacy saved folder.
        or G_reader_settings:readSetting("home_dir") or (chooser and chooser.path) or Device.home_dir
end

function Bulk:chooseFolder(path)
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        path = path,
        select_directory = true,
        select_file = false,
        show_files = true,
        onConfirm = function(folder)
            G_reader_settings:saveSetting("kobulksync_library", folder)
        end,
    })
end

function Bulk:addToMainMenu(items)
    items.bulkprogresssync = {
        text = _("Bulk Progress Sync"),
        sub_item_table = {
            {
                text = _("Push all saved positions"),
                callback = function() self:confirm(true) end,
            },
            {
                text = _("Pull all saved positions"),
                callback = function() self:confirm(false) end,
            },
            {
                text = _("Choose library folder"),
                callback = function() self:chooseFolder(self:libraryFolder() or "/") end,
            },
        },
    }
    if Device:isPocketBook() then
        table.insert(items.bulkprogresssync.sub_item_table, {
            text = _("Choose SD card folder"),
            callback = function()
                local card = "/mnt/ext2"
                if lfs.attributes(card, "mode") == "directory" then
                    self:chooseFolder(card)
                else
                    message(_("The SD card folder (/mnt/ext2) is unavailable. Disconnect USB storage and check that the PocketBook can see the card."))
                end
            end,
        })
    end
    table.insert(items.bulkprogresssync.sub_item_table, {
        text = _("Check library folder"),
        callback = function()
            local root = self:libraryFolder()
            if root then self:start(nil, root) else message(_("Choose a library folder first.")) end
        end,
    })
    table.insert(items.bulkprogresssync.sub_item_table, {
        text = _("Last bulk result"),
        enabled_func = function() return last_result ~= nil end,
        callback = function() if last_result then message(last_result) end end,
    })
    table.insert(items.bulkprogresssync.sub_item_table, {
        text = _("Check Progress Sync client"),
        callback = checkProgressSyncClient,
    })
end

function Bulk:confirm(push)
    if active_job then return end
    if self.ui.document then
        message(_("Close the book and run Bulk Progress Sync from the KOReader file browser. This saves the open book before syncing."))
        return
    end
    local root = self:libraryFolder()
    if not root or lfs.attributes(root, "mode") ~= "directory" then
        message(_("Choose a library folder first."))
        return
    end
    local prompt = push and _("Send saved reading positions for this folder and its subfolders? This can replace existing positions on the server.")
        or _("Apply server reading positions to matching books in this folder and its subfolders? This can replace newer positions on this device.")
    local settings = syncSettings()
    local server = dofile(self.path .. "/internal/server.lua")
    local endpoint = type(settings) == "table" and server.endpoint(settings.custom_server)
    local context = "\n\n" .. root
    if endpoint then
        context = context .. "\n" .. endpoint:match("^https://[^/]+")
        if push then
            context = context .. "\n" .. (settings.send_metadata == true
                and _("Book details will be sent.") or _("Send document metadata is off."))
        end
    end
    UIManager:show(ConfirmBox:new{
        text = prompt .. context,
        ok_text = push and _("Push all") or _("Pull all"),
        ok_callback = function()
            -- Let the confirmation dialog close before displaying the cancellable message.
            UIManager:nextTick(function() self:start(push, root, settings, endpoint, server) end)
        end,
    })
end

local function pause(seconds)
    local thread = coroutine.running()
    UIManager:scheduleIn(seconds, function() coroutine.resume(thread) end)
    coroutine.yield()
end

local result_labels = {
    { "updated", _("Applied") },
    { "sent", _("Accepted by server") },
    { "no_local", _("No saved local position and percentage") },
    { "no_remote", _("No matching server progress") },
    { "same", _("Already matches") },
    { "duplicate", _("Duplicate copy") },
    { "conflict", _("Ambiguous matching ID") },
    { "unreadable", _("Unreadable book or checksum") },
    { "invalid", _("Invalid or incompatible server position") },
    { "write_error", _("Could not save book settings") },
    { "network", _("Request failed") },
    { "book_error", _("Book settings error") },
}

function Bulk:start(push, root, settings, endpoint, server)
    if active_job then return end
    local check_only = push == nil
    local credentials, by_filename, send_metadata, device, device_id
    if not check_only then
        if type(settings) ~= "table" or not validHeader(settings.username) or not validHeader(settings.userkey) then
            message(_("No saved Progress Sync login found. Open a book, sign in under Progress sync, then return to the file browser."))
            return
        end
        if not endpoint then
            message(_("The Progress Sync server address must be a valid HTTPS URL."))
            return
        end
        credentials = { username = settings.username, userkey = settings.userkey }
        by_filename = tonumber(settings.checksum_method) == 1
        send_metadata = push and settings.send_metadata == true
        device = settings.kosync_hostname or Device.model or "KOReader"
        device_id = G_reader_settings:readSetting("device_id")
        if push and not validHeader(device_id) then
            message(_("KOReader has no saved sync device ID. Restart KOReader and try again."))
            return
        end
    end
    local books_api = dofile(self.path .. "/internal/books.lua")
    local Trapper = require("ui/trapper")

    local title = check_only and _("Checking library folder")
        or (push and _("Pushing library progress") or _("Pulling library progress"))
    local can_cancel, cancel_requested, closed = false, false, false
    local progress
    progress = ButtonDialog:new{
        title = title .. "\n" .. _("Scanning folders…"),
        title_align = "center",
        modal = true,
        dismissable = false,
        buttons = {{ {
            text = _("Cancel"),
            enabled = false,
            enabled_func = function() return can_cancel and not cancel_requested end,
            callback = function()
                if not can_cancel or cancel_requested or closed then return end
                cancel_requested = true
                -- Trapper sets this callback only while a request is in flight.
                if progress.dismiss_callback then progress.dismiss_callback() end
            end,
        } }},
        onCloseWidget = function(widget)
            closed = true
            ButtonDialog.onCloseWidget(widget)
            if widget.dismiss_callback then widget.dismiss_callback() end
        end,
    }
    active_job = progress
    UIManager:show(progress)
    -- Ignore any follow-up tap from the confirmation before arming Cancel.
    UIManager:scheduleIn(0.5, function()
        if not closed then
            can_cancel = true
            UIManager:setDirty(progress, "ui")
        end
    end)
    Trapper:wrap(function()
        local counts, found, scan_stats, detail = {}, nil, nil, nil
        local sent_with_metadata = 0
        local use_worker = type(Trapper.dismissableRunInSubprocess) == "function"
        local function count(key)
            counts[key] = (counts[key] or 0) + 1
        end
        local function running()
            return not cancel_requested and not closed
        end
        local function stopped()
            if cancel_requested then return _("Bulk sync cancelled") end
            return _("Bulk sync interrupted because the progress dialog closed")
        end
        local function checkpoint()
            pause(0.02)
            return running()
        end
        local ok, outcome = pcall(function()
            if not checkpoint() then return stopped() end
            local books, stats = books_api.scan(root, checkpoint)
            if not books then return stopped() end
            found, scan_stats = #books, stats
            if check_only then return _("Library check finished") end
            if found == 0 then return _("No supported books found in this folder") end
            progress:setTitle(title .. "\n" .. (_("Preparing %d books…")):format(found))

            -- Find ambiguous IDs before making changes. Filename matching can map
            -- different books to the same server record, even when one is unread.
            local names, groups = {}, {}
            if by_filename then
                for _, book in ipairs(books) do names[book.name] = (names[book.name] or 0) + 1 end
            end
            for i, book in ipairs(books) do
                if i % 16 == 0 and not checkpoint() then return stopped() end
                if by_filename and names[book.name] > 1 then
                    book.result = "conflict"
                else
                    local prepared, reason = pcall(books_api.prepare, book, push, by_filename, send_metadata)
                    if prepared then book.result = reason else book.result = "book_error" end
                    if push and not book.result then
                        local first = groups[book.id]
                        if not first then
                            groups[book.id] = book
                        elseif first.result == "conflict" or first.progress ~= book.progress
                            or first.percentage ~= book.percentage then
                            first.result, book.result = "conflict", "conflict"
                        else
                            book.first = first
                        end
                    end
                end
            end

            for i, book in ipairs(books) do
                if not running() or (i % 16 == 0 and not checkpoint()) then return stopped() end
                if book.first then book.result = book.first.result == "conflict" and "conflict" or "duplicate" end
                if not book.result then
                    progress:setTitle(title .. "\n" .. (_("Book %d of %d")):format(i, found))
                    local payload = push and {
                        document = book.id, progress = book.progress, percentage = book.percentage,
                        device = device, device_id = device_id, metadata = book.metadata,
                    } or nil
                    local function request()
                        return server.request(endpoint, credentials, book.id, payload)
                    end
                    local status, body
                    if use_worker then
                        local completed
                        completed, status, body = Trapper:dismissableRunInSubprocess(request, progress)
                        progress.dismiss_callback = nil
                        if not running() then return stopped() end
                        -- With the dialog still open, false means the worker could not start.
                        use_worker = completed
                    end
                    if not use_worker then
                        if not checkpoint() then return stopped() end
                        status, body = request()
                        if not checkpoint() then return stopped() end
                    end
                    if status == 401 or status == 403 or status == 429 or status == nil
                        or (status >= 300 and status < 400) then
                        count("network")
                        detail = status and ("HTTP " .. status) or body or _("Network worker returned no result")
                        return _("Bulk sync stopped after a server error")
                    elseif push and (status == 200 or status == 201 or status == 202 or status == 204) then
                        book.result = "sent"
                        if book.metadata then sent_with_metadata = sent_with_metadata + 1 end
                    elseif not push and (status == 404 or status == 204) then
                        book.result = "no_remote"
                    elseif not push and status == 200 then
                        local applied, result = pcall(books_api.apply, book, body, by_filename)
                        book.result = applied and result or "book_error"
                    else
                        book.result = "network"
                        detail = "HTTP " .. status
                    end
                    count(book.result)
                    pause(0.2)
                else
                    count(book.result)
                end
            end
            return running() and _("Bulk sync finished") or stopped()
        end)

        local lines = { ok and outcome or _("Could not finish the library scan or sync") }
        if endpoint then lines[#lines + 1] = endpoint:match("^https://[^/]+") end
        if found then lines[#lines + 1] = _("Books found") .. " " .. found end
        local processed = 0
        for _, label in ipairs(result_labels) do
            local total = counts[label[1]]
            if total then
                processed = processed + total
                lines[#lines + 1] = label[2] .. " " .. total
            end
        end
        if counts.sent then
            lines[#lines + 1] = _("With book details") .. " " .. sent_with_metadata
        end
        if check_only or found == 0 or not ok then lines[#lines + 1] = root end
        if scan_stats then
            if check_only or found == 0 then
                lines[#lines + 1] = _("Folders scanned") .. " " .. scan_stats.folders
                lines[#lines + 1] = _("Unsupported files") .. " " .. scan_stats.unsupported
            end
            if scan_stats.unreadable > 0 then
                lines[#lines + 1] = _("Unreadable entries") .. " " .. scan_stats.unreadable
            end
            if scan_stats.excluded > 0 then
                lines[#lines + 1] = _("Links outside library") .. " " .. scan_stats.excluded
            end
        end
        if not check_only and found and found > processed then
            lines[#lines + 1] = _("Not processed") .. " " .. (found - processed)
        end
        if detail then lines[#lines + 1] = detail end
        UIManager:nextTick(function()
            progress.dismiss_callback = nil
            if not closed then UIManager:close(progress, "full") end
            -- Let the screen repaint without the progress widget before showing the result.
            UIManager:tickAfterNext(function()
                active_job = nil
                last_result = table.concat(lines, "\n")
                message(last_result)
            end)
        end)
    end)
end

return Bulk
