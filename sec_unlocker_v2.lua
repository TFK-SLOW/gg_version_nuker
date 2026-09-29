local PROXY_URL = "https://dcsiteform.x10.mx/luagg_proxy.php"
local STATUS_URL = "https://dcsiteform.x10.mx/data.txt"

local function json_quote(s)
    s = tostring(s)
    return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
        local map = { ['\\']='\\\\', ['"']='\\"', ['\b']='\\b', ['\f']='\\f',
                      ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
        return map[c] or string.format('\\u%04x', string.byte(c))
    end) .. '"'
end

local function json_encode(v)
    local t = type(v)
    if v == nil then return 'null' end
    if t == 'boolean' or t == 'number' then return tostring(v) end
    if t == 'string' then return json_quote(v) end
    if t ~= 'table' then error('Cannot encode JSON type ' .. t) end
    local array, max, count = true, 0, 0
    for k in pairs(v) do
        count = count + 1
        if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then array = false else max = math.max(max, k) end
    end
    if array and max == count then
        local out = {}
        for i = 1, max do out[i] = json_encode(v[i]) end
        return '[' .. table.concat(out, ',') .. ']'
    end
    local out = {}
    for k, value in pairs(v) do out[#out + 1] = json_quote(k) .. ':' .. json_encode(value) end
    return '{' .. table.concat(out, ',') .. '}'
end

local function json_decode(s)
    -- Some Android HTTP clients include a UTF-8 BOM before otherwise valid JSON.
    if s:sub(1, 3) == '\239\187\191' then s = s:sub(4) end
    local i, n = 1, #s
    local function ws() while i <= n and s:sub(i,i):match('%s') do i = i + 1 end end
    local parse
    local function str()
        i = i + 1
        local out = {}
        while i <= n do
            local c = s:sub(i,i); i = i + 1
            if c == '"' then return table.concat(out) end
            if c == '\\' then
                local e = s:sub(i,i); i = i + 1
                local m = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
                if e == 'u' then
                    local h = s:sub(i,i+3); i = i + 4
                    local cp = tonumber(h, 16)
                    if not cp then error('Bad JSON unicode escape') end
                    if cp < 128 then out[#out+1] = string.char(cp)
                    elseif cp < 2048 then out[#out+1] = string.char(192+math.floor(cp/64),128+cp%64)
                    else out[#out+1] = string.char(224+math.floor(cp/4096),128+math.floor(cp/64)%64,128+cp%64) end
                else out[#out+1] = m[e] or error('Bad JSON escape') end
            else out[#out+1] = c end
        end
        error('Unterminated JSON string')
    end
    parse = function()
        ws(); local c = s:sub(i,i)
        if c == '"' then return str() end
        if c == '{' then
            i=i+1; ws(); local o={}
            if s:sub(i,i)=='}' then i=i+1; return o end
            while true do
                ws(); if s:sub(i,i) ~= '"' then error('Expected JSON key') end
                local k=str(); ws(); if s:sub(i,i) ~= ':' then error('Expected colon') end
                i=i+1; o[k]=parse(); ws(); local d=s:sub(i,i); i=i+1
                if d=='}' then return o elseif d~=',' then error('Expected comma') end
            end
        end
        if c == '[' then
            i=i+1; ws(); local a={}
            if s:sub(i,i)==']' then i=i+1; return a end
            while true do
                a[#a+1]=parse(); ws(); local d=s:sub(i,i); i=i+1
                if d==']' then return a elseif d~=',' then error('Expected comma') end
            end
        end
        local tail=s:sub(i)
        if tail:sub(1,4)=='true' then i=i+4; return true end
        if tail:sub(1,5)=='false' then i=i+5; return false end
        if tail:sub(1,4)=='null' then i=i+4; return nil end
        local num=tail:match('^-?%d+%.?%d*[eE]?[+-]?%d*')
        if num and num~='' then i=i+#num; return tonumber(num) end
        error('Invalid JSON at byte ' .. i)
    end
    local result=parse(); ws()
    if i <= n then error('Unexpected JSON data') end
    return result
end

local OPS = {
    { 'Money', 'money', 'amount', 'Account' }, { 'Coins', 'coin', 'amount', 'Account' },
    { 'Name', 'player_name', 'text', 'Account' }, { 'Player ID', 'player_id', 'text', 'Account' },
    { 'Wins', 'race_wins', 'amount', 'Account' }, { 'Losses', 'race_loses', 'amount', 'Account' },
    { 'W16', 'w16', 'none', 'Features' }, { 'Sirens / Lights', 'sirens', 'none', 'Features' },
    { 'Horns', 'horns', 'none', 'Features' }, { 'No Damage', 'damage', 'none', 'Features' },
    { 'Unlimited Fuel', 'fuel', 'none', 'Features' }, { 'Smoke', 'smoke', 'none', 'Features' },
    { 'Animations', 'animations', 'none', 'Features' }, { 'Wheels', 'wheels', 'none', 'Features' },
    { 'Headlights', 'headlights', 'none', 'Features' },
    { 'Houses', 'houses', 'none', 'Features' }, { 'All Levels', 'levels', 'none', 'Features' },
    { 'Max Rank', 'rank', 'none', 'Features' }, { 'Unlock All', 'unlock_all', 'none', 'Features' },
    { 'Change Email', 'change_email', 'text', 'Tools' }, { 'Change Password', 'change_password', 'text', 'Tools' },
    { 'Delete Friends', 'delete_friends', 'none', 'Tools' }, { 'Fix Account', 'fix_account', 'none', 'Tools' },
    { 'Clone Account', 'clone_account', 'clone', 'Tools' }, { 'Unlock Cars', 'unlock_cars', 'unlock', 'Tools' },
    { 'Delete Account', 'delete_account', 'confirm', 'Tools' },
}
local op_by_id, status = {}, {}
for _, op in ipairs(OPS) do op_by_id[op[2]]=op; status[op[2]]='working' end
for _, id in ipairs({'sirens','clothes','clone_account','unlock_cars'}) do status[id]='down' end

local function request(method, path, body)
    local encodedPath = path:gsub('/', function() return '%2F' end)
    local url = PROXY_URL .. '?path=' .. encodedPath
    local headers = {
        ['Content-Type']='application/json',
        ['Accept-Encoding']='identity',
        ['User-Agent']='Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36',
    }
    local res = gg.makeRequest(url, headers, body and json_encode(body) or nil)
    if type(res) == 'string' then error(res) end
    if type(res) ~= 'table' or type(res.content) ~= 'string' then error('No HTTP response content') end
    local code = tonumber(res.code or res.status or 200) or 200
    local parsed, data = pcall(json_decode, res.content)
    if not parsed then
        local sample = tostring(res.content):sub(1, 300):gsub('[\r\n]+', ' ')
        error('Server did not return JSON (HTTP ' .. code .. '). Response starts: ' .. sample)
    end
    if code < 200 or code >= 300 or data.ok == false then
        error(data.message or ('HTTP ' .. code))
    end
    return data
end

local session_id, email, password, account
local function refresh_status()
    local res=gg.makeRequest(STATUS_URL,
        { ['Accept-Encoding']='identity', ['User-Agent']='Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/126.0.0.0 Mobile Safari/537.36' })
    if type(res)=='string' then error(res) end
    if type(res)~='table' or type(res.content)~='string' then error('No status response') end
    local d=json_decode(res.content)
    local feed=type(d.status)=='table' and d.status or d
    if type(feed)~='table' then error('Unexpected status file format') end
    for id, value in pairs(feed) do
        if status[id]~=nil and (value=='working' or value=='maintenance' or value=='down') then status[id]=value end
    end
    return true
end
local function login()
    local v=gg.prompt({'Email','Password'},{'',''},{'text','text'})
    if not v then return end
    email,password=v[1],v[2]
    if email=='' or password=='' then error('Enter email and password') end
    account=request('POST','/api/login',{email=email,password=password})
    session_id=account.session_id
    if not session_id then error('Login response did not include a session ID') end
    pcall(refresh_status)
end
local function register()
    local v=gg.prompt({'Email','Password (6+ characters)'},{'',''},{'text','text'})
    if not v then return end
    if v[1]=='' or #v[2]<6 then error('Enter an email and a password of at least 6 characters') end
    request('POST','/api/register',{email=v[1],password=v[2]})
    gg.alert('Account created. You can now log in.')
end
local function run_unlock_all()
    local batch={
        'w16','sirens','horns','damage','fuel','smoke','animations','wheels',
        'headlights','clothes','houses','levels','rank'
    }
    local done, skipped, failed = {}, {}, {}
    for _, id in ipairs(batch) do
        local state=status[id] or 'unknown'
        if state~='working' then
            skipped[#skipped+1]=id..' ('..state..')'
        else
            local ok,err=pcall(function()
                request('POST','/api/operation/'..id,{session_id=session_id})
            end)
            if ok then done[#done+1]=id else failed[#failed+1]=id..' ('..tostring(err)..')' end
        end
    end
    local summary={'Unlock All finished.','Completed: '..#done,'Skipped as unavailable: '..#skipped,'Failed: '..#failed}
    if #skipped>0 then summary[#summary+1]='\nSkipped: '..table.concat(skipped,', ') end
    if #failed>0 then summary[#summary+1]='\nFailed: '..table.concat(failed,', ') end
    gg.alert(table.concat(summary,'\n'))
end

local function run_op(id)
    local op=op_by_id[id]; if not op then return end
    if not session_id then error('Log in first') end
    if status[id]~='working' then error(op[1] .. ' status: ' .. status[id]) end
    if id=='unlock_all' then return run_unlock_all() end
    local kind=op[3]; local body={session_id=session_id}
    if kind=='amount' then
        local v=gg.prompt({'Amount'},{''},{'number'}); if not v then return end
        body.amount=tonumber(v[1]); if not body.amount then error('Enter a number') end
    elseif kind=='text' then
        local v=gg.prompt({op[1]},{''},{'text'}); if not v then return end
        if v[1]=='' then error('Enter a value') end; body.value=v[1]
    elseif kind=='clone' then
        local v=gg.prompt({'Target email','Target password'},{'',''},{'text','text'}); if not v then return end
        body.target_email,body.target_password=v[1],v[2]; body.source_email,body.source_password=email,password
    elseif kind=='unlock' then
        local v=gg.prompt({'Source email','Source password'},{'',''},{'text','text'}); if not v then return end
        body.source_email,body.source_password=v[1],v[2]
    elseif kind=='confirm' then
        local v=gg.prompt({'Type DELETE to confirm'},{''},{'text'}); if not v then return end
        if v[1]~='DELETE' then error('Confirmation did not match') end; body.confirm=true
    end
    request('POST','/api/operation/'..id,body)
    gg.toast(op[1] .. ' successful')
    if op[4]=='Account' then pcall(function()
        account=request('POST','/api/login',{email=email,password=password})
    end) end
end

local STATUS_TEXT={working='Working',maintenance='Maintenance',down='Not working'}
local function account_details()
    if not account then gg.alert('Log in to view account details.'); return end
    gg.alert('ACCOUNT DETAILS\n\nPlayer Name: '..tostring(account.player_name or '—')..
        '\nPlayer ID: '..tostring(account.player_id or '—')..
        '\n\nMoney: '..tostring(account.money or 0)..
        '\nCoins: '..tostring(account.coin or 0)..
        '\nWins: '..tostring(account.race_wins or 0)..
        '\nLosses: '..tostring(account.race_loses or 0))
end

local function category_menu(category, title)
    local items={}
    for _,op in ipairs(OPS) do
        if op[4]==category then
            local state=status[op[2]] or 'unknown'
            items[#items+1]={op=op, label=op[1]..'  ·  '..(STATUS_TEXT[state] or 'Status unavailable')}
        end
    end
    while true do
        local choices={}
        for _,entry in ipairs(items) do choices[#choices+1]=entry.label end
        choices[#choices+1]='Back'
        local selected=gg.choice(choices,nil,title)
        if not selected or selected==#choices then return end
        local entry=items[selected]
        local state=status[entry.op[2]] or 'unknown'
        if state~='working' then
            gg.alert(entry.op[1]..' is '..(STATUS_TEXT[state] or 'unavailable')..'.')
        else
            local ok,err=pcall(run_op,entry.op[2])
            if not ok then gg.alert('Operation failed:\n'..tostring(err)) end
        end
    end
end

local function authenticated_menu()
    while session_id do
        local selected=gg.choice({
            "<font color='#00FF00'> Account details</font>",
            "<font color='#00FF00'> Money / Account</font> ",
            "<font color='#00FF00'> Features</font>",
            "<font color='#00FF00'> Account Tools</font>",
            "<font color='#00FF00'> Refresh option status</font>",
            "<font color='#00FF00'> Logout</font>",
            "<font color='#00FF00'> Exit script</font>"
        },nil,'Sec Asada Official Sc')
        if not selected then return false end
        if selected==1 then account_details()
        elseif selected==2 then category_menu('Account','MONEY / ACCOUNT')
        elseif selected==3 then category_menu('Features','FEATURES')
        elseif selected==4 then category_menu('Tools','ACCOUNT TOOLS')
        elseif selected==5 then
            local ok=pcall(refresh_status)
            gg.toast(ok and 'Option status refreshed' or 'Could not load status file')
        elseif selected==6 then
            pcall(function() request('POST','/api/logout',{session_id=session_id}) end)
            session_id,email,password,account=nil,nil,nil,nil
            return false
        elseif selected==7 then
            pcall(function() request('POST','/api/logout',{session_id=session_id}) end)
            return true
        end
    end
    return false
end

local function unauthenticated_menu()
    while not session_id do
        local selected=gg.choice({"<font color='#00FF00'> Login</font>","<font color='#00FF00'> Register</font>","<font color='#00FF00'> Exit script</font>"},nil,'CPM WEB TOOL  ·  BACKEND ONLINE')
        if not selected then return false end
        if selected==1 then
            local ok,err=pcall(login)
            if not ok then gg.alert('Login failed:\n'..tostring(err)) end
        elseif selected==2 then
            local ok,err=pcall(register)
            if not ok then gg.alert('Registration failed:\n'..tostring(err)) end
        elseif selected==3 then return true end
    end
    if session_id then return authenticated_menu() end
    return false
end

local function run_menu_cycle()
    local health=request('GET','/api/health')
    pcall(refresh_status)
    if session_id then return authenticated_menu() end
    return unauthenticated_menu()
end

local first=true
while true do
    if first or gg.isVisible(true) then
        first=false
        gg.setVisible(false)
        local ok,exitRequested=pcall(run_menu_cycle)
        if not ok then gg.alert('LuaGG client error:\n'..tostring(exitRequested)) end
        if ok and exitRequested then break end
    end
    gg.sleep(200)
end
gg.toast('CPM Web Tool closed')
