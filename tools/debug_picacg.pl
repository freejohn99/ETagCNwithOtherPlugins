#!/usr/bin/env perl
# 哔咔漫画（Picacg）本地调试脚本 —— 验证 PicacgCN.pm / PicacgLogin.pm 的签名与抓取逻辑
#
# 需要 Mojo::UserAgent 与 Digest::SHA（均为 LRR 自带）。若缺失，先安装：
#   cpanm Mojo::UserAgent
#
# 用法示例（PowerShell / cmd）:
#   perl tools\debug_picacg.pl --selftest
#   perl tools\debug_picacg.pl --keyword "关键词"
#   perl tools\debug_picacg.pl --id 5f2a... --account 用户名 --password pass
#   perl tools\debug_picacg.pl --keyword "关键词" --account 用户名 --password pass --api https://picaapi.picacomic.com
#   perl tools\debug_picacg.pl --keyword "关键词" --account 用户名 --password pass --proxy http://192.168.31.95:7890
#
# 选项:
#   --selftest   只做离线自测（HMAC 向量、签名拼接、ID 提取、关键词、db 反查），不联网
#   --keyword    搜索关键词
#   --id         直接抓取指定漫画 ID（24 位 hex）
#   --account    哔咔帐号（用户名；--email 亦可）
#   --password   哔咔密码
#   --api        API 地址，默认 https://picaapi.picacomic.com
#   --timeout    请求超时秒数，默认 25
#   --proxy      代理地址，默认空（直连）；如 http://192.168.31.95:7890
#   --no-reverse 关闭 db.text.json 标签反查
#   --db-path    db.text.json 路径（默认自动查找，含 ./db.text.json）
#   --addextra   在最终 tags 中附带汉化组/点赞/上传者/更新时间
#
# 环境变量: PICACG_API

use strict;
use warnings;
use utf8;
use v5.36;

use Encode;
use Getopt::Long;
use Mojo::UserAgent;
use Mojo::Cookie::Response;
use Mojo::JSON qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);

our $FAIL = 0;
$| = 1;

# Windows 控制台默认代码页多为 GBK(936)：脚本按 UTF-8 输出会乱码，命令行里的中文/日文参数
# 也会被当作字节处理，导致搜索词双重编码而搜不到。这里统一处理：
#   - @ARGV 按系统 ANSI 代码页解码为字符；
#   - 输出在真实终端按控制台代码页编码；重定向/管道时用 UTF-8，便于日志与工具读取。
sub setup_io_encoding {
    if ( $^O eq 'MSWin32' ) {
        require Win32;
        my $in_cp  = eval { Win32::GetACP() }             || 936;
        my $out_cp = eval { Win32::GetConsoleOutputCP() } || $in_cp;
        my $in_enc  = $in_cp == 65001 ? 'UTF-8' : "cp$in_cp";
        my $out_enc = !-t STDOUT ? 'UTF-8' : ( $out_cp == 65001 ? 'UTF-8' : "cp$out_cp" );
        @ARGV = map { utf8::is_utf8($_) ? $_ : Encode::decode( $in_enc, $_, Encode::FB_DEFAULT ) } @ARGV;
        binmode( STDOUT, ":encoding($out_enc)" );
        binmode( STDERR, ":encoding($out_enc)" );
    }
    else {
        binmode( STDOUT, ':encoding(UTF-8)' );
    }
    return;
}
setup_io_encoding();

sub p_ok   { print "[ OK ]   @_\n" }
sub p_warn { print "[WARN]   @_\n" }
sub p_fail { $FAIL++; print "[FAIL]   @_\n" }
sub p_info { print "[INFO]   @_\n" }

my $API_KEY = 'C69BAF41DA5ABD1FFEDC6D2FEA56B';
my $SECRET  = '~d}$Q7$eIni=V)9\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn';

my ( $selftest, $keyword, $id, $email, $password, $api, $timeout,
    $no_reverse, $db_path, $addextra, $proxy, $extract_authors, $extract_brackets );
$api     = $ENV{PICACG_API};
$timeout = 25;
$proxy   = '';

GetOptions(
    'selftest'   => \$selftest,
    'keyword=s'  => \$keyword,
    'id=s'       => \$id,
    'account|email=s' => \$email,
    'password=s' => \$password,
    'api=s'      => \$api,
    'timeout=i'  => \$timeout,
    'no-reverse' => \$no_reverse,
    'db-path=s'  => \$db_path,
    'addextra'   => \$addextra,
    'proxy=s'    => \$proxy,
    'extract-authors!'  => \$extract_authors,
    'extract-brackets!' => \$extract_brackets,
) or die "参数错误\n";

