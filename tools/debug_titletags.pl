#!/usr/bin/env perl
# 文件名/标题标签提取 —— 本地调试脚本（对应插件 TitleTagsCN.pm，纯离线）
#
# 用法（PowerShell / cmd）:
#   perl tools\debug_titletags.pl --selftest
#   perl tools\debug_titletags.pl --title "[らぼまじ! (武田あらのぶ)] 作品名"
#   perl tools\debug_titletags.pl --title "作品名 [中国翻訳] (C97)" --extract-brackets
#
# 选项:
#   --selftest          只做离线逻辑自测，不联网
#   --title             要解析的标题/文件名
#   --extract-authors   提取作者/艺术家/团队（默认开）
#   --extract-brackets  提取所有括号内容为标签（默认关）

use strict;
use warnings;
use utf8;
use v5.36;

use Encode;
use Getopt::Long;

our $FAIL = 0;
$| = 1;

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

my ( $selftest, $title, $extract_authors, $extract_brackets );
$extract_authors  = 1;
$extract_brackets = 0;

GetOptions(
    'selftest'          => \$selftest,
    'title=s'           => \$title,
    'extract-authors!'  => \$extract_authors,
    'extract-brackets!' => \$extract_brackets,
) or die "参数错误\n";

######
## 与 TitleTagsCN.pm 相同的纯函数
######

sub trim ($s) {
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub dedupe_exact (@list) {
    my ( %seen, @out );
    for my $x (@list) {
        next if !defined $x;
        my $t = trim($x);
        next if $t eq '';
        next if $seen{ lc($t) }++;
        push @out, $t;
    }
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

my %LANG_CN = ( chinese => '汉语', japanese => '日语', english => '英语', korean => '韩语' );

sub extract_all_bracket_tags ($title) {
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
        $add->( "语言:" . ( $LANG_CN{$lang} // $lang ) ) if $lang ne '';
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

######
## 自测 / 运行
######

print "=== 文件名/标题标签提取调试 ===\n";

if ($selftest) {
    print "--- 离线逻辑自测 ---\n";
    my @cases = (
        [ '4210316-[らぼまじ! (武田あらのぶ)] 作品', '作者:らぼまじ! (武田あらのぶ)' ],
        [ '4210316-[らぼまじ! (武田あらのぶ)] 作品', '团队:らぼまじ!' ],
        [ '4210316-[らぼまじ! (武田あらのぶ)] 作品', '艺术家:武田あらのぶ' ],
        [ '[グループ名] 作品',                       '作者:グループ名' ],
        [ '[グループ名] 作品',                       '团队:グループ名' ],
    );
    for my $c (@cases) {
        my ( $in, $want ) = @$c;
        my @got = extract_title_author_tags( $in, 1 );
        my $ok  = ( grep { $_ eq $want } @got ) ? 'OK ' : 'BAD';
        printf "[%s] %-14s <- %s\n", $ok, $want, $in;
        $FAIL++ unless grep { $_ eq $want } @got;
    }
    {
        my @b  = extract_all_bracket_tags('[中国翻訳] 作品 (C97)');
        my $ok = ( grep { $_ eq '语言:汉语' } @b ) ? 'OK ' : 'BAD';
        printf "[%s] 语言:汉语 <- [中国翻訳] 作品 (C97)  (%s)\n", $ok, join( ', ', @b );
        $FAIL++ unless grep { $_ eq '语言:汉语' } @b;
    }
    print "\n=== 自测结果: " . ( $FAIL ? "$FAIL 项失败" : "全部通过" ) . " ===\n";
    exit( $FAIL ? 1 : 0 );
}

if ( !defined $title || $title eq '' ) {
    p_warn("未提供 --title，仅运行了自测/帮助；示例：--title \"[らぼまじ! (武田あらのぶ)] 作品名\"");
    exit 0;
}

my @out;
push @out, extract_title_author_tags( $title, 1 ) if $extract_authors;
push @out, extract_all_bracket_tags($title)       if $extract_brackets;
@out = dedupe_exact(@out);

p_info("标题: $title");
p_info( "作者提取: " . ( $extract_authors  ? '开启' : '关闭' ) );
p_info( "括号提取: " . ( $extract_brackets ? '开启' : '关闭' ) );
p_ok( "tags: " . join( ', ', @out ) );

print "\n=== 结果: " . ( $FAIL ? "$FAIL 项失败" : "全部通过" ) . " ===\n";
exit( $FAIL ? 1 : 0 );
