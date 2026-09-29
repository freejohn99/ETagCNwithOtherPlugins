package LANraragi::Plugin::Login::PicacgLogin;

use strict;
use warnings;
no warnings 'uninitialized';
use utf8;

use Mojo::JSON qw(encode_json decode_json);
use Mojo::UserAgent;
use Mojo::Cookie::Response;
use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use MIME::Base64 qw(decode_base64);

use LANraragi::Model::Config;
use LANraragi::Utils::Logging qw(get_logger);

# 哔咔 API 签名使用的固定密钥
my $API_KEY = 'C69BAF41DA5ABD1FFEDC6D2FEA56B';
my $SECRET  = '~d}$Q7$eIni=V)9\RK/P.RM4;9[7|@/CA}b~OW!3?EV`:<>M7pddUBL5n|0/*Cn';

# 跨插件传递 token 用的伪域名 cookie
my $TOKEN_DOMAIN = 'picacg.local';
my $TOKEN_NAME   = 'picacg_token';

#Meta-information about your plugin.
sub plugin_info {

    return (
        name        => "Picacg",
        type        => "login",
        namespace   => "picacglogin",
        author      => "FreeJohn&DeepSeek",
        version     => "1.0.0",
        description =>
          "登录哔咔漫画（Picacg）帐号。登录成功后 token 会保存在 UserAgent 中，供「嗶咔漫畫_CN」元数据插件复用（哔咔大部分接口都需要登录）。",
        parameters => [
            { type => "string", desc => "帐号（哔咔用户名）" },
            { type => "string", desc => "密码" },
            { type => "string", desc => "API 地址（默认 https://picaapi.picacomic.com，末尾不要带斜杠）" },
            { type => "int",    desc => "登录 token 缓存小时数（0 表示每次都重新登录，默认 12；JWT 到期会自动缩短）", default_value => 12 },
        ]
    );

}

# 生成 32 位十六进制 nonce（等价于去掉横线的 uuid）
sub gen_nonce {
    return join '', map { sprintf '%02x', int rand 256 } 1 .. 16;
}

# 构造哔咔请求头；$path 为不带开头斜杠、含 query 的路径
sub picacg_headers {
    my ( $method, $path, $token, $time, $nonce ) = @_;

    my $data = lc( $path . $time . $nonce . uc($method) . $API_KEY );
    my $sig  = hmac_sha256_hex( $data, $SECRET );

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

# Mandatory function to be implemented by your login plugin
# Returns a Mojo::UserAgent object only!
sub do_login {

    # Login plugins only receive the parameters entered by the user.
    # 顺序必须与 plugin_info 的 parameters 一致：帐号、密码、API地址、缓存小时数
    shift;
    my ( $email, $password, $base_url, $cache_hours ) = @_;

    $base_url = 'https://picaapi.picacomic.com' if !defined $base_url || $base_url eq '';
    $base_url =~ s{/+$}{};

    $cache_hours = 12 if !defined $cache_hours || $cache_hours !~ /^\d+$/;

    my $logger = get_logger( "Picacg Login", "plugins" );
    my $ua     = Mojo::UserAgent->new;

    if ( !$email || !$password ) {
        $logger->info("No email/password provided, returning blank UserAgent.");
        return $ua;
    }

    # LRR 每次刮削都会调用 do_login，这里用 Redis 缓存 token，避免每个档案都重新登录
    my $cache_key = 'ETAGCN_LOGIN_PICACG_' . sha256_hex( join "\x1f", $base_url, $email, $password );

    if ( $cache_hours > 0 ) {
        my $cached = cache_load($cache_key);
        if ( $cached && defined $cached->{token} && $cached->{token} ne '' ) {
            set_token_cookie( $ua, $cached->{token} );
            $logger->info("使用缓存的 Picacg token（${cache_hours}h 内不重复登录）");
            return $ua;
        }
    }

    my $path    = 'auth/sign-in';
    my $time    = time;
    my $nonce   = gen_nonce();
    my %headers = picacg_headers( 'POST', $path, '', $time, $nonce );
    my $body    = encode_json( { email => $email, password => $password } );

    $logger->info("Logging in to $base_url ...");

    my $res = $ua->post( "$base_url/$path" => \%headers => $body )->result;

    if ( !$res || !$res->is_success ) {
        $logger->error(
            "Picacg 登录失败: " . ( $res ? "HTTP " . $res->code . " " . substr( $res->body, 0, 200 ) : 'no response' ) );
        return $ua;
    }

    my $json  = eval { $res->json } // {};
    my $token = $json->{data}{token} // '';

    if ( $token eq '' ) {
        $logger->error( "Picacg 登录失败：未获取到 token。响应: " . substr( $res->body, 0, 200 ) );
        return $ua;
    }

    set_token_cookie( $ua, $token );

    if ( $cache_hours > 0 ) {
        # 若 token 是 JWT，则按真实过期时间收紧缓存
        my $ttl = $cache_hours * 3600;
        my $jwt = jwt_ttl($token);
        if ( defined $jwt ) {
            $ttl = $jwt if $jwt < $ttl;
        }
        cache_store( $cache_key, { token => $token }, $ttl ) if $ttl > 0;
    }

    $logger->info("Picacg 登录成功，token 已保存。");

    return $ua;

}

sub set_token_cookie {
    my ( $ua, $token ) = @_;
    $ua->cookie_jar->add(
        Mojo::Cookie::Response->new(
            name   => $TOKEN_NAME,
            value  => $token,
            domain => $TOKEN_DOMAIN,
            path   => '/'
        )
    );
    return;
}

# 从 JWT 解析剩余有效期（秒）；不是 JWT 或无 exp 时返回 undef
sub jwt_ttl {
    my ($token) = @_;
    my @parts = split /\./, ( $token // '' );
    return undef unless @parts == 3;

    my $payload = $parts[1];
    $payload =~ tr{-_}{+/};
    $payload .= '=' x ( ( 4 - length($payload) % 4 ) % 4 );

    my $json = eval { decode_json( decode_base64($payload) ) };
    return undef unless ref $json eq 'HASH' && $json->{exp};

    return $json->{exp} - time() - 60;
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
