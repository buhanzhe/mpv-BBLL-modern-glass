$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../portable_config/scripts/newbv/resolve.ps1"

function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'" }
}

function Test-DashAudioUrl([string]$Url, [int]$TimeoutMs) {
    return $Url -notlike '*unreachable*'
}
$images = @{
    img_url = 'https://example.invalid/7cd084941338484aae1ad9425b84077c.png'
    sub_url = 'https://example.invalid/4932caff0ff746eab6f01bf08b70ac45.png'
}
$signature = Get-SignedQuery @{foo = 114; bar = 514; baz = 1919810} $images 1702204169
Assert-Equal $signature 'bar=514&baz=1919810&foo=114&wts=1702204169&w_rid=6149fdadf571698ca7e6a567265cd0ee'
Assert-Equal (Format-Query @{q = ([string][char]0x7535 + ' &')}) 'q=%E7%94%B5%20%26'
Assert-Equal (Read-VideoId 'https://m.bilibili.com/video/BV1GJ411x7h7/?share=1&p=2#part').part 2
Assert-Equal (Read-VideoId 'av123').key 'aid'

function Invoke-BiliApi($Path, $Parameters, [switch]$Signed) {
    switch ($Path) {
        '/x/web-interface/view' {
            Assert-Equal $Parameters.bvid 'BV1GJ411x7h7'
            @{
                bvid = $Parameters.bvid; title = 'Test'; pages = @(
                    @{page = 1; cid = 100; part = 'A'}, @{page = 2; cid = 200; part = 'B'; duration = 123}
                )
            }
        }
        '/x/player/wbi/playurl' {
            Assert-Equal $Parameters.cid 200
            Assert-Equal $Parameters.qn 127
            Assert-Equal $Signed.IsPresent $true
            if ($script:progressiveOnly) { throw 'DASH unavailable' }
            @{dash = @{
                video = @(
                    @{id = 80; codecid = 7; baseUrl = 'https://example.invalid/1080'},
                    @{id = 64; codecid = 12; base_url = 'https://example.invalid/hevc'},
                    @{id = 64; codecid = 7; baseUrl = 'file:///video'; backup_url = @('https://example.invalid/avc')}
                )
                audio = @(@{bandwidth = 128; baseUrl = 'https://example.invalid/audio?x=1,2'})
            }}
        }
        '/x/player/playurl' {
            Assert-Equal $Parameters.cid 200
            @{durl = @(@{url = 'https://example.invalid/1'}, @{url = 'https://example.invalid/2'})}
        }
        '/x/web-interface/wbi/search/type' {
            Assert-Equal $Signed.IsPresent $true
            Assert-Equal $Parameters.keyword 'test keyword'
            @{result = @(@{bvid = 'BV1GJ411x7h7'; title = '<em>Test</em> &amp; more'; author = 'Author'})}
        }
        '/x/web-interface/wbi/index/top/feed/rcmd' {
            Assert-Equal $Parameters.fresh_idx 8
            Assert-Equal $Parameters.fresh_idx_1h 8
            @{item = @(@{bvid = 'BV1GJ411x7h7'; title = 'Fresh recommendation'})}
        }
        default { throw "Unexpected endpoint: $Path" }
    }
}