$extract_authors  = 1 if !defined $extract_authors;
$extract_brackets = 0 if !defined $extract_brackets;

$api = 'https://picaapi.picacomic.com' if !defined $api || $api eq '';
$api =~ s{/+$}{};

my $use_reverse = !$no_reverse;

# ===== 从插件复制的逻辑（用于验证 PicacgCN.pm / PicacgLogin.pm）=====
sub trim ($s) {
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub strip_ids ($s) {
    $s //= '';
    $s =~ s/^\s*\d{4,}\s*[-_:]\s*//;
    $s =~ s/\b(?:aid|id)[-\s_]?\d+\b//ig;
    return $s;
}

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

sub extract_id_from_title ($t) {
    $t //= '';
    return $1 if $t =~ /([0-9a-fA-F]{24})/;
    return "";
}

sub parse_oneshot ($param) {
    $param //= '';
    return lc $1 if $param =~ /([0-9a-fA-F]{24})/;
    return "";
}

sub picacg_signature ($method, $path, $time, $nonce) {
    my $data = lc( $path . $time . $nonce . uc($method) . $API_KEY );
    return ( $data, hmac_sha256_hex( $data, $SECRET ) );
}

sub format_date ($raw) {
    return '' unless defined $raw && $raw ne '';
    return $1 if $raw =~ /^(\d{4}-\d{2}-\d{2})/;
    return $raw;
}

# ===== 标签反查（db.text.json）：与 PicacgCN.pm 保持一致 =====
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

sub norm_key ($s) {
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return lc $s;
}

sub fold_trad ($s) {
    return '' unless defined $s;
    my $out = '';
    for my $ch ( split //, $s ) { $out .= ( $T2S{$ch} // $ch ) }
    return $out;
}

sub is_simplified ($s) { return '' unless defined $s; return fold_trad($s) eq $s }

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

# 反查候选命名空间优先级：女性 > 混合 > 其他 > 语言 > 重新分类（男性已跳过）
my %NS_PRIORITY = (
    female   => 1,
    mixed    => 2,
    other    => 3,
    language => 4,
    reclass  => 5,
);

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
    my @cand;
    push @cand, $db_path if defined $db_path && $db_path ne '';
    push @cand, default_db_paths();
    for my $f (@cand) { next if !defined $f || $f eq ''; return $f if -f $f }
    return undef;
}

sub load_reverse_index ($db_path) {
    my $filename = resolve_db_path($db_path);
    if ( !$filename ) {
        p_warn("未找到 db.text.json（可用 --db-path 指定），跳过标签反查");
        return undef;
    }
    open( my $fh, '<', $filename ) or do { p_warn("无法打开 $filename: $!"); return undef };
    my $text = do { local $/; <$fh> };
    close $fh;

    my $json = eval { decode_json($text) };
    if ( !$json || ref $json->{data} ne 'ARRAY' ) {
        p_warn("db 解析失败（不是有效的 db.text.json）: $filename");
        return undef;
    }

    my %rev;
    for my $nsnode ( @{ $json->{data} } ) {
        my $nskey = $nsnode->{namespace} // '';
        next if $nskey eq 'rows';
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

    p_ok( "db.text.json 已加载（" . scalar( keys %rev ) . " 个反查键）: $filename" );
    return \%rev;
}

sub canonicalize_tag ($rev, $tag) {
    return '' unless $rev;
    my $t = trim($tag);
    return '' if $t eq '';
    my $folded = fold_trad($t);
    my @keys;
    push @keys, norm_key($folded);
    push @keys, norm_key($t) if norm_key($t) ne norm_key($folded);
    for my $k (@keys) {
        next if $k eq '';
        my $pick = pick_canonical( $rev->{$k} );
        return $pick if defined $pick;
    }
    return '';
}

# 括号拆分：返回 外层名 + 各括号内容（无括号则整体）
sub name_parts ($value) {
    my $v = trim($value);
    return () if $v eq '';
    my @parts;
    my $outer = $v;
    $outer =~ s/[\[\(【（《「『][^\]\)】）》」』]*[\]\)】）》」』]//g;
    $outer = trim($outer);
    push @parts, $outer if $outer ne '';
    while ( $v =~ /[\[\(【（《「『]([^\]\)】）》」』]*)[\]\)】）》」』]/g ) {
        my $c = trim($1);
        push @parts, $c if $c ne '';
    }
    @parts = ($v) unless @parts;
    my ( %seen, @out );
    for my $p (@parts) { next if $seen{$p}++; push @out, $p }
    return @out;
}

