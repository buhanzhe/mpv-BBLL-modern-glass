$passportOrigin = 'https://passport.bilibili.com'
$apiOrigin = 'https://api.bilibili.com'

function Get-SessionPath {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'mpv-newbv\session.dpapi'
}

function Test-SessionToken([string]$Token) {
    $Token -cmatch '^[A-Za-z0-9%_,.+=:/~-]{1,4096}$'
}

function Import-SessionSecurity {
    $manifest = Join-Path $PSHOME 'Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1'
    Import-Module -Name $manifest -ErrorAction Stop
}

function Save-BiliSession([string]$Token, [string]$Csrf = '') {
    if (-not (Test-SessionToken $Token)) { throw 'Invalid session received from Bilibili.' }
    Import-SessionSecurity
    if ($Csrf -cmatch '^[a-f0-9]{32}$') { $Token += '|' + $Csrf }
    $encrypted = ConvertFrom-SecureString (ConvertTo-SecureString $Token -AsPlainText -Force)
    $path = Get-SessionPath
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $temporary = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $encrypted)
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $path) }
    } finally {
        [IO.File]::Delete($temporary)
    }
}

function Read-BiliSession([switch]$IncludeCsrf) {
    $path = Get-SessionPath
    if (-not [IO.File]::Exists($path)) { return }
    try {
        Import-SessionSecurity
        $secret = ConvertTo-SecureString ([IO.File]::ReadAllText($path))
        $token = [PSCredential]::new('Bilibili', $secret).GetNetworkCredential().Password
        $parts = $token.Split('|')
        if (Test-SessionToken $parts[0]) {
            if ($IncludeCsrf -and $parts.Count -eq 2 -and $parts[1] -cmatch '^[a-f0-9]{32}$') { return $token }
            return $parts[0]
        }
    } catch {
        return
    }
}

function New-BiliSession([string]$Token) {
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $parts = $Token.Split('|')
    if (Test-SessionToken $parts[0]) {
        $cookie = [Net.Cookie]::new('SESSDATA', $parts[0], '/')
        $cookie.Secure = $true
        $cookie.HttpOnly = $true
        $session.Cookies.Add([Uri]$apiOrigin, $cookie)
        if ($parts.Count -eq 2 -and $parts[1] -cmatch '^[a-f0-9]{32}$') {
            $csrf = [Net.Cookie]::new('bili_jct', $parts[1], '/')
            $csrf.Secure = $true
            $session.Cookies.Add([Uri]$apiOrigin, $csrf)
        }
    }
    $session
}

function Start-BiliLogin {
    $data = Invoke-PassportApi 'generate' @{} (New-BiliSession)
    [Uri]$uri = $data.url
    if ($data.qrcode_key -cnotmatch '^[a-f0-9]{32}$' -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or
        -not $uri.IsDefaultPort -or $uri.Host -notin @('account.bilibili.com', 'passport.bilibili.com') -or
        $data.url.Length -gt 512 -or $uri.Query -cnotmatch ('[?&]qrcode_key=' + $data.qrcode_key + '(?:&|$)')) {
        throw 'Bilibili returned an invalid login QR code.'
    }
    @{url = $data.url; key = $data.qrcode_key}
}

function Read-BiliLoginTicket([string]$Url) {
    [Uri]$ticket = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$ticket) -or $ticket.Scheme -ne 'https' -or
        $ticket.Host -ne 'passport.biligame.com' -or $ticket.UserInfo -or -not $ticket.IsDefaultPort -or
        $ticket.AbsolutePath -cnotin @('/crossDomain', '/x/passport-login/web/crossDomain')) { return }
    $credential = @{}
    foreach ($name in @('SESSDATA','bili_jct')) {
        if ($ticket.Query -cmatch ("[?&]$name=([^&]+)")) { $credential[$name] = $Matches[1] }
    }
    if ((Test-SessionToken $credential.SESSDATA) -and $credential.bili_jct -cmatch '^[a-f0-9]{32}$') { return $credential }
    $credential.Clear()
    $response = $null
    try {
        $request = [Net.HttpWebRequest]::Create($ticket)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 8000
        $request.ReadWriteTimeout = 8000
        $request.UserAgent = $userAgent
        $request.Referer = $passportOrigin + '/'
        $response = $request.GetResponse()
        foreach ($header in $response.Headers.GetValues('Set-Cookie')) {
            foreach ($match in [regex]::Matches($header, '(?:^|,)\s*(SESSDATA|bili_jct)=([^;,\s]+)')) {
                $credential[$match.Groups[1].Value] = $match.Groups[2].Value
            }
        }
        return $credential
    } catch { return }
    finally { if ($response) { $response.Close() } }
}

function Update-BiliLogin([string]$Key) {
    if ($Key -cnotmatch '^[a-f0-9]{32}$') { throw 'Invalid login key.' }
    $session = New-BiliSession
    $data = Invoke-PassportApi 'poll' @{qrcode_key = $Key} $session
    switch ([string]$data.code) {
        '86101' { @{state = 'waiting'} }
        '86090' { @{state = 'scanned'} }
        '86038' { @{state = 'expired'} }
        '0' {
            $cookies = $session.Cookies.GetCookies([Uri]$apiOrigin)
            $token, $csrf = $cookies['SESSDATA'].Value, $cookies['bili_jct'].Value
            if (-not (Test-SessionToken $token) -or $csrf -cnotmatch '^[a-f0-9]{32}$') {
                $credential = Read-BiliLoginTicket $data.url
                $token, $csrf = $credential.SESSDATA, $credential.bili_jct
            }
            if (-not (Test-SessionToken $token) -or $csrf -cnotmatch '^[a-f0-9]{32}$') {
                return @{state = 'credentials_missing'}
            }
            Save-BiliSession $token $csrf
            @{state = 'success'}
        }
        default { throw 'Unexpected Bilibili login state.' }
    }
}

