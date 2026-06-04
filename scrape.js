const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const { URL } = require('url');

const targetUrl = 'https://wayin.ai/';
const outputDir = __dirname;

const headers = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
};

// Helper to make GET requests (returns string or buffer)
function fetchUrl(urlStr, isBinary = false) {
    return new Promise((resolve, reject) => {
        const url = new URL(urlStr);
        const client = url.protocol === 'https:' ? https : http;
        
        const req = client.get(urlStr, { headers }, (res) => {
            if (res.statusCode === 301 || res.statusCode === 302) {
                // Follow redirect
                const redirectUrl = new URL(res.headers.location, urlStr).toString();
                fetchUrl(redirectUrl, isBinary).then(resolve).catch(reject);
                return;
            }
            if (res.statusCode !== 200) {
                reject(new Error(`Failed to fetch ${urlStr}: HTTP ${res.statusCode}`));
                return;
            }
            
            const chunks = [];
            res.on('data', (chunk) => chunks.push(chunk));
            res.on('end', () => {
                const buffer = Buffer.concat(chunks);
                resolve(isBinary ? buffer : buffer.toString('utf8'));
            });
        });
        
        req.on('error', (err) => reject(err));
    });
}

// Download a URL and save it to file
async function downloadFile(urlStr, destPath, isBinary = false) {
    try {
        const content = await fetchUrl(urlStr, isBinary);
        fs.mkdirSync(path.dirname(destPath), { recursive: true });
        fs.writeFileSync(destPath, content);
        console.log(`Successfully downloaded: ${urlStr} -> ${destPath}`);
        return content;
    } catch (err) {
        console.error(`Error downloading ${urlStr}: ${err.message}`);
        return null;
    }
}

// Map remote URL to local relative path
function getLocalPathInfo(urlStr) {
    try {
        let cleanUrl = urlStr.split('?')[0].split('#')[0];
        if (cleanUrl.startsWith('//')) {
            cleanUrl = 'https:' + cleanUrl;
        } else if (cleanUrl.startsWith('/')) {
            cleanUrl = new URL(cleanUrl, targetUrl).toString();
        }
        
        const parsed = new URL(cleanUrl);
        let relativePath = '';
        
        if (parsed.pathname === '/') {
            relativePath = 'index.html';
        } else {
            // Keep the hostname in path to avoid conflicts
            const hostClean = parsed.hostname.replace('www.', '');
            if (hostClean === 'wayin.ai') {
                // Strip leading slash
                relativePath = parsed.pathname.substring(1);
            } else {
                relativePath = path.join('external', hostClean, parsed.pathname.substring(1));
            }
        }
        
        // Ensure index.html if no extension and not a standard asset
        const ext = path.extname(relativePath);
        if (!ext && !relativePath.endsWith('/') && !relativePath.endsWith('.html')) {
            relativePath += '/index.html';
        }
        
        // Normalize paths for windows/unix consistency
        relativePath = relativePath.replace(/\\/g, '/');
        
        return {
            fullUrl: cleanUrl,
            localPath: relativePath,
            absoluteLocalPath: path.join(outputDir, relativePath)
        };
    } catch (e) {
        return null;
    }
}