# 作者/汉化组：额外匹配 artist(艺术家) 与 group(社团)，同名全加
my %AUTHOR_NS = ( artist => 1, group => 2 );

sub author_tags ($rev, $value) {
    return () unless $rev;
    my $v = trim($value);
    return () if $v eq '';

    # 按括号拆分：整体 + 外层 + 各括号内容
    my @tokens = ($v);
    my $outer = $v;
    $outer =~ s/[\[\(【（《「『][^\]\)】）》」』]*[\]\)】）》」』]//g;
    push @tokens, trim($outer);
    while ( $v =~ /[\[\(【（《「『]([^\]\)】）》」』]*)[\]\)】）》」』]/g ) {
        push @tokens, trim($1);
    }

    my ( %seen, @out );
    for my $tok (@tokens) {
        next if $tok eq '';
        my @keys;
        my $folded = fold_trad($tok);
        push @keys, norm_key($folded);
        push @keys, norm_key($tok) if norm_key($tok) ne norm_key($folded);
        for my $k (@keys) {
            next if $k eq '';
            my $list = $rev->{$k};
            next unless $list && @$list;
            for my $it ( sort { ( $AUTHOR_NS{ $a->{ns} } // 9 ) <=> ( $AUTHOR_NS{ $b->{ns} } // 9 ) }
                grep { ref($_) eq 'HASH' && $AUTHOR_NS{ $_->{ns} } } @$list ) {
                next if $seen{ $it->{canon} }++;
                push @out, $it->{canon};
            }
        }
    }
    return @out;
}

# 处理 "团体(艺术家)"：原始名 + 强制 团队/艺术家 + 反查匹配（去重）
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
    for my $tok ( $v, @parts ) { $add->($_) for author_tags( $rev, $tok ) }
    return @out;
}

sub extract_title_author_tags ($title, $bare_first = 0) {
    my $t = $title // '';
    my ( %seen, @out );
    my $add = sub {
        my $tag = shift;
        return if !defined $tag || $tag eq '';
        return if $seen{$tag}++;
        push @out, $tag;
    };
    if ( $bare_first
        && $t =~ /^\s*(?:\d{4,}\s*-\s*)?[\[【]\s*([^\]】]*?)\s*[\]】]\s*\S/ )
    {
        my $seg = trim($1);
        if ( $seg ne '' && $seg !~ /[（(]/ ) {
            $add->("作者:$seg"); $add->("标签:$seg"); $add->("团队:$seg"); $add->("艺术家:$seg");
        }
    }
    while ( $t =~ /[\[【]\s*([^\]】]*?)\s*[\]】]/g ) {
        my $seg = trim($1);
        next if $seg eq '' || $seg !~ /[（(]/;
        $add->("作者:$seg");
        $add->("标签:$seg");
        my $outer = $seg;
        $outer =~ s/[\[\(【（《「『][^\]\)】）》」』]*[\]\)】）》」』]//g;
        $outer = trim($outer);
        $add->("团队:$outer") if $outer ne '';
        $add->("标签:$outer") if $outer ne '';
        my $tmp = $seg;
        while ( $tmp =~ /[\[\(【（《「『]([^\]\)】）》」』]*)[\]\)】）》」』]/g ) {
            my $inner = trim($1);
            $add->("艺术家:$inner") if $inner ne '';
            $add->("标签:$inner") if $inner ne '';
        }
    }
    return @out;
}

sub extract_all_bracket_tags ($title, $rev) {
    my $t = $title // '';
    my ( %seen, @out );
    my $add = sub {
        my $tag = shift;
        return if !defined $tag || $tag eq '';
        return if $seen{$tag}++;
        push @out, $tag;
    };
    my $emit = sub {
        my $c = shift;
        return if $c eq '';
        $add->("标签:$c");
        my $lang = detect_lang_key($c);
        if ( $lang ne '' ) {
            my $cn = $rev ? canonicalize_tag( $rev, $lang ) : '';
            $add->( $cn ne '' ? $cn : "语言:$lang" );
        }
        $add->("汉化组:$c") if is_scanlation_group($c);
    };
    while ( $t =~ /[\[【]\s*([^\]】]*?)\s*[\]】]/g ) { $emit->( trim($1) ) }
    while ( $t =~ /[（(]\s*([^）)]*?)\s*[）)]/g )    { $emit->( trim($1) ) }
    return @out;
}

