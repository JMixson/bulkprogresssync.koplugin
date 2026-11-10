local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local util = require("util")

local Books = {}

function Books.scan(root, checkpoint)
    local files = {}
    local stats = { folders = 0, unreadable = 0, unsupported = 0, excluded = 0 }
    root = ffiutil.realpath(root)
    if not root then
        stats.unreadable = 1
        return files, stats
    end
    local folders, seen = { root }, { [root] = true }
    local prefix = root:gsub("/+$", "") .. "/"
    local entries = 0
    while #folders > 0 do
        local folder = table.remove(folders)
        local ok, iter, state = pcall(lfs.dir, folder)
        if ok and iter then
            stats.folders = stats.folders + 1
            for name in iter, state do
                if name:sub(1, 1) ~= "." and not name:lower():match("%.sdr$") then
                    local file = folder:gsub("/+$", "") .. "/" .. name
                    local resolved = ffiutil.realpath(file)
                    if not resolved then
                        stats.unreadable = stats.unreadable + 1
                    elseif resolved:sub(1, #prefix) ~= prefix then
                        stats.excluded = stats.excluded + 1
                    elseif not seen[resolved] then
                        seen[resolved] = true
                        local mode = lfs.attributes(resolved, "mode")
                        if mode == "directory" then
                            folders[#folders + 1] = resolved
                        elseif mode == "file" then
                            local checked, supported = pcall(DocumentRegistry.hasProvider, DocumentRegistry, resolved)
                            if not checked then
                                stats.unreadable = stats.unreadable + 1
                            elseif supported then
                                files[#files + 1] = { path = resolved, name = resolved:match("[^/]+$") }
                            else
                                stats.unsupported = stats.unsupported + 1
                            end
                        elseif not mode then
                            stats.unreadable = stats.unreadable + 1
                        end
                    end
                end
                entries = entries + 1
                if entries % 64 == 0 and not checkpoint() then return end
            end
        else
            stats.unreadable = stats.unreadable + 1
        end
    end
    table.sort(files, function(a, b) return a.path < b.path end)
    return files, stats
end

local function position(value)
    if type(value) ~= "string" and type(value) ~= "number" then return end
    value = tostring(value)
    if #value > 8192 or value:find("%c") then return end
    local page = tonumber(value)
    if page and page >= 1 and page <= 2147483647 and page == math.floor(page) then
        return "last_page", page
    end
    if value:sub(1, 1) == "/" and #value > 1 then return "last_xpointer", value end
end

local function percent(value)
    if type(value) ~= "number" and type(value) ~= "string" then return end
    value = tonumber(value)
    if value and value >= 0 and value <= 1 then return value end
end

local function hash(value)
    return type(value) == "string" and #value == 32 and value:match("^%x+$") and value:lower()
end

local function metadataText(value)
    if type(value) == "string" and #value <= 512 then
        return value:match("^%s*(%S.-)%s*$")
    end
end

local function getMetadata(book, settings)
    local props = settings:readSetting("doc_props")
    if type(props) ~= "table" then props = {} end
    local custom = {}
    if settings.findCustomMetadataFile and DocSettings.openSettingsFile then
        local path = settings:findCustomMetadataFile(book.path)
        if path then
            local ok, custom_settings = pcall(DocSettings.openSettingsFile, path)
            if ok then
                local saved = custom_settings:readSetting("custom_props")
                if type(saved) == "table" then custom = saved end
            end
        end
    end
    return {
        filename = metadataText(book.name),
        title = metadataText(custom.title) or metadataText(props.display_title) or metadataText(props.title)
            or metadataText((book.name:gsub("%.[^.]+$", ""))),
        authors = metadataText(custom.authors) or metadataText(props.authors),
    }
end

function Books.prepare(book, push, by_filename, send_metadata)
    local settings = DocSettings:open(book.path)
    if push then
        local kind, value = position(settings:readSetting("last_xpointer") or settings:readSetting("last_page"))
        local percentage = percent(settings:readSetting("percent_finished"))
            or percent(settings:readSetting("last_percent"))
        if not kind or percentage == nil then return "no_local" end
        book.progress, book.percentage = tostring(value), percentage
        if send_metadata then book.metadata = getMetadata(book, settings) end
    end
    if by_filename then
        book.id = hash(md5(book.name))
    else
        book.id = hash(settings:readSetting("partial_md5_checksum")) or hash(util.partialMD5(book.path))
    end
    if not book.id then return "unreadable" end
end

function Books.apply(book, body, by_filename)
    if type(body) ~= "table" then return "invalid" end
    if next(body) == nil then return "no_remote" end
    local kind, value = position(body.progress)
    local percentage = percent(body.percentage)
    if not kind or percentage == nil or (body.document ~= nil and body.document ~= book.id) then
        return "invalid"
    end
    if ffiutil.realpath(book.path) ~= book.path or lfs.attributes(book.path, "mode") ~= "file" then
        return "unreadable"
    end
    local settings = DocSettings:open(book.path)
    local other = kind == "last_page" and "last_xpointer" or "last_page"
    if settings:readSetting(kind) == nil and settings:readSetting(other) ~= nil then return "invalid" end
    if settings:readSetting(kind) == value and settings:readSetting("percent_finished") == percentage then
        return "same"
    end
    settings:saveSetting(kind, value)
    settings:delSetting(other)
    settings:delSetting("last_percent")
    settings:saveSetting("percent_finished", percentage)
    if not by_filename then settings:saveSetting("partial_md5_checksum", book.id) end
    if not settings:flush(nil, true) then return "write_error" end
    return "updated"
end

return Books
