# run_server.ps1
# Simple static file server using standard .NET classes. Works on all PowerShell versions.
$port = 8000
$localIp = "127.0.0.1"
$url = "http://$localIp`:$port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($url)

$currentDir = $PSScriptRoot
if (-not $currentDir) { $currentDir = Get-Location }

Write-Host "`n========================================================" -ForegroundColor Cyan
Write-Host "  Starting local web server for ai.video.generater" -ForegroundColor Green
Write-Host "  URL: $url" -ForegroundColor Green
Write-Host "  Serving files from: $currentDir" -ForegroundColor Cyan
Write-Host "  Press Ctrl + C in this terminal window to stop." -ForegroundColor Yellow
Write-Host "========================================================`n" -ForegroundColor Cyan

$listener.Start()

# Automatically open in the user's default browser
Start-Process $url

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        
        # Clean request path
        $reqPath = $request.Url.LocalPath.TrimStart('/')
        if ([string]::IsNullOrEmpty($reqPath)) {
            $reqPath = "index.html"
        }
        
        $filePath = Join-Path $currentDir $reqPath
        
        # Check if requested path is a directory, if so look for index.html inside
        if (Test-Path $filePath -PathType Container) {
            $filePath = Join-Path $filePath "index.html"
        }
        
        if (Test-Path $filePath) {
            $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
            $mimeType = "application/octet-stream"
            
            # Map standard MIME types
            switch ($ext) {
                ".html" { $mimeType = "text/html; charset=utf-8" }
                ".css"  { $mimeType = "text/css; charset=utf-8" }
                ".js"   { $mimeType = "application/javascript; charset=utf-8" }
                ".png"  { $mimeType = "image/png" }
                ".jpg"  { $mimeType = "image/jpeg" }
                ".jpeg" { $mimeType = "image/jpeg" }
                ".gif"  { $mimeType = "image/gif" }
                ".svg"  { $mimeType = "image/svg+xml" }
                ".webp" { $mimeType = "image/webp" }
                ".ico"  { $mimeType = "image/x-icon" }
                ".woff" { $mimeType = "font/woff" }
                ".woff2"{ $mimeType = "font/woff2" }
                ".ttf"  { $mimeType = "font/ttf" }
            }
            
            $response.ContentType = $mimeType
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $response.ContentLength64 = $bytes.Length
            $response.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        else {
            $response.StatusCode = 404
            $errBytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $reqPath")
            $response.OutputStream.Write($errBytes, 0, $errBytes.Length)
        }
        $response.Close()
    }
}
catch {
    Write-Host "Server stopped: $_" -ForegroundColor Red
}
finally {
    $listener.Stop()
}
