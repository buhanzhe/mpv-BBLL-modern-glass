local options = {codec = 'flac'}
require('mp.options').read_options(options, 'newbv_audio_smoke')
local started = false
local target
local original_video

local function verify()
    if not target then return end
    local audio = mp.get_property_native('current-tracks/audio')
    local params = mp.get_property_native('audio-params')
    if not audio or audio.id ~= target or audio.decoder ~= options.codec or not params then return end
    if mp.get_property_number('vid') ~= original_video then mp.commandv('quit', '1'); return end
    mp.msg.info(('NEWBV_AUDIO_OK codec=%s rate=%d channels=%s'):format(audio.codec, params.samplerate, params.channels))
    mp.commandv('quit', '0')
end

mp.register_event('playback-restart', function()
    if started then return end
    started = true
    original_video = mp.get_property_number('vid')
    local current = mp.get_property_native('current-tracks/audio')
    if not current or current.codec ~= 'aac' then mp.commandv('quit', '1'); return end
    for _, track in ipairs(mp.get_property_native('track-list', {})) do
        if track.type == 'audio' and track.codec == options.codec and not track.selected then
            target = track.id
            mp.set_property_number('aid', track.id)
            return
        end
    end
    mp.msg.error('Expected an alternate ' .. options.codec .. ' track.')
    mp.commandv('quit', '1')
end)

mp.add_periodic_timer(0.1, verify)
mp.add_timeout(20, function() mp.commandv('quit', '1') end)