$dashResult = Resolve-Video 'BV1GJ411x7h7?p=2' 64
Assert-Equal ([regex]::Matches($dashResult.video, '!delay_open,media_type=video').Count) 3
Assert-Equal ([regex]::Matches($dashResult.video, '!delay_open,media_type=audio').Count) 1
Assert-Equal ([regex]::Matches($dashResult.video, ',flags=default').Count) 2
Assert-Equal $dashResult.defaultVid 2
Assert-Equal $dashResult.tracks[1].quality 64
Assert-Equal $dashResult.tracks[1].codec 'h264'
Assert-Equal (Resolve-Video 'BV1GJ411x7h7?p=2' 64 'hevc').defaultVid 3
Assert-Equal (Resolve-Video 'BV1GJ411x7h7?p=2' 127).defaultVid 1
Assert-Equal (Resolve-Video 'BV1GJ411x7h7?p=2' 32).defaultVid 2
if ($dashResult.video -notmatch 'codec=h264,w=0,h=0,fps=0;[^;]+,flags=default;%\d+%https://example.invalid/avc,length=123') {
    throw 'Requested quality was not selected by default.'
}
if ($dashResult.video -notmatch 'https://example.invalid/audio\?x=1,2,length=123' -or $dashResult.video -match 'file:///') {
    throw 'Unexpected stream URLs.'
}
$testDash = @{
    video = @(@{id = 64; codecid = 7; base_url = 'https://example.invalid/video'})
    audio = @(@{id = 30280; bandwidth = 190000; base_url = 'https://example.invalid/aac'})
    flac = @{audio = @{id = 30251; codecs = 'fLaC'; bandwidth = 2002701; baseUrl = 'file:///invalid'; backupUrl = @('https://example.invalid/flac')}}
    dolby = @{audio = @(
        @{id = 30250; codecs = 'ec-3'; bandwidth = 1024000; base_url = 'https://example.invalid/dolby'},
        @{id = 30250; codecs = 'ec-3'; bandwidth = 1024000; baseUrl = 'https://example.invalid/dolby'},
        @{id = 30255; codecs = 'ac-3'; bandwidth = 384000; base_url = 'https://example.invalid/ac3'}
    )}
}
$audioResult = Select-Dash $testDash 127 @() 100
Assert-Equal ([regex]::Matches($audioResult.video, '!delay_open,media_type=audio').Count) 4
if ($audioResult.video -notmatch 'codec=aac;[^;]*,flags=default;' -or
    $audioResult.video -notmatch 'codec=flac;[^;]*Hi-Res / FLAC 2003 kbps[^;]*;%\d+%https://example.invalid/flac' -or
    $audioResult.video -notmatch 'codec=eac3;[^;]*Dolby / E-AC-3' -or
    $audioResult.video -notmatch 'codec=ac3;[^;]*Dolby / AC-3') { throw 'Unexpected extended DASH audio track metadata.' }
$dolbyDash = @{video = @(
    @{id = 126; codecid = 12; codecs = 'dvhe.05.07'; baseUrl = 'https://example.invalid/vision'},
    @{id = 120; codecid = 13; baseUrl = 'https://example.invalid/4k-av1'}
); audio = $testDash.audio}
$vision = Select-Dash $dolbyDash 126 @() 100 'av1'
Assert-Equal $vision.defaultVid 1
Assert-Equal $vision.tracks[0].title '杜比视界 / HEVC'
Assert-Equal ([regex]::Matches($vision.video, '!delay_open,media_type=video').Count) 1
if ($vision.video -notmatch '!no_chapters;!track_meta,title=[^;]+,flags=default;%\d+%https://example.invalid/vision') {
    throw 'The Dolby Vision MP4 should open with its real codec metadata.'
}
Assert-Equal (Select-Dash $dolbyDash 120 @() 100 'av1').defaultVid 2
$preferredFlac = Select-Dash $testDash 127 @() 100 '' 'flac'
if ($preferredFlac.video -notmatch 'codec=flac;[^;]*,flags=default;' -or $preferredFlac.video -match 'codec=aac;[^;]*,flags=default;') {
    throw 'Preferred FLAC should be selected without hiding AAC.'
}
$fallbackAudio = Select-Dash @{video = $testDash.video; audio = $testDash.audio} 127 @() 100 '' 'flac'
if ($fallbackAudio.video -notmatch 'codec=aac;[^;]*,flags=default;') { throw 'Missing AAC fallback.' }
$backupDash = @{video = $testDash.video; audio = @(
    @{id = 30280; bandwidth = 198000; baseUrl = 'https://example.invalid/unreachable'; backup_url = @('https://example.invalid/backup')},
    @{id = 30232; bandwidth = 104000; baseUrl = 'https://example.invalid/aac-low'}
)}
$checked = Select-Dash $backupDash 127 @() 100 -VerifyAudio
Assert-Equal $checked.defaultAid 1
if ($checked.video -notmatch 'codec=aac;[^;]*,flags=default;%\d+%https://example.invalid/backup') { throw 'Preferred backup was not selected.' }
$backupDash.audio[0].backup_url = @()
$checked = Select-Dash $backupDash 127 @() 100 -VerifyAudio
Assert-Equal $checked.defaultAid 2
$backupDash.video = @(@{
    id = 120; codecid = 13; baseUrl = 'https://primary.example.invalid/video'
    backupUrl = @('https://primary.example.invalid/video?copy=1', 'https://backup.example.invalid/video',
        'https://backup.example.invalid/video', 'https://third.example.invalid/video', 'file:///invalid')
})
$backupDash.audio[0].backupUrl = @('https://backup.example.invalid/aac')
$alternate = Select-Dash $backupDash 120 @() 100 'av1' -VerifyAudio
Assert-Equal $alternate.defaultVid 1
Assert-Equal $alternate.defaultAid 1
if ($alternate.backupVideo -notmatch 'https://backup.example.invalid/video' -or
    $alternate.backupVideo -notmatch 'https://backup.example.invalid/aac' -or
    $alternate.backupVideo -match 'unreachable|copy=1') { throw 'Backup EDL did not keep the working audio and switch CDN.' }
