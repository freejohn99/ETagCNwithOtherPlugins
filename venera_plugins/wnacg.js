class Wnacg extends ComicSource {
    // Note: The fields which are marked as [Optional] should be removed if not used

    // name of the source
    name = "紳士漫畫"

    // unique id of the source
    key = "wnacg"

    version = "1.1.1"

    minAppVersion = "1.0.0"

    // update url
    url = "https://raw.githubusercontent.com/freejhon99/ETagCNwithOtherPlugins/master/venera_plugins/wnacg.js"

    static domains = [];

    get baseUrl() {
        let selection = this.loadSetting('domainSelection')
        if (selection === undefined || selection === null) selection = 0
        selection = parseInt(selection)

        if (selection === 0) {
            // 选择自定义域名
            let domain0 = this.loadSetting('domain0')
            if (!domain0 || domain0.trim() === '') {
                throw 'Custom domain is not set'
            }
            return `https://${domain0.trim()}`
        } else {
            // 选择获取的域名 (Domain 1-3)
            let index = selection - 1
            if (index >= Wnacg.domains.length) {
                throw 'Selected domain is unavailable'
            }
            return `https://${Wnacg.domains[index]}`
        }
    }

    overwriteDomains(domains) {
        if (domains.length != 0) Wnacg.domains = domains
    }

    // [Optional] account related
    account = {
        /**
         * login, return any value to indicate success
         * @param account {string}
         * @param pwd {string}
         * @returns {Promise<any>}
         */
        login: async (account, pwd) => {
            let res = await Network.post(
                `${this.baseUrl}/users-check_login.html`,
                {
                    'content-type': 'application/x-www-form-urlencoded'
                },
                `login_name=${encodeURIComponent(account)}&login_pass=${encodeURIComponent(pwd)}`
            )
            if (res.status !== 200) {
                throw 'Login failed'
            }
            let json = JSON.parse(res.body)
            if (json['html'].includes('登錄成功')) {
                return 'ok'
            }
            throw 'Login failed'
        },

        /**
         * logout function, clear account related data
         */
        logout: () => {
            Network.deleteCookies(this.baseUrl)
        },

        // {string?} - register url
        registerWebsite: null
    }

    async init() {
        if (this.loadSetting('refreshDomainsOnStart')) await this.refreshDomains(false)
    }

    /**
     * 刷新域名列表
     * @param showConfirmDialog {boolean}
     */
    async refreshDomains(showConfirmDialog) {
        let url = "https://wn01.link/"
        let title = ""
        let message = ""
        let domains = []

        try {
            let res = await fetch(url)
            if (res.status == 200) {
                let html = await res.text()
                let document = new HtmlDocument(html)
                // 提取所有链接
                let links = document.querySelectorAll("a[href]")
                let seenDomains = new Set()

                for (let link of links) {
                    let href = link.attributes["href"]
                    if (!href) continue

                    // 提取域名（支持 http:// 和 https://）
                    let match = href.match(/^https?:\/\/([^\/]+)/)
                    if (match) {
                        let domain = match[1]
                        // 只提取有效的域名，排除 wn01.link 自身和其他无关链接
                        if (domain &&
                            domain.includes(".") &&
                            !domain.includes("wn01.link") &&
                            !domain.includes("google.cn") &&
                            !domain.includes("cdn-cgi") &&
                            !seenDomains.has(domain)) {
                            domains.push(domain)
                            seenDomains.add(domain)
                        }
                    }
                }
                document.dispose()

                if (domains.length > 0) {
                    title = "Update Success"
                    message = "Fetched: \n\n"
                }
            }
        } catch (e) {
            // 获取失败，使用自定义域名
        }

        if (domains.length == 0) {
            title = "Update Failed"
            message = "Using Custom: \n\n"
            domains = Wnacg.domains
        }

        for (let i = 0; i < domains.length; i++) {
            message = message + `URL ${i + 1}: ${domains[i]}\n`
        }
        message = message + `\n Total: ${domains.length} URLs\n\n Re-enter page to refresh`

        if (showConfirmDialog) {
            UI.showDialog(
                title,
                message,
                [
                    {
                        text: "Cancel",
                        callback: () => { }
                    },
                    {
                        text: "Apply",
                        callback: () => this.overwriteDomains(domains)
                    }
                ]
            )
        } else {
            this.overwriteDomains(domains)
        }
    }

    // 统一封面/图片 URL：兼容 //host 与 ////host 两种写法
    _normalizeCover(url) {
        let u = String(url || '').trim()
        if (!u) return u
        if (/^https?:\/\//i.test(u)) return u
        return 'https://' + u.replace(/^\/+/, '')
    }

    // 按 / 或 ／ 拆分并去除空白
    _splitValues(value) {
        return String(value || '').split(/[/／]/).map((x) => x.trim()).filter((x) => x.length > 0)
    }

    // 去重（保持顺序）
    _dedupe(arr) {
        let seen = new Set()
        let out = []
        for (let v of arr) {
            if (v && !seen.has(v)) {
                seen.add(v)
                out.push(v)
            }
        }
        return out
    }

    // 追加合集章节：chapters 的 key=章节名（决定下载文件夹与显示），chapterMap 记录 名称 -> 章节 aid
    _appendChapters(chapters, chapterMap, elements) {
        for (let a of elements) {
            let attrs = a.attributes || {}
            let chid = attrs["data-chid"]
            if (!chid) {
                let m = RegExp("(?<=-aid-)[0-9]+").exec(attrs["href"] || "")
                if (m) chid = m[0]
            }
            if (!chid) continue
            // 按章节 aid 去重
            let exists = false
            for (let k in chapterMap) {
                if (chapterMap[k] === chid) { exists = true; break }
            }
            if (exists) continue
            let name = (a.text || '').replace(/\s+/g, ' ').trim() || `第${chapters.size + 1}話`
            let unique = name
            let suffix = 2
            while (chapters.has(unique)) {
                unique = `${name} (${suffix++})`
            }
            chapters.set(unique, unique)
            chapterMap[unique] = chid
        }
    }

    // 抓取合集完整章节目录，返回 { chapters(名->名), chapterMap(名->aid) }
    async _collectChapterDirectory(id, firstDocument) {
        let chapters = new Map()
        let chapterMap = {}
        let doc = firstDocument
        if (!doc) {
            let res = await Network.get(`${this.baseUrl}/photos-index-page-1-aid-${id}.html`, {})
            if (res.status !== 200) {
                throw `Invalid Status Code ${res.status}`
            }
            doc = new HtmlDocument(res.body)
        }
        this._appendChapters(chapters, chapterMap, doc.querySelectorAll("div.sr_compact > a[data-chid]"))
        // 章节目录分页：页码取所有分页链接中的最大数字（末端还有「後頁」链接）
        let maxPage = 1
        let pageLinks = doc.querySelectorAll("div.f_left.paginator > a")
        for (let link of pageLinks) {
            let n = parseInt(link.text)
            if (!isNaN(n) && n > maxPage) maxPage = n
        }
        if (!firstDocument) doc.dispose()
        const MAX_CHAPTER_PAGES = 30
        let lastPage = Math.min(maxPage, MAX_CHAPTER_PAGES)
        for (let p = 2; p <= lastPage; p++) {
            let r = await Network.get(`${this.baseUrl}/photos-index-aid-${id}-page-${p}.html`, {})
            if (r.status !== 200) break
            let d = new HtmlDocument(r.body)
            this._appendChapters(chapters, chapterMap, d.querySelectorAll("div.sr_compact > a[data-chid]"))
            d.dispose()
        }
        return { chapters: chapters, chapterMap: chapterMap }
    }

    parseComic(c) {
        let link = c.querySelector("div.pic_box > a").attributes["href"];
        let id = RegExp("(?<=-aid-)[0-9]+").exec(link)[0];
        let image = this._normalizeCover(
            c.querySelector("div.pic_box > a > img").attributes["src"]);
        let name = c.querySelector("div.info > div.title > a").text;
        let info = c.querySelector("div.info > div.info_col").text.trim();
        info = info.replaceAll('\n', '');
        info = info.replaceAll('\t', '');
        return new Comic({
            id: id,
            title: name,
            cover: image,
            description: info,
        })
    }

    // explore page list
    explore = [
        {
            // title of the page.
            // title is used to identify the page, it should be unique
            title: "紳士漫畫",

            /// multiPartPage or multiPageComicList or mixed
            type: "multiPartPage",

            /**
             * load function
             * @param page {number | null} - page number, null for `singlePageWithMultiPart` type
             * @returns {{}}
             * - for `multiPartPage` type, return [{title: string, comics: Comic[], viewMore: string?}]
             * - for `multiPageComicList` type, for each page(1-based), return {comics: Comic[], maxPage: number}
             * - for `mixed` type, use param `page` as index. for each index(0-based), return {data: [], maxPage: number?}, data is an array contains Comic[] or {title: string, comics: Comic[], viewMore: string?}
             */
            load: async (page) => {
                let res = await Network.get(this.baseUrl, {})
                if (res.status !== 200) {
                    throw `Invalid Status Code ${res.status}`
                }
                let document = new HtmlDocument(res.body)
                let titleBlocks = document.querySelectorAll("div.title_sort");
                let comicBlocks = document.querySelectorAll("div.bodywrap");
                if (titleBlocks.length !== comicBlocks.length) {
                    throw "Invalid Page"
                }
                let result = []
                for (let i = 0; i < titleBlocks.length; i++) {
                    let title = titleBlocks[i].querySelector("div.title_h2").text.replaceAll(/\s+/g, '')
                    let link = titleBlocks[i].querySelector("div.r > a").attributes["href"]
                    let comics = []
                    let comicBlock = comicBlocks[i]
                    let comicElements = comicBlock.querySelectorAll("div.gallary_wrap > ul.cc > li")
                    for (let comicElement of comicElements) {
                        comics.push(this.parseComic(comicElement))
                    }
                    result.push({
                        title: title,
                        comics: comics,
                        viewMore: `category:${title}@${link}`
                    })
                }
                document.dispose()
                return result
            }
        }
    ]

    // categories
    category = {
        /// title of the category page, used to identify the page, it should be unique
        title: "紳士漫畫",
        parts: [
            {
                // title of the part
                name: "最新",

                // fixed or random
                // if random, need to provide `randomNumber` field, which indicates the number of comics to display at the same time
                type: "fixed",

                // number of comics to display at the same time
                // randomNumber: 5,

                categories: ["最新"],

                // category or search
                // if `category`, use categoryComics.load to load comics
                // if `search`, use search.load to load comics
                itemType: "category",

                // [Optional] {string[]?} must have same length as categories, used to provide loading param for each category
                categoryParams: ["/albums.html"],

                // [Optional] {string} cannot be used with `categoryParams`, set all category params to this value
                groupParam: null,
            },
            {
                // title of the part
                name: "同人誌",

                // fixed or random
                // if random, need to provide `randomNumber` field, which indicates the number of comics to display at the same time
                type: "fixed",

                // number of comics to display at the same time
                // randomNumber: 5,

                categories: ["同人誌", "漢化", "日語", "English", "CG畫集", "3D漫畫", "寫真Cosplay"],

                // category or search
                // if `category`, use categoryComics.load to load comics
                // if `search`, use search.load to load comics
                itemType: "category",

                // [Optional] {string[]?} must have same length as categories, used to provide loading param for each category
                categoryParams: [
                    "/albums-index-cate-5.html",
                    "/albums-index-cate-1.html",
                    "/albums-index-cate-12.html",
                    "/albums-index-cate-16.html",
                    "/albums-index-cate-2.html",
                    "/albums-index-cate-22.html",
                    "/albums-index-cate-3.html",
                ],

                // [Optional] {string} cannot be used with `categoryParams`, set all category params to this value
                groupParam: null,
            },
            {
                // title of the part
                name: "單行本",

                // fixed or random
                // if random, need to provide `randomNumber` field, which indicates the number of comics to display at the same time
                type: "fixed",

                // number of comics to display at the same time
                // randomNumber: 5,

                categories: ["單行本", "漢化", "日語", "English",],

                // category or search
                // if `category`, use categoryComics.load to load comics
                // if `search`, use search.load to load comics
                itemType: "category",

                // [Optional] {string[]?} must have same length as categories, used to provide loading param for each category
                categoryParams: [
                    "/albums-index-cate-6.html",
                    "/albums-index-cate-9.html",
                    "/albums-index-cate-13.html",
                    "/albums-index-cate-17.html",
                ],

                // [Optional] {string} cannot be used with `categoryParams`, set all category params to this value
                groupParam: null,
            },
            {
                // title of the part
                name: "雜誌短篇",

                // fixed or random
                // if random, need to provide `randomNumber` field, which indicates the number of comics to display at the same time
                type: "fixed",

                // number of comics to display at the same time
                // randomNumber: 5,

                categories: ["雜誌短篇", "漢化", "日語", "English",],

                // category or search
                // if `category`, use categoryComics.load to load comics
                // if `search`, use search.load to load comics
                itemType: "category",

                // [Optional] {string[]?} must have same length as categories, used to provide loading param for each category
                categoryParams: [
                    "/albums-index-cate-7.html",
                    "/albums-index-cate-10.html",
                    "/albums-index-cate-14.html",
                    "/albums-index-cate-18.html",
                ],

                // [Optional] {string} cannot be used with `categoryParams`, set all category params to this value
                groupParam: null,
            },
            {
                // title of the part
                name: "韓漫",

                // fixed or random
                // if random, need to provide `randomNumber` field, which indicates the number of comics to display at the same time
                type: "fixed",

                // number of comics to display at the same time
                // randomNumber: 5,

                categories: ["韓漫", "漢化", "生肉",],

                // category or search
                // if `category`, use categoryComics.load to load comics
                // if `search`, use search.load to load comics
                itemType: "category",

                // [Optional] {string[]?} must have same length as categories, used to provide loading param for each category
                categoryParams: [
                    "/albums-index-cate-19.html",
                    "/albums-index-cate-20.html",
                    "/albums-index-cate-21.html",
                ],

                // [Optional] {string} cannot be used with `categoryParams`, set all category params to this value
                groupParam: null,
            },
        ],
        // enable ranking page
        enableRankingPage: true,
    }

    /// category comic loading related
    categoryComics = {
        /**
         * load comics of a category
         * @param category {string} - category name
         * @param param {string?} - category param
         * @param options {string[]} - options from optionList
         * @param page {number} - page number
         * @returns {Promise<{comics: Comic[], maxPage: number}>}
         */
        load: async (category, param, options, page) => {
            let url = this.baseUrl + param
            if (page !== 0) {
                if (!url.includes("-")) {
                    url = url.replaceAll(".html", "-.html");
                }
                url = url.replaceAll("index", "");
                let lr = url.split("albums-");
                lr[1] = `index-page-${page}${lr[1]}`;
                url = `${lr[0]}albums-${lr[1]}`;
            }

            let res = await Network.get(url, {})
            if (res.status !== 200) {
                throw `Invalid Status Code ${res.status}`
            }
            let document = new HtmlDocument(res.body)
            let comicElements = document.querySelectorAll("div.grid div.gallary_wrap > ul.cc > li")
            let comics = []
            for (let comicElement of comicElements) {
                comics.push(this.parseComic(comicElement))
            }
            let pagesLink = document.querySelectorAll("div.f_left.paginator > a");
            let pages = Number(pagesLink[pagesLink.length - 1].text)
            document.dispose()
            return {
                comics: comics,
                maxPage: pages,
            }
        },
        ranking: {
            options: [
                "day-Day",
                "week-Week",
                "month-Month",
            ],
            load: async (option, page) => {
                let url = `${this.baseUrl}/albums-favorite_ranking-type-${option}.html`
                if (page !== 0) {
                    url = `${this.baseUrl}/albums-favorite_ranking-page-${page}-type-${option}.html`
                }

                let res = await Network.get(url, {})
                if (res.status !== 200) {
                    throw `Invalid Status Code ${res.status}`
                }

                let document = new HtmlDocument(res.body)
                let comicElements = document.querySelectorAll("div.grid div.gallary_wrap > ul.cc > li")
                let comics = []
                for (let comicElement of comicElements) {
                    comics.push(this.parseComic(comicElement))
                }

                let pagesLink = document.querySelectorAll("div.f_left.paginator > a")
                let pages = 1
                if (pagesLink.length > 0) {
                    pages = Number(pagesLink[pagesLink.length - 1].text)
                }

                document.dispose()
                return {
                    comics: comics,
                    maxPage: pages,
                }
            }
        }
    }

    /// search related
    search = {
        /**
         * load search result
         * @param keyword {string}
         * @param options {string[]} - options from optionList
         * @param page {number}
         * @returns {Promise<{comics: Comic[], maxPage: number}>}
         */
        load: async (keyword, options, page) => {
            let url = `${this.baseUrl}/search/?q=${encodeURIComponent(keyword)}&f=_all&s=create_time_DESC&syn=yes`
            if (page !== 0) {
                url += `&p=${page}`
            }
            let res = await Network.get(url, {})
            if (res.status !== 200) {
                throw `Invalid Status Code ${res.status}`
            }
            let document = new HtmlDocument(res.body)
            let comicElements = document.querySelectorAll("div.grid div.gallary_wrap > ul.cc > li")
            let comics = []
            for (let comicElement of comicElements) {
                comics.push(this.parseComic(comicElement))
            }
            let total = document.querySelectorAll("p.result > b")[0].text.replaceAll(',', '')
            const comicsPerPage = 24
            let pages = Math.ceil(Number(total) / comicsPerPage)
            document.dispose()
            return {
                comics: comics,
                maxPage: pages,
            }
        },
    }

    // favorite related
    favorites = {
        // whether support multi folders
        multiFolder: true,
        isOldToNewSort: true,
        /**
         * add or delete favorite.
         * throw `Login expired` to indicate login expired, App will automatically re-login and re-add/delete favorite
         * @param comicId {string}
         * @param folderId {string}
         * @param isAdding {boolean} - true for add, false for delete
         * @param favoriteId {string?} - [Comic.favoriteId]
         * @returns {Promise<any>} - return any value to indicate success
         */
        addOrDelFavorite: async (comicId, folderId, isAdding, favoriteId) => {
            if (!isAdding) {
                let res = await Network.get(`${this.baseUrl}/users-fav_del-id-${favoriteId}.html?ajax=true&_t=${randomDouble(0, 1)}`, {})
                if (res.status !== 200) {
                    throw 'Delete failed'
                }
            } else {
                let res = await Network.post(`${this.baseUrl}/users-save_fav-id-${comicId}.html`, {
                    'content-type': 'application/x-www-form-urlencoded'
                }, `favc_id=${folderId}`)
                if (res.status !== 200) {
                    throw 'Delete failed'
                }
            }
            return 'ok'
        },
        /**
         * load favorite folders.
         * throw `Login expired` to indicate login expired, App will automatically re-login retry.
         * if comicId is not null, return favorite folders which contains the comic.
         * @param comicId {string?}
         * @returns {Promise<{folders: {[p: string]: string}, favorited: string[]}>} - `folders` is a map of folder id to folder name, `favorited` is a list of folder id which contains the comic
         */
        loadFolders: async (comicId) => {
            let res = await Network.get(`${this.baseUrl}/users-addfav-id-210814.html`, {})
            if (res.status !== 200) {
                throw 'Load failed'
            }
            let document = new HtmlDocument(res.body)
            let data = {}
            document.querySelectorAll("option").forEach((option => {
                if (option.attributes["value"] === "") return
                data[option.attributes["value"]] = option.text
            }))
            return {
                folders: data,
                favorited: []
            }
        },
        /**
         * add a folder
         * @param name {string}
         * @returns {Promise<any>} - return any value to indicate success
         */
        addFolder: async (name) => {
            let res = await Network.post(`${this.baseUrl}/users-favc_save-id.html`, {
                'content-type': 'application/x-www-form-urlencoded'
            }, `favc_name=${encodeURIComponent(name)}`)
            if (res.status !== 200) {
                throw 'Add failed'
            }
            return 'ok'
        },
        /**
         * delete a folder
         * @param folderId {string}
         * @returns {Promise<void>} - return any value to indicate success
         */
        deleteFolder: async (folderId) => {
            let res = await Network.get(`${this.baseUrl}/users-favclass_del-id-${folderId}.html?ajax=true&_t=${randomDouble()}`, {})
            if (res.status !== 200) {
                throw 'Delete failed'
            }
            return 'ok'
        },
        /**
         * load comics in a folder
         * throw `Login expired` to indicate login expired, App will automatically re-login retry.
         * @param page {number}
         * @param folder {string?} - folder id, null for non-multi-folder
         * @returns {Promise<{comics: Comic[], maxPage: number}>}
         */
        loadComics: async (page, folder) => {
            let url = `${this.baseUrl}/users-users_fav-page-${page}-c-${folder}.html.html`
            let res = await Network.get(url, {})
            if (res.status !== 200) {
                throw `Invalid Status Code ${res.status}`
            }
            let document = new HtmlDocument(res.body)
            let comicBlocks = document.querySelectorAll("div.asTB")
            let comics = comicBlocks.map((comic) => {
                let cover = comic.querySelector("div.asTBcell.thumb > div > img").attributes["src"]
                cover = 'https:' + cover
                let time = comic.querySelector("div.box_cel.u_listcon > p.l_catg > span").text.replaceAll("創建時間：", "")
                let name = comic.querySelector("div.box_cel.u_listcon > p.l_title > a").text;
                let link = comic.querySelector("div.box_cel.u_listcon > p.l_title > a").attributes["href"];
                let id = RegExp("(?<=-aid-)[0-9]+").exec(link)[0];
                let info = comic.querySelector("div.box_cel.u_listcon > p.l_detla").text;
                let pages = Number(RegExp("(?<=頁數：)[0-9]+").exec(info)[0])
                let delUrl = comic.querySelector("div.box_cel.u_listcon > p.alopt > a").attributes["onclick"];
                let favoriteId = RegExp("(?<=del-id-)[0-9]+").exec(delUrl)[0];
                return new Comic({
                    id: id,
                    title: name,
                    subtitle: time,
                    cover: cover,
                    pages: pages,
                    favoriteId: favoriteId,
                })
            })
            let pages = 1
            let pagesLink = document.querySelectorAll("div.f_left.paginator > a")
            if (pagesLink.length > 0) {
                pages = Number(pagesLink[pagesLink.length - 1].text)
            }
            document.dispose()
            return {
                comics: comics,
                maxPage: pages,
            }
        }
    }

    /// single comic related
    comic = {
        /**
         * load comic info
         * @param id {string}
         * @returns {Promise<ComicDetails>}
         */
        loadInfo: async (id) => {
            let res = await Network.get(`${this.baseUrl}/photos-index-page-1-aid-${id}.html`, {})
            if (res.status !== 200) {
                throw `Invalid Status Code ${res.status}`
            }
            let document = new HtmlDocument(res.body)

            let titleEl = document.querySelector("div.userwrap > h2")
            let title = titleEl ? titleEl.text : ''

            let coverEl = document.querySelector("div.userwrap > div.asTB > div.asTBcell.uwthumb > img")
            let cover = coverEl ? this._normalizeCover(coverEl.attributes["src"]) : ''

            // 解析信息标签，按冒号拆分，不依赖标签顺序
            let labelMap = {}
            let labels = document.querySelectorAll("div.asTBcell.uwconn > label")
            for (let label of labels) {
                let text = label.text || ''
                let idx = text.search(/[：:]/)
                if (idx > 0) {
                    labelMap[text.slice(0, idx).trim()] = text.slice(idx + 1).trim()
                }
            }

            // 真实标签位于 div.addtags 内；合集章节链接在 div.sr_compact，不会误入
            let rawTags = []
            let tagEls = document.querySelectorAll("div.addtags a.tagshow")
            for (let a of tagEls) {
                let text = (a.text || '').trim()
                if (!text) continue
                rawTags.push(...this._splitValues(text))
            }
            rawTags = this._dedupe(rawTags)

            // 合集检测：章节目录容器 div.sr_compact 下的章节链接
            let chapterEls = document.querySelectorAll("div.sr_compact > a[data-chid]")
            let isCollection = chapterEls.length > 0
            let chapters = new Map()
            if (isCollection) {
                // 以章节名作为章节 id：Venera 用 id 作为下载文件夹名，这样下载即为章节名
                let collected = await this._collectChapterDirectory(id, document)
                chapters = collected.chapters
                if (chapters.size > 0) {
                    let firstKey = chapters.keys().next().value
                    // 预览用：第 1 话 aid（Venera 预览点击固定进入第 1 话）
                    this.saveData('wnacgFirstEp_' + id, collected.chapterMap[firstKey])
                    // 阅读用：章节名 -> aid 映射
                    this.saveData('wnacgChapterMap_' + id, collected.chapterMap)
                }
            } else {
                // 非合集清理可能残留的数据
                this.deleteData('wnacgFirstEp_' + id)
                this.deleteData('wnacgChapterMap_' + id)
            }

            let descriptionEl = document.querySelector("div.asTBcell.uwconn > p")
            let description = descriptionEl ? descriptionEl.text : ''
            if (isCollection) {
                // Venera 预览只能展示第 1 话，这里提示用户改用章节按钮
                let count = labelMap["章節"] || `${chapters.size} 話`
                let notice = `【合集漫畫，共 ${count}】\n【Venera 預覽僅顯示第 1 話內容，切換章節請用章節按鈕】`
                description = notice + (description ? `\n\n${description}` : '')
            }
            let uploaderEl = document.querySelector("div.asTBcell.uwuinfo > a > p")
            let uploader = uploaderEl ? uploaderEl.text : ''

            let tags = new Map()
            if (labelMap["頁數"]) tags.set("頁數", [labelMap["頁數"]])
            if (labelMap["章節"]) tags.set("章節", [labelMap["章節"]])
            if (labelMap["狀態"]) tags.set("狀態", [labelMap["狀態"]])
            if (labelMap["分類"]) tags.set("分類", this._splitValues(labelMap["分類"]))
            if (rawTags.length > 0) tags.set("標籤", rawTags)

            document.dispose()

            let details = {
                title: title,
                cover: cover,
                tags: tags,
                description: description,
                uploader: uploader,
            }
            if (isCollection && chapters.size > 0) {
                details.chapters = chapters
            }
            return new ComicDetails(details)
        },
        /**
         * [Optional] load thumbnails of a comic
         * @param id {string}
         * @param next {string | null | undefined} - next page token, null for first page
         * @returns {Promise<{thumbnails: string[], next: string?}>} - `next` is next page token, null for no more
         */
        loadThumbnails: async (id, next) => {
            // 合集：预览第 1 话内容（Venera 预览点击固定进入第 1 话，保持操作逻辑一致）
            let targetId = this.loadData('wnacgFirstEp_' + id) || id
            let page = next ? (parseInt(next) || 1) : 1
            let res = await Network.get(`${this.baseUrl}/photos-index-page-${page}-aid-${targetId}.html`, {});
            if (res.status !== 200) {
                throw `Invalid Status Code ${res.status}`
            }
            let document = new HtmlDocument(res.body)
            let thumbnails = document.querySelectorAll("div.pic_box.tb > a > img").map((e) => {
                return this._normalizeCover(e.attributes["src"])
            })
            // 末页判定：取分页链接中的最大页码
            let maxPage = page
            let pageLinks = document.querySelectorAll("div.f_left.paginator > a")
            for (let link of pageLinks) {
                let n = parseInt(link.text)
                if (!isNaN(n) && n > maxPage) maxPage = n
            }
            document.dispose()
            return {
                thumbnails: thumbnails,
                next: page < maxPage ? String(page + 1) : null
            }
        },
        /**
         * load images of a chapter
         * @param comicId {string}
         * @param epId {string?}
         * @returns {Promise<{images: string[]}>}
         */
        loadEp: async (comicId, epId) => {
            // 合集某话：epId 为章节名，需映射回章节 aid；普通相册：epId 为空，读 comicId 自身
            let targetId = comicId
            if (epId) {
                let s = String(epId)
                if (s === '0') {
                    targetId = comicId
                } else if (/^[0-9]+$/.test(s)) {
                    targetId = s
                } else {
                    let map = this.loadData('wnacgChapterMap_' + comicId)
                    if (!map || !map[s]) {
                        // 映射缺失（如数据被清理）时重建章节目录
                        let collected = await this._collectChapterDirectory(comicId, null)
                        map = collected.chapterMap
                        this.saveData('wnacgChapterMap_' + comicId, map)
                        if (collected.chapters.size > 0) {
                            let firstKey = collected.chapters.keys().next().value
                            this.saveData('wnacgFirstEp_' + comicId, map[firstKey])
                        }
                    }
                    targetId = (map && map[s]) ? map[s] : s
                }
            }
            let res = await Network.get(`${this.baseUrl}/photos-gallery-aid-${targetId}.html`, {})
            if (res.status !== 200) {
                throw `Invalid Status Code ${res.status}`
            }
            const regex = RegExp(String.raw`//[^"]+/[^"]+\.[^"]+`, 'g');
            const matches = Array.from(res.body.matchAll(regex));
            return {
                images: matches.map((e) => this._normalizeCover(e[0].substring(0, e[0].length - 1)))
            }
        },
        /**
         * [Optional] Handle tag click event
         * @param namespace {string}
         * @param tag {string}
         * @returns {{action: string, keyword: string, param: string?}}
         */
        onClickTag: (namespace, tag) => {
            return {
                action: 'search',
                keyword: tag,
            }
        },
    }

    get settings() {
        // 动态生成选项，总是保留 Custom Domain (0)，然后根据 Wnacg.domains 数量添加选项
        let domainOptions = [{ value: '0', text: 'Custom Domain' }]
        for (let i = 0; i < Wnacg.domains.length; i++) {
            domainOptions.push({
                value: String(i + 1),
                text: Wnacg.domains[i]
            })
        }

        return {
            refreshDomains: {
                title: "Refresh Domain List",
                type: "callback",
                buttonText: "Refresh",
                callback: () => this.refreshDomains(true)
            },
            refreshDomainsOnStart: {
                title: "Refresh Domain List on Startup",
                type: "switch",
                default: true,
            },
            domainSelection: {
                title: "Domain Selection",
                type: "select",
                options: domainOptions,
                default: "0",
            },
            domain0: {
                title: "Custom Domain",
                type: "input",
                validator: String.raw`^(?!:\/\/)(?=.{1,253})([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$`,
                default: 'wnacg.com',
            },
        }
    }

    translation = {
        'zh_CN': {
            'Refresh Domain List': '刷新域名列表',
            'Refresh': '刷新',
            'Refresh Domain List on Startup': '启动时刷新域名列表',
            'Domain Selection': '域名选择',
            'Custom Domain': '自定义域名',
            'Custom domain is not set': '未设置自定义域名',
            'Selected domain is unavailable': '所选域名不可用，请先刷新域名列表',
            'Day': '日',
            'Week': '周',
            'Month': '月',
        },
        'zh_TW': {
            'Refresh Domain List': '刷新域名列表',
            'Refresh': '刷新',
            'Refresh Domain List on Startup': '啟動時刷新域名列表',
            'Domain Selection': '域名選擇',
            'Custom Domain': '自定義域名',
            'Custom domain is not set': '未設置自定義域名',
            'Selected domain is unavailable': '所選域名不可用，請先刷新域名列表',
            'Day': '日',
            'Week': '周',
            'Month': '月',
        },
    }
}
