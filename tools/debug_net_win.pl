#!/usr/bin/env perl
# ETagCN Windows 本地调试脚本 —— 通过代理验证 E-Hentai 搜索/API 逻辑
#
# 需要 Mojo::UserAgent（与插件同款网络栈）。若缺失，先安装：
#   cpanm Mojo::UserAgent
#   或  cpan Mojo::UserAgent
#
# 用法示例（PowerShell / cmd）:
#   perl tools\debug_net_win.pl --gid 4210316 --token <gtoken>
#   perl tools\debug_net_win.pl --title "4210316-[ひし形とまる] おしかけ！爆乳ギャルハーレム性活 THE BOOK [中国翻訳] [無修正] [DL版]"
#   perl tools\debug_net_win.pl --gid 4210316 --ex --ipb_member_id <id> --ipb_pass_hash <hash>
#
# 选项:
#   --gid        画廊 gid（如 4210316）
#   --token      画廊 gtoken（画廊 URL /g/<gid>/<gtoken>/ 的第二段）
#   --title      直接用标题做文本搜索测试
#   --ex         额外测试 ExHentai（登录 + 搜索）
#   --expunged   搜索时包含已删除画廊（附加 f_sh=on）
#   --proxy      代理地址，默认 http://192.168.31.95:7890；传空串 --proxy= 可禁用代理
#   --timeout    请求超时秒数，默认 25
#   --selftest   只做离线逻辑自测（gid 提取、搜索 URL 拼接），不联网
#
# 登录（对应 LANraragi 自带登录插件 "E-Hentai"/ehlogin，基于 cookie）:
#   --ipb_member_id   ipb_member_id cookie（配合 --ipb_pass_hash 使用）
#   --ipb_pass_hash   ipb_pass_hash cookie
#   --star            star cookie（可选）
#   --igneous         igneous cookie（可选；缺省时脚本会先访问 e-hentai.org 尝试刷新）
#
# 环境变量: EH_GID / EH_TOKEN / EH_PROXY
#           EH_IPB_MEMBER_ID / EH_IPB_PASS_HASH / EH_STAR / EH_IGNEOUS
#
# 注意(便携版 Strawberry Perl 5.42): 必须把 <安装目录>\c\bin 加入 PATH，
# 否则 Net::SSLeay/IO::Socket::SSL 无法加载、HTTPS 会失败。最简单的方式是用它自带的
# 启动器运行（会自动设置 PATH）:
#   D:\Perl\5.42.3.1\portableshell.bat tools\debug_net_win.pl --selftest
#   D:\Perl\5.42.3.1\portableshell.bat tools\debug_net_win.pl --gid 4210316 --token <gtoken>

use strict;
use warnings;
use utf8;
use v5.36;    # 启用子程序签名，与 ETagCN.pm 保持一致

use Encode;
use Getopt::Long;
use IO::Socket::INET;
use Mojo::UserAgent;
use Mojo::Cookie::Response;
use Mojo::JSON;
use URI::Escape;

our $FAIL = 0;

my ( $gid, $token, $cookie, $use_ex, $expunged, $timeout, $title, $proxy, $selftest,
    $ipb_member_id, $ipb_pass_hash, $star, $igneous );
$proxy = 'http://192.168.31.95:7890';    # 默认代理，见 README/环境变量
GetOptions(
    'gid=s'             => \$gid,
    'token=s'           => \$token,
    'cookie=s'          => \$cookie,
    'ex'                => \$use_ex,
    'expunged'          => \$expunged,
    'title=s'           => \$title,
    'proxy=s'           => \$proxy,
    'timeout=i'         => \$timeout,
    'selftest'          => \$selftest,
    'ipb_member_id=s'   => \$ipb_member_id,
    'ipb_pass_hash=s'   => \$ipb_pass_hash,
    'star=s'            => \$star,
    'igneous=s'         => \$igneous,
) or die "参数错误\n";

$cookie  //= $ENV{EH_IGNEOUS};
$gid     //= $ENV{EH_GID};
$token   //= $ENV{EH_TOKEN};
$proxy   = $ENV{EH_PROXY} if defined $ENV{EH_PROXY};
$timeout //= 25;

