param([Parameter(Mandatory)][string]$PortableConfig)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $PortableConfig).Path
$adapter = Join-Path $root 'scripts/newbv/danmaku-adapter.lua'
if (-not (Test-Path -LiteralPath $adapter -PathType Leaf)) { throw 'Copy the NewBV extension to portable_config/scripts/newbv first.' }
$main = Join-Path $root 'scripts/uosc_danmaku/main.lua'
$parser = Join-Path $root 'scripts/uosc_danmaku/modules/parse.lua'
$mainCode = [IO.File]::ReadAllText($main)
$parserCode = [IO.File]::ReadAllText($parser)
if ($mainCode -notmatch '(?m)^VERSION = "2\.2\.0"\r?$') { throw 'This integration requires the bundled uosc_danmaku 2.2.0.' }

$filter = 'if not is_blacklisted(d.text, black_patterns) then'
$replacement = 'if (not newbv_allows_danmaku or newbv_allows_danmaku(d)) and not is_blacklisted(d.text, black_patterns) then'
$hook = @'
local newbv_adapter = mp.find_config_file("scripts/newbv/danmaku-adapter.lua")
if newbv_adapter then dofile(newbv_adapter) end
'@
if (-not $parserCode.Contains($replacement) -and -not $parserCode.Contains($filter)) {
    throw 'The bundled danmaku parser has changed.'
}
$parserUpdated = $parserCode.Replace($filter, $replacement).Replace(
    '    if options.max_screen_danmaku > 0 and options.merge_tolerance <= 0 then',
    "    local merge_tolerance = options.merge_tolerance`n    if options.max_screen_danmaku > 0 and merge_tolerance <= 0 then").Replace(
    '        options.merge_tolerance = options.scrolltime', '        merge_tolerance = options.scrolltime').Replace(
    'merge_duplicate_danmaku(danmakus, options.merge_tolerance)', 'merge_duplicate_danmaku(danmakus, merge_tolerance)')
if ($parserUpdated -cne $parserCode) { [IO.File]::WriteAllText($parser, $parserUpdated) }
if (-not $mainCode.Contains('local newbv_adapter = mp.find_config_file(')) {
    [IO.File]::WriteAllText($main, $mainCode.TrimEnd() + "`n`n" + $hook + "`n")
}
