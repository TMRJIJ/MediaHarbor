const found = new Map();
const options = settings || {};
const images = /\.(avif|bmp|gif|heic|ico|jpe?g|png|svg|tiff?|webp)(?:$|\?)/i;
const videos = /\.(avi|m4v|mkv|mov|mp4|mpeg|mpg|ogv|webm)(?:$|\?)/i;
const audio = /\.(aac|aiff?|flac|m4a|mp3|oga|ogg|opus|wav|wma)(?:$|\?)/i;
const files = /\.(7z|apk|csv|dmg|docx?|epub|gz|iso|json|msi|otf|pdf|pptx?|rar|tar|torrent|ttf|txt|xlsx?|zip)(?:$|\?)/i;

function web(value) {
    if (typeof value !== 'string' || !value.trim()) return null;
    try {
        const url = new URL(value, document.baseURI);
        if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return null;
        url.hash = '';
        return url;
    } catch { return null; }
}

function streamFormat(url, type) {
    const mime = (type || '').split(';')[0].trim().toLowerCase();
    if (/\.m3u8$/i.test(url.pathname) || /^(application|audio)\/(vnd\.apple\.mpegurl|x-mpegurl|mpegurl)$/.test(mime)) return 'hls';
    if (/\.mpd$/i.test(url.pathname) || mime === 'application/dash+xml') return 'dash';
    return null;
}

function add(value, hint, type) {
    const url = web(value);
    if (!url || found.size >= 5000) return;
    if (url.hostname === 'pbs.twimg.com' && url.pathname.startsWith('/media/')) {
        const legacy = url.pathname.match(/^(\/media\/[^/]+)\.(jpe?g|png|gif|webp)(?::[a-z0-9]+)?$/i);
        if (legacy) {
            url.pathname = legacy[1];
            if (!url.searchParams.has('format')) url.searchParams.set('format', legacy[2].toLowerCase().replace('jpeg', 'jpg'));
        }
        url.searchParams.set('name', 'orig');
        url.searchParams.sort();
    }
    const stream = streamFormat(url, type);
    const kind = stream ? 'Videos' : images.test(url.pathname) ? 'Images'
        : videos.test(url.pathname) ? 'Videos'
        : audio.test(url.pathname) ? 'Audio'
        : files.test(url.pathname) ? 'Other files' : hint;
    if (!kind) return;
    const previous = found.get(url.href);
    if (!previous?.stream || stream) {
        const media = {url: url.href, kind};
        if (stream) media.stream = stream;
        found.set(url.href, media);
    }
}

function bestImage(node) {
    const variants = (node.getAttribute('data-srcset') || node.getAttribute('srcset') || '')
        .split(',').map(part => part.trim().split(/\s+/)).filter(part => part[0]);
    variants.sort((a, b) => (parseFloat(b[1]) || 1) - (parseFloat(a[1]) || 1));
    return node.getAttribute('data-original') || node.getAttribute('data-full-src')
        || variants[0]?.[0] || node.getAttribute('data-src') || node.getAttribute('data-lazy-src')
        || node.currentSrc || node.getAttribute('src');
}

function select(selector) {
    return selector ? Array.from(document.querySelectorAll(selector)) : [];
}

