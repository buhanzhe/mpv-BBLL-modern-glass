$liveOrigin = 'https://api.live.bilibili.com'

function Get-AccountId {
    $account = Get-BiliAccount
    if ($account.state -eq 'signed_in') { return [long]$account.id }
    0
}

function New-CatalogResult($Items, [string]$Cursor = '') {
    @{items = @($Items | Where-Object { $_ }); more = [bool]$Cursor; cursor = $Cursor}
}

function Format-Season($Item) {
    if ([long]$Item.season_id -lt 1) { return }
    @{
        kind = 'season'; title = [Net.WebUtility]::HtmlDecode(($Item.title -replace '</?em(?:\s+[^>]+)?>', '')); cover = Get-CoverUrl $Item.cover
        author = [string]$Item.index_show; url = $referrer + 'bangumi/play/ss' + $Item.season_id
    }
}

function Format-LiveRoom($Item) {
    $room = [long]($Item.roomid, $Item.room_id | Where-Object { $_ } | Select-Object -First 1)
    if ($room -lt 1) { return }
    $cover = if ($Item.cover) { $Item.cover } else { $Item.keyframe }
    @{
        kind = 'live'; url = 'https://live.bilibili.com/' + $room
        title = [Net.WebUtility]::HtmlDecode(($Item.title -replace '</?em(?:\s+[^>]+)?>', ''))
        cover = Get-CoverUrl $cover; author = [string]$Item.uname; views = $Item.online; duration = 'LIVE'
    }
}

function Get-SeasonData([string]$Key, [long]$Id) {
    Invoke-BiliApi '/pgc/view/web/season' @{$Key = $Id}
}

function Get-SeasonDetails([long]$Id, [string]$Key = 'season_id') {
    $season = Get-SeasonData $Key $Id
    $card = Format-Season $season
    if (-not $card) { throw 'Bilibili did not return season information.' }
    $card.description = [string]$season.evaluate
    $card.seasonId = [string]$season.season_id
    $card.parts = @($season.episodes | Where-Object { [long]$_.id -gt 0 } | ForEach-Object {
        @{
            page = [string]$_.title; title = [string]$_.long_title
            url = $referrer + 'bangumi/play/ep' + $_.id
        }
    })
    $card
}

function Resolve-SeasonEpisode([long]$Id, [int]$TargetQuality, [string]$CodecPreference = '', [string]$AudioPreference = 'aac') {
    $season = Get-SeasonData 'ep_id' $Id
    $episodes = @($season.episodes) + @($season.section | ForEach-Object { $_.episodes })
    $episode = $episodes | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $episode.cid) { throw 'Episode unavailable.' }
    $parameters = @{ep_id = $Id; cid = $episode.cid; qn = 127; fnval = 4048; fourk = 1}
    $manifest = Invoke-BiliApi '/pgc/player/web/playurl' $parameters
    $streams = Select-Dash $manifest.dash $TargetQuality $manifest.support_formats ([int]$manifest.dash.duration) $CodecPreference $AudioPreference -VerifyAudio
    if (-not $streams) { throw 'No playable episode stream for this account or region.' }
    $streams.title = $season.title + ' - ' + $episode.title + ' ' + $episode.long_title
    $streams.byline = [string]$season.title
    $streams.history = @{bvid = [string]$episode.bvid; aid = [string]$episode.aid; cid = [string]$episode.cid
        type = 4; epid = [string]$Id; sid = [string]$season.season_id; subtype = [int]$season.type}
    $streams.referrer = $referrer
    $streams.userAgent = $userAgent
    $streams
}

function Invoke-LiveApi([string]$Path, [hashtable]$Parameters) {
    Invoke-BiliRequest $liveOrigin $Path (Format-Query $Parameters) $script:apiSession
}

