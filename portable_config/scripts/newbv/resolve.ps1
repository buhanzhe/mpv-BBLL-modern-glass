param(
    [string]$Query,
    [ValidateSet('resolve', 'search', 'browse', 'detail', 'catalog', 'subtitles', 'subtitle-track', 'interaction', 'heartbeat', 'qr-generate', 'qr-poll', 'account', 'profile', 'logout')][string]$Action = 'resolve',
    [ValidateRange(1, 100)][int]$Page = 1,
    [string]$Cursor = '',
    [ValidateSet('totalrank', 'click', 'pubdate', 'dm', 'stow')][string]$Order = 'totalrank',
    [ValidateSet('video', 'media_bangumi', 'media_ft', 'live_room', 'bili_user')][string]$SearchType = 'video',
    [ValidateRange(0, 30000)][int]$LiveQuality = 10000,
    [ValidateRange(1, 127)][int]$Quality = 127,
    [ValidateSet('', 'h264', 'hevc', 'av1')][string]$PreferredCodec = '',
    [ValidateSet('aac','flac','eac3')][string]$PreferredAudio = 'aac'
)

$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$referrer = 'https://www.bilibili.com/'
. "$PSScriptRoot/account.ps1"
. "$PSScriptRoot/catalog.ps1"
$mixinOrder = @(46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52)

