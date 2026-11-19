local input = require('mp.input')
local utils = require('mp.utils')
local options = {quality = 127, autobrowse = true}
require('mp.options').read_options(options, 'newbv')

local directory = mp.get_script_directory()
local helper = utils.join_path(directory, 'resolve.ps1')
local windows = os.getenv('SystemRoot')
if not windows then return end
local shell = utils.join_path(windows, [[System32\WindowsPowerShell\v1.0\powershell.exe]])
local search_request
local browser_request
local browser_timer
local browser_mailbox
local browser_session = 0
local live_streams
local live_choice
local part_titles = {}
local quality_state
local preference_path = os.getenv('LOCALAPPDATA')
local settings_path = preference_path and utils.join_path(preference_path, 'mpv-newbv/settings.json')
preference_path = preference_path and utils.join_path(preference_path, 'mpv-newbv-quality.json')

local function read_json(path)
    if not path then return end
    local file = io.open(path, 'rb')
    if not file then return end
    local data = file:read(2 * 1024 * 1024)
    file:close()
    return data and utils.parse_json(data)
end

local function valid_quality(value, maximum)
    return type(value) == 'number' and value >= 1 and value <= maximum and value == math.floor(value)
end

local function load_preferences()
    local saved = read_json(preference_path)
    if type(saved) ~= 'table' then saved = {} end
    return {
        quality = valid_quality(saved.quality, 127) and saved.quality or nil,
        codec = (saved.codec == 'h264' or saved.codec == 'hevc' or saved.codec == 'av1') and saved.codec or '',
        live = valid_quality(saved.live, 30000) and saved.live or nil,
    }
end

local preferences = load_preferences()
local function read_settings()
    local data = read_json(settings_path)
    return type(data) == 'table' and data or {}
end

local function save_preferences()
    if not preference_path then return end
    local json = utils.format_json(preferences)
    if not json then return end
    local file = io.open(preference_path, 'wb')
    if not file then return end
    file:write(json)
    file:close()
end

local function use_highest()
    preferences.quality, preferences.codec, preferences.live = nil, '', nil
    save_preferences()
end

local function tell(text)
    mp.osd_message('NewBV：' .. text, 5)
    mp.msg.info(text)
end

local function request(action, value, callback, live_quality, settings)
    settings = settings or {}
    local quality = preferences.quality or (valid_quality(settings.quality, 127) and settings.quality)
        or (valid_quality(options.quality, 127) and options.quality or 127)
    local preferred_codec = preferences.codec ~= '' and preferences.codec or settings.codec
    if preferred_codec ~= 'h264' and preferred_codec ~= 'hevc' and preferred_codec ~= 'av1' then preferred_codec = '' end
    local preferred_audio = settings.audio
    if preferred_audio ~= 'flac' and preferred_audio ~= 'eac3' then preferred_audio = 'aac' end
    return mp.command_native_async({
        name = 'subprocess',
        args = {shell, '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned',
                '-File', helper, '-Action', action, '-Quality', tostring(quality), '-Query', 'q:' .. value,
                '-LiveQuality', tostring(live_quality or preferences.live or 30000),
                '-PreferredCodec', preferred_codec, '-PreferredAudio', preferred_audio},
        playback_only = false,
        capture_stdout = true,
    }, function(success, result)
        if not success or not result or result.status ~= 0 then
            callback(nil, '接口助手未能运行，请检查 PowerShell 和脚本配置。')
            return
        end
        local data = utils.parse_json(result.stdout or '')
        if not data or data.error then
            callback(nil, data and data.error or '接口响应无法读取。')
            return
        end
        callback(data)
    end)
end

local close_login, start_login, check_login = dofile(utils.join_path(directory, 'login.lua'))(directory, request)
local history = dofile(utils.join_path(directory, 'history.lua'))(request)

local function video_url(value)
    return value:match('^https?://www%.bilibili%.com/video/[^/]+')
        or value:match('^https?://m%.bilibili%.com/video/[^/]+')
        or value:match('^https?://bilibili%.com/video/[^/]+')
