local utils = require('mp.utils')
local input = require('mp.input')

return function(hooks)
    local panel = mp.create_osd_overlay('ass-events')
    panel.z = 92
    local icons = {}
    local visible = false
    local selected = 1
    local position = false
    local previous_osc
    local previous_modernz
    local idle_timer
    local interval
    local last_back = -10
    local subtitle_id
    local subtitle_files = {}
    local baseline_order
    local danmaku_property = 'user-data/uosc_danmaku/danmaku-switch-on'
    local buttons
    local render
    local close

    local function literal(value)
        local safe = mp.command_native({'escape-ass', tostring(value or '')})
        return (safe or ''):gsub('[\r\n]', ' ')
    end

    local function stamp(seconds)
        seconds = math.max(0, math.floor(seconds or 0))
        if seconds >= 3600 then return ('%d:%02d:%02d'):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60) end
        return ('%02d:%02d'):format(math.floor(seconds / 60), seconds % 60)
    end

    local function ensure_timer()
        if idle_timer then idle_timer:kill() end
        idle_timer = mp.add_timeout(5, close)
    end

    local function select(prompt, items, apply)
        close()
        input.select({prompt = prompt, items = items, submit = apply})
    end

    local function pick_track(kind)
        local names, ids, current = {'关闭'}, {'no'}, 1
        local property = ({video = 'vid', audio = 'aid', sub = 'sid'})[kind]
        for _, track in ipairs(mp.get_property_native('track-list', {})) do
            if track.type == kind then
                local name = track.title or ('轨道 ' .. track.id)
                if not track.title and track.codec then name = name .. ' / ' .. track.codec end
                names[#names + 1], ids[#ids + 1] = name, tostring(track.id)
                if track.selected then current = #ids end
            end
        end
        local reset_index
        if kind == 'video' and hooks.accepts(mp.get_property('path', '')) then
            names[#names + 1] = '清除画质记忆（下次自动选择）'
            reset_index = #names
        end
        close()
        input.select({
            prompt = ({video = '画质', audio = '音轨', sub = '字幕'})[kind], items = names, default_item = current,
            submit = function(index)
                if index == reset_index then
                    hooks.use_highest()
                    hooks.tell('已清除画质记忆，下次将自动选择画质。')
                elseif ids[index] then
                    if kind == 'video' then hooks.remember_video(tonumber(ids[index])) end
                    mp.set_property(property, ids[index])
                end
            end,
        })
    end

    local function network_subtitles()
        close()
        local path = mp.get_property('path', '')
        if not hooks.is_video(path) then pick_track('sub'); return end
        hooks.tell('正在读取字幕…')
        local cookie = mp.get_property_number('playlist-pos', -1)
        local function is_current()
            return path == mp.get_property('path') and cookie == mp.get_property_number('playlist-pos', -1)
        end
        hooks.request('subtitles', path, function(data)
            if not is_current() then return end
            if not data or not data.tracks or #data.tracks == 0 then pick_track('sub'); return end
            local labels = {'已有字幕轨', '关闭字幕'}
            for _, text in ipairs(data.tracks) do labels[#labels + 1] = text.name ~= '' and text.name or text.language end
            select('B 站字幕', labels, function(index)
                if not is_current() then return end
                if index == 1 then pick_track('sub'); return end
                if index == 2 then mp.set_property('sid', 'no'); return end
                local track = data.tracks[index - 2]
                if not track then return end
                hooks.request('subtitle-track', track.url, function(result)
                    if not is_current() then return end
                    if not result or not result.vtt then hooks.tell('字幕下载失败。'); return end
                    if subtitle_id then mp.commandv('sub-remove', tostring(subtitle_id)); subtitle_id = nil end
                    local root = os.getenv('LOCALAPPDATA')
                    if not root then return end
                    local file = utils.join_path(root, ('newbv-sub-%d-%d.vtt'):format(utils.getpid(), math.floor(mp.get_time() * 1000)))
                    local output = io.open(file, 'wb')
                    if not output then hooks.tell('无法保存临时字幕文件。'); return end
                    output:write(result.vtt)
                    output:close()
                    subtitle_files[#subtitle_files + 1] = file
                    mp.commandv('sub-add', file, 'select', track.name, track.language)
                    subtitle_id = mp.get_property_number('sid')
                end)
            end)
        end)
    end

    local function episodes()
        local path = mp.get_property('path', '')
        local list = mp.get_property_native('playlist', {})
        local names = {}
        for index, entry in ipairs(list) do names[index] = hooks.part_title(entry.filename) or entry.title or ('第 ' .. index .. ' 集') end
        if #list > 1 then
            close()
            input.select({prompt = '选集', items = names, default_item = (mp.get_property_number('playlist-pos', 0) + 1),
                submit = function(index) if list[index] then mp.set_property_number('playlist-pos', index - 1) end end})
        elseif hooks.is_video(path) then
            close()
            hooks.request('detail', path, function(data)
                if mp.get_property('path') ~= path or not data or not data.parts then return end
                names = {}
                for index, part in ipairs(data.parts) do names[index] = 'P' .. part.page .. '  ' .. part.title end
                select('选集', names, function(index)
                    if data.parts[index] then hooks.play_selection({url = data.parts[index].url, queue = data.parts}) end
                end)
            end)
        elseif path:match('/bangumi/play/ep%d+$') then
            close()
            hooks.request('detail', path, function(data)
                if mp.get_property('path') ~= path or not data or not data.parts then return end
                names = {}
                for index, part in ipairs(data.parts) do names[index] = part.page .. '  ' .. part.title end
                select('选集', names, function(index)
                    if data.parts[index] then hooks.play_selection({url = data.parts[index].url, queue = data.parts}) end
                end)
            end)
        else
            hooks.tell('没有其他可选剧集。')
        end
    end

    local function playback_order()
        local function entries()
            local ids = {}
            for index, entry in ipairs(mp.get_property_native('playlist', {})) do ids[index] = tostring(entry.id) end
            return ids
        end
        local current = entries()
        local baseline = {}
        for _, id in ipairs(baseline_order or {}) do baseline[id] = true end
        if not baseline_order or #baseline_order ~= #current then baseline_order = current
        else
            for _, id in ipairs(current) do if not baseline[id] then baseline_order = current; break end end
        end
        select('播放顺序', {'顺序播放', '单集循环', '列表循环', '随机播放', '播完停止', '倒序播放'}, function(index)
            mp.set_property('loop-file', index == 2 and 'inf' or 'no')
            mp.set_property('loop-playlist', index == 3 and 'inf' or 'no')
            if index == 4 then mp.commandv('playlist-shuffle')
            elseif index == 1 or index == 6 then
                local target = {}
                for part = 1, #baseline_order do
                    target[part] = baseline_order[index == 6 and (#baseline_order - part + 1) or part]
                end
                for destination, id in ipairs(target) do
                    local now = entries()
                    for source = destination, #now do
                        if now[source] == id then
                            if source ~= destination then mp.commandv('playlist-move', tostring(source - 1), tostring(destination - 1)) end
                            break
                        end
                    end
                end
            elseif index == 5 then mp.commandv('playlist-clear')
            end
        end)
    end

    local function choose_line()
        local live = hooks.get_live()
        if not live then hooks.tell('没有其他直播线路。'); return end
        local names = {}
        for index = 1, #live.lines do names[index] = '线路 ' .. index end
        select('直播线路', names, function(index) if names[index] then hooks.switch_live(index) end end)
    end

    local function live_quality()
        local live = hooks.get_live()
        if not live or #live.qualities == 0 then hooks.tell('该直播未提供其他画质。'); return end
        local labels = {}
        for index, quality in ipairs(live.qualities) do labels[index] = quality.title end
        select('直播画质', labels, function(index)
            local quality = live.qualities[index]
            if quality then hooks.switch_live(1, quality.id) end
        end)
    end

    local function settings()
        local live = hooks.get_live()
        local choices = live and {'直播画质', '直播线路', '音轨', '画面比例'} or {'画质', '音轨', '字幕', '播放速度', '画面比例'}
        local mode
        select('播放设置', choices, function(index)
            mode = choices[index]
            if mode == '直播线路' then choose_line()
            elseif mode == '直播画质' then live_quality()
            elseif mode == '画质' then pick_track('video')
            elseif mode == '音轨' then pick_track('audio')
            elseif mode == '字幕' then network_subtitles()
            elseif mode == '播放速度' then
                local speeds = {0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2}
                local labels = {}
                for position, speed in ipairs(speeds) do labels[position] = speed .. '×' end
                select('播放速度', labels, function(position) if speeds[position] then mp.set_property_number('speed', speeds[position]) end end)
            elseif mode == '画面比例' then
                select('画面比例', {'原始比例', '铺满画面', '16:9', '4:3'}, function(index)
                    local ratios = {'no', 'no', '16:9', '4:3'}
                    if not ratios[index] then return end
                    mp.set_property('video-aspect-override', ratios[index])
                    mp.set_property_number('panscan', index == 2 and 1 or 0)
                end)
            end
        end)
    end

    local function rect(x, y, width, height, colour, alpha)
        return ('{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}m 0 0 l %d 0 %d %d 0 %d'):format(
            x, y, colour, alpha or 0, width, width, height, height)
    end

    local function icon(name, x, y)
        if icons[name] == nil then
            local paths = {utils.join_path(hooks.directory, 'bbll-vectors/' .. name .. '.svg')}
            local function polygon(path)
                local shapes = {}
                local cursor, current_x, current_y, start_x, start_y = 1, 0, 0, 0, 0
                local cmd
                local function number()
                    local _, tail, value = path:find('^[%s,]*([+-]?[%d%.]+)', cursor)
                    if not tail then error('invalid vector') end
                    cursor = tail + 1
                    return assert(tonumber(value))
                end
                local function point(relative)
                    local px, py = number(), number()
                    return relative and current_x + px or px, relative and current_y + py or py
                end
                local function emit(op, ...)
                    local points = {...}
                    for index, value in ipairs(points) do points[index] = math.floor(value * 2 + 0.5) end
                    shapes[#shapes + 1] = op .. ' ' .. table.concat(points, ' ')
                end
                while cursor <= #path do
                    local _, tail, token = path:find('^[%s,]*([A-Za-z])', cursor)
                    if token then cmd, cursor = token, tail + 1
                    elseif not path:find('^[%s,]*[+-]?[%d%.]', cursor) then break end
                    local op = cmd:upper()
                    local relative = cmd ~= op
                    if op == 'M' or op == 'L' then
                        current_x, current_y = point(relative)
                        emit(op:lower(), current_x, current_y)
                        if op == 'M' then start_x, start_y = current_x, current_y; cmd = relative and 'l' or 'L' end
                    elseif op == 'H' then
                        local px = number()
                        current_x = relative and current_x + px or px
                        emit('l', current_x, current_y)
                    elseif op == 'V' then
                        local py = number()
                        current_y = relative and current_y + py or py
                        emit('l', current_x, current_y)
                    elseif op == 'C' then
                        local x1, y1 = point(relative)
                        local x2, y2 = point(relative)
                        current_x, current_y = point(relative)
                        emit('b', x1, y1, x2, y2, current_x, current_y)
                    elseif op == 'Q' then
                        local x1, y1 = point(relative)
                        local px, py = point(relative)
                        emit('b', current_x + (x1 - current_x) * 2 / 3, current_y + (y1 - current_y) * 2 / 3,
                            px + (x1 - px) * 2 / 3, py + (y1 - py) * 2 / 3, px, py)
                        current_x, current_y = px, py
                    elseif op == 'Z' then
                        emit('l', start_x, start_y)
                        current_x, current_y, cmd = start_x, start_y, nil
                    else error('unsupported vector') end
                end
                return table.concat(shapes, ' ')
            end
            icons[name] = false
            for _, path in ipairs(paths) do
                local file = io.open(path, 'rb')
                if file then
                    local svg = file:read('*a')
                    file:close()
                    local width, height = svg:match('viewBox="0 0 ([%d%.]+) ([%d%.]+)"')
                    if width and height then
                        local shapes = {}
                        for glyph in svg:gmatch(' d="([^"]+)"') do
                            local ok, shape = pcall(polygon, glyph)
                            if not ok then shapes = {}; break end
                            shapes[#shapes + 1] = shape
                        end
                        if #shapes > 0 then icons[name] = {path = table.concat(shapes, ' '), w = tonumber(width), h = tonumber(height)} end
                    end
                    break
                end
            end
        end
        local glyph = icons[name]
        if not glyph then return end
        return ('{\\an7\\pos(%d,%d)\\bord0\\shad0\\1c&HFFFFFF&\\fscx%.3f\\fscy%.3f\\p2}'):format(
            x, y, 3000 / glyph.w, 3000 / glyph.h) .. glyph.path
    end

    local function play_pause()
        mp.commandv('cycle', 'pause')
        render()
        ensure_timer()
    end

    local function browse_current(view)
        close()
        hooks.browse_detail(view)
    end

    local function toggle_danmaku()
        local enabled = mp.get_property_bool(danmaku_property, false)
        mp.commandv('script-message-to', 'uosc_danmaku', 'set', 'show_danmaku', enabled and 'off' or 'on')
    end

    buttons = {
        {'播放', 'icon_play', play_pause, '▶'},
        {'设置', 'player_icon_setting', settings, '⚙'},
        {'选集', 'icon_list', episodes, '▤'},
        {'字幕', 'icon_subtitles', network_subtitles, 'CC'},
        {'弹幕', 'icon_dm_enable', toggle_danmaku, '弹'},
        {'更多', 'icon_more', function() browse_current('actions') end, '⋯'},
        {'UP 主投稿', 'icon_user', function() browse_current('author') end, 'UP'},
        {'相关视频', 'arrow_down', function() browse_current('related') end, '↓'},
        {'播放顺序', 'icon_order_all_play', playback_order, '↻'},
        {'关闭', 'icon_close', function() close(); mp.commandv('stop') end, '×'},
    }

    render = function()
        if not visible then return end
        local clock = (tonumber(os.date('%H')) < 12 and '上午' or '下午') .. os.date('%I:%M'):gsub('^0', '')
        local current = mp.get_property_number('time-pos', 0)
        local duration = mp.get_property_number('duration', 0)
        local percent = duration > 0 and math.min(1, math.max(0, current / duration)) or 0
        local title = mp.get_property('media-title', '')
        local part = hooks.part_title(mp.get_property('path', ''))
        local byline = mp.get_property_native('user-data/newbv/byline', '')
        if part then byline = byline ~= '' and byline .. ' · ' .. part or part end
        local lines = {}
        for strip = 0, 15 do lines[#lines + 1] = rect(0, 480 + strip * 15, 1280, 15, '000000', 233 - 13 * strip) end
        lines[#lines + 1] = ('{\\an9\\pos(1247,20)\\fs28\\bord0}%s'):format(clock)
        lines[#lines + 1] = ('{\\an7\\pos(37,524)\\fs27\\b1\\bord1\\q2}%s'):format(literal(title))
        if byline ~= '' then lines[#lines + 1] = ('{\\an7\\pos(37,564)\\fs19\\bord1\\q2}%s'):format(literal(byline)) end
        lines[#lines + 1] = rect(20, 611, 1240, 4, 'A0A0A0', 128)
        lines[#lines + 1] = rect(20, 611, math.floor(percent * 1240), 4, 'F2A1C6')
        lines[#lines + 1] = rect(15 + math.floor(percent * 1240), 607, 10, 12, 'F2A1C6', position and 0 or 70)
        for index, button in ipairs(buttons) do
            local x = 20 + (index - 1) * 67
            if index == selected and not position then lines[#lines + 1] = rect(x, 633, 67, 67, 'BF82A2', 32) end
            local name = index == 1 and not mp.get_property_bool('pause') and 'icon_pause' or button[2]
            if name == 'icon_dm_enable' and not mp.get_property_bool(danmaku_property, false) then name = 'icon_dm_disable' end
            lines[#lines + 1] = icon(name, x + 18, 651) or ('{\\an5\\pos(%d,667)\\fs25\\bord0}%s'):format(x + 34, literal(button[4]))
        end
        lines[#lines + 1] = ('{\\an6\\pos(1253,667)\\fs23\\bord0}%s · %s'):format(stamp(current), duration > 0 and stamp(duration) or '直播')
        panel.res_x, panel.res_y, panel.data = 1280, 720, table.concat(lines, '\n')
        panel:update()
    end

    local bindings = {'LEFT','RIGHT','UP','DOWN','ENTER','ESC','SPACE'}
    close = function()
        if not visible then return end
        visible = false
        if idle_timer then idle_timer:kill() end
        if interval then interval:kill() end
        for index = 1, #bindings do mp.remove_key_binding('newbv-panel-' .. index) end
        panel:remove()
        if previous_osc then mp.set_property('osc', previous_osc) end
        if previous_modernz then mp.commandv('script-message-to', 'modernz', 'osc-visibility', previous_modernz, 'yes') end
    end

    local function key(command)
        if command == 'ESC' then close(); last_back = mp.get_time(); return end
        if command == 'LEFT' or command == 'RIGHT' then
            local step = command == 'RIGHT' and 1 or -1
            if position then mp.commandv('seek', tostring(5 * step), 'relative')
            else selected = math.min(#buttons, math.max(1, selected + step)) end
        elseif command == 'UP' then position = true
        elseif command == 'DOWN' then position = false
        elseif command == 'SPACE' then play_pause()
        elseif command == 'ENTER' and not position then buttons[selected][3]() end
        if visible then render(); ensure_timer() end
    end

    local function toggle()
        if visible then close(); return end
        if not hooks.accepts(mp.get_property('path', '')) then return end
        visible, selected, position = true, 1, false
        previous_osc = mp.get_property('osc')
        mp.set_property('osc', 'no')
        previous_modernz = mp.get_property_native('user-data/osc/visibility')
        if previous_modernz then mp.commandv('script-message-to', 'modernz', 'osc-visibility', 'never', 'yes') end
        for index, command in ipairs(bindings) do
            mp.add_forced_key_binding(command, 'newbv-panel-' .. index, function() key(command) end)
        end
        interval = mp.add_periodic_timer(0.25, render)
        render()
        ensure_timer()
    end

    mp.add_key_binding('Alt+p', 'controls', toggle)
    mp.add_key_binding('Alt+q', 'quality', function()
        if hooks.get_live() then choose_line() else pick_track('video') end
    end)
    mp.add_key_binding('Alt+i', 'current-detail', function()
        if hooks.is_video(mp.get_property('path', '')) then browse_current() end
    end)
    mp.add_key_binding('Alt+c', 'comments', function()
        if hooks.is_video(mp.get_property('path', '')) then browse_current('comments') end
    end)
    mp.add_key_binding(nil, 'remote-back', function()
        if visible then close(); last_back = mp.get_time()
        elseif mp.get_time() - last_back < 0.8 and hooks.is_video(mp.get_property('path', '')) then browse_current()
        else last_back = mp.get_time(); toggle() end
    end)
    mp.register_script_message('controls', toggle)
    mp.register_event('end-file', function()
        close()
        subtitle_id = nil
        for _, path in ipairs(subtitle_files) do os.remove(path) end
        subtitle_files = {}
    end)
    mp.register_event('shutdown', function() for _, path in ipairs(subtitle_files) do os.remove(path) end end)
end
