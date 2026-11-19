local utils = require('mp.utils')
local options = {screenshot = '', check_modernz = false}
require('mp.options').read_options(options, 'newbv_player_smoke')
local started
local initial_osc
local initial_modernz

mp.register_event('file-loaded', function()
    if started then return end
    started = true
    mp.add_timeout(0.5, function()
        mp.set_property_bool('pause', true)
        initial_osc = mp.get_property('osc')
        initial_modernz = mp.get_property_native('user-data/osc/visibility')
        mp.commandv('script-message-to', 'newbv', 'controls')
        mp.add_timeout(0.6, function()
            if mp.get_property('osc') ~= 'no' then mp.commandv('quit', '1'); return end
            if options.check_modernz and mp.get_property_native('user-data/osc/visibility') ~= 'never' then mp.commandv('quit', '1'); return end
            if options.screenshot ~= '' then mp.commandv('screenshot-to-file', options.screenshot, 'window') end
            mp.commandv('keypress', 'RIGHT')
            mp.commandv('keypress', 'ESC')
            mp.add_timeout(0.2, function()
                if mp.get_property('osc') ~= initial_osc then mp.commandv('quit', '1'); return end
                if options.check_modernz and mp.get_property_native('user-data/osc/visibility') ~= initial_modernz then mp.commandv('quit', '1'); return end
                mp.msg.info('BBLL_PLAYER_OK: controls opened, took focus and restored the original OSC.')
                mp.commandv('quit', '0')
            end)
        end)
    end)
end)

mp.add_timeout(20, function() mp.commandv('quit', '1') end)
