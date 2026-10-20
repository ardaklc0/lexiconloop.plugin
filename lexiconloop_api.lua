-- Minimal Supabase client (auth + REST) for the Lexicon Loop plugin.
-- All calls are blocking; the caller shows a "busy" message around them.
local JSON = require("json")
local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local socket_url = require("socket.url")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local Config = require("lexiconloop_config")

local Api = {}
Api.__index = Api

function Api:new(settings)
    return setmetatable({ settings = settings }, Api)
end

local function errText(data, code)
    if type(data) == "table" then
        local msg = data.error_description or data.msg or data.message or data.error
        if type(msg) == "string" then return msg end
    end
    return "HTTP " .. tostring(code)
end

local function networkError(code)
    return _("Network error: ") .. tostring(code)
end

local function esc(value)
    return socket_url.escape(tostring(value))
end

function Api:get(key) return self.settings:readSetting(key) end

function Api:isLoggedIn()
    return self:get("refresh_token") ~= nil and self:get("user_id") ~= nil
end

-- Returns the HTTP status (or an error string on transport failure) and the decoded JSON body.
function Api:_send(method, path, body, token, prefer, base_url, extra_headers)
    local url = (base_url or Config.supabase_url) .. path
    local headers = { ["Accept"] = "application/json" }
    if not base_url then headers["apikey"] = Config.supabase_key end
    for name, value in pairs(extra_headers or {}) do headers[name] = value end
    local payload
    if body ~= nil then
        payload = JSON.encode(body)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#payload)
    end
    if token then headers["Authorization"] = "Bearer " .. token end
    if prefer then headers["Prefer"] = prefer end

    local transport = url:find("^https") and require("ssl.https") or require("socket.http")
    local sink = {}
    local request = {
        url = url,
        method = method,
        headers = headers,
        sink = ltn12.sink.table(sink),
        source = payload and ltn12.source.string(payload) or nil,
    }
    socketutil:set_timeout(15, 40)
    local ok, first, code = pcall(transport.request, request)
    socketutil:reset_timeout()
    if not ok then return tostring(first) end
    if type(code) ~= "number" then return tostring(code or first) end

    local text = table.concat(sink)
    local data
    if text ~= "" then
        local decoded, value = pcall(JSON.decode, text)
        if decoded then data = value end
    end
    return code, data
end

function Api:storeSession(data)
    self.settings:saveSetting("access_token", data.access_token)
    self.settings:saveSetting("refresh_token", data.refresh_token)
    self.settings:saveSetting("expires_at", os.time() + (tonumber(data.expires_in) or 3600))
    if type(data.user) == "table" then
        self.settings:saveSetting("user_id", data.user.id)
        if data.user.email then self.settings:saveSetting("email", data.user.email) end
    end
    self.settings:flush()
end

function Api:clearSession()
    for _, key in ipairs({ "access_token", "refresh_token", "expires_at", "user_id",
                           "workspace_id", "workspace_name", "folder_id", "folder_name" }) do
        self.settings:delSetting(key)
    end
    self.settings:flush()
end

function Api:login(email, password)
    local code, data = self:_send("POST", "/auth/v1/token?grant_type=password", { email = email, password = password })
    if type(code) ~= "number" then return false, networkError(code) end
    if code ~= 200 or type(data) ~= "table" or not data.access_token then
        return false, errText(data, code)
    end
    -- A different account means the saved workspace/folder no longer apply.
    if self:get("user_id") and self:get("user_id") ~= (data.user and data.user.id) then
        self:clearSession()
    end
    self:storeSession(data)
    return true
end

function Api:logout()
    local token = self:get("access_token")
    if token then pcall(self._send, self, "POST", "/auth/v1/logout", nil, token) end
    self:clearSession()
end

function Api:refresh()
    local refresh_token = self:get("refresh_token")
    if not refresh_token then return false, _("Please log in first.") end
    local code, data = self:_send("POST", "/auth/v1/token?grant_type=refresh_token", { refresh_token = refresh_token })
    if type(code) ~= "number" then return false, networkError(code) end
    if code == 400 or code == 401 or code == 403 then
        self:clearSession()
        return false, _("Session expired. Please log in again.")
    end
    if code ~= 200 or type(data) ~= "table" or not data.access_token then
        return false, errText(data, code)
    end
    self:storeSession(data)
    return true
end

function Api:ensureToken()
    if not self:isLoggedIn() then return false, _("Please log in first.") end
    local expires_at = tonumber(self:get("expires_at")) or 0
    if self:get("access_token") and expires_at - os.time() > 60 then return true end
    return self:refresh()
end

-- Authenticated REST call. Returns ok, data_or_error, status.
function Api:authed(method, path, body, prefer)
    local ok, err = self:ensureToken()
    if not ok then return false, err end
    local code, data = self:_send(method, path, body, self:get("access_token"), prefer)
    if code == 401 then
        local refreshed, refresh_err = self:refresh()
        if not refreshed then return false, refresh_err end
        code, data = self:_send(method, path, body, self:get("access_token"), prefer)
    end
    if type(code) ~= "number" then return false, networkError(code) end
    if code < 200 or code >= 300 then
        logger.warn("LexiconLoop:", method, path, code)
        return false, errText(data, code), code
    end
    return true, data, code
