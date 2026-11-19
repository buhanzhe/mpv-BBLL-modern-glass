local utils = require('mp.utils')

return function(directory, request)
    local active

    local function complete(flow, state)
        if active ~= flow then return end
        active = nil
        if flow.request then mp.abort_async_command(flow.request) end
        if flow.timer then flow.timer:kill() end
        flow.update({state = state})
    end

    local function cancel()
        if active then complete(active, 'cancelled') end
    end

    local function check()
        local flow = active
        if not flow or not flow.timer or flow.request then return end
        flow.timer:kill()
        flow.timer = nil
        flow.poll(true)
    end

    local function start(update)
        cancel()
        local flow = {update = update, errors = 0}
        active = flow
        local function poll(manual)
            flow.timer = nil
            if mp.get_time() >= flow.expires then complete(flow, 'expired'); return end
            flow.request = request('qr-poll', flow.key, function(result)
                if active ~= flow then return end
                flow.request = nil
                if not result then
                    flow.errors = flow.errors + 1
                    if flow.errors >= 3 then complete(flow, 'error'); return end
                else
                    flow.errors = 0
                    local state = result.state
                    if state == 'success' or state == 'expired' or state == 'credentials_missing' then
                        complete(flow, state)
                        return
                    end
                    if state == 'scanned' and (manual or not flow.scanned) then
                        flow.scanned = true
                        update({state = 'scanned'})
                    elseif manual and state == 'waiting' then
                        update({state = 'waiting'})
                    end
                end
                flow.timer = mp.add_timeout(2.5, poll)
            end)
        end
        flow.poll = poll
        flow.request = request('qr-generate', '', function(result)
            if active ~= flow then return end
            flow.request = nil
            if not result or not result.url or not result.key then complete(flow, 'error'); return end
            local loaded, encoder = pcall(dofile, utils.join_path(directory, 'qrencode.lua'))
            local encoded, ok, matrix
            if loaded then encoded, ok, matrix = pcall(encoder.qrcode, result.url) end
            if not encoded or not ok then complete(flow, 'error'); return end
            local rows = {}
            for y = 1, #matrix do
                local row = {}
                for x = 1, #matrix do row[x] = matrix[x][y] > 0 and '1' or '0' end
                rows[y] = table.concat(row)
            end
            flow.key, flow.expires = result.key, mp.get_time() + 180
            update({state = 'ready', rows = rows})
            flow.timer = mp.add_timeout(2.5, poll)
        end)
    end

    return cancel, start, check
end
