#!/usr/bin/env perl
# docker_check_wp.pl —— 在 LANraragi 容器内，按“真实插件逻辑”测试紳士漫畫/哔咔漫画插件
#
# 它直接加载插件的 .pm，并调用与 LRR 完全相同的：
#   LANraragi::Model::Plugins::exec_login_plugin  ->  $LoginPkg->do_login(...)
#   LANraragi::Model::Plugins::exec_metadata_plugin ->  $MetaPkg->get_tags(\%lrr_info, ...)
# 因此会走插件内的 db.text.json 反查、Redis 登录缓存、picacg token 的 cookie 传递等逻辑。
#
# 容器内用法（模块目录见官方镜像）:
#   eval "$(perl -Mlocal::lib=/home/koyomi/perl5)"
#   perl /tmp/docker_check_wp.pl --plugin wnacgcn --dir /tmp/plugins \
#        --title "4210316-[artist] 作品名" \
#        --domain www.wnacg.com --username <user> --password <pass> --addextra
#
#   perl /tmp/docker_check_wp.pl --plugin picacgcn --dir /tmp/plugins \
#        --title "作品名" \
#        --api https://picaapi.picacomic.com --email <mail> --password <pass> --addextra
#
# 也可用 oneshot（等价于 LRR 编辑页里运行插件时填的 URL/ID）:
#   perl /tmp/docker_check_wp.pl --plugin wnacgcn --dir /tmp/plugins \
#        --oneshot "https://www.wnacg.com/photos-index-page-1-aid-123456.html" --domain www.wnacg.com
#
# 密码等敏感参数建议用环境变量传入（避免留在 shell 历史）:
#   WP_USERNAME / WP_EMAIL / WP_PASSWORD
#
# 选项:
#   --plugin        必填，wnacgcn 或 picacgcn
#   --dir           插件 .pm 所在目录，默认 /tmp/plugins
#   --title         存档标题（用于搜索匹配）
#   --oneshot       精确 URL 或 ID（优先于 --title）
#   --domain        wnacg 域名，默认 www.wnacg.com（必须带 www）
#   --api           picacg API 地址，默认 https://picaapi.picacomic.com
#   --username      紳士漫畫用户名（或 WP_USERNAME）
#   --email         哔咔帐号（或 WP_EMAIL）
#   --password      密码（或 WP_PASSWORD）
#   --cache-hours   登录缓存小时数（0=每次都登录；不填用插件默认）
#   --savetitle     使用搜刮到的标题
#   --addextra      获取额外元数据
#   --prefer-title-id 优先使用标题里的 ID
#   --no-reverse    关闭 db.text.json 反查
#   --db-path       db.text.json 路径（不填用插件默认）
#   --timeout       预留参数，供后续使用

use strict;
use warnings;
use utf8;
use v5.36;

use Getopt::Long;
use Mojo::UserAgent;

our $FAIL = 0;
$| = 1;
binmode( STDOUT, ':encoding(UTF-8)' );

sub p_ok   { print "[ OK ]   @_\n" }
sub p_warn { print "[WARN]   @_\n" }
sub p_fail { $FAIL++; print "[FAIL]   @_\n" }
sub p_info { print "[INFO]   @_\n" }

my ( $plugin, $dir, $title, $oneshot, $domain, $api, $username, $email, $password,
    $cache_hours, $savetitle, $addextra, $prefer_title_id, $no_reverse, $db_path, $timeout );

$dir     = '/tmp/plugins';
$api     = 'https://picaapi.picacomic.com';
$timeout = 25;

GetOptions(
    'plugin=s'         => \$plugin,
    'dir=s'            => \$dir,
    'title=s'          => \$title,
    'oneshot=s'        => \$oneshot,
    'domain=s'         => \$domain,
    'api=s'            => \$api,
    'username=s'       => \$username,
    'email=s'          => \$email,
    'password=s'       => \$password,
    'cache-hours=i'    => \$cache_hours,
    'savetitle'        => \$savetitle,
    'addextra'         => \$addextra,
    'prefer-title-id'  => \$prefer_title_id,
    'no-reverse'       => \$no_reverse,
    'db-path=s'        => \$db_path,
    'timeout=i'        => \$timeout,
) or die "参数错误\n";

