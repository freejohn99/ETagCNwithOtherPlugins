/** @type {import('./_venera_.js')} */
class Lanraragi extends ComicSource {
    name = "Lanraragi"
    key = "lanraragi"
    version = "2.2.1"
    minAppVersion = "1.4.0"
    url = "https://raw.githubusercontent.com/freejhon99/ETagCNwithOtherPlugins/master/venera_plugins/lanraragi.js"

    // 最近一次随机入口选中的真实 arcid（用于在详情页标签里加 Random 标记）
    _randomEntryId = null

    // 阅读进度上报相关状态
    _epComicId = ''
    _pageIndexByUrl = null
    _archiveProgress = {}
    _lastProgressKey = ''
    _lastProgressAt = 0
    _pendingProgress = null
    _progressTimer = null
    _infoReportId = ''

    settings = {
        api: { title: "API", type: "input", default: "http://lrr.tvc-16.science" },
        apiKey: { title: "APIKEY", type: "input", default: "" },
        randomCount: { title: "随机数量", type: "input", default: "30" },
        showRandomEntry: { title: "显示随机入口", type: "switch", default: true },
        syncProgress: { title: "同步阅读进度", type: "switch", default: true },
        progressOnInfo: { title: "详情页触发进度同步（VeneraX 等阅读器需开启）", type: "switch", default: false }
    }

