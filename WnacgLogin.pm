package LANraragi::Plugin::Login::WnacgLogin;

use strict;
use warnings;
no warnings 'uninitialized';
use utf8;

use URI::Escape;
use Mojo::UserAgent;
use Mojo::Cookie::Response;
use Mojo::JSON qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);
use LANraragi::Model::Config;
use LANraragi::Utils::Logging qw(get_logger);

# 浏览器 UA：wnacg 对默认 UA 有时会返回异常页面
my $BROWSER_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

#Meta-information about your plugin.
sub plugin_info {

    return (
        name        => "紳士漫畫",
        type        => "login",
        namespace   => "wnacglogin",
        author      => "FreeJohn&DeepSeek",
        version     => "1.0.1",
        description =>
          "登录紳士漫畫（wnacg）。登录成功后 cookie 会保存在 UserAgent 中，供「紳士漫畫_CN」元数据插件复用（部分受限内容需要登录）。",
        parameters => [
            { type => "string", desc => "自定义域名（默认 www.wnacg.com，必须带 www，末尾不要带斜杠）" },
            { type => "string", desc => "用户名" },
            { type => "string", desc => "密码" },
            { type => "int",    desc => "登录会话缓存小时数（0 表示每次都重新登录，默认 24）", default_value => 24 },
        ]
    );

}

# Mandatory function to be implemented by your login plugin
# Returns a Mojo::UserAgent object only!
sub do_login {

    # Login plugins only receive the parameters entered by the user.
    shift;
    my ( $domain, $username, $password, $cache_hours ) = @_;

    $domain = 'www.wnacg.com' if !defined $domain || $domain eq '';
    $domain =~ s{^https?://}{}i;
    $domain =~ s{/+$}{};

    $cache_hours = 24 if !defined $cache_hours || $cache_hours !~ /^\d+$/;

    my $logger = get_logger( "Wnacg Login", "plugins" );
    my $ua     = Mojo::UserAgent->new;

    if ( !$username || !$password ) {
        $logger->info("No username/password provided, returning blank UserAgent.");
        return $ua;
    }

    # LRR 每次刮削都会调用 do_login，这里用 Redis 缓存登录会话，避免每个档案都重新登录
    my $cache_key = 'ETAGCN_LOGIN_WNACG_' . sha256_hex( join "\x1f", $domain, $username, $password );

    if ( $cache_hours > 0 ) {
        my $cached = cache_load($cache_key);
        if ( $cached && ref $cached->{cookies} eq 'ARRAY' && @{ $cached->{cookies} } ) {
            for my $c ( @{ $cached->{cookies} } ) {
                add_login_cookie( $ua, $c->{name}, $c->{value}, ( $c->{domain} || $domain ) );
            }
            $logger->info("使用缓存的登录会话（${cache_hours}h 内不重复登录）");
            return $ua;
        }
    }

    my $url = "https://$domain/users-check_login.html";
    $logger->info("Logging in to $domain as $username ...");

    my $res = $ua->post(
        $url => {
            'Content-Type' => 'application/x-www-form-urlencoded',
            'User-Agent'   => $BROWSER_UA,
            'Referer'      => "https://$domain/",
        } => 'login_name=' . uri_escape_utf8($username) . '&login_pass=' . uri_escape_utf8($password)
    )->result;

    if ( !$res || !$res->is_success ) {
        $logger->error( "登录请求失败: " . ( $res ? "HTTP " . $res->code : 'no response' ) );
        return $ua;
    }

    my $json = eval { $res->json } // {};
    if ( ( $json->{html} // '' ) =~ /登錄成功|登录成功/ ) {
        $logger->info("Login succeeded for $domain.");

        if ( $cache_hours > 0 ) {
            my @ck;
            for my $c ( @{ $res->cookies } ) {
                my $v = $c->value;
                next if !defined $v || $v eq '';
                push @ck, { name => $c->name, value => $v, domain => ( $c->domain || $domain ) };
            }
            cache_store( $cache_key, { cookies => \@ck }, $cache_hours * 3600 ) if @ck;
        }
    }
    else {
        my $msg = $json->{html} // $res->body;
        $msg =~ s/\s+/ /g;
        $logger->error( "登录失败: " . substr( $msg, 0, 200 ) );
    }

    # 无论成败都返回 UA：wnacg 的搜索/详情页是公开的，登录失败不应阻断元数据插件。
    return $ua;

}

sub add_login_cookie {
    my ( $ua, $name, $value, $domain ) = @_;
    return if !defined $name || $name eq '' || !defined $value || $value eq '';
    $domain = 'www.wnacg.com' if !defined $domain || $domain eq '';
    $ua->cookie_jar->add(
        Mojo::Cookie::Response->new(
            name   => $name,
            value  => $value,
            domain => $domain,
            path   => '/'
        )
    );
    return;
}

# Redis 缓存（LRR 自带 Redis）；任何异常都静默降级为“不缓存”
sub cache_load {
    my ($key) = @_;
    my $data;
    eval {
        my $redis = LANraragi::Model::Config->get_redis;
        my $raw   = $redis->get($key);
        $redis->quit;
        $data = decode_json($raw) if defined $raw && $raw ne '';
        1;
    } or return undef;
    return $data;
}

sub cache_store {
    my ( $key, $data, $ttl ) = @_;
    return unless $ttl && $ttl > 0;
    eval {
        my $json = encode_json($data);
        utf8::encode($json) if utf8::is_utf8($json);
        my $redis = LANraragi::Model::Config->get_redis;
        $redis->set( $key, $json );
        $redis->expire( $key, int($ttl) );
        $redis->quit;
        1;
    };
    return;
}

1;