sub detect_lang_key ($c) {
    return 'chinese'  if $c =~ /(中国语|中国語|中文|中國|简体|简中|繁體|繁体|繁中|中国翻訳|中国翻译|汉化|漢化|chinese|\bchs?\b|\bcht\b|\bchi\b)/i;
    return 'japanese' if $c =~ /(日本語|日本语|日语|日文|japanese|\bjpn?\b)/i;
    return 'english'  if $c =~ /(english|\beng\b|英语|英語)/i;
    return 'korean'   if $c =~ /(korean|한국어|한글|韩语|韓語)/i;
    return '';
}

sub is_scanlation_group ($c) {
    return $c =~ /(汉化组|漢化組|汉化社|漢化社|翻译组|翻譯組|字幕组|字幕組|扫图组|掃圖組|嵌字|汉化|漢化)/ ? 1 : 0;
}

sub map_tag ($rev, $value, $prefix) {
    my $v = trim($value);
    return '' if $v eq '';
    my $c = canonicalize_tag( $rev, $v );
    return $c if $c ne '';
    my $f = fold_trad($v);
    $f = $v if !defined $f || $f eq '';
    return $prefix ne '' ? "$prefix:$f" : $f;
}

sub dedupe (@list) {
    my %NAME_NS_PREFIX = map { $_ => 1 } qw(作者 艺术家 团队 汉化组);
    my ( %idx, %named, @out );
    for my $x (@list) {
        next if !defined $x || $x eq '';
        my $is_name = ( $x =~ /^([^:]+):/ && $NAME_NS_PREFIX{$1} ) ? 1 : 0;
        my $k = $is_name ? lc($x) : norm_key( fold_trad($x) );
        next if $k eq '';
        if ( !exists $idx{$k} ) { $idx{$k} = scalar @out; $named{$k} = $is_name; push @out, $x }
        elsif ( !$named{$k} && is_simplified($x) && !is_simplified( $out[ $idx{$k} ] ) ) { $out[ $idx{$k} ] = $x }
    }
    return @out;
}
sub dedupe_values (@list) { return dedupe(@list) }

# 最终标签去重：精确（不折叠繁简）
sub dedupe_exact (@list) {
    my ( %seen, @out );
    for my $x (@list) {
        next if !defined $x || $x eq '';
        next if $seen{ lc $x }++;
        push @out, $x;
    }
    return @out;
}

my $rev = $use_reverse ? load_reverse_index($db_path) : undef;

# ===== 离线自测 =====
print "=== 哔咔漫画（Picacg）本地调试 ===\n";
p_info("API: $api");

