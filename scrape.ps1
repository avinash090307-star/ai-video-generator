$targetUrl = "https://wayin.ai/"
$outputDir = $PSScriptRoot
if (-not $outputDir) { $outputDir = Get-Location }
$userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Define helper to compute relative paths securely on all PowerShell/dotnet versions
function Get-RelativePath {
    param (
        [string]$fromDir,
        [string]$toFile
    )
    # Ensure paths end properly for Uri representation
    if (-not $fromDir.EndsWith("\") -and -not $fromDir.EndsWith("/")) {
        $fromDir += "/"
    }
    $fromUri = New-Object System.Uri -ArgumentList $fromDir
    $toUri = New-Object System.Uri -ArgumentList $toFile
    $relativeUri = $fromUri.MakeRelativeUri($toUri)
    return [System.Uri]::UnescapeDataString($relativeUri.ToString()) -replace "\\", "/"
}

# Helper to download files
function Download-File {
    param (
        [string]$url,
        [string]$destPath
    )
    try {
        $parentDir = Split-Path -Parent $destPath
        if (-not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Force -Path $parentDir | Out-Null
        }
        
        # Download file using standard .NET WebClient or Invoke-WebRequest
        # .NET WebClient is extremely fast and reliable across PS versions
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add("User-Agent", $userAgent)
        $webClient.DownloadFile($url, $destPath)
        
        Write-Host "Downloaded: $url -> $destPath" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Failed to download $url : $_"
        return $false
    }
}

# 1. Fetch main page HTML
Write-Host "Fetching main page: $targetUrl..." -ForegroundColor Cyan
try {
    $webClient = New-Object System.Net.WebClient
    $webClient.Headers.Add("User-Agent", $userAgent)
    $htmlContent = $webClient.DownloadString($targetUrl)
}
catch {
    Write-Error "Failed to fetch main page: $_"
    exit
}

# 2. Extract URLs
Write-Host "Extracting asset links from HTML..." -ForegroundColor Cyan
# We look for href="...", src="..." or content="..."
$urlMatches = [regex]::Matches($htmlContent, '(?:href|src|content)=["'']([^"'']+)["'']')
$urls = @()
foreach ($match in $urlMatches) {
    $urls += $match.Groups[1].Value
}

# Add srcset URLs if any
$srcsetMatches = [regex]::Matches($htmlContent, 'srcset=["'']([^"'']+)["'']')
foreach ($match in $srcsetMatches) {
    $parts = $match.Groups[1].Value.Split(',')
    foreach ($part in $parts) {
        $urlPart = $part.Trim().Split(' ')[0]
        if ($urlPart) { $urls += $urlPart }
    }
}

# Get unique URLs
$urls = $urls | Select-Object -Unique

# Download map: originalUrl -> localPath
$urlMap = @{}
$cssFiles = @()

foreach ($rawUrl in $urls) {
    # Skip non-downloadable types
    if ($rawUrl -like "data:*" -or $rawUrl -like "chrome-extension:*" -or $rawUrl -like "#*" -or $rawUrl -like "javascript:*") {
        continue
    }
    # Skip tracking & external third-party widgets unless they are key elements
    if ($rawUrl -match "google-analytics|doubleclick|facebook.net|ahrefs|turnstile|analytics.twitter") {
        continue
    }
    
    # Resolve relative URL
    $resolvedUrl = $rawUrl
    if ($rawUrl.StartsWith("//")) {
        $resolvedUrl = "https:" + $rawUrl
    }
    elseif ($rawUrl.StartsWith("/")) {
        $resolvedUrl = "https://wayin.ai" + $rawUrl
    }
    elseif (-not ($rawUrl.StartsWith("http://") -or $rawUrl.StartsWith("https://"))) {
        $resolvedUrl = "https://wayin.ai/" + $rawUrl.TrimStart('/')
    }
    
    # Parse URI to get extension
    try {
        $uri = New-Object System.Uri -ArgumentList $resolvedUrl
    }
    catch {
        continue
    }
    
    $cleanPath = $uri.AbsolutePath
    $ext = [System.IO.Path]::GetExtension($cleanPath).ToLower()
    
    $isAsset = $ext -in @(".js", ".css", ".png", ".jpg", ".jpeg", ".gif", ".svg", ".webp", ".ico", ".woff", ".woff2", ".ttf")
    if (-not $isAsset) {
        continue
    }
    
    # Build local path
    $hostName = $uri.Host.Replace("www.", "")
    $localRelPath = ""
    if ($hostName -eq "wayin.ai") {
        $localRelPath = $cleanPath.TrimStart('/')
    }
    else {
        # Keep host folder for non-local assets
        $localRelPath = "external/" + $hostName + $cleanPath
    }
    
    $localRelPath = $localRelPath -replace "\\", "/"
    $absoluteDest = Join-Path $outputDir $localRelPath
    
    # Download
    $success = Download-File -url $resolvedUrl -destPath $absoluteDest
    if ($success) {
        $urlMap[$rawUrl] = $localRelPath
        if ($ext -eq ".css") {
            $cssFiles += @{
                url = $resolvedUrl
                localPath = $localRelPath
                absPath = $absoluteDest
            }
        }
    }
}

# 3. Scan downloaded CSS files for background images and fonts
Write-Host "Scanning downloaded CSS files for font and image references..." -ForegroundColor Cyan
foreach ($css in $cssFiles) {
    if (-not (Test-Path $css.absPath)) { continue }
    
    $cssContent = Get-Content -Raw -Path $css.absPath
    $cssUrlMatches = [regex]::Matches($cssContent, 'url\([''"]?([^\''"\)]+)[''"]?\)')
    $cssUrls = @()
    foreach ($match in $cssUrlMatches) {
        $cssUrls += $match.Groups[1].Value
    }
    $cssUrls = $cssUrls | Select-Object -Unique
    
    foreach ($rawCssUrl in $cssUrls) {
        if ($rawCssUrl -like "data:*" -or $rawCssUrl -like "/*" -or $rawCssUrl -like "http*") {
            # Skip absolute or data links for CSS parsing (already handled, or data: base64)
            continue
        }
        
        # Resolve relative to CSS url
        try {
            $cssBaseUri = New-Object System.Uri -ArgumentList $css.url
            $resolvedSubUrl = (New-Object System.Uri -ArgumentList @($cssBaseUri, $rawCssUrl)).AbsoluteUri
            $subUri = New-Object System.Uri -ArgumentList $resolvedSubUrl
        }
        catch {
            continue
        }
        
        $subCleanPath = $subUri.AbsolutePath
        $subHost = $subUri.Host.Replace("www.", "")
        
        $subLocalRel = ""
        if ($subHost -eq "wayin.ai") {
            $subLocalRel = $subCleanPath.TrimStart('/')
        }
        else {
            $subLocalRel = "external/" + $subHost + $subCleanPath
        }
        
        $subLocalRel = $subLocalRel -replace "\\", "/"
        $subAbsDest = Join-Path $outputDir $subLocalRel
        
        $success = Download-File -url $resolvedSubUrl -destPath $subAbsDest
        if ($success) {
            # Compute relative path from the CSS file folder to the downloaded asset
            $cssFolder = Split-Path -Parent $css.absPath
            $relativeUrl = Get-RelativePath -fromDir $cssFolder -toFile $subAbsDest
            
            # Replace in CSS content
            $escapedRaw = [regex]::Escape($rawCssUrl)
            $cssContent = [regex]::Replace($cssContent, $escapedRaw, $relativeUrl)
        }
    }
    
    # Save modified CSS content
    Set-Content -Path $css.absPath -Value $cssContent
}

# 4. Rewrite HTML links
Write-Host "Rewriting HTML with local paths..." -ForegroundColor Cyan
$updatedHtml = $htmlContent
foreach ($key in $urlMap.Keys) {
    $escapedKey = [regex]::Escape($key)
    $localVal = $urlMap[$key]
    $updatedHtml = [regex]::Replace($updatedHtml, $escapedKey, $localVal)
}

# Save updated HTML
$htmlDest = Join-Path $outputDir "index.html"
Set-Content -Path $htmlDest -Value $updatedHtml

Write-Host "`nSuccessfully cloned all code, stylesheets, fonts and images!" -ForegroundColor Green
Write-Host "Root files location: $outputDir" -ForegroundColor Green
Write-Host "Open index.html to view the clone locally." -ForegroundColor Green
