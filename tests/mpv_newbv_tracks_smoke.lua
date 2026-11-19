local switched
local played_path

mp.observe_property('video-params/w', 'number', function(_, width)
    if switched and width == switched.width and mp.get_property_number('vid') == switched.id and
            mp.get_property_native('audio-params') and mp.get_property('path') == played_path then
        mp.msg.info('TRACKS_OK: switched video tracks without reloading or losing audio.')
        mp.commandv('quit', '0')
    end
end)

mp.register_event('playback-restart', function()
    if switched then return end
    local videos, audios, target = 0, 0, nil
    local width = mp.get_property_number('video-params/w')
    for _, track in ipairs(mp.get_property_native('track-list', {})) do
        if track.type == 'video' then
            videos = videos + 1
            if not track.selected and track.codec == 'h264' and track['demux-w'] and track['demux-w'] ~= width then
                target = {id = track.id, width = track['demux-w']}
            end
        elseif track.type == 'audio' then
            audios = audios + 1
        end
    end
    if videos > 1 and audios > 1 and target then
        played_path = mp.get_property('path')
        switched = target
        mp.set_property_number('vid', target.id)
    end
end)

mp.add_timeout(20, function()
    mp.msg.error('Could not switch between DASH video tracks with audio retained.')
    mp.commandv('quit', '1')
end)