function Resolve-LiveRoom([long]$Room, [int]$QualityNumber = 10000) {
    $roomInfo = Invoke-LiveApi '/room/v1/Room/room_init' @{id = $Room}
    if ($roomInfo.live_status -ne 1) { throw 'This live room is not broadcasting.' }
    $streamData = Invoke-LiveApi '/xlive/web-room/v2/index/getRoomPlayInfo' @{
        room_id = $roomInfo.room_id; protocol = '0,1'; format = '0,1,2'; codec = 0; qn = $QualityNumber
        platform = 'web'; ptype = 8
    }
    $play = $streamData.playurl_info.playurl
    $lines = [Collections.Generic.List[string]]::new()
    $accepted = [Collections.Generic.HashSet[int]]::new()
    foreach ($formatName in @('flv','ts','fmp4')) {
        foreach ($stream in $play.stream) {
            foreach ($format in @($stream.format | Where-Object { $_.format_name -eq $formatName })) {
                foreach ($codec in @($format.codec | Where-Object { $_.codec_name -eq 'avc' })) {
                    foreach ($number in $codec.accept_qn) { [void]$accepted.Add([int]$number) }
                    foreach ($edge in $codec.url_info) {
                        $address = Get-MediaUrl @{url = $edge.host + $codec.base_url + $edge.extra}
                        if ($address -and -not $lines.Contains($address)) { $lines.Add($address) }
                    }
                }
            }
        }
    }
    if (-not $lines.Count) { throw 'This room has no available HTTPS AVC stream.' }
    @{
        video = $lines[0]; lines = @($lines.ToArray() | Select-Object -First 12)
        qualities = @($play.g_qn_desc | Where-Object { $accepted.Contains([int]$_.qn) } | ForEach-Object {
            @{id = [int]$_.qn; title = [string]$_.desc}
        })
        title = 'Bilibili Live · ' + $roomInfo.room_id; referrer = 'https://live.bilibili.com/'; userAgent = $userAgent
    }
}

function Format-Comment($Comment, [bool]$WithPreview = $false) {
    if (-not $Comment.rpid -or (-not $Comment.content.message -and -not $Comment.content.pictures)) { return }
    $pictures = @()
    if ($WithPreview) {
        $pictures = @($Comment.content.pictures | Select-Object -First 3 | ForEach-Object {
            $url = Get-CoverUrl $_.img_src
            if ($url) { $url }
        })
    }
    @{
        title = [string]$Comment.content.message; author = [string]$Comment.member.uname
        avatar = Get-CoverUrl $Comment.member.avatar; views = [long]$Comment.like
        id = [string]$Comment.rpid; replies = [int]$Comment.rcount; published = [long]$Comment.ctime
        pictures = $pictures
        preview = if ($WithPreview) { @($Comment.replies | Select-Object -First 2 | ForEach-Object { Format-Comment $_ }) }
    }
}

function Get-CommentPage([long]$Aid, [int]$PageNumber, [long]$ThreadId = 0, [bool]$Latest = $false) {
    $route = '/x/v2/reply'
    $parameters = @{type = 1; oid = $Aid; sort = $(if ($Latest) { 0 } else { 2 }); pn = $PageNumber; ps = 20; nohot = 1}
    if ($ThreadId) { $route += '/reply'; $parameters.root = $ThreadId; $parameters.Remove('sort'); $parameters.Remove('nohot') }
    $response = Invoke-BiliApi $route $parameters
    $items = @($response.replies | ForEach-Object { Format-Comment $_ $true })
    $result = New-CatalogResult $items $(if ($items.Count -ge 20) { [string]($PageNumber + 1) })
    $result.total = [long]$response.page.count
    $result
}

