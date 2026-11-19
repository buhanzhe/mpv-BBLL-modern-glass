local options = {expected_width = 0, select_lower = false}
require('mp.options').read_options(options, 'newbv_quality_smoke')
local expected

mp.observe_property('video-params/w', 'number', function(_, width)
    if expected and width == expected then
        mp.add_timeout(0.25, function()
            mp.msg.info('QUALITY_SWITCH_OK: ' .. width)
            mp.commandv('quit', '0')
        end)
    end
end)

mp.register_event('playback-restart', function()
    if expected then return end
    local width = mp.get_property_number('video-params/w')
    if options.expected_width > 0 and width ~= options.expected_width then
        mp.msg.error(('Expected width %d, got %d.'):format(options.expected_width, width or 0))
        mp.commandv('quit', '1')
        return
    end
    if not options.select_lower then
        mp.msg.info('QUALITY_RESTORED_OK: ' .. width)
        mp.commandv('quit', '0')
        return
    end
    local lower
    local widest = 0
    for _, track in ipairs(mp.get_property_native('track-list', {})) do
        local track_width = track['demux-w']
        if track.type == 'video' and track_width then
            widest = math.max(widest, track_width)
            if track.codec == 'h264' and track_width < width then lower = track end
        end
    end
    if width ~= widest or not lower then mp.commandv('quit', '1'); return end
    expected = lower['demux-w']
    mp.set_property_number('vid', lower.id)
end)

mp.add_timeout(20, function() mp.commandv('quit', '1') end)