end

local function live_url(value)
    return value:match('^https://live%.bilibili%.com/[1-9]%d*/?$')
end

local function playback_url(value)
    return video_url(value) or live_url(value) or value:match('^https://www%.bilibili%.com/bangumi/play/ep[1-9]%d*$')
end

local function play_selection(data)
    if type(data.url) ~= 'string' or not playback_url(data.url) then return end
    part_titles = {}
    local queue = {}
    local selected
    for _, part in ipairs(type(data.queue) == 'table' and data.queue or {}) do
        local address = type(part) == 'table' and part.url or part
        if type(address) == 'string' and playback_url(address) then
            if type(part) == 'table' then part_titles[address] = part.title end
            queue[#queue + 1] = address
            if address == data.url then selected = #queue end
        end
    end
    if not selected or #queue <= 1 then
        mp.commandv('loadfile', data.url, 'replace')
        return
    end
    mp.commandv('loadfile', queue[1], 'replace')
    for index = 2, #queue do mp.commandv('loadfile', queue[index], 'append') end
    if selected > 1 then mp.set_property_number('playlist-pos', selected - 1) end
end

local function current_quality_track(state, track)
    if not track or track.type ~= 'video' or track.external then return end
    local info = state.tracks[track.id]
    if info and track.title == info.title then return info end
end

local function remember_track(info)
    if not info or (info.quality == preferences.quality and info.codec == preferences.codec) then return end
    preferences.quality, preferences.codec = info.quality, info.codec
    save_preferences()
end

mp.register_event('file-loaded', function()
    if quality_state then
        local track = mp.get_property_native('current-tracks/video')
        quality_state.previous = track and track.id
        quality_state.ready = true
    end
end)

mp.observe_property('vid', 'native', function()
    local state = quality_state
    if not state or not state.ready then return end
    local track = mp.get_property_native('current-tracks/video')
    if not track then state.previous = nil; return end
    if track.id == state.previous then return end
    state.previous = track.id
    local info = current_quality_track(state, track)
    if not info or mp.get_property('options/vid') == 'auto' then return end
    remember_track(info)
end)

local function cancel_search()
    if search_request then
        mp.abort_async_command(search_request)
        search_request = nil
    end
end

local function submit(value)
    if not value then return end
    cancel_search()
    value = value:match('^%s*(.-)%s*$')
    if value == '' then return end
    if value:match('^BV%w%w%w%w%w%w%w%w%w%w$') or value:match('^av[1-9]%d*$') then
        value = 'https://www.bilibili.com/video/' .. value
    end
    if playback_url(value) then
        mp.commandv('loadfile', value)
        return
    end
    if value:match('^https?://') then
        tell('请使用完整视频、番剧单集或直播房间链接。')
        return
    end
    if #value > 400 or value:find('[%z\r\n]') then
        tell('搜索词无效或过长。')
        return
    end
    tell('正在搜索…')
    local current
    current = request('search', value, function(data, err)
        if search_request ~= current then return end
        search_request = nil
        if not data then tell(err); return end
        if #data.items == 0 then tell('没有找到视频。'); return end
        local labels = {}
        for index, item in ipairs(data.items) do labels[index] = item.label:gsub('[%c]', ' ') end
        input.select({prompt = 'NewBV · 选择视频', items = labels, submit = function(index)
            local item = data.items[index]
            if item and video_url(item.url) then mp.commandv('loadfile', item.url) end
        end})
    end)
    search_request = current
end

local function open()
    close_login()
    cancel_search()
    input.get({prompt = 'NewBV · 搜索 / 视频链接 / BV、av 号', submit = submit})
end

local function browse(current, view, signin)
    if browser_request then
        local focus = io.open(browser_mailbox .. '.focus', 'wb')
        if focus then
            focus:write(utils.format_json({url = current, view = view, signin = signin}) or '{}')
            focus:close()
        end
        return
    end
    close_login()
    cancel_search()
    local browser = utils.join_path(directory, 'browser.ps1')
    local temp = os.getenv('TEMP') or os.getenv('TMP')
    if not temp then tell('无法创建选片会话。'); return end
    browser_session = browser_session + 1
    local mailbox = utils.join_path(temp, ('mpv-newbv-%d-%d-%d.json'):format(utils.getpid(), os.time(), browser_session))
    browser_mailbox = mailbox
    local last_sequence = 0
    local function receive()
        local data = read_json(mailbox)
        if type(data) ~= 'table' or type(data.sequence) ~= 'number' or data.sequence <= last_sequence then return end
        last_sequence = data.sequence
        if data.action == 'play' then
            play_selection(data)
        elseif data.action == 'signin' and browser_mailbox == mailbox then
            start_login(function(update)
                if browser_mailbox ~= mailbox then return end
                if update.state == 'success' then history.login() end
                local signal = io.open(mailbox .. '.signin.tmp', 'wb')
                if not signal then return end
                update.sequence = data.sequence
                signal:write(utils.format_json(update))
                signal:close()
                os.remove(mailbox .. '.signin')
                os.rename(mailbox .. '.signin.tmp', mailbox .. '.signin')
            end)
        elseif data.action == 'cancel-signin' then
            close_login()
        elseif data.action == 'check-signin' then
            check_login()
        end
    end
    local args = {shell, '-NoLogo', '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'RemoteSigned',
                  '-File', browser, '-PlayMailbox', mailbox, '-MpvProcessId', tostring(utils.getpid())}
    if signin then args[#args + 1] = '-SignInOnStart' end
    if current then
        args[#args + 1] = '-CurrentVideo'
        args[#args + 1] = current
        if view then
            args[#args + 1] = '-StartView'
            args[#args + 1] = view
        end
    end
    browser_timer = mp.add_periodic_timer(0.15, receive)
    browser_request = mp.command_native_async({
        name = 'subprocess', playback_only = false, capture_stdout = true,
        args = args,
    }, function(success, result)
        browser_request = nil
        browser_mailbox = nil
        close_login()
        browser_timer:kill()
        browser_timer = nil
        receive()
        for _, suffix in ipairs({'', '.tmp', '.focus', '.signin', '.signin.tmp'}) do os.remove(mailbox .. suffix) end
        if not success or not result or result.status ~= 0 then tell('无法打开选片窗口。'); return end
        local data = utils.parse_json(result.stdout or '')
        if not data then return end
        if data.action == 'play' then play_selection(data) end
        if data.action == 'account' then mp.commandv('script-message-to', mp.get_script_name(), 'account') end
    end)
end

local startup_browser
if options.autobrowse then
    startup_browser = mp.add_timeout(0.2, function()
        if not browser_request and mp.get_property_bool('idle-active', false)
            and mp.get_property_number('playlist-count', 0) == 0
            and mp.get_property('options/force-window', 'no') ~= 'no'
            and mp.get_property('options/vo') ~= 'null' then
            browse()
        end
    end)
end

mp.register_event('shutdown', function()
    if not browser_mailbox then return end
    for _, suffix in ipairs({'', '.tmp', '.focus', '.signin', '.signin.tmp'}) do os.remove(browser_mailbox .. suffix) end
end)

mp.add_key_binding('Alt+b', 'browse', function() browse() end)
mp.add_key_binding('Alt+l', 'account', function() browse(nil, nil, true) end)
mp.add_key_binding('Alt+Shift+b', 'open', open)
mp.register_script_message('open', function() browse() end)
mp.register_script_message('account', function() browse(nil, nil, true) end)
mp.register_script_message('logout', function()
    close_login()
    request('logout', '', function(result)
        tell(result and '已清除本机登录。' or '无法清除本机登录，请重试。')
    end)
end)
mp.register_script_message('quick-search', open)
mp.register_script_message('submit', submit)

mp.add_hook('on_load', 5, function(hook)
    local url = mp.get_property('stream-open-filename', '')
    if not playback_url(url) then return end
    tell('正在获取播放地址…')
    hook:defer()
    local preferred_live = live_choice and live_choice.url == url and live_choice or nil
    live_choice = nil
    preferences = load_preferences()
    local live_quality = preferred_live and preferred_live.quality or preferences.live or 30000
    local settings = read_settings()
    if not live_url(url) and type(settings.speed) == 'number' and settings.speed >= 0.25 and settings.speed <= 2 then
        mp.set_property_number('file-local-options/speed', settings.speed)
    end
    if settings.subtitles == 'no' then mp.set_property('file-local-options/sid', 'no') end
    request('resolve', url, function(data, err)
        if data and data.video then
            history.set(data.history)
            mp.set_property_native('user-data/newbv/byline', data.byline or '')
            mp.set_property('file-local-options/user-agent', data.userAgent or '')
            mp.set_property('file-local-options/referrer', data.referrer or '')
            if data.title then mp.set_property('file-local-options/force-media-title', data.title) end
            local selected = data.video
            if live_url(url) and data.lines and #data.lines > 0 then
                local index = preferred_live and preferred_live.index or 1
                index = math.min(index, #data.lines)
                live_streams = {url = url, lines = data.lines, index = index,
                    qualities = data.qualities or {}, quality = live_quality}
                selected = data.lines[index]
                mp.set_property('file-local-options/ytdl', 'no')
            end
            if data.defaultVid and data.tracks then
                local tracks = {}
                for _, track in ipairs(data.tracks) do tracks[track.id] = track end
                mp.set_property('file-local-options/vid', 'auto')
                if settings.audio == 'flac' or settings.audio == 'eac3' then
                    mp.set_property('file-local-options/aid', 'auto')
                end
                quality_state = {tracks = tracks}
            end
            mp.set_property('stream-open-filename', selected)
            mp.osd_message('', 0)
        else
            tell(err or '接口没有返回播放地址。')
        end
        hook:cont()
    end, live_quality, settings)
end)

mp.register_event('file-loaded', function()
    if mp.get_property_native('user-data/newbv/danmaku-adapter') then return end
    local path = mp.get_property('path', '')
    if not video_url(path) then return end
    local setting = read_settings().danmaku
    if setting == 'on' or setting == 'off' then
        mp.commandv('script-message-to', 'uosc_danmaku', 'set', 'show_danmaku', setting)
    end
end)

mp.register_event('start-file', function()
    if startup_browser then
        startup_browser:kill()
        startup_browser = nil
    end
    live_streams = nil
    quality_state = nil
    mp.set_property_native('user-data/newbv/byline', '')
end)

local function switch_live(index, quality)
    if not live_streams then return end
    if valid_quality(quality, 30000) then
        preferences.live = quality
        save_preferences()
    end
    live_choice = {url = live_streams.url, index = index, quality = quality or live_streams.quality}
    mp.commandv('loadfile', live_streams.url, 'replace')
end

mp.register_event('end-file', function() quality_state = nil end)

mp.add_hook('on_load_fail', 5, function()
    if not live_streams or live_streams.index >= #live_streams.lines then return end
    local index = live_streams.index + 1
    tell(('直播线路 %d 无法打开，正在尝试线路 %d。'):format(live_streams.index, index))
    live_streams.index = index
    mp.set_property('stream-open-filename', live_streams.lines[index])
end)

dofile(utils.join_path(directory, 'player.lua'))({
    directory = directory, request = request, tell = tell,
    accepts = playback_url, is_video = video_url,
    browse_detail = function(view) browse(mp.get_property('path'), view) end,
    get_live = function() return live_streams end,
    switch_live = switch_live,
    use_highest = use_highest,
    remember_video = function(id)
        if not quality_state or not id then return end
        for _, track in ipairs(mp.get_property_native('track-list', {})) do
            if track.id == id and track.type == 'video' then
                remember_track(current_quality_track(quality_state, track))
                return
            end
        end
    end,
    part_title = function(address) return part_titles[address] end,
    play_selection = play_selection,
})
