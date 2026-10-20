--[[--
Lexicon Loop: replaces "Add to vocabulary builder" in the dictionary popup with
"Add to Lexicon Loop app" and saves the word to the user's Lexicon Loop account.
]]

local Api = require("lexiconloop_api")
local Config = require("lexiconloop_config")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local util = require("util")
local TextViewer = require("ui/widget/textviewer")
local T = require("ffi/util").template
local _ = require("gettext")

local BUTTON_ID = "lexiconloop"

local LexiconLoop = WidgetContainer:extend{
    name = "lexiconloop",
    is_doc_only = false,
}

function LexiconLoop:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/lexiconloop.lua")
    self.api = Api:new(self.settings)
    self.ui.menu:registerToMainMenu(self)
    self.dict_button_registered = self:registerDictButton()
end

----------------------------------------------------------------------------------------------------
-- Small UI helpers
----------------------------------------------------------------------------------------------------

function LexiconLoop:notify(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout or 4 })
end

-- Shows a message, then runs fn (blocking network work) on the next tick.
function LexiconLoop:withBusy(text, fn)
    local message = InfoMessage:new{ text = text }
    UIManager:show(message)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        local ok, err = pcall(fn)
        UIManager:close(message)
        if not ok then self:notify(tostring(err), 6) end
    end)
end

function LexiconLoop:runOnline(fn)
    NetworkMgr:runWhenOnline(fn)
end

-- entries: { { label = "...", value = any, checked = bool }, ... }
function LexiconLoop:showChoice(title, entries, on_select)
    local item_table = {}
    local menu
    for _i, entry in ipairs(entries) do
        table.insert(item_table, {
            text = (entry.checked and "✓ " or "") .. entry.label,
            callback = function()
                UIManager:close(menu)
                on_select(entry.value, entry.label)
            end,
        })
    end
    menu = Menu:new{
        title = title,
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

----------------------------------------------------------------------------------------------------
-- Login / logout
----------------------------------------------------------------------------------------------------

function LexiconLoop:showLogin(on_done)
    local email_dialog
    email_dialog = InputDialog:new{
        title = _("Lexicon Loop e-mail"),
        input = self.settings:readSetting("email") or "",
        input_type = "text",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(email_dialog) end },
            { text = _("Next"), is_enter_default = true, callback = function()
                local email = util.trim(email_dialog:getInputText())
                UIManager:close(email_dialog)
                if email == "" then return end
                self:showPassword(email, on_done)
            end },
        }},
    }
    UIManager:show(email_dialog)
    email_dialog:onShowKeyboard()
end

function LexiconLoop:showPassword(email, on_done)
    local password_dialog
    password_dialog = InputDialog:new{
        title = T(_("Password for %1"), email),
        input = "",
        text_type = "password",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(password_dialog) end },
            { text = _("Log in"), is_enter_default = true, callback = function()
                local password = password_dialog:getInputText()
                UIManager:close(password_dialog)
                if password == "" then return end
                self:login(email, password, on_done)
            end },
        }},
    }
    UIManager:show(password_dialog)
    password_dialog:onShowKeyboard()
end

function LexiconLoop:login(email, password, on_done)
    self:runOnline(function()
        self:withBusy(_("Signing in..."), function()
            local ok, err = self.api:login(email, password)
            if not ok then
                self:notify(T(_("Login failed: %1"), err), 6)
                return
            end
            self:notify(_("Signed in. Now choose a workspace and folder."))
            -- The word goes to one workspace/folder for the whole session, so ask right away.
            self:chooseWorkspace(function()
                self:chooseFolder(on_done)
            end)
        end)
    end)
end

function LexiconLoop:confirmLogout(on_done)
    UIManager:show(ConfirmBox:new{
        text = _("Log out of Lexicon Loop?"),
        ok_text = _("Log out"),
        ok_callback = function()
            self.api:logout()
            if on_done then on_done() end
        end,
    })
end

----------------------------------------------------------------------------------------------------
-- Workspace / folder selection
----------------------------------------------------------------------------------------------------