end

function Api:listWorkspaces()
    return self:authed("GET", "/rest/v1/workspaces?select=id,name&owner_id=eq." .. esc(self:get("user_id")) .. "&order=created_at")
end

function Api:listFolders(workspace_id)
    return self:authed("GET", "/rest/v1/folders?select=id,name&user_id=eq." .. esc(self:get("user_id"))
        .. "&workspace_id=eq." .. esc(workspace_id) .. "&order=created_at")
end

-- Asks Gemini (same model and prompt as the web app's Generate button) for meaning,
-- example sentence and CEFR level. Returns { meaning, sentence, cefrLevel } or nil, error.
function Api:generateDetails(word, source, target, api_key)
    if not api_key or api_key == "" then return nil, _("No Gemini API key set.") end
    local prompt = string.format([[You are a strict language-learning assistant.
SOURCE LANGUAGE: %s
TARGET LANGUAGE: %s
WORD: "%s"

Return only valid JSON with exactly these keys: meaning, sentence, and cefrLevel.
- meaning must be a concise translation or definition of WORD written ONLY in TARGET LANGUAGE (%s). Do not write it in SOURCE LANGUAGE, do not include both languages, and do not add labels.
- sentence must be one short, natural example sentence written ONLY in SOURCE LANGUAGE (%s) using WORD.
- cefrLevel must be exactly one of A1, A2, B1, B2, or C1. Estimate the CEFR level of WORD in SOURCE LANGUAGE.
Do not swap the languages. Do not return markdown or any extra text.]], source, target, word, target, source)
    local code, data = self:_send("POST", "/v1beta/models/gemini-2.5-flash-lite:generateContent", {
        contents = { { parts = { { text = prompt } } } },
        generationConfig = { responseMimeType = "application/json", temperature = 0.2 },
    }, nil, nil, "https://generativelanguage.googleapis.com", { ["x-goog-api-key"] = api_key })
    if type(code) ~= "number" then return nil, networkError(code) end
    if code ~= 200 or type(data) ~= "table" then return nil, errText(data, code) end

    local candidate = data.candidates and data.candidates[1]
    local part = candidate and candidate.content and candidate.content.parts and candidate.content.parts[1]
    local text = part and part.text
    if type(text) ~= "string" then return nil, _("Gemini returned no text.") end
    text = text:gsub("^%s*```%w*%s*", ""):gsub("%s*```%s*$", "")
    local decoded, parsed = pcall(JSON.decode, text)
    if not decoded or type(parsed) ~= "table" then return nil, _("Gemini returned invalid JSON.") end

    local meaning = type(parsed.meaning) == "string" and util.trim(parsed.meaning) or ""
    if meaning == "" then return nil, _("Gemini returned no meaning.") end
    local sentence = type(parsed.sentence) == "string" and util.trim(parsed.sentence) or nil
    local cefr
    for _i, level in ipairs({ "A1", "A2", "B1", "B2", "C1" }) do
        if parsed.cefrLevel == level then cefr = level end
    end
    return { meaning = meaning, sentence = sentence, cefrLevel = cefr }
end

-- fields: word, meaning, cefr_level, example_sentence, notes, source_language, target_language
-- Returns "added", word_id | "exists" or false, error.
function Api:addWord(fields)
    local user_id = self:get("user_id")
    local workspace_id = self:get("workspace_id")
    local folder_id = self:get("folder_id")
    if folder_id == "" then folder_id = nil end

    local operator = fields.word:find("[%%_%*\\]") and "eq." or "ilike."
    local ok, rows = self:authed("GET", "/rest/v1/words?select=id&workspace_id=eq." .. esc(workspace_id)
        .. "&word=" .. operator .. esc(fields.word) .. "&limit=1")
    if not ok then return false, rows end
    if type(rows) == "table" and #rows > 0 then return "exists" end

    local created
    ok, created = self:authed("POST", "/rest/v1/words", {
        user_id = user_id,
        workspace_id = workspace_id,
        folder_id = folder_id,
        word = fields.word,
        meaning = fields.meaning or "",
        cefr_level = fields.cefr_level,
        example_sentence = fields.example_sentence,
        source_language = fields.source_language,
        target_language = fields.target_language,
        notes = fields.notes,
    }, "return=representation")
    if not ok then return false, created end
    local word_id = type(created) == "table" and created[1] and created[1].id
    if not word_id then return false, _("The server did not return the new word.") end

    local progress_ok, progress_err = self:authed("POST", "/rest/v1/word_progress", {
        user_id = user_id,
        workspace_id = workspace_id,
        word_id = word_id,
        state = "new",
        stability = 0.25,
        difficulty = 5,
        due_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        reps = 0,
        lapses = 0,
    }, "return=minimal")
    if not progress_ok then
        -- Same rollback the app does, so no word is left without review progress.
        self:authed("DELETE", "/rest/v1/words?id=eq." .. esc(word_id))
        return false, progress_err
    end
    return "added", word_id
end

function Api:updateSentence(word_id, sentence)
    local ok, err = self:authed("PATCH", "/rest/v1/words?id=eq." .. esc(word_id), {
        example_sentence = sentence,
        updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }, "return=minimal")
    if not ok then return false, err end
    return true
end

return Api