$dir =~ s{/+$}{};
$plugin //= '';

$username //= $ENV{WP_USERNAME};
$email    //= $ENV{WP_EMAIL};
$password //= $ENV{WP_PASSWORD};

$domain //= 'www.wnacg.com';

my %MAP = (
    wnacgcn => {
        login_pkg  => 'LANraragi::Plugin::Login::WnacgLogin',
        meta_pkg   => 'LANraragi::Plugin::Metadata::WnacgCN',
        login_file => "$dir/WnacgLogin.pm",
        meta_file  => "$dir/WnacgCN.pm",
        login_args => sub { ( $domain, $username, $password, $cache_hours ) },
        meta_args  => sub { ( $domain, $savetitle, $addextra, $prefer_title_id, ( $no_reverse ? 0 : 1 ), $db_path ) },
    },
    picacgcn => {
        login_pkg  => 'LANraragi::Plugin::Login::PicacgLogin',
        meta_pkg   => 'LANraragi::Plugin::Metadata::PicacgCN',
        login_file => "$dir/PicacgLogin.pm",
        meta_file  => "$dir/PicacgCN.pm",
        login_args => sub { ( $email, $password, $api, $cache_hours ) },
        meta_args  => sub { ( $api, $savetitle, $addextra, $prefer_title_id, ( $no_reverse ? 0 : 1 ), $db_path ) },
    },
);

my $cfg = $MAP{$plugin};
die "未知 --plugin '$plugin'（支持：wnacgcn / picacgcn）\n" unless $cfg;

for my $f ( $cfg->{login_file}, $cfg->{meta_file} ) {
    die "找不到插件文件: $f\n" unless -f $f;
}

# 直接加载真实插件（与 LRR 使用同一份代码）
require $cfg->{login_file};
require $cfg->{meta_file};

print "=== Docker 插件逻辑测试: $plugin ===\n";
p_info( "登录插件:   $cfg->{login_pkg}" );
p_info( "元数据插件: $cfg->{meta_pkg}" );
p_info( "插件目录:   $dir" );

# 1) 登录：与 exec_login_plugin 一致，登录插件只返回 Mojo::UserAgent
my $ua;
eval { $ua = $cfg->{login_pkg}->do_login( $cfg->{login_args}->() ); 1 }
  or do { p_fail("do_login 失败: $@"); exit 1 };

if ( ref($ua) eq 'Mojo::UserAgent' ) {
    p_ok("do_login 返回 Mojo::UserAgent");
}
else {
    p_fail( "do_login 未返回 Mojo::UserAgent: " . ( ref($ua) || $ua ) );
    exit 1;
}

# 2) 元数据：复刻 exec_metadata_plugin 构造的 %lrr_info，再调用真实 get_tags
my %info = (
    archive_id     => 'DOCKER_TEST',
    archive_title  => ( $title // '' ),
    existing_tags  => '',
    thumbnail_hash => '',
    file_path      => '',
    user_agent     => $ua,
    oneshot_param  => ( $oneshot // '' ),
);

my %res;
eval { %res = $cfg->{meta_pkg}->get_tags( \%info, $cfg->{meta_args}->() ); 1 }
  or do { p_fail("get_tags 失败: $@"); exit 1 };

if ( $res{error} ) {
    p_fail( "插件返回错误: $res{error}" );
    exit 1;
}

p_ok( "tags: " . ( $res{tags} // '' ) );
p_info( "title: " . ( ( $res{title} // '' ) ne '' ? $res{title} : '(未设置)' ) );
p_info( "summary: " . ( ( $res{summary} // '' ) ne '' ? substr( $res{summary}, 0, 120 ) . '...' : '(未设置)' ) );

print "\n=== 结果: " . ( $FAIL ? "$FAIL 项失败" : "全部通过" ) . " ===\n";
exit( $FAIL ? 1 : 0 );