$igneous       //= $cookie;                 # --cookie 作为 --igneous 的兼容别名
$igneous       //= $ENV{EH_IGNEOUS};
$ipb_member_id //= $ENV{EH_IPB_MEMBER_ID};
$ipb_pass_hash //= $ENV{EH_IPB_PASS_HASH};
$star          //= $ENV{EH_STAR};

$| = 1;

# Windows 控制台默认代码页多为 GBK(936)：脚本按 UTF-8 输出会乱码，命令行里的中文/日文参数
# 也会被当作字节处理。这里统一处理：@ARGV 按系统 ANSI 代码页解码；
# 输出在真实终端按控制台代码页编码，重定向/管道时用 UTF-8。
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

# ===== 登录：复刻 LANraragi 自带登录插件 EHentai.pm 的 cookie 注入 =====
sub add_cookie ( $ua, $name, $value, $domain ) {
    return if !defined $value || $value eq '';
    $ua->cookie_jar->add(
        Mojo::Cookie::Response->new(
            name   => $name,
            value  => $value,
            domain => $domain,
            path   => '/',
        )
    );
}

sub seed_login_cookies ($ua) {
    return unless $ipb_member_id && $ipb_pass_hash;
    for my $domain (qw(e-hentai.org exhentai.org)) {
        add_cookie( $ua, 'ipb_member_id', $ipb_member_id, $domain );
        add_cookie( $ua, 'ipb_pass_hash', $ipb_pass_hash, $domain );
        add_cookie( $ua, 'star',          $star,          $domain );
        add_cookie( $ua, 'igneous',       $igneous,       $domain );
        add_cookie( $ua, 'nw',            '1',            $domain );    # 跳过 offensive 警告页
    }
    add_cookie( $ua, 'ipb_coppa', '0', 'forums.e-hentai.org' );
}

# 从响应 Set-Cookie 抓取 igneous，并补种到两个域名（exhentai 需要）
sub absorb_igneous ( $ua, $res ) {
    my $found = '';
    for my $c ( @{ $res->cookies } ) {
        $found = $c->value if lc( $c->name ) eq 'igneous' && defined $c->value && $c->value ne '';
    }
    return '' unless $found;
    add_cookie( $ua, 'igneous', $found, 'e-hentai.org' );
    add_cookie( $ua, 'igneous', $found, 'exhentai.org' );
    return $found;
}

# 用 favorites.php 判定登录状态：访客会被带到登录页(name="username")，登录后是收藏页(favcat)
sub probe_login ( $ua, $domain ) {
    my $tx  = $ua->get( "https://$domain/favorites.php" );
    my $res = $tx->result;
    return ('', undef) unless $res && $res->is_success;
    my $b = $res->body;
    my ($t) = $b =~ /<title[^>]*>(.*?)<\/title>/is;
    if ( $b =~ /name="username"|act=Login&CODE=00/i || ( defined $t && $t =~ /Login/i ) ) {
        return ( 'guest', $t );
    }
    if ( $b =~ /favcat|favorites\.php\?fav=/i ) {
        return ( 'login', $t );
    }
    return ( '', $t );
}

# 取搜索结果里第一个真正的画廊链接
# 布局A(冷会话): .glink 的父级是 <a href>；布局B(有 sk 会话): .glink 是纯文本 div，
# 画廊 <a href> 在行内其它位置。这里两种都兼容，实在不行则扫描页面里第一个画廊 <a>。
sub first_gallery_link ($dom) {
    for my $el ( @{ $dom->find('.glink') } ) {
        for my $node ( $el, $el->parent ) {
            next unless $node;
            my $href = $node->attr('href') // '';
            if ( $href =~ m{hentai\.org/g/(\d+)/([0-9a-z]+)}i ) { return ( $1, $2, $href ) }
        }
    }
    for my $a ( @{ $dom->find('a') } ) {
        my $href = $a->attr('href') // '';
        if ( $href =~ m{hentai\.org/g/(\d+)/([0-9a-z]+)}i ) { return ( $1, $2, $href ) }
    }
    return ();
}

