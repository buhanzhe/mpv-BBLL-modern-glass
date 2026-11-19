-- Loaded by uosc_danmaku so settings can update its renderer in place.
local utils = require('mp.utils')
local local_data = os.getenv('LOCALAPPDATA')
if not local_data then return end
local path = utils.join_path(local_data, 'mpv-newbv/settings.json')
local last_content
local applied = {}
local visibility
local allow_top, allow_bottom = true, true

local style = {
    dmSize = {key = 'fontsize', min = 16, max = 64, rebuild = true},
    dmOpacity = {key = 'opacity', min = 0, max = 80, transform = function(n) return 1 - n / 100 end},
    dmSpeed = {key = 'scrolltime', min = 0.75, max = 2, rebuild = true,
        transform = function(n, original) return original / n end},
    dmArea = {key = 'displayarea', min = 10, max = 100, transform = function(n) return n / 100 end},
    dmDensity = {key = 'max_screen_danmaku', min = 0, max = 64, rebuild = true},
}
for _, spec in pairs(style) do spec.original = options[spec.key] end

function newbv_allows_danmaku(comment)
    return (allow_top or comment.type ~= 5) and (allow_bottom or comment.type ~= 4)
end

local function apply_style(data)
    local repaint, rebuild = false, false
    for name, spec in pairs(style) do
        local value = data[name]
        if type(value) ~= 'number' or value < spec.min or value > spec.max then value = nil end
        if applied[name] ~= value then
            applied[name] = value
            if value == nil then
                options[spec.key] = spec.original
            elseif spec.transform then
                options[spec.key] = spec.transform(value, spec.original)
            else
                options[spec.key] = math.floor(value)
            end
            repaint = true
            rebuild = rebuild or spec.rebuild
        end
    end
    local top, bottom = data.dmTop ~= false, data.dmBottom ~= false
    if top ~= allow_top or bottom ~= allow_bottom then repaint, rebuild = true, true end
    allow_top, allow_bottom = top, bottom
    if COMMENTS ~= nil then
        if rebuild then convert_danmaku_to_ass_events(true) end
        if repaint and ENABLED then render() end
    end
end

local function sync(file_loaded)
    local file = io.open(path, 'rb')
    local content = file and (file:read(16385) or '') or ''
    if file then file:close() end
    local previous_visibility = visibility
    if content ~= last_content and #content <= 16384 then
        local data = content == '' and {} or utils.parse_json(content)
        if type(data) == 'table' then
            last_content = content
            visibility = (data.danmaku == 'on' or data.danmaku == 'off') and data.danmaku or nil
            apply_style(data)
        end
    end
    if not visibility or (not file_loaded and visibility == previous_visibility) then return end
    local video = mp.get_property_native('current-tracks/video')
    if video and not video.image and not video.albumart then
        if visibility == 'on' and ENABLED and (COMMENTS ~= nil or is_async_running()) then return end
        mp.commandv('script-message-to', mp.get_script_name(), 'set', 'show_danmaku', visibility)
    end
end

mp.set_property_bool('user-data/newbv/danmaku-adapter', true)
sync(false)
mp.add_periodic_timer(0.3, sync)
mp.register_event('file-loaded', function() sync(true) end)