    get baseUrl() { 
        let api = String(this.loadSetting('api') || this.settings.api.default || '').trim()
        api = api.replace(/\/+$/, '')
        if (api && !/^https?:\/\//i.test(api)) api = 'http://' + api
        return api
    }

    get headers() {
        const raw = this.loadSetting('apiKey')
        const headers = {}
        if (raw) {
            headers.Authorization = "Bearer " + Convert.encodeBase64(Convert.encodeUtf8(raw))
        }
        return headers
    }

    // APIKEY 直接取自设置，登录时不再二次输入。
    // fields 为空数组时，登录页不会显示任何输入框，点一下按钮即用设置里的 APIKEY 完成校验。
    account = {
      loginWithCookies: {
        fields: [],
        // 必须用箭头函数：Venera 调用的是 account.loginWithCookies.validate(...)，
        // 普通函数的 this 会指向 loginWithCookies 而不是源实例，导致 this.loadSetting 不存在。
        validate: (cookies) => {
          const key = this.loadSetting('apiKey')
          return !!(key && String(key).trim().length > 0)
        }
      },
      logout: () => {
        this.deleteData("account");
      }
    }

    _getStart(key, page) {
        if (page === 1) {
            this.saveData(key, 0)
            return 0
        }
        return Number(this.loadData(key) || 0)
    }

    _updateStart(key, returned) {
        const cur = Number(this.loadData(key) || 0)
        this.saveData(key, cur + (returned || 0))
    }

    // 给缩略图 URL 加上 no_fallback=true。
    // LRR 在缩略图尚未生成时默认返回 noThumb.png 占位图(HTTP 200)，Venera 会把占位图
    // 当作有效图片缓存，之后即使刷新也永远拿不到真正的缩略图(缓存优先命中，不会再请求)。
    // 带上 no_fallback=true 后 LRR 会改为返回 202 并投递一个后台生成缩略图的任务，
    // 等任务完成后再次加载即可拿到真实缩略图。
    _thumbUrlWithNoFallback(url) {
        const s = String(url || '')
        if (s.indexOf('no_fallback=') >= 0) return s
        return s + (s.indexOf('?') >= 0 ? '&' : '?') + 'no_fallback=true'
    }

    // 校验缩略图响应是否为真正的图片字节。
    // LRR 的占位图固定是 public/img/noThumb.png(55876 字节的 PNG)，真实缩略图是 jpg/jxl。
    // 命中占位图或 202 的 JSON 时返回 null，让 Venera 判定加载失败并跳过缓存，
    // 避免占位图/JSON 被永久缓存，从而让再次加载有机会拿到真正的缩略图。
    _validateThumbResponse(buffer) {
        try {
            const u8 = new Uint8Array(buffer)
            const n = u8.length
            if (n < 12) return null
            const b0 = u8[0], b1 = u8[1], b2 = u8[2], b3 = u8[3]
            const isJpeg = b0 === 0xFF && b1 === 0xD8
            const isJxl = b0 === 0xFF && b1 === 0x0A
            const isJxlContainer = b0 === 0x00 && b1 === 0x00 && b2 === 0x00 && b3 === 0x0C &&
                u8[4] === 0x4A && u8[5] === 0x58 && u8[6] === 0x4C && u8[7] === 0x20
            const isPng = b0 === 0x89 && b1 === 0x50 && b2 === 0x4E && b3 === 0x47
            const isGif = b0 === 0x47 && b1 === 0x49 && b2 === 0x46
            const isWebp = b0 === 0x52 && b1 === 0x49 && b2 === 0x46 && b3 === 0x46 &&
                u8[8] === 0x57 && u8[9] === 0x45 && u8[10] === 0x42 && u8[11] === 0x50
            // 精确匹配 LRR 的占位图，避免误伤真实的 PNG 缩略图
            if (isPng && n === 55876) return null
            if (isJpeg || isJxl || isJxlContainer || isPng || isGif || isWebp) return buffer
            return null
        } catch (_) {
            return buffer
        }
    }

    _randomCount() {
        const v = parseInt(this.loadSetting('randomCount'), 10)
        if (isNaN(v) || v <= 0) return 30
        return Math.min(v, 200)
    }

    _showRandomEntry() {
        const v = this.loadSetting('showRandomEntry')
        return (v === undefined || v === null) ? true : !!v
    }

    // 随机入口卡片：每次列表加载（含发现页刷新）都直接请求随机接口取一部真实漫画，
    // 展示其真实封面/标题/标签；id 用真实 arcid，点进详情页就是这一部。
    // 详情页不再随机（刷新只重载同一部），从而保证列表与详情一致。
    async _randomEntryComic(base) {
        const b = (base || '').replace(/\/+$/, '') || this.baseUrl
        try {
            const list = await this._fetchRandomArchives(b, 1)
            const item = list && list[0]
            if (item && item.arcid) {
                this._randomEntryId = item.arcid
                this.saveData('random_entry_id', item.arcid)
                return this._buildRandomCard(b, item)
            }
        } catch (_) {}
        return null
    }

    _buildRandomCard(b, info) {
        const cover = `${b}/api/archives/${info.arcid}/thumbnail`
        const tags = this._cleanListTags(info.tags)
        if (!tags.includes('随机:Lanraragi(Random)')) tags.unshift('随机:Lanraragi(Random)')
        const tagRating = this._extractRatingFromTags(info.tags)
        const stars = this._toStarsFromValue(tagRating ?? null)
        return new Comic({
            id: info.arcid,
            title: info.title || info.filename || info.arcid,
            subTitle: '',
            cover,
            tags,
            description: '页数: ' + (info.pagecount || '') + ' | 新: ' + (info.isnew || '') + ' | 扩展: ' + (info.extension || ''),
            stars
        })
    }

    // 调用 LRR 的 /api/search/random，返回随机的档案列表
    async _fetchRandomArchives(base, count, filter, newonly, untaggedonly, groupby) {
        const b = (base || '').replace(/\/+$/, '') || this.baseUrl
        const qp = []
        const add = (k, v) => qp.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
        if (filter) add('filter', filter)
        add('count', String(count || 1))
        add('newonly', String(newonly === true || newonly === 'true'))
        add('untaggedonly', String(untaggedonly === true || untaggedonly === 'true'))
        add('groupby_tanks', String(!(groupby === false || groupby === 'false')))
        // 加时间戳做缓存穿透，避免任何 HTTP 缓存返回同一批随机结果（同 Mihon 的 FORCE_NETWORK）
        add('_', String(Date.now()))
        const url = `${b}/api/search/random?${qp.join('&')}`
        const res = await Network.get(url, this.headers)
        if (res.status !== 200) throw `Invalid status code: ${res.status}`
        const data = JSON.parse(res.body)
        return Array.isArray(data.data) ? data.data : []
    }

    _syncProgressEnabled() {
        return this.loadSetting('syncProgress') !== false
    }

    _serverTracksProgress() {
        // fail-open：只有明确拿到 server_tracks_progress=false 才不上报，
        // 避免 /api/info 查询失败时（旧版本/网络问题）整个同步失效。
        return this.loadData('server_tracks_progress') !== false
    }

    // 阅读进度上报（best-effort）。
    // Venera 没有专门的阅读进度回调，这里用两处近似上报：
    // 1) loadEp（打开阅读器）时按已知进度上报一次，保证 lastreadtime 更新，「最近阅读」能列出；
    // 2) onImageLoad（页面图片实际下载，缓存命中的图片不会触发）时，用 loadEp 记录的
    //    「图片 URL -> 第几页」映射反查页码并上报，用于推进具体页码。
    // 上报做了节流（约 2s 一次）+ 尾随补偿：节流期内翻页会在窗口结束后补报最新页。
    _maybeReportProgress(url, comicId) {
        if (!this._syncProgressEnabled() || !this._serverTracksProgress()) return
        const map = this._pageIndexByUrl
        if (!map) return
        const page = map[url]
        if (!page) return
        const id = String(comicId ?? this._epComicId ?? '')
        if (!id || String(this._epComicId) !== id) return
        const key = id + ':' + page
        if (this._lastProgressKey === key) return
        const now = Date.now()
        const elapsed = now - (this._lastProgressAt || 0)
        if (elapsed >= 2000) {
            this._lastProgressKey = key
            this._lastProgressAt = now
            this._sendProgress(id, page)
            return
        }
        // 节流窗口内：记住最新页，窗口结束后补报
        this._pendingProgress = { id: id, page: page }
        if (!this._progressTimer) {
            this._progressTimer = setTimeout(() => {
                this._progressTimer = null
                const p = this._pendingProgress
                this._pendingProgress = null
                if (!p) return
                this._lastProgressKey = p.id + ':' + p.page
                this._lastProgressAt = Date.now()
                this._sendProgress(p.id, p.page)
            }, 2000 - elapsed)
        }
    }

    _sendProgress(id, page) {
        try {
            const base = (this.baseUrl || '').replace(/\/$/, '')
            const url = `${base}/api/archives/${id}/progress/${page}`
            Network.put(url, this.headers, '')
                .then(r => { try { console.log(`[Lanraragi] progress ${id} -> ${page} : ${r && r.status}`) } catch (_) {} })
                .catch(e => { try { console.log(`[Lanraragi] progress ${id} -> ${page} failed: ${e}`) } catch (_) {} })
        } catch (_) {}
    }

    // 兜底上报：某些客户端（如 VeneraX）重写了阅读器/状态层，打开阅读器时
    // 可能不经过 comic.loadEp，导致上面的进度上报完全不触发。
    // 这个开关（默认关）会在 loadInfo 打开详情/阅读器后延迟约 2s 上报一次；
    // 若随后调用了 loadThumbnails（详情页预览）或 favorites.loadFolders（收藏夹），
    // 则视为并非阅读行为而取消。这样既能兼容 VeneraX，又避免浏览详情页误标为已读。
    _scheduleProgressOnInfo(id) {
        if (this.loadSetting('progressOnInfo') !== true) return
        const token = String(id ?? '')
        if (!token) return
        this._infoReportId = token
        setTimeout(() => {
            if (this._infoReportId !== token) return
            this._infoReportId = ''
            if (this.loadSetting('progressOnInfo') !== true) return
            if (!this._syncProgressEnabled() || !this._serverTracksProgress()) return
            const known = this._archiveProgress[token] || 0
            this._sendProgress(token, known > 0 ? known : 1)
        }, 2000)
    }

    _cancelProgressOnInfo() {
        this._infoReportId = ''
    }

    // Parse various rating string/number formats and convert to 0-5 scale with 0.5 step
    _toStarsFromValue(v) {
        if (v === null || v === undefined) return null
        const s = String(v).trim()
        if (s.length === 0) return null

        // Support emoji star formats like '⭐⭐⭐' or '★★★' used by some Lanraragi setups
        if (s.includes('⭐') || s.includes('★')) {
            const count = (s.match(/⭐/g) || s.match(/★/g) || []).length
            if (count >= 0) return Math.max(0, Math.min(5, count))
        }

        // fraction like 7/10 or 3/5
        if (s.includes('/')) {
            const parts = s.split('/')
            const num = parseFloat(parts[0])
            const den = parseFloat(parts[1]) || 10
            if (!isNaN(num) && !isNaN(den) && den > 0) {
                const scaled = (num / den) * 5
                return Math.round(scaled * 2) / 2
            }
        }

        // percentage like 78%
        if (s.includes('%')) {
            const num = parseFloat(s.replace('%', ''))
            if (!isNaN(num)) {
                const scaled = (num / 100) * 5
                return Math.round(scaled * 2) / 2
            }
        }

        // plain number
        const n = parseFloat(s)
        if (isNaN(n)) return null
        // if number > 5 assume 10-point scale
        if (n > 5) {
            const scaled = n / 2
            return Math.round(scaled * 2) / 2
        }
        // else already 5-point or smaller
        return Math.round(n * 2) / 2
    }

    // Extract rating value from tags (tags can be comma-separated string or array)
    _extractRatingFromTags(tags) {
        if (!tags) return null
        let arr = []
        if (Array.isArray(tags)) {
            arr = tags
        } else {
            arr = String(tags).split(',').map(t => t.trim()).filter(Boolean)
        }
        for (const t of arr) {
            if (typeof t !== 'string') continue
            const low = t.toLowerCase()
            if (low.startsWith('rating:')) {
                const raw = t.slice('rating:'.length).trim()
                // emoji stars like '⭐⭐⭐' or '★★★'
                if (raw.includes('⭐') || raw.includes('★')) {
                    const count = (raw.match(/⭐/g) || raw.match(/★/g) || []).length
                    return String(count)
                }
                return raw
            }
        }
        return null
    }

    // Convert tags input (string comma-separated or array) to array of trimmed strings
    _tagsToArray(tags) {
        if (!tags) return []
        if (Array.isArray(tags)) return tags.map(t => String(t).trim()).filter(Boolean)
        return String(tags).split(',').map(t => t.trim()).filter(Boolean)
    }

    // Clean tags for list display: remove rating:, date_added:, URL-like and source: entries
    _cleanListTags(tags) {
        const arr = this._tagsToArray(tags)
        const out = []
        for (let t of arr) {
            if (typeof t !== 'string') continue
            const lt = t.toLowerCase()
            if (lt.startsWith('rating:')) continue
            if (lt.startsWith('date_added:')) continue
            if (t.includes('://')) continue
            if (lt.startsWith('source:')) continue
            out.push(t)
        }
        return out
    }

    async init() {
        // 只要设置里填了 APIKEY 就视为已登录，免去再点一次登录；
        // 没填 APIKEY 时清除登录状态。
        // 直接标记为已登录，省去「点登录 → 进子页面 → 再点一次」的多余流程。
        // 实际鉴权完全由设置里的 APIKEY 决定：未填时收藏/评分会提示需要 API token；
        // 需要“登出”时清空 APIKEY 即可。
        this.saveData('account', 'ok')

        try {
            const url = `${this.baseUrl}/api/categories`
            const res = await Network.get(url, this.headers)
            if (res.status !== 200) { this.saveData('categories', []); return }
            let data = []
            try { data = JSON.parse(res.body) } catch (_) { data = [] }
            if (!Array.isArray(data)) data = []
            // Save full categories list
            this.saveData('categories', data)
            this.saveData('categories_ts', Date.now())

            if (Array.isArray(data)) {
                const favorites = Array.isArray(data)
                    ? data.filter(c => c && (c.search === "" || c.search === null || typeof c.search === 'undefined'))
                    : []
                this.saveData('favorites', favorites)
                this.saveData('favorites_ts', Date.now())
            } else {
                this.saveData('favorites', [])
            }
        } catch (_) { this.saveData('categories', []) }

        // 查询服务端是否开启「阅读进度追踪」，供进度上报判断（/api/info）
        if (this._syncProgressEnabled()) {
            try {
                const infoRes = await Network.get(`${this.baseUrl}/api/info`, this.headers)
                if (infoRes.status === 200) {
                    let info = {}
                    try { info = JSON.parse(infoRes.body) } catch (_) { info = {} }
                    this.saveData('server_tracks_progress', info.server_tracks_progress === true)
                }
            } catch (_) {}
        }
    }

    explore = [
        { title: "Lanraragi", type: "multiPageComicList", load: async (page = 1) => {
            const base = (this.baseUrl || '').replace(/\/$/, '')
            const exploreKey = 'explore_start'
            let start = this._getStart(exploreKey, page)
            const qp = []
            const add = (k, v) => qp.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
            add('sortby', 'date_added')
            add('order', 'desc')
            add('start', String(start))
            // 时间戳做缓存穿透：Venera 的 NetworkCacheManager 会缓存相同 GET URL 的响应，
            // 否则「最近阅读」等列表会命中旧缓存、要刷新多次才更新。
            add('_', String(Date.now()))

            const url = `${base}/api/search?${qp.join('&')}`
            const res = await Network.get(url, this.headers)
            if (res.status !== 200) throw `Invalid status code: ${res.status}`
            const data = JSON.parse(res.body)
            const list = Array.isArray(data.data) ? data.data : []

            const parseComic = (item) => {
                let b = base
                if (!/^https?:\/\//.test(b)) b = 'http://' + b
                const cover = `${b}/api/archives/${item.arcid}/thumbnail`
                const tagRating = this._extractRatingFromTags(item.tags)
                const stars = this._toStarsFromValue(tagRating ?? null)
                return new Comic({ id: item.arcid, title: item.title || item.filename || item.arcid, subTitle: '', cover, tags: this._cleanListTags(item.tags), description: '页数: ' + (item.pagecount || '') + ' | 新: ' + (item.isnew || '') + ' | 扩展: ' + (item.extension || ''), stars })
            }

            const returned = list.length
            this._updateStart(exploreKey, returned)

            const total = (typeof data.recordsFiltered === 'number' && data.recordsFiltered >= 0)
                ? data.recordsFiltered
                : (start + returned)
            const serverPage = returned || 1
            const maxPage = Math.max(1, Math.ceil(total / serverPage))

            const comics = list.map(parseComic)
            if (page === 1 && this._showRandomEntry()) {
                const randomEntry = await this._randomEntryComic(base)
                if (randomEntry) comics.unshift(randomEntry)
            }
            return { comics, maxPage }
        }}
    ]

    category = {
        title: "Lanraragi",
        parts: [
            // 与 LANraragi 网页版一致的内置分类：全部 / 新档案 / 无标签档案。
            // 通过跳转到搜索页实现（与点击 tag 一样），并预置好默认选项，
            // 使「仅新」「仅未打标签」等筛选项默认生效。
            { name: "内置", type: "dynamic", loader: () => {
                const make = (label, options) => {
                    // 选项顺序必须与 search.optionList 一致：
                    // [sortby, order, newonly, untaggedonly, groupby_tanks]
                    const attributes = { text: '', options: options }
                    try { return { label: label, target: new PageJumpTarget({ page: 'search', attributes: attributes }) } }
                    catch (_) { return { label: label, target: { page: 'search', attributes: attributes } } }
                }
                return [
                    make('最近阅读', ['lastread', 'asc', 'false', 'false', 'true']),
                    make('全部漫画', ['date_added', 'desc', 'false', 'false', 'true']),
                    make('新档案', ['date_added', 'desc', 'true', 'false', 'true']),
                    make('无标签档案', ['date_added', 'desc', 'false', 'true', 'true']),
                ]
            } },
            { name: "分类", type: "dynamic", loader: () => {
                const data = this.loadData('categories')
                const items = []
                if (Array.isArray(data)) {
                    for (const cat of data) {
                        if (!cat) continue
                        const id = cat.id ?? cat._id ?? cat.name
                        const label = cat.name ?? String(id)
                        try { items.push({ label, target: new PageJumpTarget({ page: 'category', attributes: { category: id, param: null } }) }) }
                        catch (_) { items.push({ label, target: { page: 'category', attributes: { category: id, param: null } } }) }
                    }
                }
                return items
            } },
        ],
        enableRankingPage: false,
    }

    categoryComics = {
        load: async (category, param, options, page) => {
            // Use /search endpoint filtered by category tag value
            const base = (this.baseUrl || '').replace(/\/$/, '')
            const key = 'category_start_' + String(category || '')
            let start = this._getStart(key, page)

            const qp = []
            const add = (k, v) => qp.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
            add('category', category || '')
            add('sortby', 'date_added')
            add('order', 'desc')
            add('start', String(start))
            // 时间戳做缓存穿透：Venera 的 NetworkCacheManager 会缓存相同 GET URL 的响应，
            // 否则「最近阅读」等列表会命中旧缓存、要刷新多次才更新。
            add('_', String(Date.now()))

            const url = `${base}/api/search?${qp.join('&')}`
            const res = await Network.get(url, this.headers)
            if (res.status !== 200) throw `Invalid status code: ${res.status}`
            const data = JSON.parse(res.body)
            const list = Array.isArray(data.data) ? data.data : []
            const comics = list.map(item => {
                const cover = `${base}/api/archives/${item.arcid}/thumbnail`
                const tags = this._cleanListTags(item.tags)
                const tagRating = this._extractRatingFromTags(item.tags)
                const stars = this._toStarsFromValue(tagRating ?? null)
                return new Comic({
                    id: item.arcid,
                    title: item.title || item.filename || item.arcid,
                    subTitle: '',
                    cover,
                    tags,
                    description: '页数: ' + (item.pagecount || '') + ' | 新: ' + (item.isnew || '') + ' | 扩展: ' + (item.extension || ''),
                    stars
                })
            })

            const returned = list.length
            this._updateStart(key, returned)

            const total = typeof data.recordsFiltered === 'number' && data.recordsFiltered >= 0
                ? data.recordsFiltered
                : (start + returned)
            const serverPage = returned || 1
            const maxPage = Math.max(1, Math.ceil(total / serverPage))
            return { comics, maxPage }
        }
    }

    search = {
        load: async (keyword, options, page = 1) => {
            const base = (this.baseUrl || '').replace(/\/$/, '')

            // Fetch all results once (start=-1), then page locally for consistent UX across servers
            const qp = []
            const add = (k, v) => qp.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
            const pick = (key, def) => {
                let v = options && (options[key])
                if (typeof v === 'string') {
                    v = v.trim()
                    // 兼容某些 Venera 版本会把 optionList 的 default 值 JSON 编码后传入
                    // （例如 default: "title" 会变成带引号的 "\"title\""），去掉外层引号。
                    if (v.length >= 2 && v[0] === '"' && v[v.length - 1] === '"') v = v.slice(1, -1)
                    const idx = v.indexOf('-');
                    if (idx > 0) v = v.slice(0, idx)
                }
                return (v === undefined || v === null || v === '') ? def : v
            }
            const sortby = pick(0, 'title')
            const order = pick(1, 'asc')
            const newonly = String(pick(2, 'false'))
            const untaggedonly = String(pick(3, 'false'))
            const groupby = String(pick(4, 'true'))
            const filter = (keyword || '').trim()
            const isRandom = String(order).toLowerCase() === 'random'

            const toComic = (item) => {
                const cover = `${base}/api/archives/${item.arcid}/thumbnail`
                const tags = this._cleanListTags(item.tags)
                const tagRating = this._extractRatingFromTags(item.tags)
                const stars = this._toStarsFromValue(tagRating ?? null)
                return new Comic({
                    id: item.arcid,
                    title: item.title || item.filename || item.arcid,
                    subTitle: '',
                    cover,
                    tags,
                    description: '页数: ' + (item.pagecount || '') + ' | 新: ' + (item.isnew || '') + ' | 扩展: ' + (item.extension || ''),
                    stars
                })
            }

            // 随机排序：改用 /api/search/random，直接用服务端返回的顺序（不在插件端洗牌）
            if (isRandom) {
                const list = await this._fetchRandomArchives(base, this._randomCount(), filter, newonly, untaggedonly, groupby)
                return { comics: list.map(toComic), maxPage: (Number(page) || 1) + 1 }
            }

            add('filter', filter)
            add('sortby', sortby)
            add('order', order)
            add('newonly', newonly)
            add('untaggedonly', untaggedonly)
            add('groupby_tanks', groupby)

            const searchKey = 'search_start_' + encodeURIComponent(String(keyword || ''))
            let start = 0
            if (page === 1) {
                this.saveData(searchKey, 0)
            } else {
                start = Number(this.loadData(searchKey) || 0)
            }
            add('start', String(start))
            // 时间戳做缓存穿透：Venera 的 NetworkCacheManager 会缓存相同 GET URL 的响应，
            // 否则「最近阅读」等列表会命中旧缓存、要刷新多次才更新。
            add('_', String(Date.now()))

            const url = `${base}/api/search?${qp.join('&')}`
            const res = await Network.get(url, this.headers)
            if (res.status !== 200) throw `Invalid status code: ${res.status}`
            const data = JSON.parse(res.body)
            const list = Array.isArray(data.data) ? data.data : []

            const comics = list.map(toComic)

            const returned = list.length
            this.saveData(searchKey, start + returned)

            const total = (typeof data.recordsFiltered === 'number' && data.recordsFiltered >= 0)
                ? data.recordsFiltered
                : (start + returned)
            const serverPage = returned || 1
            const maxPage = Math.max(1, Math.ceil(total / serverPage))

            // 随机入口只在发现页展示，搜索/标签/分类页不再插入
            return { comics, maxPage }
        },
        // 注意：不要设置 default 字段。Venera 会把 default 值 JSON 编码后作为
        // defaultValue（例如 "title" -> "\"title\""），既不会命中任何选项 key 导致选项
        // 无法默认勾选，又会把带引号的值传给 JS，令生成的 URL 参数错误。
        // 不设置 default 时 Venera 会取第一个选项作为默认值，因此把想要的默认项放在首位即可。
        optionList: [
            { type: "select", options: ["title-按标题","date_added-最新添加","lastread-最近阅读"], label: "sortby" },
            { type: "select", options: ["asc-升序","desc-降序","random-随机"], label: "order" },
            { type: "select", options: ["false-全部","true-仅新"], label: "newonly" },
            { type: "select", options: ["false-全部","true-仅未打标签"], label: "untaggedonly" },
            { type: "select", options: ["true-启用","false-禁用"], label: "groupby_tanks" }
        ],
        enableTagsSuggestions: false,
    }

    favorites = {
        multiFolder: true,
        singleFolderForSingleComic: false,

        addOrDelFavorite: async (comicId, folderId, isAdding, favoriteId) => {
            const hdrs = this.headers || {}
            if (!hdrs || Object.keys(hdrs).length === 0) {
                throw 'API token required to modify favorites'
            }

            if (!folderId || String(folderId) === '-1') {
                throw 'Invalid folder id'
            }

            const base = (this.baseUrl || '').replace(/\/$/, '')
            const url = `${base}/api/categories/${folderId}/${comicId}`

            let res
            if (isAdding) {
                res = await Network.put(url, hdrs)
            } else {
                // remove
                res = await Network.delete(url, hdrs)
            }

            if (res.status !== 200 && res.status !== 204) throw `Invalid status code: ${res.status}`
            return 'ok'
        },

        loadFolders: async (comicId) => {
            const data = this.loadData('favorites')
            const folders = {}
            if (Array.isArray(data)) {
                for (const cat of data) {
                    if (!cat) continue
                    const id = cat.id ?? cat._id ?? cat.name
                    const label = cat.name ?? String(id)
                    folders[String(id)] = label
                }
            }

            const favorited = []
            if (comicId) {
                try {
                    const info = await this.comic.loadInfo(comicId)
                    // 收藏夹里读取信息不算阅读，取消 loadInfo 的兜底上报
                    this._cancelProgressOnInfo()

                    try {
                        if (info && (info.isFavorite === true || info.isFavorite === 'true')) {
                            // Prefer explicit folders array if provided by loadInfo
                            const infoFolders = Array.isArray(info.folders) ? info.folders.map(f => String(f)) : null
                            const added = new Set(favorited)
                            if (infoFolders && infoFolders.length > 0) {
                                for (const f of infoFolders) {
                                    for (const [fid, fname] of Object.entries(folders)) {
                                        if (f === fid || f === fname) {
                                            added.add(fid)
                                        }
                                    }
                                }
                            }
                            // assign deduped results back to favorited
                            favorited.length = 0
                            for (const v of added) favorited.push(v)
                        }
                    } catch (_) {}

                    const tags = info.tags || {}
                    const possibleKeys = Object.keys(tags)
                    for (const k of possibleKeys) {
                        if (String(k).toLowerCase() === 'category') {
                            const vals = tags[k]
                            if (Array.isArray(vals)) {
                                for (const v of vals) {
                                    // try to match category id or name
                                    for (const [fid, fname] of Object.entries(folders)) {
                                        if (String(v) === fid || String(v) === fname) {
                                            if (!favorited.includes(fid)) favorited.push(fid)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch (_) {}
            }

            return { folders: folders, favorited: favorited }
        },

        loadComics: async (page, folder) => {
            return await this.categoryComics.load(folder, null, [], (typeof page === 'number' && page > 0) ? page : 1)
        },
    }

    comic = {
        loadInfo: async (id) => {
            const url = `${this.baseUrl}/api/archives/${id}/metadata?_=${Date.now()}`
            const res = await Network.get(url, this.headers)
            if (res.status !== 200) throw `Invalid status code: ${res.status}`
            const data = JSON.parse(res.body)
            // 记录服务端已知的阅读进度，供打开阅读器（loadEp）时刷新 lastreadtime 用
            this._archiveProgress[String(id)] = (typeof data.progress === 'number' && data.progress > 0) ? data.progress : 0
            // 可选的兜底上报（见 _scheduleProgressOnInfo）
            this._scheduleProgressOnInfo(id)
            const cover = `${this.baseUrl}/api/archives/${id}/thumbnail`
                let flatTags = data.tags ? data.tags.split(',').map(t=>t.trim()).filter(Boolean) : []
                const rating = flatTags.find(t=>t.startsWith('rating:'))
                if (rating) flatTags = flatTags.filter(t=>!t.startsWith('rating:'))

                let uploadTime = null
                const dateTag = flatTags.find(t => t.startsWith('date_added:'))
                if (dateTag) {
                    uploadTime = dateTag.slice('date_added:'.length).trim()
                    flatTags = flatTags.filter(t => !t.startsWith('date_added:'))
                }

                const nsMap = new Map();
                const nonNs = []
                for (const t of flatTags) {
                    const idx = t.indexOf(':')
                    if (idx > 0) {
                        const ns = t.slice(0, idx)
                        const val = t.slice(idx + 1)
                        if (!nsMap.has(ns)) nsMap.set(ns, [])
                        nsMap.get(ns).push(val)
                    } else {
                        nonNs.push(t)
                    }
                }

                const tagsObj = {}
                // 若这是随机入口选中的那部，在最前面加一个「随机: Lanraragi(Random)」标记。
                // 组名用「随机」，值用「Lanraragi(Random)」，这样在会隐藏组名的客户端（如 VeneraX）
                // 也能显示成 Lanraragi(Random)，在原版 Venera 显示为 “随机: Lanraragi(Random)”。
                const randomEntryId = this._randomEntryId || this.loadData('random_entry_id')
                if (randomEntryId && String(id) === String(randomEntryId)) {
                    const cur = Array.isArray(tagsObj['随机']) ? tagsObj['随机'] : []
                    if (!cur.includes('Lanraragi(Random)')) tagsObj['随机'] = ['Lanraragi(Random)'].concat(cur)
                }
                for (const [k, v] of nsMap.entries()) {
                    tagsObj[k] = v
                }
                tagsObj['Tags'] = nonNs
                // Preserve special metadata fields
                tagsObj['Pages'] = [String(data.pagecount)]
                tagsObj['Extension'] = [data.extension]

                // Move any tag value that looks like a URL (contains '://') into description
                const urlEntries = []
                const skipKeys = new Set(['Extension', 'Pages'])
                for (const key of Object.keys(tagsObj)) {
                    if (skipKeys.has(key)) continue
                    const arr = tagsObj[key]
                    if (!Array.isArray(arr)) continue
                    const keep = []
                    for (const val of arr) {
                        if (typeof val !== 'string') { keep.push(val); continue }
                        // already a URL with scheme
                        if (val.includes('://')) {
                            urlEntries.push(val)
                            continue
                        }
                        // special-case 'source' namespace: may lack scheme, prepend https://
                        if (String(key).toLowerCase() === 'source') {
                            let corrected = val
                            if (corrected.startsWith('//')) corrected = 'https:' + corrected
                            else if (!/^https?:\/\//i.test(corrected)) corrected = 'https://' + corrected
                            urlEntries.push(corrected)
                            continue
                        }
                        // otherwise keep the tag
                        keep.push(val)
                    }
                    tagsObj[key] = keep
                }
                // 移除空分组（例如 source 的值已并入描述，不再显示为空标签组）
                for (const key of Object.keys(tagsObj)) {
                    const arr = tagsObj[key]
                    if (Array.isArray(arr) && arr.length === 0) delete tagsObj[key]
                }

                let summary = data.summary || ''
                if (urlEntries.length) {
                    if (summary) summary += '\n'
                    summary += '关联：' + urlEntries.join(', ')
                }

                let isFavorite = false
                let folders = []
                try {
                    const catUrl = `${this.baseUrl}/api/archives/${id}/categories`
                    const catRes = await Network.get(catUrl, this.headers)
                    if (catRes.status === 200) {
                        let catData = []
                        try { catData = JSON.parse(catRes.body) } catch (_) { catData = [] }

                        // Normalize common response shapes. Prefer explicit `categories` array.
                        if (catData && typeof catData === 'object') {
                            if (Array.isArray(catData.categories)) catData = catData.categories
                            else if (Array.isArray(catData.data)) catData = catData.data
                            else if (!Array.isArray(catData)) catData = []
                        }

                        if (Array.isArray(catData) && catData.length > 0) {
                            // Find categories that actually contain this archive id in their `archives` list
                            const matched = []
                            for (const c of catData) {
                                const archives = Array.isArray(c.archives) ? c.archives : []
                                if (Array.isArray(archives) && archives.some(a => String(a) === String(id))) {
                                    matched.push(c)
                                }
                            }

                            if (matched.length > 0) {
                                isFavorite = true
                                folders = matched.map(c => String(c.id ?? c._id ?? c.name ?? c))
                            }
                        }
                    }
                } catch (_) { /* ignore category detection errors */ }

                const chapters = new Map()
                // 读取服务端章节目录（Table of Contents）：[{ name, page }]，按起始页排序生成章节。
                // 章节 id 用 "start-end" 编码页范围，end=0 表示到结尾；loadEp 会据此切片。
                const toc = Array.isArray(data.toc)
                    ? data.toc.filter(e => e && typeof e.page === 'number' && e.page > 0)
                    : []
                if (toc.length > 0) {
                    toc.sort((a, b) => a.page - b.page)
                    for (let i = 0; i < toc.length; i++) {
                        const start = Math.max(1, Math.floor(toc[i].page))
                        const next = (i + 1 < toc.length) ? Math.max(1, Math.floor(toc[i + 1].page)) : null
                        const end = next ? Math.max(start, next - 1) : 0
                        const rawName = (toc[i].name ?? toc[i].title)
                        const name = (rawName && String(rawName).trim()) ? String(rawName).trim() : `Chapter ${i + 1}`
                        chapters.set(`${start}-${end}`, name)
                    }
                } else {
                    // 服务端未设置章节目录时，退回“整本一章”，沿用漫画名
                    chapters.set(id, data.title || 'Local manga')
                }
                let stars = this._toStarsFromValue((rating ? rating.replace('rating:', '') : null))
                // Ensure details page always has a numeric star value (0 if no rating),
                // otherwise UI may not allow submitting a rating.
                if (stars === null || stars === undefined) stars = 0
                return {
                    title: data.title || data.filename || id,
                    cover,
                    description: summary,
                    uploadTime: uploadTime,
                    tags: tagsObj,
                    stars,
                    chapters,
                    isFavorite: isFavorite,
                    folders: folders
                }
        },
        loadThumbnails: async (id, next) => {
            // 详情页预览：说明只是浏览详情而非阅读，取消 loadInfo 的兜底上报
            this._cancelProgressOnInfo()
            const metaUrl = `${this.baseUrl}/api/archives/${id}/metadata?_=${Date.now()}`
            const res = await Network.get(metaUrl, this.headers)
            if (res.status !== 200) throw `Invalid status code: ${res.status}`
            const data = JSON.parse(res.body)
            const pagecount = data.pagecount || 1
            const thumbnails = []
            for (let i = 1; i <= pagecount; i++) thumbnails.push(`${this.baseUrl}/api/archives/${id}/thumbnail?page=${i}`)
            return { thumbnails, next: null }
        },
        starRating: async (id, rating) => {
            // Only allow when API token (headers) is provided
            const hdrs = this.headers || {}
            if (!hdrs || Object.keys(hdrs).length === 0) {
                throw 'API token required to submit rating'
            }

            // Fetch current metadata to preserve other tags
            const metaUrl = `${this.baseUrl}/api/archives/${id}/metadata?_=${Date.now()}`
            const getRes = await Network.get(metaUrl, hdrs)
            if (getRes.status !== 200) throw `Invalid status code: ${getRes.status}`
            let data = {}
            try { data = JSON.parse(getRes.body) } catch (_) { data = {} }

            let tagsArr = []
            if (data.tags) tagsArr = String(data.tags).split(',').map(t => t.trim()).filter(Boolean)

            // remove existing rating tags
            tagsArr = tagsArr.filter(t => !(typeof t === 'string' && t.toLowerCase().startsWith('rating:')))

            // if rating > 0, add emoji rating tag
            if (rating > 0) {
                const starsStr = '⭐'.repeat(rating / 2)
                tagsArr.push(`rating:${starsStr}`)
            }

            const tagsStr = tagsArr.join(', ')
            const body = `tags=${encodeURIComponent(tagsStr)}`
            const putUrl = `${this.baseUrl}/api/archives/${id}/metadata`
            const putRes = await Network.put(putUrl, Object.assign({}, hdrs, { 'Content-Type': 'application/x-www-form-urlencoded' }), body)
            if (putRes.status !== 200 && putRes.status !== 204) throw `Invalid status code: ${putRes.status}`
            return 'ok'
        },
        loadEp: async (comicId, epId) => {
            const base = (this.baseUrl || '').replace(/\/$/, '')
            const url = `${base}/api/archives/${comicId}/files?force=false&_=${Date.now()}`
            const res = await Network.get(url, this.headers)
            if (res.status !== 200) throw `Invalid status code: ${res.status}`
            const data = JSON.parse(res.body)
            const all = (data.pages || []).map(p => {
                if (!p) return null
                const s = String(p)
                if (/^https?:\/\//i.test(s)) return s
                return `${base}${s.startsWith('/') ? s : '/' + s}`
            }).filter(Boolean)
            // 章节 id 形如 "start-end"（end=0 表示到结尾）；否则视为整本漫画
            let startPage = 1
            let endPage = 0
            const m = String(epId ?? '').match(/^(\d+)-(\d+)$/)
            if (m) {
                startPage = Math.max(1, parseInt(m[1], 10) || 1)
                endPage = parseInt(m[2], 10) || 0
            }
            const images = all.slice(startPage - 1, endPage > 0 ? endPage : undefined)
            // 记录当前章节的页面顺序，供 onImageLoad 反查页码并上报阅读进度（使用整本的绝对页码）
            this._epComicId = String(comicId ?? '')
            this._pageIndexByUrl = {}
            images.forEach((u, i) => { if (u) this._pageIndexByUrl[u] = startPage + i })
            // 打开阅读器即上报一次进度：更新 lastreadtime，让「最近阅读」立刻能列出该漫画。
            // 页码用已知进度（无则本章起始页），保证不因缓存命中（onImageLoad 被跳过）而完全不上报。
            if (this._syncProgressEnabled() && this._serverTracksProgress()) {
                const known = this._archiveProgress[String(comicId)] || 0
                this._sendProgress(String(comicId), known > 0 ? known : startPage)
            }
            return { images }
        },
        onImageLoad: (url, comicId, epId) => {
            try { this._maybeReportProgress(url, comicId) } catch (_) {}
            return {
                headers: this.headers
            }
        },
        onThumbnailLoad: (url) => {
            return {
                url: this._thumbUrlWithNoFallback(url),
                headers: this.headers,
                onResponse: (buffer) => this._validateThumbResponse(buffer)
            }
        },
        // likeComic: async (id, isLike) => {},
        // loadComments: async (comicId, subId, page, replyTo) => {},
        // sendComment: async (comicId, subId, content, replyTo) => {},
        // likeComment: async (comicId, subId, commentId, isLike) => {},
        // voteComment: async (id, subId, commentId, isUp, isCancel) => {},
        // idMatch: null,
        onClickTag: (namespace, tag) => {
            const ns = namespace ? String(namespace) : ''
            const nsLower = ns.toLowerCase()

            // 随机标记可点击：跳转到搜索页并随机排序全部作品
            // options 顺序与 search.optionList 一致：sortby, order, newonly, untaggedonly, groupby_tanks
            if (String(tag) === 'Lanraragi(Random)') {
                return { page: 'search', attributes: { text: '', options: ['date_added', 'random', 'false', 'false', 'true'] } }
            }
            // Pages/Extension 不可点击（Source 标签已并入描述，不会出现在标签列表里）
            if (nsLower === 'pages' || nsLower === 'extension') return null

            // 'Tags' 是本插件为「无命名空间标签」合成的分组名。
            // LRR 中无命名空间的标签就是裸标签，搜索时不能加前缀，
            // 否则会被当成 Tags:xxx 而永远搜不到结果。
            const t = String(tag)
            let term = (ns && ns !== 'Tags') ? `${ns}:${t}` : t
            // LRR 的精确匹配语法要求把整个 token(含命名空间)用双引号包起来，
            // 写成 artist:"foo bar" 会被拆成两个 token，必须写成 "artist:foo bar"。
            if (term.includes(' ')) term = `"${term}"`
            return { action: 'search', keyword: term, param: null }
        },
        // link: { domains: ['example.com'], linkToId: (url) => null },
        // 关闭 App 内置的标签值翻译：它会把所有标签值转成小写
        // （TagsTranslation.translationTagWithNamespace 里 text.toLowerCase()），
        // LRR 的标签是用户自定义的，保留原样更合适（组名仍由本插件 translation 翻译）。
        enableTagsTranslate: false,
    }

    translation = {
        'zh_CN': {
            "language": "语言",
            "artist": "画师",
            "male": "男性",
            "female": "女性",
            "mixed": "混合",
            "other": "其它",
            "parody": "原作",
            "character": "角色",
            "group": "团队",
            "cosplayer": "Coser",
            "reclass": "重新分类",
            "uploader": "上传者",
            "Languages": "语言",
            "Artists": "画师",
            "Characters": "角色",
            "Groups": "团队",
            "Tags": "标签",
            "Parodies": "原作",
            "Categories": "分类",
            "Category": "分类",
            "series": "系列",
            "Series": "系列",
            "Pages": "页数",
            "Extension": "文件类型",
            "随机数量": "随机数量",
            "显示随机入口": "显示随机入口",
            "同步阅读进度": "同步阅读进度",
            "详情页触发进度同步（VeneraX 等阅读器需开启）": "详情页触发进度同步（VeneraX 等阅读器需开启）",
            "最近阅读": "最近阅读",
            "随机": "随机",
            "内置": "内置",
            "分类": "分类",
            "全部漫画": "全部漫画",
            "新档案": "新档案",
            "无标签档案": "无标签档案",
        },
        'en_US': {
            "language": "Language",
            "artist": "Artist",
            "male": "Male",
            "female": "Female",
            "mixed": "Mixed",
            "other": "Other",
            "parody": "Parody",
            "character": "Character",
            "group": "Group",
            "cosplayer": "Cosplayer",
            "reclass": "Reclass",
            "uploader": "Uploader",
            "Languages": "Languages",
            "Artists": "Artists",
            "Characters": "Characters",
            "Groups": "Groups",
            "Tags": "Tags",
            "Parodies": "Parodies",
            "Categories": "Categories",
            "Category": "Category",
            "series": "Series",
            "Series": "Series",
            "Pages": "Pages",
            "Extension": "Extension",
            "随机数量": "Random count",
            "显示随机入口": "Show random entry",
            "同步阅读进度": "Sync read progress",
            "详情页触发进度同步（VeneraX 等阅读器需开启）": "Sync progress on info (enable for VeneraX-like readers)",
            "最近阅读": "Recently read",
            "随机": "Random",
            "内置": "Built-in",
            "分类": "Categories",
            "全部漫画": "All",
            "新档案": "New",
            "无标签档案": "Untagged",
        }
    }
}
