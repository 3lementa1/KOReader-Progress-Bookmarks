-- Progress Bookmarks for Bookshelf Cover View and Spine View.
-- Install as koreader/patches/2-bookshelf-progress-bookmark.lua.
-- The patch adds the renderer and top-level Bookshelf settings without changing plugin files.

if rawget(_G, "_bookshelf_progress_bookmark_patch") then return end
_G._bookshelf_progress_bookmark_patch = true

-- Keep PATCH_VERSION aligned with the GitHub release tag and downloadable asset.
local PATCH_VERSION = "1.0.0"
local PATCH_FILE_NAME = "2-bookshelf-progress-bookmark.lua"
local PATCH_RELEASE_API = "https://api.github.com/repos/3lementa1/KOReader-Progress-Bookmarks/releases/latest"
local PATCH_RELEASE_ASSET_PREFIX = "https://github.com/3lementa1/KOReader-Progress-Bookmarks/releases/download/"

local Blitbuffer = require("ffi/blitbuffer")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")
local OverlapGroup = require("ui/widget/overlapgroup")
local CenterContainer = require("ui/widget/container/centercontainer")
local TextWidget = require("ui/widget/textwidget")
local Font = require("ui/font")
local logger = require("logger")
local Device = require("device")
local Screen = Device.screen
local floor, max, min, sqrt = math.floor, math.max, math.min, math.sqrt

local PAGE_THICKNESS = 1
local PAGE_SPACING = 3
local PAGE_STEP = PAGE_THICKNESS + PAGE_SPACING
local PAGE_BINDING_GAP = 4
local MAX_PAGE_LINES = 6
local DEFAULT_PAGES_PER_LINE = 200
local MIN_PAGES_PER_LINE = 25
local MAX_PAGES_PER_LINE = 5000
local SPINE_WIDTH_PRESETS = {
    cover = {
        min = 40, max = 200, default = "medium",
        values = { thin = 85, medium = 100, thick = 135 },
    },
    spine = {
        min = 40, max = 85, default = "thick",
        values = { thin = 70, medium = 80, thick = 85 },
    },
}
-- Match the original spine-text perspective shear.
local SPINE_TEXT_SHEAR = 0.30
local Store
local original_require = require

-- Settings access: use Bookshelf's own persistent store, with local defaults
-- so the renderer remains inert if Bookshelf is unavailable.
local function settingsStore()
    if not Store then
        local ok, result = pcall(original_require, "lib/bookshelf_settings_store")
        if ok then Store = result end
    end
    return Store
end

local function setting(key, default)
    local store = settingsStore()
    if store and store.read then
        local ok, value = pcall(store.read, key, default)
        if ok and value ~= nil then return value end
    end
    return default
end

local function saveSetting(key, value)
    local store = settingsStore()
    if store and store.save then
        local ok, err = pcall(store.save, key, value)
        if ok then return true end
        logger.warn("Progress Bookmarks: setting save failed", err)
    end
    return false
end

local function modeKey(mode, key)
    local suffix = key:gsub("^bookcraft_", "")
    suffix = suffix:gsub("^progress_bookmarks_spine_", "")
    return "bookcraft_" .. mode .. "_" .. suffix
end

local function modeSetting(mode, key, default)
    local value = setting(modeKey(mode, key), nil)
    if value ~= nil then return value end
    -- Read the former shared preference until this mode gets its own value.
    return setting(key, default)
end

local function modeSaveSetting(mode, key, value)
    return saveSetting(modeKey(mode, key), value)
end