function pageAsset(node, value) {
    if (!options.ignoreComponents) return false;
    const marker = /^(?:(?:site|brand|forum|user|profile)[ _-])?(?:logo|favicon|icon|spinner|loader|loading|avatar|emoji|emoticon|sprite|placeholder|spacer|tracking[ _-]pixel)(?:[@_. -](?:dark|light|small|large|\d+x?\d*))?$/i;
    const url = web(value);
    const filename = url?.pathname.split('/').pop()?.replace(/\.[a-z0-9]+$/i, '') || '';
    if (marker.test(filename) || /\/(avatars|profile_images|favicons|emojis|emoticons)\//i.test(url?.pathname || '')) return true;
    for (let element = node, depth = 0; element && depth < 3; element = element.parentElement, depth++) {
        if (element.getAttribute('role') === 'progressbar') return true;
        const identifiers = [element.id, element.getAttribute('class'), element.getAttribute('data-testid')];
        const labels = [element.getAttribute('alt'), element.getAttribute('aria-label')];
        if (identifiers.some(value => value && value.split(/\s+/).some(token => marker.test(token))) ||
            labels.some(value => value && marker.test(value.trim()))) return true;
    }
    return false;
}

const galleryLinks = new Map();
const replacedPreviews = new Set();
const linkedOriginals = new Set();
const galleryHosts = new Set(options.galleryHosts || []);

function matchesGalleryHost(host) {
    while (host) {
        if (galleryHosts.has(host)) return true;
        const dot = host.indexOf('.');
        if (dot < 0) return false;
        host = host.slice(dot + 1);
    }
    return false;
}

if (!options.search && options.linkedGalleries) {
    for (const link of select(options.linkedGalleries)) {
        const isImageNode = link.tagName === 'IMG';
        const explicitGallery = link.getAttribute('data-gallery-url');
        const value = explicitGallery || link.getAttribute('href') ||
            (isImageNode && (link.getAttribute('data-full-src') || link.getAttribute('data-original')));
        const url = web(value);
        if (!url) continue;
        const host = url.hostname.replace(/^www\./, '');
        const imageLanding = (/^pixhost\.(cc|to|org)$/.test(host) && /^\/show\/\d+\/\d+_/.test(url.pathname))
            || (/^(phun\.)?image(twist|haha)\.com$/.test(host) && /^\/[a-z0-9]{12}\//.test(url.pathname));
        const isImage = !imageLanding && images.test(url.pathname);
        const isLoadedImage = isImageNode && !explicitGallery && link.complete && link.naturalWidth > 0
            && web(link.currentSrc)?.href === url.href;
        const isGallery = !isImage && url.origin !== location.origin && matchesGalleryHost(url.hostname)
            && !isLoadedImage && !videos.test(url.pathname) && !audio.test(url.pathname) && !files.test(url.pathname)
            && !streamFormat(url);
        if (!isImage && (!isGallery || (galleryLinks.size >= 100 && !galleryLinks.has(url.href)))) continue;
        const imagesInLink = isImageNode ? [link] : [...link.querySelectorAll('img')];
        if (imagesInLink.length && imagesInLink.every(image => pageAsset(image, bestImage(image)))) continue;
        const thumbnails = selectThumbnails(imagesInLink);
        if (isImage) {
            if (pageAsset(link, url.href)) continue;
            add(url.href, 'Images');
            linkedOriginals.add(url.href);
            for (const preview of thumbnails) {
                if (preview !== url.href) replacedPreviews.add(preview);
            }
        } else {
            const entry = galleryLinks.get(url.href) || new Set();
            for (const preview of thumbnails) entry.add(preview);
            galleryLinks.set(url.href, entry);
        }
    }
}
for (const original of linkedOriginals) replacedPreviews.delete(original);

function selectThumbnails(imagesInLink) {
    const previews = new Set();
    for (const image of imagesInLink) {
        const preferred = bestImage(image);
        if (pageAsset(image, preferred)) continue;
        const original = web(image.getAttribute('data-original') || image.getAttribute('data-full-src'));
        for (const value of [preferred, image.currentSrc, image.getAttribute('src')]) {
            const url = web(value);
            if (url && url.href !== original?.href) previews.add(url.href);
        }
    }
    return [...previews];
}

function addXMedia(value) {
    const url = web(value);
    if (!url) return;
    if (url.hostname === 'pbs.twimg.com' &&
        /^\/(media|ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)\//.test(url.pathname)) {
        add(url.href, 'Images');
    } else if (['video.twimg.com', 'video-s.twimg.com'].includes(url.hostname)
        && (/\.mp4$/i.test(url.pathname) || streamFormat(url))) {
        add(url.href, 'Videos');
    }
}

if (options.search) {
    for (const node of select('a.iusc[m], [data-m]')) {
        try {
            const data = JSON.parse(node.getAttribute('m') || node.getAttribute('data-m'));
            add(data.murl, 'Images');
        } catch {}
    }
    for (const node of select('a[href*="imgurl="], a[href*="mediaurl="], a[href*="iurl="], [data-iurl]')) {
        const url = web(node.href);
        add(node.getAttribute('data-iurl') || url?.searchParams.get('imgurl')
            || url?.searchParams.get('mediaurl') || url?.searchParams.get('iurl'), 'Images');
    }
    // Google exposes full-size URLs when an image result is opened.
    for (const node of select('img.sFlh5c, img.iPVvYb')) {
        const url = web(node.currentSrc || node.src);
        if (url && !/gstatic\.com$/.test(url.hostname)) add(url.href, 'Images');
    }
    if (options.search === 'Yandex Images') {
        for (const node of select('a[href*="img_url="], a[href*="rpt=imageview"], [data-bem], [data-state]')) {
            const link = web(node.href);
            const original = link?.searchParams.get('img_url')
                || (link?.searchParams.get('rpt') === 'imageview' ? link.searchParams.get('url') : null);
            if (original) add(original, 'Images');
            const metadata = node.getAttribute('data-bem') || node.getAttribute('data-state');
            if (!metadata || metadata.length > 250000) continue;
            try {
                const values = [JSON.parse(metadata)];
                for (let index = 0; index < values.length && index < 2000; index++) {
                    const entry = values[index];
                    if (!entry || typeof entry !== 'object') continue;
                    for (const [key, value] of Object.entries(entry)) {
                        if (/^(origUrl|originalUrl|img_href|imgUrl|imageUrl)$/i.test(key)
                            && typeof value === 'string' && /^(https?:)?\/\//i.test(value)) {
                            add(value, 'Images');
                        } else if (value && typeof value === 'object') {
                            values.push(value);
                        }
                    }
                }
            } catch {}
        }
    }
    if (options.search === 'DuckDuckGo Images') {
        for (const node of select('img, a[href*="/iu/"]')) {
            const value = web(node.tagName === 'IMG' ? bestImage(node) : node.href);
            if (value?.hostname.endsWith('.duckduckgo.com') && value.pathname.startsWith('/iu/')) {
                add(value.searchParams.get('u'), 'Images');
            } else if (node.matches('.tile--img__img, .detail__media__img, [data-testid="image-result-image"]')) {
                add(value?.href, 'Images');
            }
        }
    }
} else if (options.xMedia) {
    for (const node of select('img, picture source, video, video source, a[href*="twimg.com"], [style*="twimg.com"], meta[content*="twimg.com"]')) {
        if (node.tagName === 'IMG' || node.tagName === 'SOURCE') addXMedia(bestImage(node));
        for (const value of [node.currentSrc, node.getAttribute('src'), node.getAttribute('poster'),
            node.getAttribute('data-src'), node.getAttribute('href'), node.getAttribute('content')]) {
            addXMedia(value);
        }
        for (const match of (node.getAttribute('style') || '').matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/gi)) {
            addXMedia(match[1]);
        }
    }
} else {
    for (const node of select(options.selector || 'img, video, audio, video source, audio source, a[href], meta[property], link[as]')) {
        const tag = node.tagName;
        let hint = options.kind || null;
        let value = options.attribute ? node.getAttribute(options.attribute) : null;
        if (tag === 'IMG') {
            hint = options.kind || 'Images';
            if (!options.attribute) {
                value = bestImage(node);
                if (galleryLinks.has(web(value)?.href)) value = node.currentSrc || node.getAttribute('src');
            }
        } else if (tag === 'VIDEO' || tag === 'AUDIO' || tag === 'SOURCE') {
            const isAudio = tag === 'AUDIO' || node.parentElement?.tagName === 'AUDIO';
            hint = isAudio ? 'Audio' : 'Videos';
            if (!options.attribute) value = node.currentSrc || node.getAttribute('src');
        } else if (tag === 'A') {
            if (!options.attribute) value = node.getAttribute('href');
            if (!hint && node.hasAttribute('download')) hint = 'Other files';
            if (!hint && /attachment/i.test(value || '')) hint = 'Other files';
        } else if (tag === 'META') {
            const property = node.getAttribute('property') || '';
            if (/^(og:image|twitter:image)(:url|:secure_url)?$/.test(property)) hint = 'Images';
            if (/^og:video:(url|secure_url)$/.test(property)) hint = 'Videos';
            if (/^og:audio(:url|:secure_url)?$/.test(property)) hint = 'Audio';
            if (hint && !options.attribute) value = node.content;
        } else if (tag === 'LINK') {
            hint = {image: 'Images', video: 'Videos', audio: 'Audio'}[node.as] || hint;
            if (hint && !options.attribute) value = node.href;
        } else if (!options.attribute) {
            value = node.getAttribute('data-src') || node.getAttribute('src') || node.getAttribute('href');
        }
        const address = web(value);
        if (address && galleryLinks.has(address.href)) continue;
        if (address && (hint === 'Images' || images.test(address.pathname)) &&
            (replacedPreviews.has(address.href) || pageAsset(node, address.href))) continue;
        add(value, hint, node.getAttribute('type'));
    }
}

if (!options.search && document.querySelector('video')) {
    for (const entry of performance.getEntriesByType('resource')) {
        if (performance.timeOrigin + entry.startTime < (options.resourceSince || 0)) continue;
        const url = web(entry.name);
        if (url && streamFormat(url, entry.contentType)) add(url.href, 'Videos', entry.contentType);
    }
}

const next = new Set();
function addPage(value) {
    const url = web(value);
    if (url && url.origin === location.origin && next.size < 500) next.add(url.href);
}
if (!options.search) {
    for (const node of select(options.next || 'a[rel=next], link[rel=next], a.pageNav-jump--next, .pagination .next a, a[aria-label="Next page"]')) {
        addPage(node.getAttribute('href'));
    }
    if (options.follow) {
        for (const node of select('main a[href], article a[href], [role=main] a[href], body a[href]')) {
            const href = web(node.getAttribute('href'));
            if (href && !found.has(href.href) && !images.test(href.pathname) && !videos.test(href.pathname)
                && !audio.test(href.pathname) && !files.test(href.pathname)) addPage(href.href);
        }
    }
}
const gallery = document.querySelector('[data-gallery-title]');
const galleryTitle = gallery?.getAttribute('data-gallery-title')?.trim()
    || document.querySelector('main h1, article h1, body > h1')?.textContent?.trim()
    || null;
return {media: [...found.values()], pages: [...next],
        galleries: [...galleryLinks].map(([url, previews]) => ({url, previews: [...previews]})),
        replacedPreviews: [...replacedPreviews],
        pageTitle: (document.title || '').slice(0, 500) || null,
        galleryTitle: galleryTitle?.slice(0, 500) || null};