function Format-Query($Parameters) {
    [string[]]$keys = @($Parameters.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    ($keys | ForEach-Object {
        [Uri]::EscapeDataString($_) + '=' + [Uri]::EscapeDataString([string]$Parameters[$_])
    }) -join '&'
}

function Get-SignedQuery($Parameters, $Images, [long]$Timestamp) {
    $keys = -join (@($Images.img_url, $Images.sub_url) | ForEach-Object {
        [IO.Path]::GetFileNameWithoutExtension(([Uri]$_).AbsolutePath)
    })
    if ($keys -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid WBI signing keys.' }
    $mixin = -join ($mixinOrder[0..31] | ForEach-Object { $keys[$_] })
    $clean = @{wts = $Timestamp}
    foreach ($key in $Parameters.Keys) { $clean[$key] = [string]$Parameters[$key] -replace '[!''()*]', '' }
    $queryString = Format-Query $clean
    $md5 = [Security.Cryptography.MD5]::Create()
    try { $digest = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($queryString + $mixin)) }
    finally { $md5.Dispose() }
    $queryString + '&w_rid=' + [BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()
}

function Invoke-BiliRequest([string]$Origin, [string]$Path, [string]$QueryString, $Session, [switch]$Nav) {
    $uri = $Origin + $Path
    if ($queryString) { $uri += '?' + $queryString }
    try {
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 8 `
            -UserAgent $userAgent -Headers @{Referer = $referrer; Accept = 'application/json'} -WebSession $Session
    } catch {
        $status = $_.Exception.Response.StatusCode
        if ($status) { throw "Bilibili $Path HTTP $([int]$status)." }
        throw "Could not connect to Bilibili $Path."
    }
    $body = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()).TrimStart([char]0xFEFF) | ConvertFrom-Json
    if ($Nav -and $body.data.wbi_img) { return $body.data }
    if ($null -eq $body.code -or $body.code -ne 0) { throw "Bilibili API $Path [$($body.code)]." }
    if ($null -ne $body.data) { return ,$body.data }
    if ($null -ne $body.result) { return ,$body.result }
}

function Invoke-BiliApi([string]$Path, [hashtable]$Parameters = @{}, [switch]$Signed, [switch]$Nav) {
    $queryString = Format-Query $Parameters
    if ($Signed) {
        $images = (Invoke-BiliApi '/x/web-interface/nav' -Nav).wbi_img
        $queryString = Get-SignedQuery $Parameters $images ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    }
    Invoke-BiliRequest $apiOrigin $Path $queryString $script:apiSession -Nav:$Nav
}

function Invoke-PassportApi([string]$Operation, [hashtable]$Parameters, $Session) {
    Invoke-BiliRequest $passportOrigin "/x/passport-login/web/qrcode/$Operation" (Format-Query $Parameters) $Session
}

function Read-VideoId([string]$Value) {
    $pathPattern = '(?<id>BV[A-Za-z0-9]{10}|av[1-9][0-9]*)'
    $pagePattern = '(?:\?(?<query>[^#]*))?(?:#.*)?$'
    if ($Value -cmatch "^(?:https?://(?:www\.|m\.)?bilibili\.com/video/)?$pathPattern/?$pagePattern") {
        $videoId = $Matches.id
        $part = 1
        if ($Matches.query -match '(?:^|&)p=([^&]*)') {
            if (-not [int]::TryParse($Matches[1], [ref]$part) -or $part -lt 1) { throw 'Invalid video part (p).' }
        }
        $key = 'bvid'
        if ($videoId.StartsWith('av')) { $key = 'aid'; $videoId = $videoId.Substring(2) }
        return @{key = $key; id = $videoId; part = $part}
    }
    throw 'Expected a Bilibili video URL or a BV/av ID.'
}

function Get-MediaUrl($Track) {
    foreach ($candidate in @($Track.baseUrl, $Track.base_url, $Track.url) + @($Track.backupUrl) + @($Track.backup_url)) {
        [Uri]$uri = $null
        if ($candidate -and $candidate -notmatch '[\x00-\x20]' -and
            [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -eq 'https' -and $uri.Host -and -not $uri.UserInfo) { return [string]$candidate }
    }
}

function Format-EdlValue([string]$Value) {
    '%' + [Text.Encoding]::UTF8.GetByteCount($Value) + '%' + $Value
}

function Format-DashTrack($Track, [string]$MediaType, [string]$Label, [string]$Codec, [bool]$Default, [int]$Duration) {
    $info = "!delay_open,media_type=$MediaType,codec=$Codec"
    if ($MediaType -eq 'video') {
        $rate = 0
        if ([string]$Track.frameRate -match '^(\d+)(?:/(\d+))?$') {
            $rate = [double]$Matches[1]
            if ($Matches[2] -and [double]$Matches[2] -gt 0) { $rate /= [double]$Matches[2] }
        }
        $info += ",w=$([int]$Track.width),h=$([int]$Track.height),fps=$([int]$rate)"
    }
    $meta = '!track_meta,title=' + (Format-EdlValue $Label) + ',byterate=' + [int]($Track.bandwidth / 8)
    if ($Default) { $meta += ',flags=default' }
    $entry = Format-EdlValue (Get-MediaUrl $Track)
    if ($Duration -gt 0) { $entry += ",length=$Duration" }
    "!new_stream;!no_clip;!no_chapters;$info;$meta;$entry"
}

function Get-DashAudioTracks($Dash) {
    $groups = @(
        @{source = @($Dash.audio); codec = 'aac'; title = 'AAC'},
        @{source = @($Dash.flac.audio); codec = 'flac'; title = 'Hi-Res / FLAC'},
        @{source = @($Dash.dolby.audio); codec = 'eac3'; title = 'Dolby / E-AC-3'}
    )
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($group in $groups) {
        foreach ($track in ($group.source | Where-Object { $_ } | Sort-Object -Property @{Expression = { [long]$_.bandwidth }; Descending = $true})) {
            $url = Get-MediaUrl $track
            if (-not $url -or -not $seen.Add($url)) { continue }
            $codec = $group.codec
            $title = $group.title
            switch -Regex ([string]$track.codecs) {
                '^flac(?:\.|$)' { $codec = 'flac'; $title = 'Hi-Res / FLAC' }
                '^ec-3(?:\.|$)' { $codec = 'eac3'; $title = 'Dolby / E-AC-3' }
                '^ac-3(?:\.|$)' { $codec = 'ac3'; $title = 'Dolby / AC-3' }
            }
            if ($track.bandwidth -gt 0) { $title += " $([int]($track.bandwidth / 1000)) kbps" }
            @{track = $track; codec = $codec; title = $title}
        }
    }
}

function Select-Dash($Dash, [int]$TargetQuality, $Formats, [int]$Duration, [string]$CodecPreference = '', [string]$AudioPreference = 'aac') {
    $codecNames = @{'7' = 'h264'; '12' = 'hevc'; '13' = 'av1'}
    $codecLabels = @{'7' = 'AVC'; '12' = 'HEVC'; '13' = 'AV1'}
    $qualityLabels = @{}
    foreach ($format in $Formats) {
        if ($format.new_description) { $qualityLabels[[int]$format.quality] = [string]$format.new_description }
    }
    $ordering = @(@{Expression = { [int]$_.id }; Descending = $true},
        @{Expression = { $_.codecid -eq 7 }; Descending = $true}, @{Expression = 'bandwidth'; Descending = $true})
    $videos = @($Dash.video | Where-Object { $codecNames.ContainsKey([string]$_.codecid) -and (Get-MediaUrl $_) } |
        Sort-Object -Property $ordering)
    $audios = @(Get-DashAudioTracks $Dash)
    if (-not $videos.Count -or -not $audios.Count) { return }
    $defaultAudio = 0
    for ($index = 0; $index -lt $audios.Count; $index++) {
        $codec = $audios[$index].codec
        if ($codec -eq $AudioPreference -or ($AudioPreference -eq 'eac3' -and $codec -eq 'ac3')) { $defaultAudio = $index; break }
    }
    $quality = ($videos | Where-Object { $_.id -le $TargetQuality } | Select-Object -First 1).id
    if (-not $quality) { $quality = $videos[-1].id }
    $defaultVideo = -1
    for ($index = 0; $index -lt $videos.Count; $index++) {
        $track = $videos[$index]
        if ($track.id -ne $quality) { continue }
        if ($defaultVideo -lt 0) { $defaultVideo = $index }
        if ($codecNames[[string]$track.codecid] -eq $CodecPreference) { $defaultVideo = $index; break }
    }
    $trackInfo = @(
        for ($index = 0; $index -lt $videos.Count; $index++) {
            $track = $videos[$index]
            $codec = [string]$track.codecid
            $label = $qualityLabels[[int]$track.id]
            if (-not $label) { $label = if ($track.height) { "$($track.height)p" } else { "QN $($track.id)" } }
            @{id = $index + 1; quality = [int]$track.id; codec = $codecNames[$codec]; title = $label + ' / ' + $codecLabels[$codec]}
        }
    )
    $entries = @(
        for ($index = 0; $index -lt $videos.Count; $index++) {
            $track = $videos[$index]
            Format-DashTrack $track 'video' $trackInfo[$index].title $trackInfo[$index].codec ($index -eq $defaultVideo) $Duration
        }
        for ($index = 0; $index -lt $audios.Count; $index++) {
            $audio = $audios[$index]
            Format-DashTrack $audio.track 'audio' $audio.title $audio.codec ($index -eq $defaultAudio) $Duration
        }
    )
    @{video = ('edl://' + ($entries -join ';')); defaultVid = $defaultVideo + 1; tracks = $trackInfo}
}

function Resolve-Video([string]$Value, [int]$TargetQuality, [string]$CodecPreference = '', [string]$AudioPreference = 'aac') {
    $target = Read-VideoId $Value
    $detail = Invoke-BiliApi '/x/web-interface/view' @{$target.key = $target.id}
    $page = $detail.pages | Where-Object { $_.page -eq $target.part } | Select-Object -First 1
    if (-not $page.cid) { throw "Video part $($target.part) does not exist." }

    $parameters = @{bvid = $detail.bvid; cid = $page.cid; qn = 127; fnval = 4048; fnver = 0; fourk = 1; prefer_codec = 7}
    try {
        $manifest = Invoke-BiliApi '/x/player/wbi/playurl' $parameters -Signed
        $duration = [int]$page.duration
        if ($duration -le 0) { $duration = [int]$manifest.dash.duration }
        $streams = Select-Dash $manifest.dash $TargetQuality $manifest.support_formats $duration $CodecPreference $AudioPreference
        if (-not $streams) { throw 'No complete DASH video/audio pair.' }
    } catch {
        $parameters = @{bvid = $detail.bvid; cid = $page.cid; qn = $TargetQuality; fnval = 1; fnver = 0; fourk = 0; type = 'mp4'; platform = 'html5'; otype = 'json'}
        $progressive = Invoke-BiliApi '/x/player/playurl' $parameters
        if ($progressive.v_voucher) { throw 'Bilibili requires verification for playback.' }
        $segments = @($progressive.durl | ForEach-Object { Get-MediaUrl $_ })
        if (-not $segments.Count -or $segments.Count -ne $progressive.durl.Count) { throw 'No usable video stream. The video may require login or be restricted.' }
        $streams = @{video = $segments[0]}
        if ($segments.Count -gt 1) {
            $streams.video = 'edl://' + (($segments | ForEach-Object { Format-EdlValue $_ }) -join ';')
        }
    }
    $streams.title = $detail.title
    $streams.byline = [string]$detail.owner.name
    $streams.history = @{bvid = [string]$detail.bvid; aid = [string]$detail.aid; cid = [string]$page.cid; type = 3}
    if ($detail.pages.Count -gt 1 -and $page.part) { $streams.title += ' - P' + $target.part + ' ' + $page.part }
    $streams.userAgent = $userAgent
    $streams.referrer = $referrer
    $streams
}

function Get-CoverUrl([string]$Cover) {
    if ($cover -like '//*') { $cover = 'https:' + $cover }
    if ($cover -like 'http://*') { $cover = 'https://' + $cover.Substring(7) }
    [Uri]$image = $null
    if (-not [Uri]::TryCreate($cover, [UriKind]::Absolute, [ref]$image) -or $image.Scheme -ne 'https' -or
        -not $image.Host.EndsWith('.hdslb.com') -or $image.UserInfo -or -not $image.IsDefaultPort) { return '' }
    $cover
}

function Format-Card($Item) {
    if ($Item.bvid -cnotmatch '^BV[A-Za-z0-9]{10}$') { return }
    $owner = if ($Item.owner) { $Item.owner.name } elseif ($Item.author_name) { $Item.author_name } else { $Item.author }
    $cover = Get-CoverUrl $(if ($Item.pic) { $Item.pic } else { $Item.cover })
    $title = [Net.WebUtility]::HtmlDecode(($Item.title -replace '</?em(?:\s+[^>]+)?>', ''))
    @{
        url = $referrer + 'video/' + $Item.bvid
        label = $title + '  /  ' + $owner
        title = $title; author = [string]$owner; cover = $cover; duration = [string]($Item.duration, $Item.length | Where-Object { $_ } | Select-Object -First 1)
        published = if ($Item.pubdate) { $Item.pubdate } else { $Item.created }
        views = if ($Item.stat) { $Item.stat.view } else { $Item.play }
        danmaku = if ($Item.stat) { $Item.stat.danmaku } else { $Item.video_review }
    }
}

function Search-Videos([string]$Keyword, [int]$PageNumber = 1, [string]$Sort = 'totalrank', [string]$Type = 'video') {
    if ($Keyword.Length -gt 100) { throw 'Search keyword is too long.' }
    $parameters = @{keyword = $Keyword; search_type = $Type; page = $PageNumber; page_size = 24}
    if ($Type -eq 'video') { $parameters.order = $Sort }
    $result = Invoke-BiliApi '/x/web-interface/wbi/search/type' $parameters -Signed
    if ($result.v_voucher) { throw 'Bilibili requires verification for search.' }
    $items = @($result.result | ForEach-Object {
        $item = $_
        switch ($Type) {
            'video' { Format-Card $item }
            {$_ -in @('media_bangumi','media_ft')} { Format-Season $item }
            'live_room' { Format-LiveRoom $item }
            'bili_user' {
                if ([long]$item.mid -gt 0) {
                    @{kind = 'catalog'; key = 'author:' + $item.mid; url = 'author:' + $item.mid
                        title = [Net.WebUtility]::HtmlDecode(($item.uname -replace '</?em(?:\s+[^>]+)?>', ''))
                        cover = Get-CoverUrl $item.upic; author = [string]$item.usign}
                }
            }
        }
    })
    @{items = $items; more = $PageNumber -lt [int]$result.numPages}
}

function Get-BrowsePage([string]$Section, [int]$PageNumber) {
    $more = $false
    switch ($Section) {
        'home' {
            try {
                $feed = Invoke-BiliApi '/x/web-interface/wbi/index/top/feed/rcmd' @{
                    fresh_type = 3; ps = 24; fresh_idx = $PageNumber; fresh_idx_1h = $PageNumber; feed_version = 'V8'
                } -Signed
                $cards = @($feed.item | ForEach-Object { Format-Card $_ })
                if ($cards.Count) { return @{items = $cards; more = $true} }
            } catch {}
            return Get-BrowsePage 'popular' $PageNumber
        }
        'popular' {
            $feed = Invoke-BiliApi '/x/web-interface/popular' @{pn = $PageNumber; ps = 24}
            $items = $feed.list
            $more = -not $feed.no_more
        }
        'history' {
            if ((Get-BiliAccount).state -ne 'signed_in') { return @{requiresLogin = $true; items = @(); more = $false} }
            $items = (Invoke-BiliApi '/x/web-interface/history/cursor' @{ps = 24; type = 'archive'}).list
            foreach ($item in $items) { $item | Add-Member -NotePropertyName bvid -NotePropertyValue $item.history.bvid -Force }
        }
        'later' {
            if ((Get-BiliAccount).state -ne 'signed_in') { return @{requiresLogin = $true; items = @(); more = $false} }
            $items = (Invoke-BiliApi '/x/v2/history/toview').list
        }
        default { throw 'Invalid browse section.' }
    }
    @{items = @($items | ForEach-Object { Format-Card $_ }); more = $more}
}

function Get-VideoDetails([string]$Value) {
    if ($Value -cmatch '^https://www\.bilibili\.com/bangumi/play/ss([1-9]\d{0,12})$') { return Get-SeasonDetails ([long]$Matches[1]) }
    if ($Value -cmatch '^https://www\.bilibili\.com/bangumi/play/ep([1-9]\d{0,12})$') { return Get-SeasonDetails ([long]$Matches[1]) 'ep_id' }
    $target = Read-VideoId $Value
    $detail = Invoke-BiliApi '/x/web-interface/view' @{$target.key = $target.id}
    $card = Format-Card $detail
    if (-not $card) { throw 'Video details unavailable.' }
    $card.description = [string]$detail.desc
    $card.aid = [string]$detail.aid
    $card.bvid = [string]$detail.bvid
    $card.mid = [string]$detail.owner.mid
    $card.part = $target.part
    $base = $card.url
    $card.parts = @($detail.pages | Where-Object { $_.cid -and $_.page -ge 1 } | ForEach-Object {
        @{title = [string]$_.part; page = $_.page; url = $base + '?p=' + $_.page}
    })
    $card
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try {
        $value = if ($Query.StartsWith('q:')) { $Query.Substring(2).Trim() }
        if ($Action -in @('search', 'browse', 'detail', 'catalog', 'resolve', 'subtitles', 'account', 'profile')) { $script:apiSession = New-BiliSession (Read-BiliSession) }
        if ($Action -in @('interaction','heartbeat')) { $script:apiSession = New-BiliSession (Read-BiliSession -IncludeCsrf) }
        $result = switch ($Action) {
            'search' { if (-not $value) { throw 'Empty or invalid input.' }; Search-Videos $value $Page $Order $SearchType }
            'browse' { Get-BrowsePage $value $Page }
            'detail' { Get-VideoDetails $value }
            'catalog' { Get-CatalogPage $value $Page $Cursor }
            'resolve' {
                if (-not $value) { throw 'Empty or invalid input.' }
                if ($value -cmatch '^https://live\.bilibili\.com/([1-9]\d{0,12})/?$') { Resolve-LiveRoom ([long]$Matches[1]) $LiveQuality }
                elseif ($value -cmatch '^https://www\.bilibili\.com/bangumi/play/ep([1-9]\d{0,12})$') { Resolve-SeasonEpisode ([long]$Matches[1]) $Quality $PreferredCodec $PreferredAudio }
                else { Resolve-Video $value $Quality $PreferredCodec $PreferredAudio }
            }
            'subtitles' {
                $target = Read-VideoId $value
                $detail = Invoke-BiliApi '/x/web-interface/view' @{$target.key = $target.id}
                $part = $detail.pages | Where-Object { $_.page -eq $target.part } | Select-Object -First 1
                if ($part.cid) { Get-VideoSubtitles $detail.bvid $part.cid } else { @{tracks = @()} }
            }
            'subtitle-track' { Read-SubtitleTrack $value }
            'interaction' { Invoke-VideoAction $value }
            'heartbeat' { Send-PlaybackHistory $value }
            'qr-generate' { Start-BiliLogin }
            'qr-poll' { Update-BiliLogin $value }
            'account' { Get-BiliAccount }
            'profile' { Get-BiliAccount -Detailed }
            'logout' { [IO.File]::Delete((Get-SessionPath)); @{state = 'signed_out'} }
        }
        ConvertTo-Json -InputObject $result -Compress -Depth 6
    } catch {
        ConvertTo-Json -InputObject @{error = $_.Exception.Message} -Compress
    }
}