function LexiconLoop:chooseWorkspace(on_done)
    self:runOnline(function()
        self:withBusy(_("Loading workspaces..."), function()
            local ok, rows = self.api:listWorkspaces()
            if not ok then self:notify(rows, 6) return end
            if #rows == 0 then self:notify(_("No workspace found for this account.")) return end
            local current = self.settings:readSetting("workspace_id")
            local entries = {}
            for _i, row in ipairs(rows) do
                table.insert(entries, { label = row.name, value = row.id, checked = row.id == current })
            end
            self:showChoice(_("Choose workspace"), entries, function(id, name)
                if id ~= current then
                    -- Folders belong to a workspace, so the old folder is no longer valid.
                    self.settings:delSetting("folder_id")
                    self.settings:delSetting("folder_name")
                end
                self.settings:saveSetting("workspace_id", id)
                self.settings:saveSetting("workspace_name", name)
                self.settings:flush()
                if on_done then on_done() end
            end)
        end)
    end)
end

function LexiconLoop:chooseFolder(on_done)
    local workspace_id = self.settings:readSetting("workspace_id")
    if not workspace_id then
        self:notify(_("Choose a workspace first."))
        return
    end
    self:runOnline(function()
        self:withBusy(_("Loading folders..."), function()
            local ok, rows = self.api:listFolders(workspace_id)
            if not ok then self:notify(rows, 6) return end
            local current = self.settings:readSetting("folder_id")
            local entries = { { label = _("Unsorted (no folder)"), value = "", checked = current == "" } }
            for _i, row in ipairs(rows) do
                table.insert(entries, { label = row.name, value = row.id, checked = row.id == current })
            end
            self:showChoice(_("Choose folder"), entries, function(id, name)
                self.settings:saveSetting("folder_id", id)
                self.settings:saveSetting("folder_name", name)
                self.settings:flush()
                if on_done then on_done() end
            end)
        end)
    end)
end

function LexiconLoop:isConfigured()
    return self.api:isLoggedIn()
        and self.settings:readSetting("workspace_id") ~= nil
        and self.settings:readSetting("folder_id") ~= nil
end

----------------------------------------------------------------------------------------------------
-- Main menu
----------------------------------------------------------------------------------------------------

function LexiconLoop:languageMenu(key, default)
    local items = {}
    for _i, language in ipairs(Config.languages) do
        table.insert(items, {
            text = language,
            checked_func = function() return (self.settings:readSetting(key) or default) == language end,
            callback = function()
                self.settings:saveSetting(key, language)
                self.settings:flush()
            end,
        })
    end
    return items
end