# ===== 从插件复制的 gid 提取逻辑，用于验证 ETagCN.pm 的修复 =====
sub extract_gid_from_title ($title) {

    # 前导 gid，如 "4210316-[artist] title"
    if ( $title =~ /^\s*(\d{4,})\s*-/ ) {
        return $1;
    }

    # 中括号/圆括号包裹的 gid
    if ( $title =~ /(?:\[|\()\s*(\d{4,})\s*(?:\]|\))/ ) {
        return $1;
    }

    return "";
}

print "=== ETagCN Windows 本地调试 ===\n";
p_info("Perl: $^V");
p_info("操作系统: $^O");
p_info( "代理: " . ( defined($proxy) && $proxy ne '' ? $proxy : '(禁用/直连)' ) );

for my $m (qw(Mojo::UserAgent Mojo::JSON URI::Escape IO::Socket::SSL IO::Socket::INET)) {
    if ( eval "require $m; 1" ) {
        my $v = eval "\$${m}::VERSION" // '?';
        p_ok("模块 $m 已安装 (v$v)");
    }
    else {
        p_fail("模块 $m 缺失: $@");
        p_info("可尝试: cpanm $m") if $m =~ /^Mojo/;
    }
}

# --- 0. 标题 gid 提取自测（验证 ETagCN.pm 的修复）---
print "\n--- 0. 离线逻辑自测 ---\n";
{
    my @cases = (
        [ '4210316-[ひし形とまる] おしかけ！爆乳ギャルハーレム性活 THE BOOK [中国翻訳] [無修正] [DL版]', '4210316' ],
        [ '[4210316] Some title',   '4210316' ],
        [ 'Some title (4210316)',   '4210316' ],
        [ 'No gid here',            '' ],
        [ '2024-some unrelated',    '2024' ],
    );
    for my $c (@cases) {
        my ( $in, $want ) = @$c;
        my $got = extract_gid_from_title($in);
        my $mark = ( $got eq $want ) ? 'OK ' : 'BAD';
        printf "[%s] gid   want=%-8s got=%-8s <- %s\n", $mark, "'$want'", "'$got'", $in;
        $FAIL++ unless $got eq $want;
    }

    # 验证“gid 搜索 URL”的拼接方式（与插件一致）
    my $gid_url = 'https://e-hentai.org/?f_search=' . uri_escape_utf8( 'gid:' . extract_gid_from_title($cases[0][0]) );
    my $want_url = 'https://e-hentai.org/?f_search=gid%3A4210316';
    printf "[%s] url   want=%s got=%s\n", ( $gid_url eq $want_url ? 'OK ' : 'BAD' ), $want_url, $gid_url;
    $FAIL++ unless $gid_url eq $want_url;

    # 验证文本搜索前会剥离前导 gid（ETagCN.pm 里的 s/^\s*\d{4,}\s*-\s*//）
    my $search_title = $cases[0][0];
    $search_title =~ s/^\s*\d{4,}\s*-\s*//;
    my $want_title = '[ひし形とまる] おしかけ！爆乳ギャルハーレム性活 THE BOOK [中国翻訳] [無修正] [DL版]';
    printf "[%s] strip want=%s\n     got =%s\n", ( $search_title eq $want_title ? 'OK ' : 'BAD' ), $want_title, $search_title;
    $FAIL++ unless $search_title eq $want_title;
}

if ($selftest) {
    print "\n=== 离线自测结果: " . ( $FAIL ? "$FAIL 项失败" : "全部通过" ) . " ===\n";
    exit( $FAIL ? 1 : 0 );
}

# --- 1. DNS 解析 ---
print "\n--- 1. DNS 解析 ---\n";
for my $host (qw(e-hentai.org exhentai.org api.e-hentai.org)) {
    my ( $name, $aliases, $type, $len, @addr ) = gethostbyname($host);
    if (@addr) {
        p_ok( "$host -> " . join( ',', map { join( '.', unpack( 'C4', $_ ) ) } @addr ) );
    }
    else {
        p_fail("$host 无法解析 ($!)");
    }
}