Assert-Equal ([regex]::Matches($alternate.backupVideo, ',flags=default').Count) 2
Assert-Equal $alternate.backupVideos.Count 3
Assert-Equal $alternate.backupVideos[0] $alternate.backupVideo
if ($alternate.backupVideos[1] -notmatch 'https://third.example.invalid/video' -or
    $alternate.backupVideos[1] -notmatch 'https://backup.example.invalid/aac' -or
    $alternate.backupVideos[2] -notmatch 'copy=1') { throw 'Distinct CDN hosts should precede same-host URLs.' }
$testDash.audio = @()
$testDash.dolby = $null
$flacOnly = Select-Dash $testDash 127 @() 100
if ($flacOnly.video -notmatch 'codec=flac;[^;]*,flags=default;') { throw 'A FLAC-only video should remain playable.' }
Assert-Equal $dashResult.title 'Test - P2 B'
$script:progressiveOnly = $true
$fallback = Resolve-Video 'BV1GJ411x7h7?p=2' 64
Assert-Equal $fallback.video 'edl://%25%https://example.invalid/1;%25%https://example.invalid/2'
Assert-Equal $fallback.audio $null
$invalidPartError = $null
try { Resolve-Video 'BV1GJ411x7h7?p=3' 64 } catch { $invalidPartError = $_.Exception.Message }
Assert-Equal $invalidPartError 'Video part 3 does not exist.'
$search = Search-Videos 'test keyword'
Assert-Equal $search.items.Count 1
Assert-Equal $search.items[0].label 'Test & more  /  Author'
Assert-Equal $search.items[0].url 'https://www.bilibili.com/video/BV1GJ411x7h7'
Assert-Equal ((Get-BrowsePage 'home' 1 8).items[0].title) 'Fresh recommendation'