print "\n--- 0. 离线逻辑自测 ---\n";
{
    # RFC 4231 HMAC-SHA256 标准测试向量，验证 HMAC 实现
    my @vec = (
        [ ( "\x0b" x 20 ), 'Hi There', 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7' ],
        [ 'Jefe', 'what do ya want for nothing?', '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843' ],
    );
    for my $v (@vec) {
        my ( $key, $data, $want ) = @$v;
        my $got  = hmac_sha256_hex( $data, $key );
        my $mark = ( $got eq $want ) ? 'OK ' : 'BAD';
        printf "[%s] hmac  want=%s got=%s\n", $mark, $want, $got;
        $FAIL++ unless $got eq $want;
    }

    # 签名数据拼接顺序：path + time + nonce + METHOD + apiKey，整体小写
    my $time  = 1700000000;
    my $nonce = '0123456789abcdef0123456789abcdef';
    my ( $data, $sig ) = picacg_signature( 'POST', 'auth/sign-in', $time, $nonce );
    my $want_data = lc( 'auth/sign-in' . '1700000000' . $nonce . 'POST' . $API_KEY );
    my $mark = ( $data eq $want_data ) ? 'OK ' : 'BAD';
    printf "[%s] data  %s\n", $mark, $data;
    $FAIL++ unless $data eq $want_data;

    # 打印固定输入的签名，便于与 venera JS 实现对照
    p_info("固定输入签名(POST auth/sign-in, time=$time): $sig");

    # ID 提取
    my @id_cases = (
        [ 'https://picaapi.picacomic.com/comics/5f2a1b3c4d5e6f708192a3b4', '5f2a1b3c4d5e6f708192a3b4' ],
        [ '5F2A1B3C4D5E6F708192A3B4',                                       '5f2a1b3c4d5e6f708192a3b4' ],
        [ 'not-an-id',                                                      '' ],
    );
    for my $c (@id_cases) {
        my ( $in, $want ) = @$c;
        my $got  = parse_oneshot($in);
        my $ok   = ( $got eq $want ) ? 'OK ' : 'BAD';
        printf "[%s] id    want=%-26s got=%-26s <- %s\n", $ok, "'$want'", "'$got'", $in;
        $FAIL++ unless $got eq $want;
    }

    # 搜索关键词重试逻辑
    my @kwds = search_keywords('4210316-[group] 作品 [中国翻訳]');
    my $q1   = $kwds[0] // '';
    my $q2   = $kwds[1] // '';
    my $ok1  = ( $q1 eq '[group] 作品 [中国翻訳]' ) ? 'OK ' : 'BAD';
    my $ok2  = ( $q2 eq '作品' ) ? 'OK ' : 'BAD';
    printf "[%s] kw1   %s\n", $ok1, $q1;
    printf "[%s] kw2   %s\n", $ok2, $q2;
    $FAIL++ unless $ok1 eq 'OK ' && $ok2 eq 'OK ';

    # db 反查（需要 db.text.json；缺失时仅提示，不计失败）
    if ($rev) {
        my @rev_cases = (
            [ '百合',   '女性:百合' ],
            [ '巨乳',   '女性:巨乳' ],
            [ '連褲襪', '女性:连裤袜' ],
            [ '貧乳',   '女性:贫乳' ],
            [ '亂交',   '女性:乱交' ],
            [ '後宮',   '女性:后宫' ],
            [ '亲子丼', '混合:亲子丼' ],      # 仅混合命名空间
            [ '全彩',   '其他:全彩' ],
            [ '單行本', '其他:单行本' ],
        );
        for my $c (@rev_cases) {
            my ( $in, $want ) = @$c;
            my $got = canonicalize_tag( $rev, $in );
            my $ok  = ( $got eq $want ) ? 'OK ' : 'BAD';
            printf "[%s] rev   %-6s -> %s\n", $ok, $in, ( $got eq '' ? '(raw)' : $got );
            $FAIL++ unless $got eq $want;
        }
        # 反查不到时，至少做基本繁→简
        for my $c ( [ '純愛', '标签:纯爱' ] ) {
            my ( $in, $want ) = @$c;
            my $raw = canonicalize_tag( $rev, $in );
            my $got = map_tag( $rev, $in, '标签' );
            my $ok  = ( $raw eq '' && $got eq $want ) ? 'OK ' : 'BAD';
            printf "[%s] fold  %-6s -> %s (无匹配，仅繁简)\n", $ok, $in, $got;
            $FAIL++ unless $raw eq '' && $got eq $want;
        }
        # 作者/汉化组：同名 -> 艺术家/社团 全加（不落 raw）
        {
            my @a          = author_tags( $rev, '宇宙 (+丼)' );
            my $has_artist = ( grep { $_ eq '艺术家:宇宙' } @a ) ? 1 : 0;
            my $has_group  = ( grep { $_ eq '团队:+丼' } @a ) ? 1 : 0;
            my $ok         = ( $has_artist && $has_group ) ? 'OK ' : 'BAD';
            printf "[%s] auth  宇宙 (+丼) -> %s (括号拆分为艺术家/团队)\n", $ok, join( ', ', @a );
            $FAIL++ unless $has_artist && $has_group;
        }
        {
            my @p  = name_parts('圣華快楽书店 (くまっこ)');
            my $ok = ( join( '|', @p ) eq '圣華快楽书店|くまっこ' ) ? 'OK ' : 'BAD';
            printf "[%s] parts 圣華快楽书店 (くまっこ) -> %s\n", $ok, join( ' | ', @p );
            $FAIL++ unless $ok eq 'OK ';
        }
        {
            my @a = author_like_tags( $rev, '圣華快楽书店 (くまっこ)', '作者' );
            my $ok = ( grep { $_ eq '作者:圣華快楽书店 (くまっこ)' } @a )
                && ( grep { $_ eq '团队:圣华快乐书店' } @a )
                && ( grep { $_ eq '艺术家:くまっこ' } @a ) ? 'OK ' : 'BAD';
            printf "[%s] like  圣華快楽书店 (くまっこ) -> %s\n", $ok, join( ', ', @a );
            $FAIL++ unless $ok eq 'OK ';
        }
        {
            my @t  = extract_title_author_tags( '[らぼまじ! (武田あらのぶ)] 作品', 1 );
            my $ok = ( grep { $_ eq '艺术家:武田あらのぶ' } @t ) ? 'OK ' : 'BAD';
            printf "[%s] title -> %s\n", $ok, join( ', ', @t );
            $FAIL++ unless grep { $_ eq '艺术家:武田あらのぶ' } @t;
        }
        {
            my @b  = extract_all_bracket_tags( '[中国翻訳] 作品 (C97)', $rev );
            my $ok = ( grep { $_ eq '标签:中国翻訳' } @b ) ? 'OK ' : 'BAD';
            printf "[%s] bracket -> %s\n", $ok, join( ', ', @b );
            $FAIL++ unless grep { $_ eq '标签:中国翻訳' } @b;
        }
    }
    else {
        p_warn("未加载 db.text.json，跳过反查自测（--db-path 可指定）");
    }
}

if ($selftest) {
    print "\n=== 离线自测结果: " . ( $FAIL ? "$FAIL 项失败" : "全部通过" ) . " ===\n";
    exit( $FAIL ? 1 : 0 );
}

# ===== 在线测试 =====
my $ua = Mojo::UserAgent->new( timeout => $timeout, max_redirects => 5 );
$ua->insecure(1);
if ( $proxy ne '' ) {
    $ua->proxy->http($proxy)->https($proxy);
    p_info("Mojo 已设置 http/https 代理: $proxy");
}

sub gen_nonce { return join '', map { sprintf '%02x', int rand 256 } 1 .. 16 }

sub headers {
    my ( $method, $path, $token, $time, $nonce ) = @_;
    my ( undef, $sig ) = picacg_signature( $method, $path, $time, $nonce );
    return (
        'api-key'           => $API_KEY,
        'accept'            => 'application/vnd.picacomic.com.v1+json',
        'app-channel'       => '3',
        'authorization'     => $token // '',
        'time'              => "$time",
        'nonce'             => $nonce,
        'app-version'       => '2.2.1.3.3.4',
        'app-uuid'          => 'defaultUuid',
        'image-quality'     => 'original',
        'app-platform'      => 'android',
        'app-build-version' => '45',
        'Content-Type'      => 'application/json; charset=UTF-8',
        'user-agent'        => 'okhttp/3.8.1',
        'version'           => 'v1.5.4',
        'signature'         => $sig,
        'http_client'       => 'dart:io',
    );
}

my $token = '';
if ( $email && $password ) {
    my $path = 'auth/sign-in';
    my %h    = headers( 'POST', $path, '', time, gen_nonce() );
    my $res  = $ua->post( "$api/$path" => \%h => encode_json( { email => $email, password => $password } ) )->result;
    if ( $res && $res->is_success ) {
        $token = ( eval { $res->json } // {} )->{data}{token} // '';
        if ($token) { p_ok("登录成功，已获取 token") }
        else        { p_fail("登录响应中无 token: " . substr( $res->body, 0, 200 ) ) }
    }
    else {
        p_fail( "登录失败: " . ( $res ? "HTTP " . $res->code . " " . substr( $res->body, 0, 200 ) : 'no response' ) );
    }
}

if ( !$id && defined $keyword && $keyword ne '' ) {
    for my $kw ( search_keywords($keyword) ) {
        my $path = 'comics/advanced-search?page=1';    # 哔咔分页从 1 开始
        my %h    = headers( 'POST', $path, $token, time, gen_nonce() );
        my $res  = $ua->post( "$api/$path" => \%h => encode_json( { keyword => $kw, sort => 'dd' } ) )->result;
        if ( !$res || !$res->is_success ) {
            p_fail( "搜索失败: " . ( $res ? "HTTP " . $res->code : 'no response' ) );
            last;
        }
        my $doc = ( eval { $res->json } // {} )->{data}{comics}{docs}[0];
        if ( $doc && $doc->{_id} ) {
            $id = $doc->{_id};
            p_ok("关键词 \"$kw\" 搜索首个结果 id=$id ({$doc->{title}})");
            last;
        }
        p_warn("关键词 \"$kw\" 无结果，尝试下一个关键词");
    }
    p_fail("所有关键词搜索均无结果") unless $id;
}

if ($id) {
    my $path = "comics/$id";
    my %h    = headers( 'GET', $path, $token, time, gen_nonce() );
    my $res  = $ua->get( "$api/$path" => \%h )->result;
    if ( $res && $res->is_success ) {
        my $comic = ( eval { $res->json } // {} )->{data}{comic};
        if ($comic) {
            p_ok( "标题: $comic->{title}" );

            my $author  = $comic->{author} // '';
            my $team    = $comic->{chineseTeam} // '';
            my $creator = $comic->{_creator}{name} // '';
            my @cats    = @{ $comic->{categories} // [] };
            my @tags    = @{ $comic->{tags} // [] };

            p_info("作者: $author | 汉化组: $team");

            p_info( "分类: " . join( ' | ', @cats ) );
            for my $c (@cats) {
                p_info( "  分类反查: $c -> " . ( canonicalize_tag( $rev, $c ) || '(raw)' ) );
            }

            p_info( "标签: " . join( ' | ', @tags ) );
            for my $t (@tags) {
                p_info( "  标签反查: $t -> " . ( canonicalize_tag( $rev, $t ) || '(raw)' ) );
            }

            # 组装最终 tags（与 PicacgCN.pm 的 get_tags 一致）
            my @out;
            push @out, "picacg:$id";
            push @out, author_like_tags( $rev, $author, '作者' );

            my @cat_candidates;
            for my $c (@cats) {
                for my $p ( split m{[/／]}, ( $c // '' ) ) {
                    my $v = trim($p);
                    push @cat_candidates, $v if $v ne '';
                }
            }
            for my $c ( dedupe_values(@cat_candidates) ) {
                my $m = canonicalize_tag( $rev, $c );
                if ( $m ne '' ) { push @out, $m }
                else {
                    my $f = fold_trad($c);
                    push @out, '分类:' . ( defined $f && $f ne '' ? $f : $c );
                }
            }

            my @tag_candidates;
            for my $t (@tags) {
                for my $p ( split m{[/／]}, ( $t // '' ) ) {
                    my $v = trim($p);
                    push @tag_candidates, $v if $v ne '';
                }
            }
            for my $t ( dedupe_values(@tag_candidates) ) {
                my $m = canonicalize_tag( $rev, $t );
                if ( $m ne '' ) { push @out, $m }
                else {
                    my $f = fold_trad($t);
                    push @out, '标签:' . ( defined $f && $f ne '' ? $f : $t );
                }
            }

            push @out, '混合:女男女3P' if grep { /(?<![a-z0-9])3p(?![a-z0-9])/i } @tag_candidates;

            push @out, "页数:$comic->{pagesCount}" if defined $comic->{pagesCount};

            if ($addextra) {
                push @out, author_like_tags( $rev, $team, '汉化组' );
                push @out, "点赞:$comic->{likesCount}" if defined $comic->{likesCount};
                push @out, "上传者:$creator" if $creator ne '';
                my $date = format_date( $comic->{updated_at} );
                push @out, "更新时间:$date" if $date ne '';
            }

            if ($extract_authors) {
                push @out, extract_title_author_tags( $keyword        // '', 1 );
                push @out, extract_title_author_tags( $comic->{title} // '', 1 );
            }
            if ($extract_brackets) {
                push @out, extract_all_bracket_tags( $keyword        // '', $rev );
                push @out, extract_all_bracket_tags( $comic->{title} // '', $rev );
            }

            @out = dedupe(@out);
            my $host = $api;
            $host =~ s{^https?://}{}i;
            p_ok( "最终 tags: " . join( ', ', @out ) . ", source:$host/comics/$id" );
        }
        else { p_fail("响应中无 comic 数据") }
    }
    else {
        p_fail( "详情请求失败: " . ( $res ? "HTTP " . $res->code . ( $res->code == 401 ? " (需要登录)" : '' ) : 'no response' ) );
    }
}

if ( !$keyword && !$id ) {
    p_info("未提供 --keyword / --id，跳过在线抓取测试");
}

print "\n=== 结果: " . ( $FAIL ? "$FAIL 项失败" : "全部通过" ) . " ===\n";
exit( $FAIL ? 1 : 0 );
