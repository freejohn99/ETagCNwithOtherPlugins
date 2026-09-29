package LANraragi::Plugin::Metadata::WnacgCN;

use v5.36;
use strict;
use warnings;
no warnings 'uninitialized';
use utf8;

#Plugins can freely use all Perl packages already installed on the system
#Try however to restrain yourself to the ones already installed for LRR (see tools/cpanfile) to avoid extra installations by the end-user.
use URI::Escape;
use Mojo::JSON qw(decode_json);
use Mojo::UserAgent;

#You can also use the LRR Internal API when fitting.
use LANraragi::Model::Plugins;
use LANraragi::Utils::Logging qw(get_plugin_logger);

my $BROWSER_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

#Meta-information about your plugin.
sub plugin_info {

    return (
        name        => "紳士漫畫_CN",
        type        => "metadata",
        namespace   => "wnacgcn",
        login_from  => "wnacglogin",
        author      => "FreeJohn&DeepSeek",
        version     => "1.0.1",
        description =>
          "搜索紳士漫畫（wnacg）以查找与您的存档匹配的标签。<br/><i class='fa fa-exclamation-circle'></i> 此插件将使用存档的 source: 标签（如果存在）。",
        parameters => [
            { type => "string", desc => "自定义域名（默认 www.wnacg.com，必须带 www，末尾不要带斜杠）" },
            { type => "bool",   desc => "使用搜刮到的标题重命名存档（⚠ 警告：站点标题可能重复，可能导致命名冲突；默认关闭）", default_value => 0 },
            { type => "bool",   desc => "获取额外的元数据（页数/分类/上传者）并将简介写入摘要" },
            { type => "bool",   desc => "优先使用标题中的数字 ID 直接获取（如果失败，则使用标题搜索）" },
            { type => "bool",   desc => "通过 db.text.json 反查并规范化标签（兼容 E-Hentai 刮削结果）", default_value => 1 },
            { type => "string", desc => "EhTagTranslation 的 db.text.json 绝对路径（留空则使用常见位置）" },
        ],
        oneshot_arg => "该作品在紳士漫畫的 URL 或 aid(将于确切的漫画相匹配的标签到你的档案中)",
        cooldown    => 4
    );

}