$loginKey = '0123456789abcdef0123456789abcdef'
$script:sessionFile = Join-Path ([IO.Path]::GetTempPath()) ('newbv-test-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
function Get-SessionPath { $script:sessionFile }
function Invoke-PassportApi($Operation, $Parameters, $Session) {
    if ($Operation -eq 'generate') {
        return @{qrcode_key = $loginKey; url = "https://account.bilibili.com/h5/account-h5/auth/scan-web?qrcode_key=$loginKey"}
    }
    Assert-Equal $Parameters.qrcode_key $loginKey
    if ($script:loginCode -eq 0) {
        $Session.Cookies.SetCookies([Uri]$passportOrigin, 'SESSDATA=fixture%2Ctoken; Domain=.bilibili.com; Path=/; Secure; HttpOnly')
        if (-not $script:omitWriteToken) {
            $Session.Cookies.SetCookies([Uri]$passportOrigin, ('bili_jct=' + $loginKey + '; Domain=.bilibili.com; Path=/; Secure'))
        }
    }
    @{code = $script:loginCode; url = $script:loginTicket}
}

try {
    Assert-Equal (Start-BiliLogin).key $loginKey
    foreach ($case in @(@{code = 86101; state = 'waiting'}, @{code = 86090; state = 'scanned'}, @{code = 86038; state = 'expired'})) {
        $script:loginCode = $case.code
        Assert-Equal (Update-BiliLogin $loginKey).state $case.state
        Assert-Equal ([IO.File]::Exists($script:sessionFile)) $false
    }
    $script:loginCode = 0
    $success = Update-BiliLogin $loginKey
    Assert-Equal $success.state 'success'
    Assert-Equal $success.Count 1
    Assert-Equal (Read-BiliSession) 'fixture%2Ctoken'
    $withCsrf = New-BiliSession (Read-BiliSession -IncludeCsrf)
    Assert-Equal $withCsrf.Cookies.GetCookies([Uri]$apiOrigin)['bili_jct'].Value $loginKey
    if ([IO.File]::ReadAllText($script:sessionFile).Contains('fixture%2Ctoken')) { throw 'Session stored in plaintext.' }
    $session = New-BiliSession (Read-BiliSession)
    Assert-Equal $session.Cookies.GetCookieHeader([Uri]$apiOrigin) 'SESSDATA=fixture%2Ctoken'
    Assert-Equal $session.Cookies.GetCookieHeader([Uri]$passportOrigin) ''
    Assert-Equal $session.Cookies.GetCookieHeader([Uri]'https://example.invalid') ''
    Assert-Equal $session.Cookies.GetCookieHeader([Uri]'http://api.bilibili.com') ''
    $script:omitWriteToken = $true
    Assert-Equal (Update-BiliLogin $loginKey).state 'credentials_missing'
    Assert-Equal (Read-BiliSession -IncludeCsrf) ('fixture%2Ctoken|' + $loginKey)
    $script:loginTicket = "https://passport.biligame.com/crossDomain?SESSDATA=ticket%2Ctoken&bili_jct=$loginKey"
    Assert-Equal (Update-BiliLogin $loginKey).state 'success'
    Assert-Equal (Read-BiliSession -IncludeCsrf) ('ticket%2Ctoken|' + $loginKey)
    Assert-Equal (Read-BiliLoginTicket "https://example.invalid/crossDomain?SESSDATA=fake&bili_jct=$loginKey") $null
    Save-BiliSession 'replacement'
    Assert-Equal (Read-BiliSession) 'replacement'
    [IO.File]::WriteAllText($script:sessionFile, 'invalid')
    Assert-Equal (Read-BiliSession) $null
} finally {
    [IO.File]::Delete($script:sessionFile)
}

function Invoke-BiliPost($Path, $Form, $Timeout) { @{path = $Path; form = $Form; timeout = $Timeout} }

$heartbeat = Send-PlaybackHistory '{"bvid":"BV1GJ411x7h7","cid":"200","type":3,"kind":2,"progress":41,"realtime":14,"started":1795075500}'
Assert-Equal $heartbeat.path '/x/click-interface/web/heartbeat'
Assert-Equal $heartbeat.form.played_time 41
Assert-Equal $heartbeat.form.play_type 2
Assert-Equal $heartbeat.form.cid '200'
$heartbeat = Send-PlaybackHistory '{"aid":"37","cid":"200","type":4,"epid":"12","sid":"42","subtype":1,"kind":1,"progress":2,"realtime":2,"started":1795075500}'
Assert-Equal $heartbeat.form.epid '12'
Assert-Equal $heartbeat.form.sid '42'
Assert-Equal $heartbeat.form.sub_type 1
$coin = Invoke-VideoAction 'coin:123:2'
Assert-Equal $coin.path '/x/web-interface/coin/add'
Assert-Equal $coin.form.multiply '2'
$later = Invoke-VideoAction 'later:123'
Assert-Equal $later.path '/x/v2/history/toview/add'
Assert-Equal $later.form.aid '123'
$favoriteAdd = Invoke-VideoAction 'favorite:123:456:add'
Assert-Equal $favoriteAdd.path '/x/v3/fav/resource/deal'
Assert-Equal $favoriteAdd.form.add_media_ids '456'
Assert-Equal $favoriteAdd.form.del_media_ids ''
$favorite = Invoke-VideoAction 'favorite:123:456:remove'
Assert-Equal $favorite.form.del_media_ids '456'
Assert-Equal $favorite.form.add_media_ids ''
$season = Invoke-VideoAction 'season:123:add'
Assert-Equal $season.path '/pgc/web/follow/add'
$invalidAction = $false
try { Invoke-VideoAction 'coin:123:9' } catch { $invalidAction = $true }
Assert-Equal $invalidAction $true

function Invoke-BiliApi($Path, $Parameters, [switch]$Nav) {
    switch ($Path) {
        '/x/web-interface/nav' {
            Assert-Equal $Nav.IsPresent $true
            @{isLogin = $true; mid = 1234; uname = 'Sample'; face = '//i0.hdslb.com/bfs/face/sample.jpg'
              level_info = @{current_level = 0}; vipStatus = 0; money = 0}
        }
        '/x/web-interface/nav/stat' {
            if ($script:unavailableStats) { throw 'Statistics unavailable' }
            @{following = 20; follower = 15; dynamic_count = 0}
        }
        default { throw "Unexpected account endpoint: $Path" }
    }
}

$script:apiSession = New-BiliSession ''
Assert-Equal (Get-BiliAccount -Detailed).state 'signed_out'
$script:apiSession = New-BiliSession 'sample'
$profile = Get-BiliAccount -Detailed
Assert-Equal $profile.state 'signed_in'
Assert-Equal $profile.avatar 'https://i0.hdslb.com/bfs/face/sample.jpg'
Assert-Equal $profile.level 0
Assert-Equal $profile.coins 0
Assert-Equal $profile.vip $false
Assert-Equal $profile.following 20
Assert-Equal $profile.followers 15
Assert-Equal $profile.dynamics 0
$script:unavailableStats = $true
$profile = Get-BiliAccount -Detailed
Assert-Equal $profile.state 'signed_in'
Assert-Equal $profile.followers $null
$script:apiSession = New-BiliSession ''

function Get-AccountId { 1 }
function Invoke-BiliApi($Path, $Parameters, [switch]$Signed) {
    switch ($Path) {
        '/x/web-interface/region/feed/rcmd' { throw 'Unavailable' }
        '/x/web-interface/ranking/v2' {
            Assert-Equal $Parameters.rid 1
            @{list = @(@{bvid = 'BV1GJ411x7h7'; title = 'Ranking fallback'})}
        }
        '/x/web-interface/history/cursor' {
            Assert-Equal $Parameters.max '123'
            Assert-Equal $Parameters.view_at '456'
            @{list = @(@{title = 'History'; duration = 50; progress = 17; history = @{page = 2; bvid = 'BV1GJ411x7h7'}})}
        }
        '/x/v2/reply/reply' {
            Assert-Equal $Parameters.root 999
            @{replies = @(@{rpid = 111; content = @{message = 'Reply'}; member = @{uname = 'Reader'}})}
        }
        default { throw "Unexpected endpoint: $Path" }
    }
}
Assert-Equal (Get-CatalogPage 'region:1005' 1 '').items[0].title 'Ranking fallback'
$history = Get-CatalogPage 'history' 2 '123:456:archive'
Assert-Equal $history.items[0].url 'https://www.bilibili.com/video/BV1GJ411x7h7?p=2'
Assert-Equal $history.items[0].progress 17
Assert-Equal (Get-CatalogPage 'comments:12:999' 1 '').items[0].title 'Reply'

& {
    $mock = @{failure = 'Bilibili /x/web-interface/view HTTP 412.'; pageRequests = 0; bvid = 'BV1GJ411x7h7'}
    function Invoke-BiliApi($Path, $Parameters) { throw $mock.failure }
    function Invoke-WebRequest {
        [CmdletBinding()]
        param([string]$Uri, [switch]$UseBasicParsing, [int]$MaximumRedirection, [int]$TimeoutSec)
        $mock.pageRequests++
        if ($Uri -cnotmatch '^https://www\.bilibili\.com/zh-Hans/video/(BV1GJ411x7h7|av123)/$') { throw "Unexpected URL: $Uri" }
        $initial = @{videoData = @{
            bvid = $mock.bvid; aid = 123; title = 'Public video'
            pages = @(@{page = 1; cid = 100; part = 'A'}, @{page = 2; cid = 200; part = 'B'})
        }} | ConvertTo-Json -Depth 6 -Compress
        $html = '<script>window.__INITIAL_STATE__=' + $initial + ';(function(){throw "Do not execute script";}());</script>'
        @{RawContentStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($html))}
    }
    $detail = Get-VideoDetails 'BV1GJ411x7h7?p=2'
    Assert-Equal $detail.title 'Public video'
    Assert-Equal $detail.part 2
    Assert-Equal $detail.parts[1].url 'https://www.bilibili.com/video/BV1GJ411x7h7?p=2'
    Assert-Equal (Get-VideoMetadata (Read-VideoId 'av123')).pages[1].cid 200
    Assert-Equal $mock.pageRequests 2

    $mock.bvid = 'BV1KEJ36bEid'
    $failure = try { Get-VideoMetadata (Read-VideoId 'BV1GJ411x7h7') } catch { $_.Exception.Message }
    Assert-Equal $failure $mock.failure
    Assert-Equal $mock.pageRequests 3

    $mock.failure = 'Bilibili /x/web-interface/view HTTP 403.'
    $failure = try { Get-VideoMetadata (Read-VideoId 'BV1GJ411x7h7') } catch { $_.Exception.Message }
    Assert-Equal $failure $mock.failure
    Assert-Equal $mock.pageRequests 3
}
'NewBV contract checks passed.'