function Invoke-BiliPost([string]$Path, [hashtable]$Form, [int]$Timeout = 8) {
    $csrf = $script:apiSession.Cookies.GetCookies([Uri]$apiOrigin)['bili_jct'].Value
    if (-not $csrf) { return @{requiresLogin = $true} }
    $Form.csrf = $csrf
    $request = @{
        Uri = $apiOrigin + $Path; Method = 'Post'; Body = $Form; TimeoutSec = $Timeout
        UseBasicParsing = $true; MaximumRedirection = 0; WebSession = $script:apiSession
        UserAgent = $userAgent; Headers = @{Referer = $referrer; Origin = 'https://www.bilibili.com'}
    }
    try { $response = Invoke-WebRequest @request }
    catch { throw 'Bilibili did not accept the operation.' }
    $result = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json
    if ($result.code -in @(-101, -111)) { return @{requiresLogin = $true} }
    if ($null -eq $result.code -or $result.code -ne 0) { throw "Bilibili rejected the operation [$($result.code)]." }
    @{success = $true}
}

function Send-PlaybackHistory([string]$Value) {
    $report = ConvertFrom-Json -InputObject $Value
    $idPattern = '^[1-9][0-9]{0,18}$'
    $timePattern = '^[0-9]{1,10}$'
    if ($report.cid -notmatch $idPattern -or $report.type -notin @(3,4) -or $report.kind -notin @(0,1,2) -or
        $report.progress -notmatch $timePattern -or $report.realtime -notmatch $timePattern -or $report.started -notmatch $timePattern) {
        throw 'Invalid playback history record.'
    }
    $form = @{cid = $report.cid; type = $report.type; dt = 2; play_type = $report.kind
        played_time = $report.progress; realtime = $report.realtime; start_ts = $report.started}
    if ($report.bvid -cmatch '^BV[A-Za-z0-9]{10}$') { $form.bvid = $report.bvid }
    elseif ($report.aid -match $idPattern) { $form.aid = $report.aid }
    else { throw 'Missing video ID for playback history.' }
    if ($report.type -eq 4) {
        if ($report.epid -notmatch $idPattern -or $report.sid -notmatch $idPattern) { throw 'Missing episode ID for playback history.' }
        $form.epid = $report.epid
        $form.sid = $report.sid
        if ($report.subtype -in @(1,2,3,4,5,7)) { $form.sub_type = $report.subtype }
    }
    Invoke-BiliPost '/x/click-interface/web/heartbeat' $form 3
}

function Invoke-VideoAction([string]$Value) {
    switch -Regex ($Value) {
        '^like:(\d{1,19}):([12])$' {
            return Invoke-BiliPost '/x/web-interface/archive/like' @{aid = $Matches[1]; like = $Matches[2]}
        }
        '^coin:(\d{1,19}):([12])$' {
            return Invoke-BiliPost '/x/web-interface/coin/add' @{aid = $Matches[1]; multiply = $Matches[2]; select_like = 0; source = 'web_normal'}
        }
        '^triple:(\d{1,19})$' {
            return Invoke-BiliPost '/x/web-interface/archive/like/triple' @{aid = $Matches[1]}
        }
        '^later:(\d{1,19})$' {
            return Invoke-BiliPost '/x/v2/history/toview/add' @{aid = $Matches[1]}
        }
        '^favorite:(\d{1,19}):(\d{1,19}):(add|remove)$' {
            $form = @{rid = $Matches[1]; type = 2; add_media_ids = ''; del_media_ids = ''}
            if ($Matches[3] -eq 'add') { $form.add_media_ids = $Matches[2] } else { $form.del_media_ids = $Matches[2] }
            return Invoke-BiliPost '/x/v3/fav/resource/deal' $form
        }
        '^follow:(\d{1,19}):([12])$' {
            return Invoke-BiliPost '/x/relation/modify' @{fid = $Matches[1]; act = $Matches[2]; re_src = 11}
        }
        '^season:(\d{1,19}):(add|del)$' {
            return Invoke-BiliPost ('/pgc/web/follow/' + $Matches[2]) @{season_id = $Matches[1]}
        }
        default { throw 'Invalid video action.' }
    }
}

function Get-BiliAccount([switch]$Detailed) {
    if (-not $script:apiSession.Cookies.GetCookies([Uri]$apiOrigin)['SESSDATA']) { return @{state = 'signed_out'} }
    $data = Invoke-BiliApi '/x/web-interface/nav' -Nav
    if ($data.isLogin -ne $true) { return @{state = 'signed_out'} }
    $account = @{state = 'signed_in'; name = [string]$data.uname; id = [long]$data.mid}
    if ($Detailed) {
        $account.avatar = Get-CoverUrl $data.face
        $account.level = $data.level_info.current_level
        $account.coins = $data.money
        $account.vip = $data.vipStatus -eq 1
        try { $stats = Invoke-BiliApi '/x/web-interface/nav/stat' } catch { $stats = $null }
        $account.following = $stats.following
        $account.followers = $stats.follower
        $account.dynamics = $stats.dynamic_count
    }
    $account
}