#Mandatory function to be implemented by your plugin
sub get_tags {

    shift;
    my $lrr_info = shift;    # Global info hash
    my ( $domain, $savetitle, $addextra, $prefer_title_id, $usereverse, $db_path ) = @_;    # Plugin parameters

    $domain = 'www.wnacg.com' if !defined $domain || $domain eq '';
    $domain =~ s{^https?://}{}i;
    $domain =~ s{/+$}{};
    my $base = "https://$domain";

    my $logger = get_plugin_logger();
    my $ua     = $lrr_info->{user_agent};

    # 按需加载 EhTagTranslation 反查索引（与 ETagCN.pm 使用同一份 db.text.json）
    my $reverse;
    if ($usereverse) {
        $reverse = load_reverse_index($db_path);
    }

    my $title    = $lrr_info->{archive_title}   // '';
    my $existing = $lrr_info->{existing_tags}   // '';
    my $param    = $lrr_info->{oneshot_param}   // '';

    my $aid      = '';
    my $hasSrc   = 0;
    my $explicit = 0;

    # 1) oneshot 指定的 URL 或 aid
    if ( $param =~ /aid-(\d+)/i ) {
        $aid      = $1;
        $explicit = 1;
        $logger->debug("使用 oneshot URL 中的 aid=$aid");
    }
    elsif ( $param =~ /^\s*(\d{3,})\s*$/ ) {
        $aid      = $1;
        $explicit = 1;
        $logger->debug("使用 oneshot 指定的 aid=$aid");
    }

    # 2) 已存在的 source:/aid: 标签
    if ( !$aid ) {
        if ( $existing =~ /source:\s*(?:https?:\/\/)?[^,]*?aid-(\d+)/i ) {
            $aid      = $1;
            $hasSrc   = 1;
            $explicit = 1;
            $logger->debug("使用 source 标签中的 aid=$aid");
        }
        elsif ( $existing =~ /(?:^|,)\s*aid:(\d+)/i ) {
            $aid      = $1;
            $explicit = 1;
            $logger->debug("使用已存在的 aid 标签=$aid");
        }
    }

    # 3) 标题中的数字 ID（可回退到搜索）
    my $from_title = 0;
    if ( !$aid && $prefer_title_id ) {
        my $tid = extract_aid_from_title($title);
        if ($tid) {
            $aid        = $tid;
            $from_title = 1;
            $logger->info("尝试使用标题中的 aid=$tid 直接获取");
        }
    }

    my $detail;
    if ($aid) {
        $detail = fetch_wnacg_detail( $ua, $base, $aid, $logger );
        if ( !$detail && $from_title ) {
            $logger->info("标题中的 aid=$aid 无效，回退到标题搜索");
            $aid = '';
        }
    }

    if ( $explicit && !$detail ) {
        $logger->info("无法获取指定的作品 aid=$aid");
        die "无法获取指定的紳士漫畫作品 (aid=$aid)！\n";
    }

    # 4) 标题搜索
    if ( !$aid || !$detail ) {
        my $found = search_wnacg( $ua, $base, $title, $logger );
        if ($found) {
            $aid    = $found;
            $detail = fetch_wnacg_detail( $ua, $base, $aid, $logger );
        }
    }

    if ( !$aid || !$detail ) {
        $logger->info("没有找到匹配的绅士漫画作品！");
        die "没有找到匹配的绅士漫画作品！\n";
    }

    $logger->info("Using wnacg aid=$aid ({$detail->{title}})");

    # 组装标签（启用反查时，能唯一对应到 E-Hentai 标签的会替换为一致的中文规范标签）
    my @out;
    push @out, "aid:$aid";

    # 分类可能是 "同人誌／日語" 这种以 / 或 ／ 分隔的多值，拆分后逐个成为独立标签
    for my $c ( split m{[/／]}, ( $detail->{category} // '' ) ) {
        my $v = trim($c);
        next if $v eq '';
        my @m = canonical_tags( $reverse, $v );
        if (@m) {
            push @out, @m;
        }
        else {
            my $f = fold_trad($v);
            push @out, '分类:' . ( defined $f && $f ne '' ? $f : $v );
        }
    }

    # 站点标签可能是单个 "a/b/c" 字符串或多标签拼接，按 / 或 ／ 拆分后逐个成为独立标签
    my @tag_candidates;
    for my $t ( @{ $detail->{tags} } ) {
        for my $part ( split m{[/／]}, ( $t // '' ) ) {
            my $v = trim($part);
            push @tag_candidates, $v if $v ne '';
        }
    }
    @tag_candidates = dedupe_values(@tag_candidates);

    for my $t (@tag_candidates) {
        if ( $t =~ /[（(]/ ) {    # 形如 "团体(艺术家)" 的标签，按名人类处理
            push @out, author_like_tags( $reverse, $t, '标签' );
            next;
        }
        my @m = canonical_tags( $reverse, $t );
        if (@m) {
            push @out, @m;
        }
        else {
            my $f = fold_trad($t);    # 未命中：至少繁→简，保证与 EH 简体一致
            push @out, '标签:' . ( defined $f && $f ne '' ? $f : $t );
        }
    }

    # 标签含 3P 时，追加默认的 混合:女男女3P
    push @out, '混合:女男女3P' if grep { /(?<![a-z0-9])3p(?![a-z0-9])/i } @tag_candidates;

    push @out, "页数:$detail->{pages}" if $detail->{pages} ne '';
    if ($addextra) {
        push @out, "上传者:$detail->{uploader}" if $detail->{uploader} ne '';
    }

    push @out, title_author_tags( $reverse, $title );    # 标题中 [团体 (艺术家)] 的作者匹配

    @out = dedupe(@out);    # 名人类精确去重、普通标签繁简去重
    my $tagstr = join( ', ', @out );
    if ( !$hasSrc ) {
        $tagstr .= ", source:$domain/photos-index-page-1-aid-$aid.html";
    }

    my %hashdata = ( tags => $tagstr );
    $hashdata{title}   = $detail->{title}       if $savetitle && $detail->{title} ne '';
    $hashdata{summary} = $detail->{description} if $addextra  && $detail->{description} ne '';

    $logger->info("Sending the following tags to LRR: $tagstr");

    return %hashdata;

}

######
## Wnacg Specific Methods
######

sub trim ($s) {
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# 去掉标题里的各种 id（前导数字 id、id-<数字>、aid-<数字>），保留其余内容
sub strip_ids ($s) {
    $s //= '';
    $s =~ s/^\s*\d{4,}\s*[-_:]\s*//;           # 前导编号，如 "4210316-..."
    $s =~ s/\b(?:aid|id)[-\s_]?\d+\b//ig;      # 任意位置的 id-123 / aid-123
    return $s;
}

# 生成搜索关键词候选（按顺序重试）：
#   1) 仅去掉 id 的标题（保留括号内容），提高命中率；
#   2) 若 1) 无结果，再去掉所有括号及其内容（应对括号内写法不同 / 重名）。
sub search_keywords ($title) {
    my $t = $title // '';
    $t =~ s/\s+/ /g;
    $t = trim($t);

    my $k1 = trim( strip_ids($t) );

    my $k2 = strip_ids($t);
    $k2 =~ s/[\[\(【（《「『][^\]\)】）》」』]*[\]\)】）》」』]//g;
    $k2 =~ s/\s+/ /g;
    $k2 = trim($k2);

    my @out;
    push @out, $k1 if $k1 ne '';
    push @out, $k2 if $k2 ne '' && $k2 ne $k1;
    return @out;
}

# 从标题中提取数字 ID，支持：
#   "4210316-[artist] title"  -> 前导数字
#   "[4210316] title" / "title (4210316)" -> 括号包裹
sub extract_aid_from_title ($title) {
    $title //= '';
    if ( $title =~ /^\s*(\d{4,})\s*-/ ) {
        return $1;
    }
    if ( $title =~ /(?:\[|\()\s*(\d{4,})\s*(?:\]|\))/ ) {
        return $1;
    }
    return "";
}

sub fetch_dom ( $ua, $url, $logger ) {

    my $res = $ua->get(
        $url => {
            'User-Agent' => $BROWSER_UA,
            'Accept'     => 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
            'Referer'    => $url,
        }
    )->result;

    if ( !$res || !$res->is_success ) {
        $logger->error( "GET $url 失败: " . ( $res ? "HTTP " . $res->code : 'no response' ) );
        return undef;
    }

    return $res->dom;

}

# 通过标题搜索返回第一个结果的 aid
sub search_wnacg ( $ua, $base, $title, $logger ) {

    my @keywords = search_keywords($title);
    if ( !@keywords ) {
        $logger->info("标题为空，无法搜索");
        return "";
    }

    for my $kw (@keywords) {

        my $url = "$base/search/?q=" . uri_escape_utf8($kw) . "&f=_all&s=create_time_DESC&syn=yes";
        $logger->info("wnacg 搜索 URL: $url");

        my $dom = fetch_dom( $ua, $url, $logger );
        next unless $dom;

        my $li = $dom->at('div.grid div.gallary_wrap > ul.cc > li');
        if ( !$li ) {
            $logger->info("wnacg 搜索 \"$kw\" 无结果，尝试下一个关键词");
            next;
        }

        my $a    = $li->at('div.pic_box > a');
        my $href = $a ? ( $a->attr('href') // '' ) : '';
        if ( $href =~ /aid-(\d+)/ ) {
            return $1;
        }

        $logger->info("wnacg 搜索结果中未解析出 aid（href=$href）");
    }

    return "";

}

# 抓取详情页，返回 hashref；页面无效时返回 undef
sub fetch_wnacg_detail ( $ua, $base, $aid, $logger ) {

    my $url = "$base/photos-index-page-1-aid-$aid.html";
    my $dom = fetch_dom( $ua, $url, $logger );
    return undef unless $dom;

    my $h2 = $dom->at('div.userwrap > h2');
    return undef unless $h2;
    my $title = trim( $h2->text );
    return undef if $title eq '';

    my @labels = map { trim( $_->text ) } @{ $dom->find('div.asTBcell.uwconn > label') };
    my $category = '';
    my $pages    = '';
    if (@labels) {
        $category = $1 if $labels[0] =~ /[：:]\s*(.+)$/;
    }
    if ( @labels > 1 ) {
        $pages = $1 if $labels[1] =~ /[：:]\s*(.+)$/;
    }

    my @tags = map { trim( $_->text ) } @{ $dom->find('a.tagshow') };

    my $up = $dom->at('div.asTBcell.uwuinfo > a > p');
    my $uploader = $up ? trim( $up->text ) : '';

    my $dp = $dom->at('div.asTBcell.uwconn > p');
    my $description = $dp ? trim( $dp->text ) : '';

    return {
        title       => $title,
        category    => $category,
        pages       => $pages,
        tags        => \@tags,
        uploader    => $uploader,
        description => $description,
    };

}

######
## EhTagTranslation 反查（与 ETagCN.pm 使用同一份 db.text.json，保证标签字符串一致）
######

# 繁→简折叠表（空格分隔的一对一映射），仅用于查询匹配（不影响输出；缺项时退化为不匹配）。
# 用空格分隔，避免单个错误导致后续整体错位。
my $T2S_PAIRS =
    '純纯 愛爱 漢汉 語语 畫画 寫写 單单 雜杂 誌志 韓韩 無无 長长 髮发 體体 實实 頁页 個个 這这 對对 說说 見见 現现 點点 學学 園园 師师 醫医 護护 門门 鏡镜 裝装 襪袜 連连 褲裤 絲丝 網网 紋纹 亞亚 轉转 換换 場场 動动 機机 讀读 書书 圖图 館馆 觀观 類类 題题 節节 記记 認认 讓让 誘诱 麗丽 豔艳 嬌娇 濕湿 潤润 澤泽 濃浓 潔洁 淨净 亂乱 倫伦 親亲 寶宝 貝贝 財财 貴贵 買买 賣卖 費费 賺赚 贏赢 戲戏 樂乐 團团 隊队 開开 關关 張张 彈弹 錄录 響响 頂顶 順顺 預预 領领 頭头 額额 顆颗 願愿 風风 飛飞 飲饮 飯饭 馬马 騎骑 驚惊 驗验 驅驱 綠绿 軌轨 縛缚 癡痴 獵猎 薦荐 經经 結结 觸触 獸兽 強强 調调 藥药 僕仆 '
  . '貧贫 顏颜 顔颜 陰阴 雙双 臉脸 醜丑 稱称 總总 織织 續续 統统 絕绝 級级 紀纪 約约 紅红 糾纠 纖纤 維维 緊紧 綁绑 線线 緣缘 練练 變变 邊边 選选 還还 進进 遠远 運运 達达 適适 過过 遺遗 鄉乡 鄰邻 釋释 鋼钢 銀银 銅铜 錢钱 鐘钟 錯错 鐵铁 鑰钥 針针 釘钉 釣钓 鈴铃 飢饥 飽饱 飾饰 養养 黃黄 黨党 龍龙 竜龙 龜龟 質质 資资 賭赌 車车 軍军 輪轮 軟软 較较 載载 輝辉 輩辈 輕轻 間间 閒闲 閨闺 閱阅 闆板 雲云 電电 霧雾 靈灵 幹干 幾几 麼么 頰颊 頸颈 顧顾 鳥鸟 雞鸡 鴨鸭 麥麦 麵面 齊齐 剛刚 創创 劇剧 劍剑 劃划 劉刘 則则 務务 勝胜 勞劳 勢势 匯汇 區区 協协 嚴严 囑嘱 國国 圍围 圓圆 壞坏 壓压 壘垒 壯壮 壽寿 夢梦 夾夹 奧奥 奮奋 婦妇 媽妈 嫵妩 孫孙 寧宁 寵宠 導导 將将 專专 尋寻 層层 屬属 島岛 嶺岭 嶼屿 帥帅 帳帐 帶带 幫帮 廣广 廠厂 廳厅 歸归 當当 徹彻 徑径 從从 復复 徵征 憂忧 懷怀 懸悬 懼惧 戀恋 戰战 戶户 擔担 擴扩 擺摆 攔拦 攜携 攝摄 攢攒 敵敌 數数 斂敛 斷断 舊旧 時时 晉晋 曆历 曉晓 暫暂 會会 東东 極极 構构 槍枪 標标 樓楼 樣样 樹树 橋桥 檢检 櫃柜 權权 櫻樱 歐欧 歡欢 歲岁 歷历 殘残 殺杀 殼壳 毀毁 氣气 決决 沒没 沖冲 準准 滅灭 溝沟 溫温 測测 湯汤 滿满 濟济 瀏浏 濁浊 灣湾 災灾 為为 烏乌 煙烟 營营 燦灿 燭烛 燒烧 爺爷 牆墙 獨独 獎奖 環环 瓊琼 產产 産产 畢毕 異异 疊叠 瘋疯 療疗 癢痒 發发 発发 皺皱 盜盗 監监 盤盘 矯矫 砲炮 碼码 礎础 禮礼 禱祷 離离 種种 積积 穩稳 窮穷 競竞 筆笔 筍笋 範范 築筑 簡简 籃篮 籌筹 簽签 簾帘 紙纸 紛纷 細细 紹绍 終终 組组 給给 綜综 綱纲 緩缓 編编 縱纵 縮缩 繞绕 罰罚 罷罢 義义 習习 聯联 聰聪 聲声 職职 聽听 聾聋 肅肃 膚肤 臘腊 臨临 舉举 艙舱 藝艺 蘇苏 蘭兰 處处 號号 蟲虫 術术 衛卫 衝冲 補补 複复 視视 覺觉 覽览 訂订 計计 訊讯 討讨 訓训 託托 訪访 設设 許许 訴诉 診诊 註注 評评 詞词 試试 詩诗 話话 詳详 誠诚 誤误 課课 誰谁 談谈 請请 論论 諮咨 講讲 謝谢 證证 識识 譜谱 議议 豐丰 豬猪 負负 貢贡 貨货 販贩 貪贪 貫贯 責责 貸贷 貿贸 貼贴 賀贺 賈贾 賊贼 賓宾 賞赏 賠赔 賢贤 賬账 購购 賽赛 贈赠 贊赞 趙赵 趨趋 躍跃 輔辅 輛辆 辦办 辭辞 農农 釀酿 錦锦 鍵键 鍾钟 鍋锅 鎖锁 鎮镇 閉闭 閏闰 閩闽 陳陈 陸陆 陽阳 階阶 隨随 險险 隱隐 雖虽 難难 靜静 項项 須须 頌颂 顯显 駕驾 鬥斗 魯鲁 鮮鲜 鳴鸣 鴻鸿 腦脑 窺窥 姦奸 搾榨 腳脚 暈晕 腸肠 聖圣 襯衬 內内 裡里 裏里 與与 並并 佔占 於于 実实 沢泽 広广 後后 宮宫 業业 魚鱼 隻只 別别 億亿 儀仪 傾倾 償偿 儲储 傑杰 傘伞 兇凶 兌兑 冊册 凍冻 凱凯 剎刹 勁劲 卻却 參参 叢丛 墊垫 墳坟 墜坠 奪夺 妝妆 娛娱 審审 寬宽 屆届 岡冈 巒峦 巔巅 廈厦 廚厨 廁厕 廢废 廟庙 龐庞 廬庐 弒弑 悽凄 悅悦 慘惨 慚惭 慶庆 憐怜 憑凭 懇恳 應应 懶懒 懺忏 掃扫 掛挂 採采 揀拣 揮挥 揹背 損损 搶抢 搗捣 摑掴 撈捞 撐撑 撓挠 撥拨 撫抚 撲扑 據据 擠挤 擬拟 擾扰 攏拢 攙搀 攤摊 攪搅 攬揽 敗败 敘叙 斃毙 斕斓 昇升 曇昙 朧胧 樞枢 樸朴 橫横 檯台 檻槛 櫥橱 欄栏 欽钦 歎叹 毆殴 滄沧 滯滞 滲渗 滷卤 漲涨 漸渐 潑泼 潛潜 濤涛 濫滥 濱滨 瀉泻 瀋沈 瀕濒 灘滩 煉炼 煩烦 熱热 燁烨 燈灯 燼烬 爐炉 爭争 爾尔 牘牍 犧牺 狀状 狹狭 狽狈 獄狱 獅狮 獲获 獻献 獼猕 玨珏 琺珐 璽玺 甌瓯 畝亩 疇畴 痙痉 瘍疡 瘡疮 瘧疟 癘疠 癥症 皚皑 蓋盖 瞞瞒 矇蒙 礦矿 磚砖 礙碍 禍祸 禪禅 禿秃 稈秆 竄窜 竊窃 筧笕 箋笺 篤笃 籤签 粵粤 糞粪 糧粮 絞绞 絡络 緒绪 締缔 縣县 繒缯 繡绣 繫系 繳缴 繼继 纏缠 纜缆 缽钵 羅罗 羆罴 翹翘 耬耧 聳耸 恥耻 聶聂 臍脐 臟脏 艱艰 藍蓝 蘊蕴 虛虚 襖袄 襲袭 規规 覓觅 詫诧 該该 誣诬 誹诽 誼谊 諒谅 諷讽 諸诸 諾诺 謀谋 謂谓 謎谜 謠谣 謙谦 謹谨 譯译 譽誉 讎仇 讚赞 豎竖 貓猫 貞贞 貯贮 賄贿 貲赀 賜赐 賦赋 賴赖 贓赃 贖赎 贛赣 趕赶 躋跻 躡蹑 軀躯 軒轩 輯辑 輸输 輻辐 轎轿 轟轰 迴回 逕径 違违 遙遥 遜逊 遞递 遲迟 遼辽 邁迈 邏逻 鄧邓 鑒鉴 釵钗 鈔钞 鉤钩 銘铭 銬铐 銷销 鋁铝 鋒锋 鋪铺 銳锐 鋸锯 錘锤 錚铮 錫锡 錮锢 錶表 鎊镑 鏈链 鏗铿 鑄铸 鑑鉴 鑼锣 鑽钻 閃闪 閑闲 閘闸 閡阂 閣阁 闊阔 闌阑 闖闯 闢辟 陝陕 陣阵 隕陨 際际 隸隶 雛雏 靨靥 韌韧 頑顽 頓顿 頗颇 頜颌 顛颠 颱台 飼饲 餅饼 餌饵 餘余 餚肴 餡馅 饅馒 饋馈 饑饥 饒饶 馮冯 馳驰 馴驯 駁驳 駐驻 騙骗 騰腾 驕骄 驟骤 髒脏 鬆松 鬍胡 鬧闹 鬱郁 鮑鲍 鯉鲤 鯨鲸 鰭鳍 鴉鸦 鴕鸵 鵝鹅 鷹鹰 黴霉 齒齿 員员 脅胁 偽伪 紗纱 惡恶 癒愈 執执 萬万 誕诞 週周 曬晒 嚐尝 鹹咸 燙烫 醬酱 蔥葱 薑姜 蘿萝 蔔卜 檸柠 蘋苹 幣币 懲惩 擁拥 擇择 擊击 撿捡 擋挡 盪荡 盃杯 捲卷 華华 楽乐 図图 圧压 圏圈 塩盐 検检 験验 権权 訳译 覚觉 栄荣 拡扩 続续 総总 経经 絵绘 歩步 単单 売卖 読读 変变 戦战 気气 対对 県县 剣剑 獣兽 桜樱 渋涩 麺面 鶏鸡 撃击 齢龄 壌壤 剰剩 乗乘 剤剂 増增 徳德 稲稻 縁缘 頬颊 顕显 髪发 渕渊 浜滨 瀬濑 抜拔 収收 蔵藏 帯带 塁垒 亜亚 悪恶 囲围 団团 帰归 庁厅 挙举 拠据 摂摄 査查 歯齿 焼烧 縦纵 繊纤 聴听 臓脏 舗铺 覧览 醸酿 鉄铁 銭钱 錬炼 駅驿 駆驱 曽曾';
my %T2S;
{
    for my $pair ( split /\s+/, $T2S_PAIRS ) {
        next unless length($pair) == 2;
        my ( $t, $s ) = split //, $pair;
        $T2S{$t} = $s;
    }
}

# 单条缓存，避免同进程内重复解析 5MB 的 db.text.json
our ( $REV_CACHE_KEY, $REV_CACHE );

sub norm_key ($s) {
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return lc $s;
}

sub fold_trad ($s) {
    return '' unless defined $s;
    my $out = '';
    for my $ch ( split //, $s ) {
        $out .= ( $T2S{$ch} // $ch );
    }
    return $out;
}

sub add_rev ( $rev, $ns, $token, $canon ) {
    return if !defined $token || $token eq '' || !defined $canon || $canon eq '';
    my $list = $rev->{$token} ||= [];
    for my $it (@$list) {
        my $c = ref($it) eq 'HASH' ? $it->{canon} : $it;
        return if defined $c && $c eq $canon;
    }
    push @$list, { ns => $ns, canon => $canon };
    return;
}

# 反查候选的命名空间优先级（仅保留这几个；男性在建立索引时已跳过）。
# 女性 > 混合 > 其他 > 语言 > 重新分类；未列入的命名空间不参与反查。
my %NS_PRIORITY = (
    female   => 1,
    mixed    => 2,
    other    => 3,
    language => 4,
    reclass  => 5,
    
);

# 从候选中按优先级择优；无法判断返回 undef（交给 map_tag 做基本繁→简兜底）。
# 兼容旧版缓存（元素可能是纯字符串），避免 "Can't use string as a HASH ref"。
sub pick_canonical ($list) {
    return undef unless $list && @$list;
    my ( $best, $best_rank );
    for my $it (@$list) {
        next unless ref($it) eq 'HASH';
        my $rank = $NS_PRIORITY{ $it->{ns} };
        next unless defined $rank;
        if ( !defined $best_rank || $rank < $best_rank ) {
            $best      = $it;
            $best_rank = $rank;
        }
    }
    return $best ? $best->{canon} : undef;
}

sub default_db_paths {
    return (
        '/home/koyomi/lanraragi/database/db.text.json',
        ( $ENV{LRR_DATA_DIR} ? "$ENV{LRR_DATA_DIR}/db.text.json" : () ),
        './db.text.json',
    );
}

sub resolve_db_path ($db_path) {
    my @candidates;
    push @candidates, $db_path if defined $db_path && $db_path ne '';
    push @candidates, default_db_paths();
    for my $f (@candidates) {
        next if !defined $f || $f eq '';
        return $f if -f $f;
    }
    return undef;
}

# 建立 反查索引：中文名/英文 key（小写） -> [ 规范标签 "命名空间名称:标签名称" ]
sub load_reverse_index ($db_path) {

    my $logger   = get_plugin_logger();
    my $filename = resolve_db_path($db_path);

    if ( !$filename ) {
        $logger->error(
            "未找到 EhTagTranslation 的 db.text.json（插件参数路径: '"
              . ( $db_path // '' )
              . "'），将保留原始标签。"
        );
        return undef;
    }

    my $mtime = ( stat($filename) )[9] // 0;
    my $key   = "$filename|$mtime|v2";    # v2: 索引结构升级（元素含 ns/canon），旧缓存 key 不匹配会自动重建
    return $REV_CACHE if defined $REV_CACHE_KEY && $REV_CACHE_KEY eq $key && $REV_CACHE;

    $logger->info("使用标签数据库进行反查: $filename");

    open( my $fh, '<', $filename )
      or do {
        $logger->error("无法打开标签数据库 $filename: $!；将保留原始标签。");
        return undef;
      };
    my $text = do { local $/; <$fh> };
    close $fh;

    my $json = eval { decode_json($text) };
    if ( !$json || ref $json->{data} ne 'ARRAY' ) {
        $logger->error("标签数据库解析失败（不是有效的 EhTagTranslation db.text.json？）: $filename；将保留原始标签。");
        return undef;
    }

    my %rev;
    for my $nsnode ( @{ $json->{data} } ) {
        my $nskey = $nsnode->{namespace} // '';
        next if $nskey eq 'rows';    # rows 是命名空间索引，不是真实标签
        next if $nskey eq 'male';    # 取向女：不考虑男性命名空间
        my $nsname = $nsnode->{frontMatters}{name} // $nskey;
        next if $nsname eq '';
        my $vals = $nsnode->{data};
        next if ref $vals ne 'HASH';
        for my $k ( keys %$vals ) {
            my $vname = $vals->{$k}{name};
            next if !defined $vname || $vname eq '';
            my $canon = "$nsname:$vname";
            add_rev( \%rev, $nskey, norm_key($vname), $canon );
            add_rev( \%rev, $nskey, norm_key($k),     $canon );
        }
    }

    $logger->info( "标签反查索引已建立（" . scalar( keys %rev ) . " 个键）" );

    $REV_CACHE_KEY = $key;
    $REV_CACHE     = \%rev;
    return \%rev;

}

# 将站点标签反查为与 ETagCN 一致的中文规范标签；多义时按命名空间优先级选择
sub canonicalize_tag ($rev, $tag) {

    return '' unless $rev;

    my $t = trim($tag);
    return '' if $t eq '';

    # 先精确匹配（简体/英文 key），再不区分繁简匹配
    for my $k ( norm_key($t), norm_key( fold_trad($t) ) ) {
        next if $k eq '';
        my $pick = pick_canonical( $rev->{$k} );
        return $pick if defined $pick;
    }

    return '';

}

# 人名命名空间（与标签重名时全部加入，不落 raw）
my %NAME_NS = ( artist => 1, group => 2 );

# 返回该值对应的全部规范标签：
#   - 标签命名空间（女性/混合/其他/语言/重新分类）按优先级取一个；
#   - 若与 artist(艺术家)/group(社团) 重名，则全部加入。
sub canonical_tags ($rev, $value) {
    return () unless $rev;
    my $v = trim($value);
    return () if $v eq '';

    # 简体优先；简体无结果时再尝试原文（繁体/日文变体）
    my $folded = fold_trad($v);
    my @keys;
    push @keys, norm_key($folded);
    push @keys, norm_key($v) if norm_key($v) ne norm_key($folded);

    my @found;
    for my $k (@keys) {
        next if $k eq '';
        my $list = $rev->{$k};
        next unless $list && @$list;

        my $pick = pick_canonical($list);    # 标签命名空间择一
        push @found, $pick if defined $pick;

        for my $it ( sort { ( $NAME_NS{ $a->{ns} } // 9 ) <=> ( $NAME_NS{ $b->{ns} } // 9 ) }
            grep { ref($_) eq 'HASH' && $NAME_NS{ $_->{ns} } } @$list ) {
            push @found, $it->{canon};       # 艺术家/团队 全加
        }

        last if @found;
    }

    my ( %seen, @out );
    for my $c (@found) { next if $seen{$c}++; push @out, $c }
    return @out;
}

# 人名反查：只要 artist(艺术家) / group(团队) 的匹配（简体优先，失败再原文）
sub author_tags ($rev, $value) {
    return () unless $rev;
    my $v = trim($value);
    return () if $v eq '';

    my @keys;
    my $folded = fold_trad($v);
    push @keys, norm_key($folded);
    push @keys, norm_key($v) if norm_key($v) ne norm_key($folded);

    my ( %seen, @out );
    for my $k (@keys) {
        next if $k eq '';
        my $list = $rev->{$k};
        next unless $list && @$list;
        for my $it ( sort { ( $NAME_NS{ $a->{ns} } // 9 ) <=> ( $NAME_NS{ $b->{ns} } // 9 ) }
            grep { ref($_) eq 'HASH' && $NAME_NS{ $_->{ns} } } @$list ) {
            next if $seen{ $it->{canon} }++;
            push @out, $it->{canon};
        }
    }
    return @out;
}

# 处理 "团体(艺术家)"（圆括号）：保留原始完整名 + 强制加 团队/艺术家 + 反查匹配（去重）
sub author_like_tags ($rev, $value, $prefix) {
    my $v = trim($value);
    return () if $v eq '';

    my ( %seen, @out );
    my $add = sub {
        my $t = shift;
        return if !defined $t || $t eq '';
        return if $seen{$t}++;
        push @out, $t;
    };

    $add->("$prefix:$v");

    # 括号剥离：外层 + 括号内容；圆括号约定 外层=团队，括号内=艺术家
    my @parts;
    my $outer = $v;
    $outer =~ s/[\[\(【（《「『][^\]\)】）》」』]*[\]\)】）》」』]//g;
    $outer = trim($outer);
    push @parts, $outer if $outer ne '';
    my $tmp = $v;
    while ( $tmp =~ /[\[\(【（《「『]([^\]\)】）》」』]*)[\]\)】）》」』]/g ) {
        my $c = trim($1);
        push @parts, $c if $c ne '';
    }
    if ( $v =~ /[（(]/ && @parts ) {
        $add->("团队:$parts[0]")   if $parts[0] ne '';
        $add->("艺术家:$parts[1]") if defined $parts[1] && $parts[1] ne '';
    }

    for my $tok ( $v, @parts ) {
        $add->($_) for author_tags( $rev, $tok );
    }

    return @out;
}

# 从标题的 [...] / 【...】 中提取 "[团体 (艺术家)]" 形式并按作者处理
sub title_author_tags ($rev, $title) {
    my $t = $title // '';
    my ( %seen, @out );
    while ( $t =~ /[\[【]\s*([^\]】]*?)\s*[\]】]/g ) {
        my $group = trim($1);
        next if $group eq '' || $group !~ /[（(]/;
        for my $tag ( author_like_tags( $rev, $group, '作者' ) ) {
            next if $seen{$tag}++;
            push @out, $tag;
        }
    }
    return @out;
}

# 匹配则返回规范标签；未命中时至少做繁→简（保证与 EH 简体一致），实在没映射才用原文
sub map_tag ($rev, $value, $prefix) {
    my $v = trim($value);
    return '' if $v eq '';
    my $c = canonicalize_tag( $rev, $v );
    return $c if $c ne '';
    my $f = fold_trad($v);
    $f = $v if !defined $f || $f eq '';
    return $prefix ne '' ? "$prefix:$f" : $f;
}

sub is_simplified ($s) {
    return '' unless defined $s;
    return fold_trad($s) eq $s;
}

# 按“繁→简折叠 + 小写”去重；遇到繁简同义时优先保留简体写法
sub dedupe (@list) {
    # 名人类（作者/艺术家/团队/汉化组）精确去重，保留原文与反查名；其余标签做繁简折叠去重
    my %NAME_NS_PREFIX = map { $_ => 1 } qw(作者 艺术家 团队 汉化组);
    my ( %idx, %named, @out );
    for my $x (@list) {
        next if !defined $x || $x eq '';
        my $is_name = ( $x =~ /^([^:]+):/ && $NAME_NS_PREFIX{$1} ) ? 1 : 0;
        my $k = $is_name ? lc($x) : norm_key( fold_trad($x) );
        next if $k eq '';
        if ( !exists $idx{$k} ) {
            $idx{$k}   = scalar @out;
            $named{$k} = $is_name;
            push @out, $x;
        }
        elsif ( !$named{$k} && is_simplified($x) && !is_simplified( $out[ $idx{$k} ] ) ) {
            $out[ $idx{$k} ] = $x;
        }
    }
    return @out;
}

# 对“值列表”（未加命名空间的原始标签）做同样的繁简去重
sub dedupe_values (@list) {
    return dedupe(@list);
}

# 最终标签去重：精确（不折叠繁简），以保留“原始名 + 反查名”两种形态
sub dedupe_exact (@list) {
    my ( %seen, @out );
    for my $x (@list) {
        next if !defined $x || $x eq '';
        next if $seen{ lc $x }++;
        push @out, $x;
    }
    return @out;
}

1;