# --- 2. 代理 TCP 连通性 ---
print "\n--- 2. 代理连通性 ---\n";
if ( defined($proxy) && $proxy ne '' ) {
    my ( $phost, $pport ) = $proxy =~ m{^https?://\[?([^/\]:]+)\]?:(\d+)};
    if ($phost) {
        my $sock = IO::Socket::INET->new(
            PeerHost => $phost,
            PeerPort => $pport,
            Timeout  => $timeout,
            Proto    => 'tcp',
        );
        if ($sock) {
            p_ok("可连接代理 $phost:$pport");
            close $sock;
        }
        else {
            p_fail("无法连接代理 $phost:$pport ($!)");
            p_info("请确认代理已启动、端口正确，且允许局域网访问");
        }
    }
    else {
        p_warn("无法从 '$proxy' 解析出主机/端口，跳过 TCP 检查");
    }
}
else {
    p_info("未使用代理，跳过");
}

my $ua = Mojo::UserAgent->new( timeout => $timeout, max_redirects => 5 );
$ua->insecure(1);    # 忽略证书错误，便于区分“证书问题”和“网络不通”
if ( defined($proxy) && $proxy ne '' ) {
    $ua->proxy->http($proxy)->https($proxy);
    p_info("Mojo 已设置 http/https 代理: $proxy");
}

# 注入登录 cookie（与 LRR ehlogin 插件一致）
seed_login_cookies($ua);
if ( $ipb_member_id && $ipb_pass_hash ) {
    my @extra = ();
    push @extra, 'star'    if $star;
    push @extra, 'igneous' if $igneous;
    p_ok( "已注入登录 cookie: ipb_member_id=$ipb_member_id" . ( @extra ? " (+" . join( '+', @extra ) . ")" : '' ) );
    p_info("未提供 igneous，稍后将访问 e-hentai.org 尝试刷新") unless $igneous;
}
elsif ($igneous) {
    p_info("仅提供 igneous，未提供 ipb_member_id/ipb_pass_hash");
}
else {
    p_info("未提供登录 cookie，将以访客身份访问");
}

# --- 3. 直连 e-hentai.org ---
print "\n--- 3. 访问 e-hentai.org ---\n";
{
    my $tx  = $ua->get('https://e-hentai.org/');
    my $res = $tx->result;
    if ( !$res || !$res->is_success ) {
        my $err = $tx->error;
        p_fail( "GET https://e-hentai.org/ 失败: " . ( $err ? $err->{message} : 'unknown' ) );
        p_warn( "若有证书错误，可临时设置环境变量 MOJO_TLS_VERIFY=0，或确认代理支持 HTTPS CONNECT" );
    }
    else {
        p_ok( "GET https://e-hentai.org/ -> HTTP " . $res->code . ", " . length( $res->body ) . " bytes" );
        my $body = $res->body;
        if ( $body eq '' ) {
            p_fail("响应体为空：登录 cookie 可能已过期（插件会因此报错）");
        }
        if ( $body =~ /Your IP address has been/i ) {
            p_fail("检测到 'Your IP address has been ... banned'：IP 被 EH 临时封禁");
        }
        elsif ( $body =~ /<title[^>]*>(.*?)<\/title>/is ) {
            p_info("页面标题: $1");
        }

        # 登录状态判定（用 favorites.php，访客会落到登录页）
        if ( $ipb_member_id && $ipb_pass_hash ) {
            my ( $state, $t ) = probe_login( $ua, 'e-hentai.org' );
            if    ( $state eq 'login' ) { p_ok("登录状态: 已登录 (e-hentai.org)") }
            elsif ( $state eq 'guest' ) { p_warn("登录状态: 未登录，cookie 可能无效 (title=" . ( $t // '' ) . ")") }
            else                        { p_info("登录状态: 无法判定") }
        }

        # 记录 e-hentai 下发的 igneous，供 ExHentai 使用
        my $ig = absorb_igneous( $ua, $res );
        if ($ig) { $igneous = $ig; p_ok( "从 e-hentai 获得 igneous (len=" . length($ig) . ")" ) }
    }
}

# --- 4. EH API ---
print "\n--- 4. E-H API (api.e-hentai.org) ---\n";
if ( $gid && $token ) {
    my $atx = $ua->post(
        'https://api.e-hentai.org/api.php' => json => {
            method    => 'gdata',
            gidlist   => [ [ $gid, $token ] ],
            namespace => 1,
        }
    );
    my $ares = $atx->result;
    if ( !$ares || !$ares->is_success ) {
        my $err = $atx->error;
        p_fail( "API POST 失败: " . ( $err ? $err->{message} : 'unknown' ) );
    }
    else {
        my $j = eval { $ares->json } // {};
        if (   ref $j->{gmetadata} eq 'ARRAY'
            && @{ $j->{gmetadata} }
            && $j->{gmetadata}[0]{title} )
        {
            p_ok( "API gdata 成功: " . $j->{gmetadata}[0]{title} );
        }
        elsif ( $j->{error} ) {
            p_fail("API 返回错误: $j->{error}");
        }
        else {
            p_warn( "API 返回异常内容: " . substr( $ares->body, 0, 200 ) );
        }
    }
}
else {
    p_info("未提供 --gid/--token，仅测试 API 主机连通性");
    my $tx  = $ua->get('https://api.e-hentai.org/');
    my $res = $tx->result;
    if ($res) { p_ok( "GET api.e-hentai.org -> HTTP " . $res->code ) }
    else      { p_fail( "无法连接 api.e-hentai.org: " . ( $tx->error ? $tx->error->{message} : 'unknown' ) ) }
}

# --- 5. 搜索页 + .glink 解析（模拟插件 lookup_gallery）---
print "\n--- 5. 搜索页解析 ---\n";
{
    # 与插件一致：优先用 gid 搜索，否则用标题
    my $q = $gid ? "gid:$gid" : ( $title // '' );
    if ( $q ne '' ) {
        my $surl = 'https://e-hentai.org/?advsearch=1&f_sfu=on&f_sft=on&f_sfl=on'
                 . '&f_search=' . uri_escape_utf8($q);
        $surl .= '&f_sh=on' if $expunged;
        p_info("搜索 URL: $surl");
        my $tx  = $ua->get($surl);
        my $res = $tx->result;
        if ( !$res || !$res->is_success ) {
            p_fail( "搜索请求失败: " . ( $tx->error ? $tx->error->{message} : 'unknown' ) );
        }
        else {
            my ( $rgid, $rtoken, $href ) = first_gallery_link( $res->dom );
            if ($rgid) {
                p_ok("找到首个结果: $href");
                p_info("解析出 gid=$rgid token=$rtoken");
            }
            else {
                my ( $t ) = $res->body =~ /<title[^>]*>(.*?)<\/title>/is;
                my $n = scalar @{ $res->dom->find('.glink') };
                p_info( "响应诊断: HTTP " . $res->code . ", " . length( $res->body ) . " bytes, .glink=" . $n . ", title=" . ( $t // '' ) );
                p_fail("未找到画廊链接（无匹配结果，或页面结构/登录问题）");
                p_fail("页面提示 IP 已被封禁") if $res->body =~ /Your IP address has been/i;
                p_fail("页面提示请求过多/限流") if $res->body =~ /excessive|too many|slow down/i;
                if ( $res->body =~ /not found|No results/i ) { p_info("页面提示无结果") }
                if ( $res->body =~ /Log ?in|Login/i )        { p_info("页面可能要求登录") }
            }
        }
    }
    else {
        p_info("未提供 --gid/--title，跳过搜索测试");
    }
}

# --- 6. ExHentai（登录 + 搜索）---
if ($use_ex) {
    print "\n--- 6. ExHentai (cookie 登录 + 搜索) ---\n";

    if ( !$ipb_member_id && !$igneous ) {
        p_warn("未提供登录 cookie（--ipb_member_id/--ipb_pass_hash 或 --igneous），ExHentai 很可能返回 Sad Panda");
    }

    # 若只有 ipb cookie 而没有 igneous，先访问 e-hentai.org 抓取 Set-Cookie 里的 igneous
    if ( $ipb_member_id && $ipb_pass_hash && !$igneous ) {
        p_info("尝试从 e-hentai.org 刷新 igneous ...");
        my $tx  = $ua->get('https://e-hentai.org/');
        my $res = $tx->result;
        if ( $res && $res->is_success ) {
            my $ig = absorb_igneous( $ua, $res );
            if ($ig) { $igneous = $ig; p_ok( "刷新到 igneous (len=" . length($ig) . ")" ) }
            else     { p_warn("e-hentai 未下发 igneous，ExHentai 可能失败") }
        }
        else {
            p_fail( "刷新 igneous 时请求 e-hentai.org 失败: " . ( $tx->error ? $tx->error->{message} : 'unknown' ) );
        }
    }

    # ExHentai 首页
    {
        my $tx  = $ua->get('https://exhentai.org/');
        my $res = $tx->result;
        if ( !$res ) {
            p_fail( "ExHentai 请求失败: " . ( $tx->error ? $tx->error->{message} : 'unknown' ) );
        }
        elsif ( $res->body =~ /Sad Panda|sadpanda/i ) {
            p_fail("ExHentai 返回 Sad Panda：cookie 无效/缺失，或出口 IP 被限制");
        }
        elsif ( $res->body eq '' ) {
            p_fail("ExHentai 返回空响应：通常表示 cookie 失效");
        }
        else {
            p_ok( "ExHentai 可访问 (HTTP " . $res->code . ", " . length( $res->body ) . " bytes)" );
            absorb_igneous( $ua, $res );
            if ( $ipb_member_id && $ipb_pass_hash ) {
                my ( $state, $t ) = probe_login( $ua, 'exhentai.org' );
                if    ( $state eq 'login' ) { p_ok("登录状态: 已登录 (exhentai.org)") }
                elsif ( $state eq 'guest' ) { p_warn("登录状态: 未登录 (exhentai.org) (title=" . ( $t // '' ) . ")") }
                else                        { p_info("登录状态: 无法判定") }
            }
        }
    }

    # ExHentai 搜索（与插件 lookup_gallery 同逻辑）
    my $exq = $gid ? "gid:$gid" : ( $title // '' );
    if ( $exq ne '' ) {
        my $surl = 'https://exhentai.org/?advsearch=1&f_sfu=on&f_sft=on&f_sfl=on'
                 . '&f_search=' . uri_escape_utf8($exq);
        $surl .= '&f_sh=on' if $expunged;
        p_info("ExHentai 搜索 URL: $surl");
        my $tx  = $ua->get($surl);
        my $res = $tx->result;
        if ( !$res || !$res->is_success ) {
            p_fail( "ExHentai 搜索失败: " . ( $tx->error ? $tx->error->{message} : 'unknown' ) );
        }
        else {
            my ( $rgid, $rtoken, $href ) = first_gallery_link( $res->dom );
            if ($rgid) {
                p_ok("ExHentai 找到首个结果: $href");
                p_info("解析出 gid=$rgid token=$rtoken");
            }
            else {
                p_fail("ExHentai 未找到画廊链接");
                if    ( $res->body =~ /Sad Panda|sadpanda/i )       { p_fail("页面为 Sad Panda：登录/IGNEOUS 失败") }
                elsif ( $res->body =~ /Your IP address has been/i ) { p_fail("页面提示 IP 被封禁") }
                elsif ( $res->body =~ /No hits found|No results/i )  { p_info("页面提示无搜索结果") }
            }
        }
    }
    else {
        p_info("未提供 --gid/--title，跳过 ExHentai 搜索");
    }
}

print "\n=== 结果: " . ( $FAIL ? "$FAIL 项失败" : "全部通过" ) . " ===\n";
exit( $FAIL ? 1 : 0 );
