local Server = {}

function Server.endpoint(custom)
    if custom == nil or custom == "" then return "https://sync.koreader.rocks" end
    if type(custom) ~= "string" or custom:find("[%c%s\\]") then return end
    local parsed = require("socket.url").parse(custom)
    if parsed and parsed.scheme == "https" and parsed.host and parsed.host ~= ""
        and not (parsed.userinfo or parsed.user or parsed.password or parsed.query or parsed.fragment) then
        return (custom:gsub("/+$", ""))
    end
end

-- Called in a KOReader worker process, so neither the request nor its timeouts block the UI.
function Server.request(endpoint, credentials, document, progress)
    local https = require("ssl.https")
    local http = require("socket.http")
    local ssl = require("ssl")
    local json = require("rapidjson")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local ca = ssl.get_system_ca and ssl.get_system_ca()
    if not ca then
        local bundle = io.open("data/ca-bundle.crt", "rb")
        if not bundle then return nil, "No trusted certificate bundle found" end
        bundle:close()
        ca = "data/ca-bundle.crt"
    end
    local request = {
        url = endpoint .. "/syncs/progress",
        method = progress and "PUT" or "GET",
        verify = "peer",
        cafile = ca,
        redirect = false,
        headers = {
            ["accept"] = "application/vnd.koreader.v1+json",
            ["x-auth-user"] = credentials.username,
            ["x-auth-key"] = credentials.userkey,
        },
    }
    if progress then
        local body = json.encode(progress)
        if not body then return nil, "Could not encode reading progress" end
        request.source = ltn12.source.string(body)
        request.headers["content-type"] = "application/json"
        request.headers["content-length"] = tostring(#body)
    else
        request.url = request.url .. "/" .. document
    end
    local chunks, length = {}, 0
    local old_block, old_total = socketutil.block_timeout, socketutil.total_timeout
    local old_https, old_http = https.TIMEOUT, http.TIMEOUT
    local ok, received, status = pcall(function()
        socketutil:set_timeout(5, 15)
        local sink = socketutil.table_sink(chunks)
        request.sink = function(chunk, err)
            length = length + (chunk and #chunk or 0)
            if length > 65536 then return nil, "Response too large" end
            return sink(chunk, err)
        end
        return https.request(request)
    end)
    socketutil.block_timeout, socketutil.total_timeout = old_block, old_total
    https.TIMEOUT, http.TIMEOUT = old_https, old_http
    if not ok or not received or not tonumber(status) then
        if ok and type(status) == "string" then
            local err = status:lower()
            if err:find("certificate", 1, true) then return nil, "TLS certificate verification failed" end
            if err:find("timeout", 1, true) or err == "wantread" or err == "wantwrite" then
                return nil, "Server connection timed out"
            end
        end
        return nil, "Could not reach the sync server over HTTPS"
    end
    status = tonumber(status)
    if progress or status ~= 200 then return status end
    local decoded, body = pcall(json.decode, table.concat(chunks))
    if not decoded or type(body) ~= "table" then return status, "Invalid server response" end
    return status, body
end

return Server
