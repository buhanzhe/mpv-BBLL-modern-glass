local utils = require('mp.utils')

return function(request)
    local metadata
    local active

    local function sample(state)
        local now = mp.get_time()
        local position = mp.get_property_number('time-pos')
        if position and position >= 0 then
            if position ~= state.raw_position and not mp.get_property_bool('pause', false)
                and not mp.get_property_bool('seeking', false) then
                state.elapsed = state.elapsed + math.min(now - state.sampled_at, 2)
            end
            state.raw_position = position
            state.position = math.floor(position)
        end
        state.sampled_at = now
    end

    local function send(state, kind, done)
        local position = state.position
        local payload = {}
        for key, value in pairs(state.metadata) do payload[key] = value end
        payload.progress = position
        payload.realtime = math.floor(state.elapsed)
        payload.started = state.started
        payload.kind = kind
        state.sent_at = mp.get_time()
        state.busy = true
        request('heartbeat', utils.format_json(payload), function(result)
            state.busy = false
            if result and result.success then state.saved = position end
            if result and result.requiresLogin then state.blocked = true end
            done()
        end)
    end

    local function flush(state)
        local hook = state.closing
        if not hook or state.busy then return end
        state.closing = nil
        if not state.blocked and state.elapsed > 0 and state.position ~= state.saved then
            send(state, 2, function() hook:cont() end)
        else
            hook:cont()
        end
    end

    mp.register_event('start-file', function() metadata = nil; active = nil end)
    mp.register_event('file-loaded', function()
        if type(metadata) ~= 'table' or not metadata.cid then return end
        local pos = mp.get_property_number('time-pos', 0)
        active = {metadata = metadata, started = os.time(), sampled_at = mp.get_time(),
            elapsed = 0, raw_position = pos, position = math.floor(pos), sent_at = -math.huge}
    end)

    mp.add_periodic_timer(1, function()
        local state = active
        if not state or state.closing then return end
        sample(state)
        if not state.busy and not state.blocked and state.elapsed >= 1 and state.position ~= state.saved
            and mp.get_time() - state.sent_at >= 15 then
            send(state, state.saved == nil and 1 or 0, function() flush(state) end)
        end
    end)

    mp.add_hook('on_unload', 60, function(hook)
        local state = active
        active = nil
        if not state then return end
        sample(state)
        state.closing = hook
        hook:defer()
        flush(state)
    end)

    return {
        set = function(value) metadata = value end,
        login = function()
            if active and active.blocked then
                active.blocked = false
                active.sent_at = -math.huge
            end
        end,
    }
end