function LexiconLoop:addToMainMenu(menu_items)
    menu_items.lexiconloop = {
        text = _("Lexicon Loop"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return {
                {
                    text_func = function()
                        if self.api:isLoggedIn() then
                            return T(_("Signed in as %1"), self.settings:readSetting("email") or "?")
                        end
                        return _("Log in")
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        if self.api:isLoggedIn() then return end
                        self:showLogin(function() if touchmenu_instance then touchmenu_instance:updateItems() end end)
                    end,
                },
                {
                    text = _("Log out"),
                    enabled_func = function() return self.api:isLoggedIn() end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:confirmLogout(function() if touchmenu_instance then touchmenu_instance:updateItems() end end)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Workspace: %1"), self.settings:readSetting("workspace_name") or _("not set"))
                    end,
                    enabled_func = function() return self.api:isLoggedIn() end,
                    keep_menu_open = true,
                    separator = false,
                    callback = function(touchmenu_instance)
                        self:chooseWorkspace(function()
                            -- The folder list depends on the workspace, so ask for it again.
                            self:chooseFolder(function() if touchmenu_instance then touchmenu_instance:updateItems() end end)
                        end)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Folder: %1"), self.settings:readSetting("folder_name") or _("not set"))
                    end,
                    enabled_func = function()
                        return self.api:isLoggedIn() and self.settings:readSetting("workspace_id") ~= nil
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:chooseFolder(function() if touchmenu_instance then touchmenu_instance:updateItems() end end)
                    end,
                },
                {
                    text_func = function()
                        return self:getGeminiKey() ~= "" and _("Gemini API key: set") or _("Gemini API key: not set")
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        self:showGeminiKeyDialog(function() if touchmenu_instance then touchmenu_instance:updateItems() end end)
                    end,
                },
                {
                    text_func = function()
                        return T(_("Source language: %1"), self.settings:readSetting("source_language") or Config.default_source_language)
                    end,
                    keep_menu_open = true,
                    sub_item_table = self:languageMenu("source_language", Config.default_source_language),
                },
                {
                    text_func = function()
                        return T(_("Target language: %1"), self.settings:readSetting("target_language") or Config.default_target_language)
                    end,
                    keep_menu_open = true,
                    sub_item_table = self:languageMenu("target_language", Config.default_target_language),
                },
            }
        end,
    }
end

----------------------------------------------------------------------------------------------------
-- Dictionary popup button
----------------------------------------------------------------------------------------------------

function LexiconLoop:getGeminiKey()
    local key = self.settings:readSetting("gemini_api_key")
    if key and key ~= "" then return key end
    return Config.gemini_api_key
end

function LexiconLoop:showGeminiKeyDialog(on_done)
    local dialog
    dialog = InputDialog:new{
        title = _("Gemini API key (empty = use dictionary meaning)"),
        input = self.settings:readSetting("gemini_api_key") or "",
        input_type = "text",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local key = util.trim(dialog:getInputText())
                UIManager:close(dialog)
                if key == "" then self.settings:delSetting("gemini_api_key")
                else self.settings:saveSetting("gemini_api_key", key) end
                self.settings:flush()
                if on_done then on_done() end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- Plain-text definition of the dictionary entry shown in the popup (best effort).
function LexiconLoop:getDefinition(dict_popup)
    local result = dict_popup.results and dict_popup.results[dict_popup.dict_index or 1]
    local text = result and result.definition
    if type(text) ~= "string" then return "" end
    if util.htmlToPlainTextIfHtml then
        local ok, plain = pcall(util.htmlToPlainTextIfHtml, text)
        if ok and plain then text = plain end
    end
    text = text:gsub("<[^>]*>", " "):gsub("%s+", " ")
    text = util.trim(text)
    return #text > 300 and (text:sub(1, 300) .. "...") or text
end

-- The sentence around the looked-up word, cut at sentence punctuation (best effort).
function LexiconLoop:getSentence(word)
    local highlight = self.ui.highlight
    if not highlight or not highlight.getSelectedWordContext then return nil end
    local ok, previous, following = pcall(highlight.getSelectedWordContext, highlight, 25)
    if not ok then return nil end
    previous, following = previous or "", following or ""
    local selected = highlight.selected_text and highlight.selected_text.text
    selected = selected and util.cleanupSelectedText(selected) or word

    local start = 1
    for after in previous:gmatch("[%.%!%?]()%s") do start = after end
    previous = previous:sub(start)
    local stop = following:find("[%.%!%?]")
    if stop then following = following:sub(1, stop) end

    local sentence = (previous .. " " .. selected .. " " .. following)
    sentence = sentence:gsub("%s+([,%.;:!%?])", "%1"):gsub("%s+", " ")
    sentence = util.trim(sentence)
    if sentence == "" or sentence == word then return nil end
    return #sentence > 400 and sentence:sub(1, 400) or sentence
end

function LexiconLoop:addWordFromPopup(dict_popup, on_result)
    if not self:isConfigured() then
        self:notify(_("Lexicon Loop is not set up. Open Tools > Lexicon Loop to log in and choose a workspace and folder."), 7)
        return false
    end
    local word = dict_popup.lookupword
    local doc_props = dict_popup.ui and dict_popup.ui.doc_props
    local title = doc_props and doc_props.display_title
    local fields = {
        word = word,
        example_sentence = self:getSentence(word),
        notes = title and T(_("Book: %1"), title) or nil,
        source_language = self.settings:readSetting("source_language") or Config.default_source_language,
        target_language = self.settings:readSetting("target_language") or Config.default_target_language,
    }
    local definition = self:getDefinition(dict_popup)
    self:runOnline(function()
        self:withBusy(_("Saving to Lexicon Loop..."), function()
            -- Meaning and CEFR come from Gemini; without a key or on failure, use the
            -- dictionary definition shown in the popup so the meaning is never empty.
            local details, generate_err = self.api:generateDetails(
                word, fields.source_language, fields.target_language, self:getGeminiKey())
            if details then
                fields.meaning = details.meaning
                fields.cefr_level = details.cefrLevel
                -- The real sentence from the book beats an invented one.
                fields.example_sentence = fields.example_sentence or details.sentence
            else
                fields.meaning = definition
            end
            local result, err = self.api:addWord(fields)
            if result == "added" then fields.word_id = err; err = nil end
            if result == "added" and not details then
                self:notify(T(_("Saved with dictionary meaning (Gemini: %1)"), generate_err or "?"), 6)
            end
            if not result then
                self:notify(T(_("Could not save: %1"), err), 7)
                return
            end
            on_result(result, fields)
        end)
    end)
    return true
end

-- Simple read-only card with what was saved (or that the word already existed).
function LexiconLoop:showSummary(result, fields)
    local lines = {}
    local function add(label, value)
        if value and value ~= "" then table.insert(lines, label .. ": " .. value) end
    end
    if result == "exists" then
        table.insert(lines, _("Already in Lexicon Loop. Nothing was added."))
        table.insert(lines, "")
    end
    add(_("Word"), fields.word)
    if result ~= "exists" then
        add(_("Meaning"), fields.meaning)
        add(_("Level"), fields.cefr_level)
        add(_("Example"), fields.example_sentence)
        add(_("Languages"), fields.source_language .. " > " .. fields.target_language)
        add(_("Workspace"), self.settings:readSetting("workspace_name"))
        add(_("Folder"), self.settings:readSetting("folder_name"))
        add(_("Notes"), fields.notes)
    end
    local viewer
    local buttons
    if result == "added" and fields.word_id then
        buttons = {{
            { text = _("Generate sentence"), callback = function()
                self:regenerateSentence(fields, function()
                    UIManager:close(viewer)
                    self:showSummary(result, fields)
                end)
            end },
        }}
    end
    viewer = TextViewer:new{
        title = result == "exists" and _("Lexicon Loop") or _("Added to Lexicon Loop"),
        text = table.concat(lines, "\n\n"),
        width = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.6),
        buttons_table = buttons,
        add_default_buttons = true,
    }
    UIManager:show(viewer)
end

-- Replaces the saved example sentence (e.g. the one from the book) with a Gemini sentence.
function LexiconLoop:regenerateSentence(fields, on_done)
    local key = self:getGeminiKey()
    if not key or key == "" then
        self:notify(_("Set a Gemini API key first (Tools > Lexicon Loop)."), 5)
        return
    end
    self:runOnline(function()
        self:withBusy(_("Generating sentence..."), function()
            local details, err = self.api:generateDetails(fields.word, fields.source_language, fields.target_language, key)
            if not details or not details.sentence then
                self:notify(T(_("Could not generate: %1"), err or _("no sentence returned")), 6)
                return
            end
            local ok, update_err = self.api:updateSentence(fields.word_id, details.sentence)
            if not ok then
                self:notify(T(_("Could not save: %1"), update_err), 6)
                return
            end
            fields.example_sentence = details.sentence
            on_done()
        end)
    end)
end

local BUTTON_TEXT = _("Add to Lexicon Loop app")

-- Tap handler shared by both registration styles below.
function LexiconLoop:onButtonTapped(dict_popup)
    if dict_popup._lexiconloop_busy then return end
    dict_popup._lexiconloop_busy = true
    local started = self:addWordFromPopup(dict_popup, function(result, fields)
        -- The dictionary window is done; show what was saved instead.
        dict_popup:onClose()
        self:showSummary(result, fields)
    end)
    -- Allow another tap if nothing was sent or the save failed.
    UIManager:scheduleIn(2, function() dict_popup._lexiconloop_busy = false end)
    if not started then dict_popup._lexiconloop_busy = false end
end

-- Current KOReader: plugins register dictionary popup buttons with the dictionary module.
function LexiconLoop:registerDictButton()
    local dictionary = self.ui.dictionary
    if not dictionary or not dictionary.addToDictButtons then return false end
    dictionary:addToDictButtons({
        id = BUTTON_ID,
        menu_text = _("Lexicon Loop"),
        text = BUTTON_TEXT,
        insert_first = true,
        font_bold = false,
        auto_row_style_width_min_row_size = 2,
        auto_row_style_width_ratio = 0.7,
        callback = function(dict_popup) self:onButtonTapped(dict_popup) end,
    })
    return true
end

-- Older KOReader: the popup sends DictButtonsReady with the button rows.
function LexiconLoop:onDictButtonsReady(dict_popup, buttons)
    if self.dict_button_registered or dict_popup.is_wiki_fullpage then return end
    table.insert(buttons, 1, {{
        id = BUTTON_ID,
        text = BUTTON_TEXT,
        font_bold = false,
        callback = function() self:onButtonTapped(dict_popup) end,
    }})
end

return LexiconLoop