-- Compare numeric release tags, accepting the usual leading "v" prefix.
local function versionIsNewer(remote, current)
    local function parts(version)
        local result = {}
        for part in tostring(version):gsub("^v", ""):gmatch("([^.]+)") do
            local number = tonumber(part)
            if not number then return nil end
            result[#result + 1] = number
        end
        return #result > 0 and result or nil
    end
    local latest_parts, current_parts = parts(remote), parts(current)
    if not latest_parts or not current_parts then return nil end
    for i = 1, max(#latest_parts, #current_parts) do
        local latest, installed = latest_parts[i] or 0, current_parts[i] or 0
        if latest ~= installed then return latest > installed end
    end
    return false
end

-- Read bounded HTTPS responses through KOReader's configured LuaSocket layer.
local function requestText(url, accept, limit)
    local ok_modules, http, ltn12, socket, socketutil = pcall(function()
        return original_require("socket.http"), original_require("ltn12"),
            original_require("socket"), original_require("socketutil")
    end)
    if not ok_modules then return nil, "network modules unavailable" end
    local chunks, total = {}, 0
    local sink = function(chunk)
        if chunk then
            total = total + #chunk
            if total > limit then return nil, "response too large" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    local ok_request, code, headers, status = pcall(function()
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, 120)
        local response_code, response_headers, response_status = socket.skip(1, http.request{
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "KOReader-Progress-Bookmarks/" .. PATCH_VERSION,
                ["Accept"] = accept,
            },
            sink = sink,
            redirect = true,
        })
        socketutil:reset_timeout()
        return response_code, response_headers, response_status
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not ok_request then return nil, tostring(code) end
    if tonumber(code) ~= 200 then return nil, status or ("HTTP " .. tostring(code)) end
    if total > limit then return nil, "response too large" end
    return table.concat(chunks), headers
end

local function latestPatchRelease()
    local body, err = requestText(PATCH_RELEASE_API,
        "application/vnd.github+json", 1024 * 1024)
    if not body then
        -- Bookshelf's shared helper falls back to curl on devices where
        -- LuaSocket cannot complete GitHub's TLS handshake.
        local ok_http, Http = pcall(original_require, "lib/bookshelf_http")
        if ok_http and Http and Http.getJSON then
            local release = Http.getJSON(PATCH_RELEASE_API, {
                user_agent = "KOReader-Progress-Bookmarks/" .. PATCH_VERSION,
                accept = "application/vnd.github+json",
                curl_max_time = 20,
            })
            if release then return release end
        end
        return nil, err
    end
    local ok_json, release = pcall(original_require("json").decode, body)
    if not ok_json or type(release) ~= "table" then return nil, "invalid GitHub response" end
    return release
end

-- Validate the release asset before it can replace the running user patch.
local function validatePatchSource(source, release_version)
    if type(source) ~= "string" or #source > 2 * 1024 * 1024 then
        return nil, "download is empty or too large"
    end
    if not source:find("_bookshelf_progress_bookmark_patch", 1, true) then
        return nil, "download is not the Progress Bookmarks patch"
    end
    if not source:find('local PATCH_FILE_NAME = "' .. PATCH_FILE_NAME .. '"', 1, true) then
        return nil, "download does not match this patch filename"
    end
    local source_version = source:match('local PATCH_VERSION%s*=%s*"([^"]+)"')
    if not source_version or source_version ~= release_version then
        return nil, "release tag and patch version do not match"
    end
    local compile, compile_error = loadstring(source, "@" .. PATCH_FILE_NAME)
    if not compile then return nil, "Lua syntax check failed: " .. tostring(compile_error) end
    return source
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function downloadPatchAsset(url, temp_path)
    if url:sub(1, #PATCH_RELEASE_ASSET_PREFIX) ~= PATCH_RELEASE_ASSET_PREFIX then
        return nil, "release asset URL is outside the expected GitHub repository"
    end
    local body, err = requestText(url, "application/octet-stream", 2 * 1024 * 1024)
    if body then return body end

    -- Use curl only as a fallback for KOReader builds where LuaSocket TLS fails.
    pcall(os.remove, temp_path)
    local command = string.format("curl -fLsS --connect-timeout 10 --max-time 120 --max-filesize 2097152 -o %s %s",
        shellQuote(temp_path), shellQuote(url))
    local ok_curl, result = pcall(os.execute, command)
    local downloaded = ok_curl and (result == true or result == 0)
    local fallback = downloaded and readFile(temp_path) or nil
    pcall(os.remove, temp_path)
    return fallback, fallback and nil or err or "download failed"
end

local function installPatchSource(source)
    local DataStorage = original_require("datastorage")
    local patches_dir = DataStorage:getPatchesDir()
    local target = patches_dir .. "/" .. PATCH_FILE_NAME
    local temp = target .. ".download"
    local old_source = readFile(target)
    if not old_source then return nil, "installed patch file was not found" end

    local temp_file = io.open(temp, "wb")
    if not temp_file then return nil, "could not create temporary update file" end
    local wrote, write_error = temp_file:write(source)
    local closed, close_error = temp_file:close()
    if not wrote or not closed then
        pcall(os.remove, temp)
        return nil, tostring(write_error or close_error or "could not write update")
    end

    local backup = target .. ".backup-" .. PATCH_VERSION .. "-" .. tostring(os.time())
    local backup_file = io.open(backup, "wb")
    if not backup_file then
        pcall(os.remove, temp)
        return nil, "could not create a backup of the installed patch"
    end
    local backed_up = backup_file:write(old_source)
    local backup_closed = backup_file:close()
    if not backed_up or not backup_closed then
        pcall(os.remove, temp)
        pcall(os.remove, backup)
        return nil, "could not finish backing up the installed patch"
    end

    local renamed, rename_error = os.rename(temp, target)
    if not renamed then
        -- POSIX rename replaces atomically; this fallback accommodates builds
        -- whose filesystem refuses to rename over an existing file.
        local removed = os.remove(target)
        if removed then renamed, rename_error = os.rename(temp, target) end
        if not renamed then
            local restore_file = io.open(target, "wb")
            if restore_file then restore_file:write(old_source); restore_file:close() end
            pcall(os.remove, temp)
            return nil, tostring(rename_error or "could not replace the patch file")
        end
    end
    return backup
end

local function spineWidth(total_w, mode)
    -- Keep Spine View narrower than Cover View so face-out books do not crowd neighbours.
    local mode_name = mode or "cover"
    local config = SPINE_WIDTH_PRESETS[mode_name] or SPINE_WIDTH_PRESETS.cover
    local default_width = config.values[config.default]
    local preset = modeSetting(mode_name, "progress_bookmarks_spine_size", nil)
    local tenths_percent
    if preset then
        tenths_percent = tonumber(modeSetting(mode_name,
            "progress_bookmarks_spine_thickness_" .. preset, config.values[preset] or default_width))
    else
        -- Honour the former single-value setting until the user selects a preset.
        local legacy_width = setting(modeKey(mode_name, "progress_bookmarks_spine_thickness"), nil)
        if legacy_width == nil then legacy_width = setting("progress_bookmarks_spine_thickness", nil) end
        if legacy_width ~= nil then
            tenths_percent = tonumber(legacy_width)
        else
            tenths_percent = default_width
        end
    end
    tenths_percent = max(config.min, min(config.max, tenths_percent or default_width))
    local ratio = tenths_percent / 1000
    return max(2, floor(total_w * ratio / (1 + ratio) + 0.5))
end

-- Scale the configured base font with the spine; 100 dp is the reference cover width.
local function spineTextFontSize(base_size, spine_w)
    local reference_w = spineWidth(Screen:scaleBySize(100))
    local scale = spine_w / max(1, reference_w)
    return max(4, min(40, floor(base_size * scale + 0.5)))
end

-- The face-out binding uses an elliptical cut; Cover View keeps its existing curve.
local function bindingTrim(label_y, cut_h, spine_w, py, spine_mode)
    local row = py - label_y
    if spine_mode then
        local t = max(0, min(1, row / cut_h))
        return floor(sqrt(max(0, 1 - t * t)) * spine_w)
    end
    return floor(((cut_h - row) / cut_h) ^ 0.6 * spine_w)
end

-- Place each page start a small grey gutter to the right of the binding edge.
local function pageBindingLeft(label_x, label_y, cut_h, spine_w, py, spine_mode)
    local trim = bindingTrim(label_y, cut_h, spine_w, py, spine_mode)
    return label_x + spine_w - trim + PAGE_BINDING_GAP
end

-- Use the per-view pages-per-line setting, retaining the existing six-line cap.
local function pageLineCount(book, mode)
    local pages = book and (tonumber(book.page_count) or tonumber(book._badge_pages)) or 5
    local pages_per_line = tonumber(modeSetting(mode or "cover", "bookcraft_pages_per_line",
        DEFAULT_PAGES_PER_LINE)) or DEFAULT_PAGES_PER_LINE
    pages_per_line = max(1, min(MAX_PAGES_PER_LINE, floor(pages_per_line + 0.5)))
    return max(1, min(MAX_PAGE_LINES, floor((pages + pages_per_line - 1) / pages_per_line)))
end

-- Read page counts from filenames or Bookshelf's progress repository.
local function ensurePageCount(book)
    if not book or book.page_count or not book.filepath then return end
    local filename = book.filepath:match("([^/]+)$") or ""
    local pages = filename:match("[Pp]%((%d+)%)") or filename:match("[Pp](%d+)")
    if pages then
        book.page_count = tonumber(pages)
        return
    end
    local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
    if ok and Repo and Repo.readProgress then
        local read_ok, _progress, _status, _reason, repo_pages = pcall(Repo.readProgress, book.filepath)
        if read_ok and repo_pages then book.page_count = repo_pages end
    end
end

-- Draw the shaded binding behind the cover and page block.
local function drawSpineBackground(bb, label_x, label_y, label_h,
        cover_x, cover_y, cover_w, cover_h, cut_h_top, spine_w, spine_mode)
    if label_h <= 0 then return end
    local cut_h_bot = floor(spine_w * 0.5774)
    local bg = Blitbuffer.new(spine_w, label_h, bb:getType())
    bg:blitFrom(bb, 0, 0, label_x, label_y, spine_w, label_h)
    if cover_w > 0 and cover_h > 0 then
        local sample_w = min(spine_w, cover_w)
        local src = Blitbuffer.new(spine_w, cover_h, bb:getType())
        src:paintRect(0, 0, spine_w, cover_h, Blitbuffer.COLOR_GRAY_4)
        src:blitFrom(bb, spine_w - sample_w, 0, cover_x, cover_y, sample_w, cover_h)
        local stretched = src:scale(spine_w, label_h)
        src:free()
        bb:blitFrom(stretched, label_x, label_y, 0, 0, spine_w, label_h)
        stretched:free()
    else
        bb:paintRect(label_x, label_y, spine_w, label_h, Blitbuffer.COLOR_GRAY_4)
    end
    bb:blendRectRGB32(label_x, label_y, spine_w, label_h,
        Blitbuffer.ColorRGB32(0, 0, 0, 150))
    for row = 0, max(cut_h_top, cut_h_bot) - 1 do
        if row < cut_h_top and cut_h_top > 0 then
            local trim = bindingTrim(label_y, cut_h_top, spine_w, label_y + row, spine_mode)
            if trim > 0 then
                bb:blitFrom(bg, label_x + spine_w - trim, label_y + row,
                    spine_w - trim, row, trim, 1)
            end
        end
        if row < cut_h_bot and cut_h_bot > 0 then
            local t = (cut_h_bot - row) / cut_h_bot
            local trim = floor((1 - (1 - t) ^ 0.6) * spine_w)
            if trim > 0 then
                local dest_y = label_y + label_h - 1 - row
                bb:blitFrom(bg, label_x, dest_y, 0, dest_y - label_y, trim, 1)
            end
        end
    end
    -- Fine, low-contrast flecks suggest woven cloth on the exposed binding.
    for py = label_y, label_y + label_h - 1, 3 do
        local phase = floor((py - label_y) / 3) % 2
        for px = phase, spine_w - 1, 3 do
            bb:blendRectRGB32(label_x + px, py, 1, 1,
                Blitbuffer.ColorRGB32(0, 0, 0, 24))
        end
    end
    bg:free()
end

-- Render the selected book metadata over the shaded binding.
local function drawSpineText(bb, label_x, label_y, label_h, book, cut_h_top, spine_w, spine_mode)
    local mode = spine_mode and "spine" or "cover"
    if not book or modeSetting(mode, "progress_bookmarks_spine_text_enabled", true) == false then return end
    local title, author, series_index
    if modeSetting(mode, "progress_bookmarks_spine_show_title", true) then
        title = book.title or book.text or book.filepath
        if title and title ~= "" then
            title = title:match("([^/\\]+)$") or title
            title = title:gsub("%.%w+$", "")
            title = tostring(title)
        else
            title = nil
        end
    end
    if modeSetting(mode, "progress_bookmarks_spine_show_author", true) then
        author = book.author
        if (not author or author == "") and type(book.authors) == "table" then
            author = table.concat(book.authors, ", ")
        elseif (not author or author == "") and type(book.authors) == "string" then
            author = book.authors
        end
        if author then author = tostring(author) end
        if author == "" then author = nil end
    end
    if modeSetting(mode, "progress_bookmarks_spine_show_series_index", true) then
        series_index = book.series_num
        if series_index == nil or series_index == "" then
            series_index = book.series_index
        end
        if series_index ~= nil then series_index = tostring(series_index) end
        if series_index == "" then series_index = nil end
    end
    if not title and not author and not series_index then return end
    local cut_h_bot = floor(spine_w * 0.5774)
    local match_cover_font = modeSetting(mode, "progress_bookmarks_spine_match_cover_font", nil)
    if match_cover_font == nil then
        -- Honour the previous font-source choice for existing configurations.
        match_cover_font = modeSetting(mode, "progress_bookmarks_spine_font_source", "spine_view") == "user"
    end
    local font_name
    if match_cover_font then
        font_name = modeSetting("cover", "progress_bookmarks_spine_font", "cfont")
    elseif modeSetting(mode, "progress_bookmarks_spine_font", "cfont") ~= "cfont" then
        font_name = modeSetting(mode, "progress_bookmarks_spine_font", "cfont")
    else
        local ok_book_fonts, BookFonts = pcall(original_require, "lib/bookshelf_fonts")
        if ok_book_fonts and BookFonts and BookFonts.getUIFontFace then
            local ok_face, ui_face = pcall(BookFonts.getUIFontFace)
            font_name = ok_face and ui_face or "cfont"
        else
            font_name = "cfont"
        end
    end
    local base_font_size = floor(tonumber(modeSetting(mode, "progress_bookmarks_spine_font_size", 7)) or 7)
    base_font_size = max(6, min(20, base_font_size))
    local font_size = spineTextFontSize(base_font_size, spine_w)
    local text_color = modeSetting(mode, "progress_bookmarks_spine_font_color", "dark_gray")
    local ink, shadow = 255, 0
    if text_color == "light_gray" then
        ink, shadow = 210, 0
    elseif text_color == "dark_gray" then
        ink, shadow = 128, 255
    elseif text_color == "black" then
        ink, shadow = 0, 255
    end
    local function getFace(size)
        local ok_face, face = pcall(Font.getFace, Font, font_name, size)
        if ok_face and face then return face end
        font_name = "cfont"
        return Font:getFace(font_name, size)
    end
    local function makeText(text, size, max_width)
        if not text or max_width < 1 then return nil end
        return TextWidget:new{
            text = text, face = getFace(size), fgcolor = Blitbuffer.COLOR_WHITE,
            max_width = max_width, truncate_with_ellipsis = true, padding = 0,
        }
    end
    -- Reserve space at the spine foot for the series index.
    local text_start = cut_h_top + 2
    local text_end = label_h - cut_h_bot - 2
    local index_size = max(5, floor(font_size * 1.20 + 0.5))
    -- Longer indices run in the title direction so they fit within the binding.
    local index_digits = series_index and series_index:gsub("%D", "") or ""
    local rotate_index = #index_digits >= 2
    local index_run = rotate_index and max(1, label_h - cut_h_top - cut_h_bot - 4) or spine_w
    local index_widget = makeText(series_index, index_size, index_run)
    while rotate_index and index_widget and index_widget:getSize().h > spine_w and index_size > 4 do
        index_widget:free()
        index_size = index_size - 1
        index_widget = makeText(series_index, index_size, index_run)
    end
    if rotate_index and index_widget and index_widget:getSize().h > spine_w then
        index_widget:free()
        index_widget = nil
    end
    local index_height = index_widget and (rotate_index
        and index_widget:getSize().w or index_widget:getSize().h) or 0
    if index_widget then text_end = text_end - index_height - 2 end
    local run_len = max(0, text_end - text_start)
    local tmp = Blitbuffer.new(label_h, spine_w, bb:getType())
    tmp:paintRect(0, 0, label_h, spine_w, Blitbuffer.COLOR_BLACK)
    local text_was_drawn = false

    if run_len > 1 and (title or author) then
        local title_size = font_size
        -- Leave room after the title for the smaller author text.
        local title_run = author and max(1, floor(run_len * 0.70)) or run_len
        local title_widget = makeText(title, title_size, title_run)
        while title_widget and title_widget:getSize().h > spine_w and title_size > 4 do
            title_widget:free()
            title_size = title_size - 1
            title_widget = makeText(title, title_size, title_run)
        end
        local title_widgets = title_widget and { title_widget } or {}
        if title_widget and modeSetting(mode, "progress_bookmarks_spine_overflow", "truncate") == "second_line"
                and title_widget.isTruncated and title_widget:isTruncated() then
            local split_at
            for i = 1, #title do
                if title:sub(i, i) == " " then
                    local prefix = title:sub(1, i - 1):gsub("%s+$", "")
                    local probe = makeText(prefix, title_size, title_run)
                    local fits = probe and not (probe.isTruncated and probe:isTruncated())
                    if probe then probe:free() end
                    if prefix ~= "" and fits then split_at = i end
                end
            end
            if split_at then
                title_widget:free()
                local first = title:sub(1, split_at - 1):gsub("%s+$", "")
                local rest = title:sub(split_at + 1):gsub("^%s+", "")
                local first_widget = makeText(first, title_size, title_run)
                local rest_widget = makeText(rest, title_size, title_run)
                if first_widget and rest_widget
                        and first_widget:getSize().h + rest_widget:getSize().h <= spine_w then
                    title_widgets = { first_widget, rest_widget }
                else
                    if first_widget then first_widget:free() end
                    if rest_widget then rest_widget:free() end
                    title_widgets = { makeText(title, title_size, title_run) }
                end
            end
        end

        local line_h = 0
        local title_width = 0
        for _, widget in ipairs(title_widgets) do
            line_h = max(line_h, widget:getSize().h)
            title_width = max(title_width, widget:getSize().w)
        end
        local first_line_y = max(0, floor((spine_w - line_h * #title_widgets) / 2))
        local author_y = floor((spine_w - line_h) / 2)
        local author_size = max(3, title_size - 3)
        local has_title = #title_widgets > 0
        local min_gap = max(1, floor(title_size * 0.35))
        local reserved_gap = min(min_gap,
            max(0, floor((run_len - title_width - 1) / 3)))
        local author_widget
        if author then
            author_widget = makeText(author, author_size,
                max(1, run_len - title_width - 3 * reserved_gap))
        end
        local author_width = author_widget and author_widget:getSize().w or 0
        local gap = 0
        local sequence_x = text_start
        local author_x = text_start
        if has_title and author_width > 0 then
            -- Distribute all remaining room evenly across the two margins and title-author gap.
            gap = floor(max(0, run_len - title_width - author_width) / 3)
            sequence_x = text_start + gap
            author_x = sequence_x + title_width + gap
        elseif has_title then
            sequence_x = text_start + floor(max(0, run_len - title_width) / 2)
        elseif author_width > 0 then
            author_x = text_start + floor(max(0, run_len - author_width) / 2)
        end
        for i, widget in ipairs(title_widgets) do
            local size = widget:getSize()
            local line_y = first_line_y + (i - 1) * line_h
            local centered = CenterContainer:new{
                dimen = Geom:new{ w = size.w, h = line_h }, widget,
            }
            centered:paintTo(tmp, sequence_x, line_y)
            centered:free()
            if i == #title_widgets then
                author_y = line_y
            end
            text_was_drawn = true
        end
        if author_widget then
            local size = author_widget:getSize()
            local author_line_h = line_h > 0 and line_h or size.h
            local author_line_y = line_h > 0 and author_y
                or floor((spine_w - size.h) / 2)
            local centered = CenterContainer:new{
                dimen = Geom:new{ w = size.w, h = author_line_h }, author_widget,
            }
            centered:paintTo(tmp, author_x, author_line_y)
            centered:free()
            text_was_drawn = true
        end
    elseif run_len > 1 and author then
        local author_widget = makeText(author, max(4, font_size - 3), run_len)
        if author_widget then
            local size = author_widget:getSize()
            local y_pos = floor((spine_w - size.h) / 2)
            local centered = CenterContainer:new{
                dimen = Geom:new{ w = size.w, h = size.h }, author_widget,
            }
            centered:paintTo(tmp, text_start + floor(max(0, run_len - size.w) / 2), y_pos)
            centered:free()
            text_was_drawn = true
        end
    end

    -- Follow Bookshelf's selected spine direction for both rendered text styles.
    local rotated
    if text_was_drawn then
        local sheared = Blitbuffer.new(label_h, spine_w, bb:getType())
        sheared:paintRect(0, 0, label_h, spine_w, Blitbuffer.COLOR_BLACK)
        for row = 0, spine_w - 1 do
            local offset = floor((row - spine_w / 2) * -SPINE_TEXT_SHEAR)
            local src_x = max(0, -offset)
            local dst_x = max(0, offset)
            local copy_w = label_h - math.abs(offset)
            if copy_w > 0 then
                sheared:blitFrom(tmp, dst_x, row, src_x, row, copy_w, 1)
            end
        end
        local text_direction = setting("spine_text_direction", "top_down")
        rotated = sheared:rotatedCopy(text_direction == "bottom_up" and 90 or 270)
        sheared:free()
    end
    tmp:free()
    local function spineTextBounds(py)
        local first_px, last_px = 0, spine_w
        if py < cut_h_top then
            local trim = bindingTrim(label_y, cut_h_top, spine_w, label_y + py, spine_mode)
            last_px = min(last_px, spine_w - trim)
        end
        local bottom_row = label_h - 1 - py
        if bottom_row < cut_h_bot then
            local t = (cut_h_bot - bottom_row) / cut_h_bot
            local trim = floor((1 - (1 - t) ^ 0.6) * spine_w)
            first_px = max(first_px, trim)
        end
        return first_px, last_px
    end
    -- Clip to the binding's top and bottom cut profiles before blending text.
    -- Preserve antialiased coverage and a subtle offset for contrast.
    if rotated then
        for py = 0, label_h - 1 do
            local first_px, last_px = spineTextBounds(py)
            local shadow_first, shadow_last = spine_w, 0
            if py + 1 < label_h then
                shadow_first, shadow_last = spineTextBounds(py + 1)
            end
            for px = 0, spine_w - 1 do
                local coverage = rotated:getPixel(px, py):getColor8().a
                if px >= first_px and px < last_px and coverage > 20 then
                    if coverage > 64 and px + 1 >= shadow_first
                            and px + 1 < shadow_last and py + 1 < label_h then
                        local shadow_alpha = floor(coverage * 0.4)
                        bb:blendRectRGB32(label_x + px + 1, label_y + py + 1, 1, 1,
                            Blitbuffer.ColorRGB32(shadow, shadow, shadow, shadow_alpha))
                    end
                    local ink_alpha = min(255, 80 + floor(coverage * 175 / 255))
                    bb:blendRectRGB32(label_x + px, label_y + py, 1, 1,
                        Blitbuffer.ColorRGB32(ink, ink, ink, ink_alpha))
                end
            end
        end
        rotated:free()
    end

    if index_widget then
        local index_y = label_y + label_h - cut_h_bot - index_height - 2
        local index_buffer
        local draw_x, draw_y, draw_w, draw_h
        if rotate_index then
            local size = index_widget:getSize()
            local horizontal = Blitbuffer.new(size.w, size.h, bb:getType())
            horizontal:paintRect(0, 0, size.w, size.h, Blitbuffer.COLOR_BLACK)
            index_widget:paintTo(horizontal, 0, 0)
            index_buffer = horizontal:rotatedCopy(
                setting("spine_text_direction", "top_down") == "bottom_up" and 90 or 270)
            horizontal:free()
            index_widget:free()
            draw_w, draw_h = index_buffer:getWidth(), index_buffer:getHeight()
            draw_x = label_x + floor((spine_w - draw_w) / 2)
            draw_y = index_y
        else
            index_buffer = Blitbuffer.new(spine_w, index_height, bb:getType())
            index_buffer:paintRect(0, 0, spine_w, index_height, Blitbuffer.COLOR_BLACK)
            local centered = CenterContainer:new{
                dimen = Geom:new{ w = spine_w, h = index_height }, index_widget,
            }
            centered:paintTo(index_buffer, 0, 0)
            centered:free()
            draw_x, draw_y, draw_w, draw_h = label_x, index_y, spine_w, index_height
        end
        for py = 0, index_height - 1 do
            for px = 0, draw_w - 1 do
                local coverage = index_buffer:getPixel(px, py):getColor8().a
                if coverage > 20 then
                    if coverage > 64 and px + 1 < draw_w and py + 1 < draw_h then
                        local shadow_alpha = floor(coverage * 0.4)
                        bb:blendRectRGB32(draw_x + px + 1, draw_y + py + 1, 1, 1,
                            Blitbuffer.ColorRGB32(shadow, shadow, shadow, shadow_alpha))
                    end
                    local ink_alpha = min(255, 80 + floor(coverage * 175 / 255))
                    bb:blendRectRGB32(draw_x + px, draw_y + py, 1, 1,
                        Blitbuffer.ColorRGB32(ink, ink, ink, ink_alpha))
                end
            end
        end
        index_buffer:free()
    end
end

-- Draw the opaque paper block, curved binding edge, and page rules.
local function drawPages(bb, x, y, w, book, spine_w, spine_mode, num_lines)
    local page_thick, page_gap = PAGE_THICKNESS, PAGE_SPACING
    local line_step = page_thick + page_gap
    local strip_w, label_x, cover_y = spine_w, x, y
    local l_total = num_lines * line_step
    local label_y = cover_y - l_total
    local cut_h_top = l_total
    -- Match the page-side binding contour to the selected view's spine curve.
    local function spineEdgeAt(py)
        local trim = bindingTrim(label_y, cut_h_top, strip_w, py, spine_mode)
        return label_x + strip_w - trim
    end
    -- Keep the curved page starts four pixels right of the spine at each row.
    local function pageLeftAt(py)
        return pageBindingLeft(label_x, label_y, cut_h_top, strip_w, py, spine_mode)
    end
    -- The top rule anchors Cover View; Spine View uses the cover's vertical
    -- outer edge for both the paper fill and each page rule.
    local top_line_y = cover_y - page_thick - page_gap
        - (num_lines - 1) * line_step
    local top_line_start = pageLeftAt(top_line_y)
    local cover_top_right = x + w
    local page_line_length
    if not spine_mode then
        -- Cover View uses the top rule as its established length reference.
        page_line_length = max(1, cover_top_right - 2 - top_line_start)
    end

    -- Keep the back board aligned with the top page line; Spine View leaves a
    -- small inset at the outer edge to reinforce the cover's perspective.
    local back_start_x = pageLeftAt(label_y)
    local back_width
    if spine_mode then
        back_width = max(1, cover_top_right - back_start_x - 2)
    else
        local top_line_length = max(1, cover_top_right - 2 - top_line_start)
        back_width = max(1, top_line_length + 2)
    end
    bb:paintRect(back_start_x, label_y - 2, back_width, 2, Blitbuffer.COLOR_BLACK)

    -- Shade the four-pixel gutter between the angled binding edge and paper.
    for py = label_y, cover_y - 1 do
        local spine_edge = spineEdgeAt(py)
        local left_edge = pageLeftAt(py)
        local right_edge
        if spine_mode then
            right_edge = cover_top_right
        else
            right_edge = left_edge + page_line_length
        end
        local gutter_width = max(0, left_edge - spine_edge)
        if gutter_width > 0 then
            bb:paintRect(left_edge - gutter_width, py, gutter_width, 1,
                Blitbuffer.COLOR_GRAY_4)
        end
        bb:paintRect(left_edge, py, max(1, right_edge - left_edge), 1,
            Blitbuffer.COLOR_WHITE)
        bb:paintRect(left_edge, py, 1, 1, Blitbuffer.COLOR_GRAY_4)
    end

    -- Cover-view rules keep equal lengths; face-out rules reach the cover edge.
    for i = 0, num_lines - 1 do
        local by = cover_y - page_thick - page_gap - i * line_step
        local line_color = (i == num_lines - 1)
            and Blitbuffer.COLOR_GRAY_2 or Blitbuffer.COLOR_BLACK
        local left_edge = pageLeftAt(by)
        local rule_length
        if spine_mode then
            rule_length = max(1, cover_top_right - left_edge)
        else
            rule_length = page_line_length
        end
        bb:paintRect(left_edge, by, rule_length,
            page_thick, line_color)
    end
end

-- Resolve normalized reading progress and status from Bookshelf.
local function currentProgress(book)
    local pct = book and tonumber(book.book_pct)
    local status = book and book.status
    -- Some views attach status without percent, so fetch whichever progress field is missing.
    if (status == nil or pct == nil) and book and book.filepath then
        local repo_ok, Repo = pcall(require, "lib/bookshelf_book_repository")
        if repo_ok and Repo and Repo.readProgress then
            local read_ok, repo_pct, repo_status = pcall(Repo.readProgress, book.filepath)
            if read_ok then
                pct = pct or tonumber(repo_pct)
                status = repo_status or status
            end
        end
    end
    local ok, CoverProgress = pcall(require, "lib/bookshelf_cover_progress")
    if ok and CoverProgress and CoverProgress.decide then
        local decided, result = pcall(CoverProgress.decide, book)
        if decided and result then
            pct = tonumber(result.badge_pct) or pct or tonumber(result.bar_pct)
            if result.glyph == "complete_bookmark" or result.glyph == "complete_tickbox" then
                status = "finished"
            elseif result.glyph == "in_progress" then
                status = "reading"
            elseif status ~= "complete" and status ~= "finished"
                    and (result.on_hold or result.on_hold_fade) then
                status = "on_hold"
            end
        end
    end
    -- A completed position takes precedence over a stale cached status.
    if pct and pct >= 0.99 then status = "finished" end
    if status == nil and pct and pct > 0 then status = "reading" end
    return max(0, min(1, pct or 0)), status
end

-- Apply finished and unopened-book behaviour before drawing the bookmark.
local function bookmarkProgress(book, mode)
    local pct, status = currentProgress(book)
    local finished_mode = modeSetting(mode, "bookcraft_finished_bookmark", "start_half")
    local finished = status == "complete" or status == "finished"
    local unopened = not finished and (status == nil or status == "new")
    if finished and finished_mode == "remove" then return nil end
    if unopened and modeSetting(mode, "bookcraft_unopened_bookmark", "off") == "off" then return nil end
    if finished then
        if finished_mode == "start" or finished_mode == "start_half" then pct = 0 else pct = 1 end
    end
    local half = (unopened and modeSetting(mode, "bookcraft_unopened_bookmark", "off") == "half")
        or (finished and (finished_mode == "start_half" or finished_mode == "keep_end_half"))
    return pct, half
end

-- Draw the progress ribbon with a curved hinge, tapered end, and edge detail.
local function paintProgressBookmark(bb, x, y, w, h, pct, book, half, spine_w, spine_mode, num_lines)
    local mode = spine_mode and "spine" or "cover"
    local tracking = modeSetting(mode, "bookcraft_bookmark_tracking", "both")
    local progress = max(0, min(1, pct or 0))

    -- Bookmark thickness and length are controlled independently.
    local size_mode = modeSetting(mode, "bookcraft_bookmark_size", "thick")
    local default_tenths = { thin = 85, medium = 100, thick = 135 }
    local thickness_tenths = tonumber(setting(
        modeKey(mode, "bookcraft_thickness_" .. size_mode), default_tenths[size_mode] or 85)) or 85
    local width_scale = max(40, min(200, thickness_tenths)) / 1000
    local ribbon_w = max(2, floor(w * width_scale + 0.5))
    local ribbon_h = max(6, floor(h * 0.28))
    local length_mode = modeSetting(mode, "bookcraft_bookmark_length", "short")
    -- Length presets are independently adjustable percentages of standard height.
    local default_lengths = { short = 65, medium = 100, long = 135 }
    local length_percent = tonumber(setting(modeKey(mode, "bookcraft_length_" .. length_mode),
        default_lengths[length_mode] or 65)) or 65
    local length_factor = max(25, min(200, length_percent)) / 100
    ribbon_h = max(3, floor(ribbon_h * length_factor * (half and 0.5 or 1) + 0.5))

    -- Use contrasting edge tones so the ribbon reads on varied cover art.
    local color_name = modeSetting(mode, "bookcraft_bookmark_color", "default")
    local ribbon_color = color_name == "lighter" and Blitbuffer.COLOR_GRAY_4
        or color_name == "darker" and Blitbuffer.COLOR_GRAY_1
        or Blitbuffer.COLOR_GRAY_2
    local outer_dark = Blitbuffer.COLOR_GRAY_7
    local outer_light = Blitbuffer.COLOR_GRAY_1
    local inner_light = Blitbuffer.COLOR_GRAY_3
    local inner_dark = Blitbuffer.COLOR_GRAY_5
    local details = modeSetting(mode, "bookcraft_bookmark_details", true) ~= false

    local page_thick, page_gap = PAGE_THICKNESS, PAGE_SPACING
    local line_step = page_thick + page_gap
    local top_page = y - page_gap - page_thick
    local bottom_page = top_page - (num_lines - 1) * line_step
    local by = floor(tracking ~= "horizontal"
        and (top_page - progress * (top_page - bottom_page)) or top_page)
    by = by + floor(page_thick / 2)

    -- In Both mode, track along the page rule at this vertical position;
    -- with vertical tracking off, use the cover's full horizontal extent.
    local left, right
    if tracking == "both" then
        local cut_h = num_lines * line_step
        local label_x, label_y = x - spine_w, y - cut_h
        left = pageBindingLeft(label_x, label_y, cut_h, spine_w, by, spine_mode)
        if spine_mode then
            right = x + w
        else
            local top_line_left = pageBindingLeft(label_x, label_y, cut_h, spine_w, label_y)
            local line_length = max(1, x + w - 2 - top_line_left)
            right = left + line_length
        end
    else
        left = x + floor(w * 0.04)
        local end_inset = tracking == "horizontal" and 0 or 2
        right = x + w - end_inset
    end
    local eased = 1 - (1 - progress) * (1 - progress)

    -- Shape the curved hinge and tapered notch relative to ribbon width.
    local notch_depth = max(1, floor(ribbon_w / 2))
    local hinge_size = 2
    local max_shift = floor(w * 0.06)
    local bx
    if tracking == "vertical" then
        bx = left
    else
        -- Keep the whole ribbon and its curved top inside the track. The
        -- thickness-based inset prevents wide bookmarks crowding either end.
        local end_clearance = floor((ribbon_w + 1) / 2) + 1
        local first_x = left + end_clearance
        local last_x = right - ribbon_w - max_shift - end_clearance
        bx = first_x + floor(eased * max(0, last_x - first_x))
    end
    local drop_x = bx

    for i = 0, ribbon_h do
        local ry = by + i
        local rx
        if ry < y - hinge_size then
            local t = (ry - by) / max(1, h * 0.20)
            t = max(0, min(1, t))
            rx = bx + floor(t ^ 0.25 * max_shift)
            drop_x = rx
        elseif ry < y then
            rx = drop_x
        else
            rx = drop_x
        end

        -- Shade the notch interior to keep its edges distinct.
        if i >= ribbon_h - notch_depth then
            local offset = ribbon_h - i
            for px = 0, ribbon_w - 1 do
                if px < offset or px > ribbon_w - 1 - offset then
                    local draw_x = rx + px
                    bb:paintRect(draw_x, ry, 1, 1, ribbon_color)

                    if details and px == 0 then
                        bb:paintRect(draw_x, ry, 1, 1, Blitbuffer.COLOR_GRAY_5)
                    end
                    if details and px == ribbon_w - 1 then
                        bb:paintRect(draw_x, ry, 1, 1, Blitbuffer.COLOR_GRAY_6)
                    end
                    if details and (px == offset - 1 or px == ribbon_w - offset) then
                        bb:paintRect(draw_x, ry, 1, 1, Blitbuffer.COLOR_WHITE)
                    end
                    if details and (px == offset or px == ribbon_w - 1 - offset) then
                        bb:paintRect(draw_x, ry, 1, 1, Blitbuffer.COLOR_GRAY_6)
                    end
                end
            end
        else
            bb:paintRect(rx, ry, ribbon_w, 1, ribbon_color)
            if details then
                bb:paintRect(rx, ry, 1, 1, Blitbuffer.COLOR_GRAY_5)
                bb:paintRect(rx + ribbon_w - 1, ry, 1, 1, Blitbuffer.COLOR_GRAY_6)
            end
        end

        -- Draw the outer outline and inset light and shadow edges.
        if details then
            bb:paintRect(rx - 1, ry, 1, 1, outer_dark)
            bb:paintRect(rx + ribbon_w, ry, 1, 1, outer_light)
            if ribbon_w > 2 then
                bb:paintRect(rx + 1, ry, 1, 1, inner_light)
                bb:paintRect(rx + ribbon_w - 2, ry, 1, 1, inner_dark)
            end
        end
    end
end

-- Compose the binding, page block, and progress ribbon over a cover tile.
local ProgressBookmarkCover = Widget:extend{
    book = nil, width = 0, height = 0, spine_width = nil,
    spine_mode = false, show_bookmark = true,
}

function ProgressBookmarkCover:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function ProgressBookmarkCover:paintTo(bb, x, y)
    ensurePageCount(self.book)
    local mode = self.spine_mode and "spine" or "cover"
    local render_spine = not self.spine_mode
        or modeSetting("spine", "progress_bookmarks_spine_rendering", true) ~= false
    local spine_w = self.spine_width or spineWidth(self.width, mode)
    local w = max(1, self.width - spine_w)
    local cx, cy = x + spine_w, y
    local n = pageLineCount(self.book, mode)
    local stack_h = n * PAGE_STEP
    local label_x, label_y = cx - spine_w, cy - stack_h
    local label_h = self.height + stack_h
    -- Spine View can hide the custom binding, page block, and spine text
    -- without disabling the progress bookmark or its tracking.
    if render_spine then
        drawSpineBackground(bb, label_x, label_y, label_h, cx, cy, w, self.height,
            stack_h, spine_w, self.spine_mode)
        drawSpineText(bb, label_x, label_y, label_h, self.book, stack_h,
            spine_w, self.spine_mode)
        drawPages(bb, label_x, cy, w + spine_w, self.book, spine_w, self.spine_mode, n)
    end

    if not self.show_bookmark then return end
    local pct, half = bookmarkProgress(self.book, mode)
    if pct == nil then return end
    paintProgressBookmark(bb, cx, cy, w, self.height, pct, self.book, half,
        spine_w, self.spine_mode, n)
end

-- Add the custom cover overlay and hide duplicate built-in indicators.
local function patchSpineWidget(SpineWidget)
    if type(SpineWidget) ~= "table" or SpineWidget._progress_bookmarks_patch then return end
    SpineWidget._progress_bookmarks_patch = true
    local original_init = SpineWidget.init
    local original_status = SpineWidget._statusIndicators

    if original_status then
        function SpineWidget:_statusIndicators(...)
            local indicators = original_status(self, ...)
            if self._progress_bookmarks_active and type(indicators) == "table" then
                indicators.bar = false
                indicators.glyph = nil
            end
            return indicators
        end
    end

    function SpineWidget:init(...)
        local spine_view = self.spine_face_out == true
        local bookmark_enabled = self.show_progress and (
            (spine_view and setting("progress_bookmarks_spine_face_out", true))
            or (not spine_view and setting("bookcraft_cover_view", false)))
        local spine_changes_enabled = spine_view
            and modeSetting("spine", "progress_bookmarks_spine_rendering", true) ~= false
        self._progress_bookmarks_active = bookmark_enabled
        local result = original_init(self, ...)
        if (bookmark_enabled or spine_changes_enabled)
                and self.book and self[1] and not self.is_fallback then
            local spine_w = spineWidth(self.width, self.spine_face_out and "spine" or "cover")
            -- Face-out tiles provide only the cover width; expand left so the
            -- page block and binding do not steal width from the cover image.
            local overlay_width = self.width + (self.spine_face_out and spine_w or 0)
            local overlay = ProgressBookmarkCover:new{
                book = self.book, width = overlay_width, height = self.height,
                spine_width = spine_w, spine_mode = self.spine_face_out,
                show_bookmark = bookmark_enabled,
            }
            overlay.overlap_offset = { -spine_w, 0 }
            self[1] = OverlapGroup:new{
                dimen = Geom:new{ w = self.width, h = self.height },
                self[1], overlay,
            }
        end
        return result
    end
end

-- Let spine-only books use the selected cover font without changing their layout.
local function patchSpineShelf(SpineShelf)
    if type(SpineShelf) ~= "table" or SpineShelf._progress_bookmarks_text_patch then return end
    local Slot = SpineShelf._SpineBookSlot
    if type(Slot) ~= "table" or type(Slot._renderIntoAt) ~= "function" then return end
    SpineShelf._progress_bookmarks_text_patch = true

    local original_render = Slot._renderIntoAt
    function Slot:_renderIntoAt(bb, x, y, night, ...)
        if modeSetting("spine", "progress_bookmarks_spine_rendering", true) == false then
            return original_render(self, bb, x, y, night, ...)
        end
        local match_cover_font = modeSetting("spine", "progress_bookmarks_spine_match_cover_font", nil)
        if match_cover_font == nil then
            match_cover_font = modeSetting("spine", "progress_bookmarks_spine_font_source", "spine_view") == "user"
        end
        local font_name = match_cover_font
            and modeSetting("cover", "progress_bookmarks_spine_font", "cfont")
            or modeSetting("spine", "progress_bookmarks_spine_font", "cfont")
        if not match_cover_font and font_name == "cfont" then
            return original_render(self, bb, x, y, night, ...)
        end

        local ok_fonts, BookFonts = pcall(original_require, "lib/bookshelf_fonts")
        if not ok_fonts or type(BookFonts) ~= "table" or not BookFonts.getUIFontFace then
            return original_render(self, bb, x, y, night, ...)
        end
        local original_get_font = BookFonts.getUIFontFace
        BookFonts.getUIFontFace = function()
            return font_name
        end
        local ok, result = pcall(original_render, self, bb, x, y, night, ...)
        BookFonts.getUIFontFace = original_get_font
        if not ok then error(result) end
        return result
    end

    local original_key = Slot._renderKey
    if original_key then
        function Slot:_renderKey(night, ...)
            local key = original_key(self, night, ...)
            return table.concat({ key, "progress_bookmarks_spine_font",
                tostring(modeSetting("spine", "progress_bookmarks_spine_rendering", true)),
                tostring(modeSetting("spine", "progress_bookmarks_spine_match_cover_font", false)),
                tostring(modeSetting("cover", "progress_bookmarks_spine_font", "cfont")),
                tostring(modeSetting("spine", "progress_bookmarks_spine_font", "cfont")),
            }, "|")
        end
    end
end

-- Build the Progress Bookmarks Patch Settings controls for Bookshelf.
local function patchSettings(Settings)
    if type(Settings) ~= "table" or Settings._progress_bookmarks_patch then return end
    Settings._progress_bookmarks_patch = true
    local function tr(text)
        local ok, i18n = pcall(require, "lib/bookshelf_i18n")
        return ok and i18n.gettext and i18n.gettext(text) or text
    end
    function Settings:_progressBookmarkSubItems()
        local function refresh()
            if self._bw and self._bw._rebuild then
                self._bw:_rebuild()
                local UIManager = require("ui/uimanager")
                pcall(UIManager.setDirty, UIManager, self._bw, "ui")
            end
            local ok, FileChooser = pcall(require, "ui/widget/filechooser")
            if ok and FileChooser.instance then FileChooser.instance:updateItems() end
        end
        local function showUpdateMessage(message, timeout)
            local InfoMessage = require("ui/widget/infomessage")
            local UIManager = require("ui/uimanager")
            UIManager:show(InfoMessage:new{ text = tr(message), timeout = timeout or 4 })
        end
        local function installReleaseAsset(asset_url, release_version)
            local DataStorage = require("datastorage")
            local target = DataStorage:getPatchesDir() .. "/" .. PATCH_FILE_NAME
            local source, download_error = downloadPatchAsset(asset_url, target .. ".download")
            if not source then
                showUpdateMessage("Update download failed: " .. tostring(download_error))
                return
            end
            local valid_source, validation_error = validatePatchSource(source, release_version)
            if not valid_source then
                showUpdateMessage("Update rejected: " .. tostring(validation_error))
                return
            end
            local backup, install_error = installPatchSource(valid_source)
            if not backup then
                showUpdateMessage("Update could not be installed: " .. tostring(install_error), 6)
                return
            end
            showUpdateMessage("Installed v" .. release_version
                .. ". Restart KOReader to load it. Backup: " .. backup, 8)
            refresh()
        end
        local function checkForUpdates()
            local NetworkMgr = require("ui/network/manager")
            local UIManager = require("ui/uimanager")
            local ConfirmBox = require("ui/widget/confirmbox")
            local function checkConnected()
                if not NetworkMgr:isConnected() then
                    showUpdateMessage("Could not connect to GitHub. Check the device's network connection.")
                    return
                end
                showUpdateMessage("Checking for Progress Bookmarks updates...", 1)
                UIManager:scheduleIn(0.1, function()
                    local release, request_error = latestPatchRelease()
                    if not release then
                        if tostring(request_error):find("404", 1, true) then
                            showUpdateMessage("No published stable GitHub release was found yet.", 6)
                        else
                            showUpdateMessage("Could not check GitHub releases: " .. tostring(request_error))
                        end
                        return
                    end
                    if release.draft or release.prerelease or type(release.tag_name) ~= "string" then
                        showUpdateMessage("No stable Progress Bookmarks release was found.")
                        return
                    end
                    local latest_version = release.tag_name:gsub("^v", "")
                    local newer = versionIsNewer(latest_version, PATCH_VERSION)
                    if newer == nil then
                        showUpdateMessage("The latest GitHub release has an unsupported version tag.")
                        return
                    elseif not newer then
                        showUpdateMessage("Progress Bookmarks is up to date: v" .. PATCH_VERSION)
                        return
                    end

                    local asset_url
                    for _, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
                        if asset.name == PATCH_FILE_NAME
                                and type(asset.browser_download_url) == "string" then
                            asset_url = asset.browser_download_url
                            break
                        end
                    end
                    if not asset_url then
                        showUpdateMessage("Version v" .. latest_version
                            .. " is published, but the release has no " .. PATCH_FILE_NAME .. " asset.", 6)
                        return
                    end
                    UIManager:show(ConfirmBox:new{
                        text = "Progress Bookmarks update available.\n\nInstalled: v" .. PATCH_VERSION
                            .. "\nLatest: v" .. latest_version .. "\n\nInstall this release?",
                        ok_text = tr("Install"),
                        cancel_text = tr("Cancel"),
                        ok_callback = function()
                            installReleaseAsset(asset_url, latest_version)
                        end,
                    })
                end)
            end
            if NetworkMgr:isConnected() then
                checkConnected()
            else
                NetworkMgr:runWhenConnected(checkConnected)
            end
        end
        local function readSetting(mode, key, default)
            if mode then return modeSetting(mode, key, default) end
            return setting(key, default)
        end
        local function toggle(key, title, help, default, mode)
            default = default == true
            return {
                text = tr(title), help_text = tr(help), keep_menu_open = true,
                checked_func = function()
                    local value = readSetting(mode, key, default)
                    return value == true
                end,
                callback = function()
                    local value = readSetting(mode, key, default)
                    if mode then modeSaveSetting(mode, key, not (value == true))
                    else saveSetting(key, not (value == true)) end
                    refresh()
                end,
            }
        end
        local function choices(key, title, default, options, mode)
            local rows = {}
            for _, pair in ipairs(options) do
                local value, label = pair[1], pair[2]
                rows[#rows + 1] = {
                    text = tr(label), radio = true, keep_menu_open = true,
                    checked_func = function()
                        local current = readSetting(mode, key, default)
                        return current == value
                    end,
                    callback = function(menu)
                        if mode then modeSaveSetting(mode, key, value) else saveSetting(key, value) end
                        refresh()
                        if menu and menu.updateItems then menu:updateItems() end
                    end,
                }
            end
            return { text = tr(title), sub_item_table = rows, keep_menu_open = true }
        end
        local function fontSizeSetting(mode)
            local key, default = "progress_bookmarks_spine_font_size", 7
            local function read() return modeSetting(mode, key, default) end
            return {
                text_func = function()
                    local value = tonumber(read()) or default
                    return tr("Font size") .. ": " .. tostring(value)
                end,
                help_text = tr("Base font size at a 100 dp cover width; rendered size scales with the spine."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text = tr("Font size"),
                        info_text = tr("Base spine title size at a 100 dp cover width."),
                        value = tonumber(read()) or default,
                        value_min = 6,
                        value_max = 20,
                        value_step = 1,
                        value_text_func = function(value)
                            return tostring(floor(value + 0.5))
                        end,
                        ok_text = tr("Set"),
                        callback = function(spin)
                            modeSaveSetting(mode, key, floor(spin.value + 0.5))
                            refresh()
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end,
            }
        end
        local function userFontSetting(mode)
            local key = "progress_bookmarks_spine_font"
            local function read() return modeSetting(mode, key, "cfont") end
            return {
                text_func = function()
                    local face = read()
                    if face == "cfont" then
                        return tr("Selected font") .. ": " .. tr("System")
                    end
                    return tr("User font") .. ": " .. (face:match("([^/\\]+)$") or face)
                end,
                help_text = tr("Choose an installed font file for spine text."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    -- Bookshelf's picker returns an installed, resolvable font path.
                    local LineEditor = require("lib/bookshelf_hero_line_editor")
                    LineEditor.showFontPicker(read(), "cfont", function(face)
                        if face and face ~= "" then modeSaveSetting(mode, key, face) end
                        refresh()
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end)
                end,
            }
        end
        local function percentSetting(key, title, default, help, mode, maximum)
            local function readValue()
                local value = tonumber(readSetting(mode, key, default)) or default
                return max(40, min(maximum or 200, value))
            end
            return {
                text_func = function()
                    local value = readValue()
                    return tr(title) .. ": " .. string.format("%.1f%%", value / 10)
                end,
                help_text = tr(help),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text = tr(title),
                        info_text = tr("Set as a percentage of cover width, in 0.5% steps."),
                        value = readValue() / 10,
                        value_min = 4,
                        value_max = (maximum or 200) / 10,
                        value_step = 0.5,
                        value_text_func = function(value)
                            return string.format("%.1f%%", value)
                        end,
                        ok_text = tr("Set"),
                        callback = function(spin)
                            if mode then modeSaveSetting(mode, key, floor(spin.value * 10 + 0.5))
                            else saveSetting(key, floor(spin.value * 10 + 0.5)) end
                            refresh()
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end,
            }
        end
        local function lengthSetting(key, title, default, mode)
            local function readValue()
                return tonumber(readSetting(mode, key, default)) or default
            end
            return {
                text_func = function()
                    local value = readValue()
                    return tr(title) .. ": " .. string.format("%d%%", value)
                end,
                help_text = tr("Set the bookmark length relative to its standard length."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text = tr(title),
                        info_text = tr("Percentage of the standard bookmark length."),
                        value = readValue(),
                        value_min = 25,
                        value_max = 200,
                        value_step = 5,
                        value_text_func = function(value)
                            return string.format("%d%%", floor(value + 0.5))
                        end,
                        ok_text = tr("Set"),
                        callback = function(spin)
                            if mode then modeSaveSetting(mode, key, floor(spin.value + 0.5))
                            else saveSetting(key, floor(spin.value + 0.5)) end
                            refresh()
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end,
            }
        end
        local function pagesPerLineSetting(mode)
            local key, default = "bookcraft_pages_per_line", DEFAULT_PAGES_PER_LINE
            local function readValue()
                local value = tonumber(modeSetting(mode, key, default)) or default
                return max(MIN_PAGES_PER_LINE, min(MAX_PAGES_PER_LINE, floor(value + 0.5)))
            end
            return {
                text_func = function()
                    return tr("Pages per line") .. ": " .. tostring(readValue())
                end,
                help_text = tr("Set the pages represented by each page line. The number of lines remains capped at six."),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local UIManager = require("ui/uimanager")
                    UIManager:show(SpinWidget:new{
                        title_text = tr("Pages per line"),
                        info_text = tr("Page-line count is capped at six."),
                        value = readValue(),
                        value_min = MIN_PAGES_PER_LINE,
                        value_max = MAX_PAGES_PER_LINE,
                        value_step = MIN_PAGES_PER_LINE,
                        value_text_func = function(value)
                            return tostring(floor(value + 0.5))
                        end,
                        ok_text = tr("Set"),
                        callback = function(spin)
                            modeSaveSetting(mode, key, floor(spin.value + 0.5))
                            refresh()
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end,
            }
        end
        local function returnToDefault(mode)
            local is_spine = mode == "spine"
            local spine_config = SPINE_WIDTH_PRESETS[mode]
            -- Explicit view-scoped values prevent old shared settings from overriding reset.
            local values = {
                bookcraft_finished_bookmark = "start_half",
                bookcraft_unopened_bookmark = "off",
                bookcraft_bookmark_tracking = "both",
                bookcraft_bookmark_color = "default",
                bookcraft_bookmark_length = "short",
                bookcraft_length_short = 65,
                bookcraft_length_medium = 100,
                bookcraft_length_long = 135,
                bookcraft_bookmark_size = "thick",
                bookcraft_thickness_thin = 85,
                bookcraft_thickness_medium = 100,
                bookcraft_thickness_thick = 135,
                bookcraft_bookmark_details = true,
                bookcraft_pages_per_line = DEFAULT_PAGES_PER_LINE,
                progress_bookmarks_spine_size = spine_config.default,
                progress_bookmarks_spine_thickness = spine_config.values[spine_config.default],
                progress_bookmarks_spine_thickness_thin = spine_config.values.thin,
                progress_bookmarks_spine_thickness_medium = spine_config.values.medium,
                progress_bookmarks_spine_thickness_thick = spine_config.values.thick,
                progress_bookmarks_spine_text_enabled = true,
                progress_bookmarks_spine_show_title = true,
                progress_bookmarks_spine_show_author = true,
                progress_bookmarks_spine_show_series_index = true,
                progress_bookmarks_spine_overflow = "truncate",
                progress_bookmarks_spine_match_cover_font = false,
                progress_bookmarks_spine_font = "cfont",
                progress_bookmarks_spine_font_size = 7,
                progress_bookmarks_spine_font_color = "dark_gray",
            }
            if is_spine then values.progress_bookmarks_spine_rendering = true end
            return {
                text = tr("Return to Default"),
                help_text = tr("Restore this view's default settings."),
                keep_menu_open = true,
                callback = function()
                    for key, value in pairs(values) do modeSaveSetting(mode, key, value) end
                    saveSetting(is_spine and "progress_bookmarks_spine_face_out" or "bookcraft_cover_view",
                        is_spine)
                    refresh()
                end,
            }
        end
        local function modeSettings(mode)
            local is_spine = mode == "spine"
            local spine_config = SPINE_WIDTH_PRESETS[mode]
            local max_spine = spine_config.max
            local min_spine = spine_config.min
            local spine_defaults = spine_config.values
            local default_spine_preset = spine_config.default
            local spine_options = {
                {
                    text = tr("Spine thickness"), keep_menu_open = true,
                    sub_item_table = {
                        choices("progress_bookmarks_spine_size", "Preset", default_spine_preset, {
                            { "thin", "Thin" }, { "medium", "Medium" }, { "thick", "Thick" },
                        }, mode),
                        percentSetting("progress_bookmarks_spine_thickness_thin", "Thin", spine_defaults.thin,
                            string.format("%s width range: %.1f%% minimum to %.1f%% maximum of cover width.",
                                is_spine and "Spine View" or "Cover View", min_spine / 10, max_spine / 10),
                            mode, max_spine),
                        percentSetting("progress_bookmarks_spine_thickness_medium", "Medium", spine_defaults.medium,
                            string.format("%s width range: %.1f%% minimum to %.1f%% maximum of cover width.",
                                is_spine and "Spine View" or "Cover View", min_spine / 10, max_spine / 10),
                            mode, max_spine),
                        percentSetting("progress_bookmarks_spine_thickness_thick", "Thick", spine_defaults.thick,
                            string.format("%s width range: %.1f%% minimum to %.1f%% maximum of cover width.",
                                is_spine and "Spine View" or "Cover View", min_spine / 10, max_spine / 10),
                            mode, max_spine),
                    },
                },
                {
                    text = tr("Page lines"), keep_menu_open = true,
                    sub_item_table = { pagesPerLineSetting(mode) },
                },
                {
                    text = tr("Spine Text"), keep_menu_open = true,
                    sub_item_table = {
                        toggle("progress_bookmarks_spine_text_enabled", "Show spine text",
                            "Show or hide all text on the spine.", true, mode),
                        toggle("progress_bookmarks_spine_show_title", "Title",
                            "Show the book title on the spine.", true, mode),
                        toggle("progress_bookmarks_spine_show_author", "Author",
                            "Show the book author on the spine.", true, mode),
                        toggle("progress_bookmarks_spine_show_series_index", "Series Index",
                            "Show the book's series index on the spine.", true, mode),
                        choices("progress_bookmarks_spine_overflow", "Overflow", "truncate", {
                            { "truncate", "Truncate" },
                            { "second_line", "Move overflow to a second line" },
                        }, mode),
                        toggle("progress_bookmarks_spine_match_cover_font",
                            is_spine and "Match Cover View font" or "Use selected font",
                            is_spine and "Use the Cover View font for face-out and spine-only text."
                                or "Use the selected Progress Bookmarks font instead of Bookshelf's font.", false, mode),
                        userFontSetting(mode),
                        fontSizeSetting(mode),
                        choices("progress_bookmarks_spine_font_color", "Font colour", "dark_gray", {
                            { "white", "White" }, { "light_gray", "Light grey" },
                            { "dark_gray", "Dark grey" }, { "black", "Black" },
                        }, mode),
                    },
                },
            }
            return {
                {
                    text = tr("Bookmark"), keep_menu_open = true,
                    sub_item_table = {
                        {
                            text = tr("Behaviour"), keep_menu_open = true,
                            sub_item_table = {
                                choices("bookcraft_finished_bookmark", "Finished book", "start_half", {
                                    { "keep_end", "Keep at right end" },
                                    { "keep_end_half", "Keep at right end, half-length" },
                                    { "start", "Return to starting position" },
                                    { "start_half", "Return to starting position, half-length" },
                                    { "remove", "Remove bookmark" },
                                }, mode),
                                choices("bookcraft_unopened_bookmark", "Unopened books", "off", {
                                    { "on", "On" }, { "off", "Off" }, { "half", "Half-length" },
                                }, mode),
                                choices("bookcraft_bookmark_tracking", "Tracking", "both", {
                                    { "vertical", "Vertical only" },
                                    { "horizontal", "Horizontal only" },
                                    { "both", "Both" },
                                }, mode),
                            },
                        },
                        {
                            text = tr("Appearance"), keep_menu_open = true,
                            sub_item_table = {
                                choices("bookcraft_bookmark_color", "Bookmark colour", "default", {
                                    { "lighter", "Lighter" }, { "default", "Default" },
                                    { "darker", "Darker" },
                                }, mode),
                                {
                                    text = tr("Bookmark length"), keep_menu_open = true,
                                    sub_item_table = {
                                        choices("bookcraft_bookmark_length", "Preset", "short", {
                                            { "short", "Short" }, { "medium", "Medium" },
                                            { "long", "Long" },
                                        }, mode),
                                        lengthSetting("bookcraft_length_short", "Short", 65, mode),
                                        lengthSetting("bookcraft_length_medium", "Medium", 100, mode),
                                        lengthSetting("bookcraft_length_long", "Long", 135, mode),
                                    },
                                },
                                {
                                    text = tr("Bookmark thickness"), keep_menu_open = true,
                                    sub_item_table = {
                                        choices("bookcraft_bookmark_size", "Preset", "thick", {
                                            { "thin", "Thin" }, { "medium", "Medium" },
                                            { "thick", "Thick" },
                                        }, mode),
                                        percentSetting("bookcraft_thickness_thin", "Thin", 85,
                                            "Thin bookmark default: 8.5% of cover width.", mode, 200),
                                        percentSetting("bookcraft_thickness_medium", "Medium", 100,
                                            "Medium bookmark default: 10.0% of cover width.", mode, 200),
                                        percentSetting("bookcraft_thickness_thick", "Thick", 135,
                                            "Thick bookmark default: 13.5% of cover width.", mode, 200),
                                    },
                                },
                                toggle("bookcraft_bookmark_details", "Bookmark details",
                                    "Show the contrast outline, edge shading, and notch highlights.", true, mode),
                            },
                        },
                    },
                },
                {
                    text = tr("Spine"), keep_menu_open = true,
                    sub_item_table = spine_options,
                },
                returnToDefault(mode),
            }
        end
        local cover_settings = modeSettings("cover")
        table.insert(cover_settings, 1, toggle("bookcraft_cover_view",
            "Enable Progress Bookmarks",
            "Show page edges and a reading-progress bookmark on cover tiles."))
        local spine_settings = modeSettings("spine")
        -- Keep the bookmark overlay independent from spine artwork and font changes.
        table.insert(spine_settings, 1, toggle("progress_bookmarks_spine_face_out",
            "Enable Progress Bookmarks",
            "Show page edges and a reading-progress bookmark on face-out books.", true))
        table.insert(spine_settings, 2, toggle("progress_bookmarks_spine_rendering",
            "Enable Spine Changes",
            "Apply custom spine rendering and font changes independently of progress bookmarks.", true, "spine"))
        return {
            {
                text = tr("Check for updates"),
                help_text = tr("Check GitHub for the latest Progress Bookmarks release."),
                keep_menu_open = true,
                callback = checkForUpdates,
            },
            { text = tr("Cover View"), keep_menu_open = true, sub_item_table = cover_settings },
            { text = tr("Spine View"), keep_menu_open = true, sub_item_table = spine_settings },
        }
    end
end

-- Add Progress Bookmarks as a top-level Bookshelf menu entry.
local function patchBookshelfMain(Bookshelf)
    if type(Bookshelf) ~= "table" or Bookshelf._progress_bookmarks_patch then return end
    if type(Bookshelf.buildMenuItems) ~= "function"
            or type(Bookshelf.MENU_ORDER) ~= "table" then return end
    Bookshelf._progress_bookmarks_patch = true

    local found_order_entry = false
    for _, id in ipairs(Bookshelf.MENU_ORDER) do
        if id == "bookshelf_progress_bookmarks" then
            found_order_entry = true
            break
        end
    end
    if not found_order_entry then
        local insert_at = #Bookshelf.MENU_ORDER + 1
        for i, id in ipairs(Bookshelf.MENU_ORDER) do
            if id == "bookshelf_settings" then
                insert_at = i + 1
                break
            end
        end
        table.insert(Bookshelf.MENU_ORDER, insert_at, "bookshelf_progress_bookmarks")
    end

    local original = Bookshelf.buildMenuItems
    function Bookshelf:buildMenuItems(menu_items, ...)
        local result = original(self, menu_items, ...)
        menu_items.bookshelf_progress_bookmarks = {
            text = "Progress Bookmarks Patch Settings",
            sub_item_table_func = function()
                local ok, Settings = pcall(require, "lib/bookshelf_settings")
                if not ok or type(Settings) ~= "table" then return {} end
                patchSettings(Settings)
                if self._widget then Settings._bw = self._widget end
                return Settings:_progressBookmarkSubItems()
            end,
        }
        return result
    end
end

local function patchModule(name, module)
    if type(name) ~= "string" then return end
    if name:match("bookshelf_spine_widget$") then patchSpineWidget(module)
    elseif name:match("bookshelf_spine_shelf$") then patchSpineShelf(module)
    elseif name:match("bookshelf_settings$") then patchSettings(module)
    elseif name:find("bookshelf", 1, true) then patchBookshelfMain(module)
    end
end

-- Patch cached Bookshelf modules and register for plugin initialization.
for name, module in pairs(package.loaded) do patchModule(name, module) end
_G.require = function(name, ...)
    local module = original_require(name, ...)
    if type(name) == "string" and name:find("bookshelf", 1, true) then
        patchModule(name, module)
    end
    return module
end
local ok_userpatch, userpatch = pcall(original_require, "userpatch")
if ok_userpatch and userpatch and userpatch.registerPatchPluginFunc then
    userpatch.registerPatchPluginFunc("bookshelf", patchBookshelfMain)
else
    logger.warn("Progress Bookmarks: KOReader plugin patch hook unavailable")
end