function Get-VideoSubtitles([string]$Bvid, [long]$Cid) {
    try {
        $info = Invoke-BiliApi '/x/player/wbi/v2' @{bvid = $Bvid; cid = $Cid} -Signed
        $tracks = @($info.subtitle.subtitles | ForEach-Object {
            $url = [string]$_.subtitle_url
            if ($url.StartsWith('//')) { $url = 'https:' + $url }
            [Uri]$uri = $null
            if ([Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and
                -not $uri.UserInfo -and $uri.IsDefaultPort -and $uri.Host.EndsWith('.hdslb.com')) {
                @{url = $url; language = [string]$_.lan; name = [string]$_.lan_doc}
            }
        })
        @{tracks = $tracks}
    } catch { @{tracks = @()} }
}

function Read-SubtitleTrack([string]$Address) {
    [Uri]$uri = $null
    if (-not [Uri]::TryCreate($Address, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or
        $uri.UserInfo -or -not $uri.IsDefaultPort -or -not $uri.Host.EndsWith('.hdslb.com')) { throw 'Invalid subtitle URL.' }
    $response = Invoke-WebRequest -Uri $uri -TimeoutSec 8 -UseBasicParsing -MaximumRedirection 0 -UserAgent $userAgent -Headers @{Referer = $referrer}
    if ($response.RawContentLength -gt 4194304) { throw 'Subtitle track is too large.' }
    $data = [Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json
    $vtt = [Text.StringBuilder]::new()
    [void]$vtt.AppendLine('WEBVTT').AppendLine()
    foreach ($line in $data.body) {
        $start = [double]$line.from
        $end = [double]$line.to
        if ($start -lt 0 -or $end -le $start -or $end -ge 360000) { continue }
        $startTime = [TimeSpan]::FromSeconds($start)
        $endTime = [TimeSpan]::FromSeconds($end)
        $from = '{0:00}:{1:00}:{2:00}.{3:000}' -f [int][Math]::Floor($startTime.TotalHours), $startTime.Minutes, $startTime.Seconds, $startTime.Milliseconds
        $to = '{0:00}:{1:00}:{2:00}.{3:000}' -f [int][Math]::Floor($endTime.TotalHours), $endTime.Minutes, $endTime.Seconds, $endTime.Milliseconds
        $caption = [Net.WebUtility]::HtmlEncode([string]$line.content) -replace '\r?\n(?:\s*\r?\n)+', [Environment]::NewLine
        if ($caption) { [void]$vtt.AppendLine("$from --> $to").AppendLine($caption).AppendLine() }
    }
    @{vtt = $vtt.ToString()}
}

function Get-CatalogPage([string]$Key, [int]$PageNumber, [string]$Cursor) {
    $items = @()
    $next = ''
    $pageNext = [string]($PageNumber + 1)
    switch -Regex ($Key) {
        '^region:([1-9][0-9]{0,5})$' {
            $region = [int]$Matches[1]
            try {
                $response = Invoke-BiliApi '/x/web-interface/region/feed/rcmd' @{
                    from_region = $region; display_id = $PageNumber; request_cnt = 15; device = 'web'; plat = 30
                }
            } catch {
                $legacy = @{1005 = 1; 1003 = 3; 1004 = 129; 1008 = 4; 1010 = 36; 1001 = 181; 1002 = 5}
                if (-not $legacy.ContainsKey($region)) { throw }
                $response = Invoke-BiliApi '/x/web-interface/ranking/v2' @{rid = $legacy[$region]; type = 'all'}
                $items = @($response.list | Select-Object -Skip (($PageNumber - 1) * 24) -First 24 | ForEach-Object { Format-Card $_ })
                if ($response.list.Count -gt $PageNumber * 24) { $next = $pageNext }
                return New-CatalogResult $items $next
            }
            $source = if ($response.archives) { $response.archives } else { $response.items }
            $items = @($source | ForEach-Object { Format-Card $_ })
            if ($items.Count -ge 15) { $next = $pageNext }
        }
        '^season:([1-7])$' {
            $type = [int]$Matches[1]
            $response = Invoke-BiliApi '/pgc/season/index/result' @{st = $type; season_type = $type; page = $PageNumber; pagesize = 24; type = 1}
            $items = @($response.list | ForEach-Object { Format-Season $_ })
            if ($response.has_next) { $next = $pageNext }
        }
        '^live$' {
            $response = Invoke-LiveApi '/xlive/web-interface/v1/webMain/getMoreRecList' @{platform = 'web'; page = $PageNumber}
            $items = @($response.recommend_room_list | ForEach-Object { Format-LiveRoom $_ })
            if ($items.Count) { $next = $pageNext }
        }
        '^hot-search$' {
            $response = Invoke-BiliApi '/x/web-interface/search/square' @{limit = 10; platform = 'web'}
            $items = @($response.trending.list | Where-Object { $_.keyword } | ForEach-Object {
                @{title = [string]$_.show_name; keyword = [string]$_.keyword}
            })
        }
        '^author:([1-9][0-9]{0,19})$' {
            $userId = $Matches[1]
            $response = Invoke-BiliApi '/x/space/wbi/arc/search' @{mid = $userId; order = 'pubdate'; pn = $PageNumber; ps = 24} -Signed
            $items = @($response.list.vlist | ForEach-Object { Format-Card $_ })
            if ($response.page.count -gt $PageNumber * 24) { $next = $pageNext }
        }
        '^related:(BV[A-Za-z0-9]{10})$' {
            $response = Invoke-BiliApi '/x/web-interface/archive/related' @{bvid = $Matches[1]}
            $items = @($response | ForEach-Object { Format-Card $_ })
        }
        '^comments:([1-9][0-9]{0,18})(?::([1-9][0-9]{0,18})|:(latest))?$' {
            return Get-CommentPage ([long]$Matches[1]) $PageNumber ([long]$Matches[2]) ($Matches[3] -eq 'latest')
        }
        '^(history|dynamic|later|folders|following|following-seasons|following-series|favorite:[1-9][0-9]{0,19})$' {
            $userId = Get-AccountId
            if (-not $userId) { return @{requiresLogin = $true; items = @(); more = $false; cursor = ''} }
            switch -Regex ($Key) {
                '^history$' {
                    $parameters = @{ps = 24}
                    if ($Cursor -match '^(\d+):(\d+):([a-z][a-z0-9_-]{0,20})$') {
                        $parameters.max = $Matches[1]; $parameters.view_at = $Matches[2]; $parameters.business = $Matches[3]
                    }
                    $response = Invoke-BiliApi '/x/web-interface/history/cursor' $parameters
                    $items = @($response.list | ForEach-Object {
                        $item = $_
                        $card = Format-Card @{bvid = $item.history.bvid; title = $item.title; cover = $item.cover; author = $item.author_name; duration = $item.duration}
                        if ($item.history.business -eq 'pgc' -and [string]$item.history.epid -match '^[1-9][0-9]{0,18}$') {
                            $card = @{
                                kind = 'season'; title = [string]$item.title; duration = $item.duration
                                cover = Get-CoverUrl $item.cover; author = [string]$item.show_title
                                url = $referrer + 'bangumi/play/ep' + $item.history.epid
                            }
                        }
                        if ($card) {
                            if ($card.kind -ne 'season' -and $item.history.page -gt 1) { $card.url += '?p=' + $item.history.page }
                            $card.progress = $item.progress
                            $card
                        }
                    })
                    if ($response.list.Count -ge 24 -and $response.cursor.view_at -and $response.cursor.business -match '^[a-z][a-z0-9_-]{0,20}$') {
                        $next = "$($response.cursor.max):$($response.cursor.view_at):$($response.cursor.business)"
                    }
                }
                '^dynamic$' {
                    $response = Invoke-BiliApi '/x/polymer/web-dynamic/v1/feed/all' @{type = 'video'; offset = $Cursor}
                    $items = @($response.items | ForEach-Object {
                        $archive = $_.modules.module_dynamic.major.archive
                        if ($archive.bvid) {
                            Format-Card @{bvid = $archive.bvid; title = $archive.title; cover = $archive.cover
                                author = $_.modules.module_author.name; duration = $archive.duration_text; play = $archive.stat.play}
                        }
                    })
                    if ($response.has_more -and $response.offset) { $next = [string]$response.offset }
                }
                '^later$' {
                    $response = Invoke-BiliApi '/x/v2/history/toview'
                    $items = @($response.list | Select-Object -Skip (($PageNumber - 1) * 24) -First 24 | ForEach-Object { Format-Card $_ })
                    if ($response.list.Count -gt $PageNumber * 24) { $next = $pageNext }
                }
                '^folders$' {
                    $response = Invoke-BiliApi '/x/v3/fav/folder/created/list-all' @{up_mid = $userId}
                    $items = @($response.list | Where-Object { $_.id } | ForEach-Object {
                        @{kind = 'catalog'; key = 'favorite:' + $_.id; url = 'favorite:' + $_.id; title = $_.title; author = "$($_.media_count) 个视频"}
                    })
                }
                '^favorite:(\d+)$' {
                    $response = Invoke-BiliApi '/x/v3/fav/resource/list' @{media_id = $Matches[1]; pn = $PageNumber; ps = 24; order = 'mtime'; type = 0}
                    $items = @($response.medias | ForEach-Object {
                        Format-Card @{bvid = $_.bvid; title = $_.title; cover = $_.cover; owner = $_.upper; duration = $_.duration}
                    })
                    if ($response.has_more) { $next = $pageNext }
                }
                '^following$' {
                    $response = Invoke-BiliApi '/x/relation/followings' @{vmid = $userId; pn = $PageNumber; ps = 24; order = 'desc'}
                    $items = @($response.list | Where-Object { $_.mid } | ForEach-Object {
                        @{kind = 'catalog'; key = 'author:' + $_.mid; url = 'author:' + $_.mid; title = $_.uname; cover = Get-CoverUrl $_.face; author = $_.sign}
                    })
                    if ($response.total -gt $PageNumber * 24) { $next = $pageNext }
                }
                '^following-(seasons|series)$' {
                    $type = if ($Key -eq 'following-series') { 2 } else { 1 }
                    $response = Invoke-BiliApi '/x/space/bangumi/follow/list' @{vmid = $userId; type = $type; pn = $PageNumber; ps = 24}
                    $items = @($response.list | ForEach-Object { Format-Season $_ })
                    if ($response.total -gt $PageNumber * 24) { $next = $pageNext }
                }
            }
        }
        default { throw 'Invalid catalog section.' }
    }
    if ($next -eq $Cursor) { $next = '' }
    New-CatalogResult $items $next
}
