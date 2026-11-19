local utils = require('mp.utils')
local options = {script_dir = ''}
require('mp.options').read_options(options, 'newbv_login_smoke')
local states = {}
local proof_url = 'https://account.bilibili.com/h5/account-h5/auth/scan-web?qrcode_key=0123456789abcdef0123456789abcdef'
local polls = 0
local cancel, start, check

local function request(action, _, callback)
    mp.add_timeout(0.01, function()
        if action == 'qr-generate' then callback({url = proof_url, key = 'fixture'}) end
        if action == 'qr-poll' then
            polls = polls + 1
            callback({state = polls == 1 and 'scanned' or 'success'})
        end
    end)
end

cancel, start, check = dofile(utils.join_path(options.script_dir, 'login.lua'))(options.script_dir, request)
start(function(update)
    states[#states + 1] = update.state
    if update.state == 'ready' then
        for _, row in ipairs(update.rows) do
            if #row ~= #update.rows or not row:match('^[01]+$') then mp.commandv('quit', '1'); return end
        end
        mp.add_timeout(0.05, check)
    elseif update.state == 'scanned' then
        mp.add_timeout(0.05, check)
    elseif update.state == 'success' then
        start(function(reopened)
            if reopened.state == 'ready' then mp.add_timeout(0.05, cancel) end
            if reopened.state == 'cancelled' then
                local valid = table.concat(states, ',') == 'ready,scanned,success' and polls == 2
                mp.commandv('quit', valid and '0' or '1')
            end
        end)
    end
end)
mp.add_timeout(8, function() mp.commandv('quit', '1') end)
