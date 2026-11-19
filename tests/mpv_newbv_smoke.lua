local requested = false
local completed = false

mp.add_timeout(0.5, function()
    mp.commandv('keypress', 'Alt+Shift+b')
    mp.add_timeout(0.3, function()
        for character in ('mpv'):gmatch('.') do mp.commandv('keypress', character) end
        mp.commandv('keypress', 'ENTER')
        requested = true
    end)
end)

mp.register_event('start-file', function()
    local path = mp.get_property('path', '')
    if requested and path:match('^https://www%.bilibili%.com/video/BV%w+$') then
        completed = true
        mp.msg.info('NewBV search selection opened a Bilibili video.')
        mp.commandv('quit', '0')
    end
end)

mp.add_periodic_timer(1.5, function()
    if requested and not completed then mp.commandv('keypress', 'ENTER') end
end)

mp.add_timeout(19, function()
    if not completed then
        mp.msg.error('NewBV search selection did not open a video before timeout.')
        mp.commandv('quit', '1')
    end
end)