async function main() {
    console.log(`Starting clone of ${targetUrl}...`);
    
    // 1. Fetch main HTML
    let htmlContent;
    try {
        htmlContent = await fetchUrl(targetUrl);
    } catch (err) {
        console.error(`Failed to fetch index HTML: ${err.message}`);
        return;
    }
    
    const urlMap = new Map(); // originalUrl -> local relative path
    const cssFiles = [];      // Array of { url, localPath, content }
    
    // Regular expressions to extract resource URLs
    const attributeRegex = /(?:href|src|content|data-preload-url)=["']([^"']+)["']/gi;
    const srcsetRegex = /srcset=["']([^"']+)["']/gi;
    
    // Extract assets from HTML
    const foundUrls = new Set();
    
    let match;
    while ((match = attributeRegex.exec(htmlContent)) !== null) {
        foundUrls.add(match[1]);
    }
    
    while ((match = srcsetRegex.exec(htmlContent)) !== null) {
        // srcset format: "image1.jpg 100w, image2.jpg 200w"
        const parts = match[1].split(',');
        for (const part of parts) {
            const urlPart = part.trim().split(' ')[0];
            if (urlPart) foundUrls.add(urlPart);
        }
    }
    
    // Filter and normalize URLs to download
    const assetsToDownload = [];
    
    for (const rawUrl of foundUrls) {
        // Skip external trackings, analytics, next-specific api calls, etc. unless they are main chunks
        if (rawUrl.startsWith('data:') || rawUrl.startsWith('chrome-extension:') || rawUrl.startsWith('#') || rawUrl.startsWith('javascript:')) {
            continue;
        }
        if (rawUrl.includes('google-analytics') || rawUrl.includes('doubleclick') || rawUrl.includes('facebook.net')) {
            continue;
        }
        
        const pathInfo = getLocalPathInfo(rawUrl);
        if (!pathInfo) continue;
        
        // We only want static assets, scripts, styles, fonts, images
        const ext = path.extname(pathInfo.localPath).toLowerCase();
        const isAsset = ext === '.js' || ext === '.css' || ext === '.png' || ext === '.jpg' || ext === '.jpeg' || ext === '.gif' || ext === '.svg' || ext === '.webp' || ext === '.ico' || ext === '.woff' || ext === '.woff2' || ext === '.ttf';
        
        if (isAsset) {
            assetsToDownload.push({
                rawUrl,
                ...pathInfo,
                isBinary: ['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.ico', '.woff', '.woff2', '.ttf'].includes(ext)
            });
        }
    }
    
    console.log(`Found ${assetsToDownload.length} assets to download from HTML.`);
    
    // Download assets
    for (const asset of assetsToDownload) {
        console.log(`Downloading ${asset.fullUrl}...`);
        const content = await downloadFile(asset.fullUrl, asset.absoluteLocalPath, asset.isBinary);
        
        if (content !== null) {
            urlMap.set(asset.rawUrl, asset.localPath);
            if (path.extname(asset.localPath) === '.css') {
                cssFiles.push({
                    url: asset.fullUrl,
                    localPath: asset.localPath,
                    absoluteLocalPath: asset.absoluteLocalPath,
                    content: content.toString('utf8')
                });
            }
        }
    }
    
    // 2. Parse downloaded CSS files for sub-resources (fonts, images)
    console.log('Parsing CSS files for font and image references...');
    const cssUrlRegex = /url\(['"]?([^'")]+)['"]?\)/gi;
    
    for (const cssFile of cssFiles) {
        let cssContent = cssFile.content;
        let cssMatch;
        const subAssets = [];
        
        while ((cssMatch = cssUrlRegex.exec(cssFile.content)) !== null) {
            const rawSubUrl = cssMatch[1];
            if (rawSubUrl.startsWith('data:')) continue;
            
            // Resolve sub URL relative to CSS file URL
            let absoluteSubUrl = '';
            try {
                absoluteSubUrl = new URL(rawSubUrl, cssFile.url).toString();
            } catch (e) {
                continue;
            }
            
            const subPathInfo = getLocalPathInfo(absoluteSubUrl);
            if (!subPathInfo) continue;
            
            subAssets.push({
                rawUrl: rawSubUrl,
                fullUrl: absoluteSubUrl,
                ...subPathInfo
            });
        }
        
        // Download sub-assets and rewrite CSS links
        for (const subAsset of subAssets) {
            const ext = path.extname(subAsset.localPath).toLowerCase();
            const isBinary = ['.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.ico', '.woff', '.woff2', '.ttf'].includes(ext);
            
            console.log(`Downloading sub-asset from CSS: ${subAsset.fullUrl}...`);
            await downloadFile(subAsset.fullUrl, subAsset.absoluteLocalPath, isBinary);
            
            // Rewrite CSS path to be relative to the CSS file itself
            const relativeToCss = path.relative(path.dirname(cssFile.absoluteLocalPath), subAsset.absoluteLocalPath).replace(/\\/g, '/');
            
            // Replace the URL reference in the CSS content
            cssContent = cssContent.replace(new RegExp(escapeRegExp(subAsset.rawUrl), 'g'), relativeToCss);
        }
        
        // Write the updated CSS file
        fs.writeFileSync(cssFile.absoluteLocalPath, cssContent);
    }
    
    // 3. Rewrite HTML content to point to local assets
    console.log('Rewriting HTML links...');
    let updatedHtml = htmlContent;
    
    for (const [rawUrl, localPath] of urlMap.entries()) {
        updatedHtml = updatedHtml.replace(new RegExp(escapeRegExp(rawUrl), 'g'), localPath);
    }
    
    // Save updated index.html
    const indexDest = path.join(outputDir, 'index.html');
    fs.writeFileSync(indexDest, updatedHtml);
    console.log(`Saved updated main page to: ${indexDest}`);
    
    console.log('\nClone completed successfully!');
    console.log(`Open C:\\Users\\user\\.gemini\antigravity\\scratch\\wayin-clone\\index.html in your browser to view the page.`);
}

function escapeRegExp(string) {
    return string.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); // $& means the whole matched string
}

main();

