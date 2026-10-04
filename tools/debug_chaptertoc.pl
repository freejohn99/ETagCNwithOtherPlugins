#!/usr/bin/env perl
# 子目录章节 ToC —— 本地离线调试脚本（对应插件 ChapterTOC.pm）
#
# 用法（PowerShell / cmd，perl 路径按需替换）:
#   perl tools\debug_chaptertoc.pl --selftest
#   perl tools\debug_chaptertoc.pl --zip "D:\comic.zip"
#   perl tools\debug_chaptertoc.pl --zip "D:\comic.zip" --mode auto --list
#   perl tools\debug_chaptertoc.pl --raw-list tools\paths.txt --mode first --json
#
# 说明:
#   - 页码与 LANraragi 阅读器完全一致：脚本复刻了 LRR 的 get_filelist 排序
#     （自然排序 expand + 封面提前 / 版权页后置），并给出每个章节的起始页。
#   - 章节起始页 = 该目录下第一张图片在阅读顺序中的页码（1 起）。
#   - 生成的 JSON 即 LRR 存在 redis 字段 toc 中的格式：{ "页码": "章节名" }。

use strict;
use warnings;
use utf8;
use v5.36;
no warnings 'once';

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

######
## 与 LANraragi 保持一致的排序 / 过滤规则（复刻自 LANraragi::Utils::Archive/Generic）
######

sub is_image {
    return ( $_[0] // '' ) =~ /^.+\.(?:png|jpg|gif|bmp|jpeg|jfif|webp|avif|heif|heic|jxl|)$/i;
}

# 复刻 LANraragi::Utils::Redis::redis_decode —— 存档内文件名是原始字节，
# LRR 在展示/读取前用该函数解码；章节名也必须走同样的解码，否则会双重编码成乱码。
sub redis_decode {
    my ($data) = @_;
    eval { $data = Encode::decode_utf8( $data, Encode::FB_CROAK ) };
    eval { $data = Encode::decode_utf8( $data, Encode::FB_CROAK ) };
    return $data;
}

sub expand {
    my $file = shift;
    $file =~ s{(\d+)}{sprintf "%04d", $1}eg;
    return lc($file);
}

# 复刻 get_filelist 的排序与封面/版权页重排。
sub lr_sort {
    my @files = @_;
    @files = sort { expand($a) cmp expand($b) } @files;

    my @cover_pages  = grep { /^(?!.*(back|end|rear|recover|discover)).*cover.*/i } @files;
    my @credit_pages = grep { /^end_card_save_file|notes\.[^\.]*$|note\.[^\.]*$|^artist_info|credit|^999.*/i } @files;

    my %credit_hash = map { $_ => 1 } @credit_pages;
    my %cover_hash  = map { $_ => 1 } @cover_pages;
    my @other_pages = grep { !$credit_hash{$_} && !$cover_hash{$_} } @files;

    return ( @cover_pages, @other_pages, @credit_pages );
}

######
## 与 ChapterTOC.pm 完全相同的章节检测逻辑（请保持同步）
######

sub norm_path ($p) {
    ( my $x = $p // '' ) =~ tr{\\}{/};
    return $x;
}

sub dir_segments ($p) {
    my @segs = split m{/}, norm_path($p), -1;
    pop @segs if @segs;
    return @segs;
}

sub dir_full ($p) {
    my @d = dir_segments($p);
    return @d ? join( '/', @d ) : '';
}

sub dir_at ( $p, $depth ) {
    my @d = dir_segments($p);
    return '' if @d < $depth;
    return join( '/', @d[ 0 .. $depth - 1 ] );
}

sub choose_depth ( $files, $mode ) {
    my $max = 0;
    for my $f (@$files) {
        my @d = dir_segments($f);
        $max = scalar @d if scalar @d > $max;
    }
    return undef if $max < 1;
    return 1 if $mode eq 'first';
    for my $d ( 1 .. $max ) {
        my %set;
        for my $f (@$files) {
            my $k = dir_at( $f, $d );
            $set{$k} = 1 if $k ne '';
        }
        return $d if scalar( keys %set ) >= 2;
    }
    return $max;
}

sub common_prefix_len ($keys) {
    return 0 unless @$keys >= 2;
    my @split = map { [ split m{/}, $_, -1 ] } @$keys;
    my $n     = 0;
    while (1) {
        my $seg = $split[0][$n];
        last unless defined $seg;
        my $all = 1;
        for my $s (@split) {
            if ( !defined $s->[$n] || $s->[$n] ne $seg ) { $all = 0; last; }
        }
        last unless $all;
        $n++;
    }
    my $min = ( sort { $a <=> $b } map { scalar @$_ } @split )[0];
    $n = $min - 1 if $n >= $min;
    $n = 0       if $n < 0;
    return $n;
}

sub strip_prefix ( $key, $n ) {
    return $key unless $n;
    my @segs = split m{/}, $key, -1;
    return join( '/', @segs[ $n .. $#segs ] );
}

sub trim_title ($s) {
    ( my $x = $s // '' ) =~ s/^\s+|\s+$//g;
    $x =~ s{^/+|/+$}{}g;
    return $x;
}

# 返回 ( { 起始页 => 章节名 }, 章节数 )
sub detect_chapters ( $files, $mode ) {
    my @paths = map { redis_decode($_) } @$files;

    my $depth = ( $mode eq 'full' ) ? undef : choose_depth( \@paths, $mode );

    return ( undef, 0 ) if $mode ne 'full' && !defined $depth;

    my ( %seen, %page_key );
    my $index = 0;
    for my $f (@paths) {
        $index++;
        my $key = ( $mode eq 'full' ) ? dir_full($f) : dir_at( $f, $depth );
        next if $key eq '';
        next if $seen{$key}++;
        $page_key{$index} = $key;
    }

    return ( undef, 0 ) unless %page_key;

    my $strip = common_prefix_len( [ values %page_key ] );

    my %toc;
    for my $page ( keys %page_key ) {
        my $title = trim_title( strip_prefix( $page_key{$page}, $strip ) );
        $title = trim_title( $page_key{$page} ) if $title eq '';
        $toc{$page} = $title;
    }

    return ( \%toc, scalar keys %toc );
}

######
## zip / 文件清单读取
######

sub decode_name {
    my ($name) = @_;
    return $name if utf8::is_utf8($name);
    my $decoded = eval { Encode::decode( 'UTF-8', $name, Encode::FB_CROAK ) };
    return defined $decoded ? $decoded : $name;
}

sub list_zip {
    my ($path) = @_;

    my @names;
    if ( eval { require Archive::Zip; 1 } ) {
        my $zip = Archive::Zip->new();
        unless ( $zip->read($path) == Archive::Zip::AZ_OK() ) {
            die "无法读取 zip: $path\n";
        }
        @names = map { $_->fileName } $zip->members;
    }
    elsif ( eval { require IO::Uncompress::Unzip; 1 } ) {
        my $u = IO::Uncompress::Unzip->new($path)
          or die "无法打开 zip: $path ($IO::Uncompress::Unzip::UnzipError)\n";
        while (1) {
            my $hdr = $u->getHeaderInfo();
            last unless $hdr;
            push @names, $hdr->{Name};
            last unless $u->nextStream();
        }
    }
    else {
        die "缺少 Archive::Zip / IO::Uncompress::Unzip，无法读取 zip。可用 --raw-list 传入路径清单。\n";
    }

    @names = map { decode_name($_) } @names;
    @names = grep { length && !m{/$} } @names;    # 跳过目录项
    return @names;
}

sub read_raw_list {
    my ($path) = @_;
    open( my $fh, '<:encoding(UTF-8)', $path ) or die "无法读取清单文件 $path: $!\n";
    my @names = grep { /\S/ } map { s/\r?\n\z//r } <$fh>;
    close $fh;
    return @names;
}

######
## 自测
######

sub run_selftest {

    print "--- 离线逻辑自测 ---\n";

    sub check_chapters ( $label, $files, $mode, $want_hash ) {
        my @sorted = lr_sort(@$files);
        my ( $toc, $count ) = detect_chapters( \@sorted, $mode );
        my $got = $toc // {};
        my @got_pairs = map { "$_=$got->{$_}" } sort { $a <=> $b } keys %$got;
        my @want_pairs =
          map { "$_=$want_hash->{$_}" } sort { $a <=> $b } keys %$want_hash;
        my $ok = ( join( '|', @got_pairs ) eq join( '|', @want_pairs ) );
        printf "[%s] %-28s -> %s\n", ( $ok ? 'OK ' : 'BAD' ), $label, ( @got_pairs ? join( ', ', @got_pairs ) : '(无)' );
        $FAIL++ unless $ok;
        return $count;
    }

    # 自然排序：Ch2 排在 Ch10 之前（数字补零到 4 位）
    {
        my @sorted = lr_sort(qw(Ch10/a.jpg Ch2/a.jpg Ch1/a.jpg));
        my $ok = ( join( '|', @sorted ) eq 'Ch1/a.jpg|Ch2/a.jpg|Ch10/a.jpg' );
        printf "[%s] 自然排序 Ch1<Ch2<Ch10\n", ( $ok ? 'OK ' : 'BAD' );
        $FAIL++ unless $ok;
    }

    # 基础：三个章节目录，页码按排序结果递增
    check_chapters(
        '基础多章',
        [qw(Ch1/01.jpg Ch1/02.jpg Ch2/01.jpg Ch2/02.jpg Ch10/01.jpg Ch10/02.jpg)],
        'auto',
        { 1 => 'Ch1', 3 => 'Ch2', 5 => 'Ch10' }
    );

    # 包裹目录：Series/Ch1, Series/Ch2 -> 自动下钻并去掉公共前缀
    check_chapters(
        '包裹目录下钻',
        [qw(Series/Ch1/01.jpg Series/Ch1/02.jpg Series/Ch2/01.jpg)],
        'auto',
        { 1 => 'Ch1', 3 => 'Ch2' }
    );

    # 根目录散图（封面）不生成章节，且封面被提前到第 1 页
    check_chapters(
        '根目录封面被跳过',
        [qw(Ch1/01.jpg Ch2/01.jpg cover.jpg)],
        'auto',
        { 2 => 'Ch1', 3 => 'Ch2' }
    );

    # full 模式：使用完整相对目录
    check_chapters(
        'full 模式',
        [qw(V1/Ch1/a.jpg V1/Ch2/a.jpg V2/Ch1/a.jpg V2/Ch2/a.jpg)],
        'full',
        { 1 => 'V1/Ch1', 2 => 'V1/Ch2', 3 => 'V2/Ch1', 4 => 'V2/Ch2' }
    );

    # 单目录：应只得到 1 章（插件端 require_multiple 会据此跳过）
    {
        my @sorted = lr_sort(qw(Manga/01.jpg Manga/02.jpg));
        my ( $toc, $count ) = detect_chapters( \@sorted, 'auto' );
        my $ok = ( $count == 1 && $toc->{1} eq 'Manga' );
        printf "[%s] 单目录只得到 1 章\n", ( $ok ? 'OK ' : 'BAD' );
        $FAIL++ unless $ok;
    }

    # 无子目录：不产生章节
    {
        my @sorted = lr_sort(qw(01.jpg 02.jpg 03.jpg));
        my ( $toc, $count ) = detect_chapters( \@sorted, 'auto' );
        my $ok = ( !$toc && $count == 0 );
        printf "[%s] 无子目录不生成章节\n", ( $ok ? 'OK ' : 'BAD' );
        $FAIL++ unless $ok;
    }

    # libarchive 返回的原始字节文件名：应先按 UTF-8 解码再生成章节名，避免双重编码乱码
    {
        my $raw1   = Encode::encode( 'UTF-8', "作品/第1话/001.jpg" );    # 未带 utf8 flag 的字节串
        my $raw2   = Encode::encode( 'UTF-8', "作品/第2话/001.jpg" );
        my @sorted = lr_sort( $raw1, $raw2 );
        my ( $toc, $count ) = detect_chapters( \@sorted, 'auto' );
        my $ok = ( $count == 2 && $toc->{1} eq "第1话" && $toc->{2} eq "第2话" );
        printf "[%s] 原始字节文件名解码 -> %s, %s\n", ( $ok ? 'OK ' : 'BAD' ),
          ( $toc->{1} // '(无)' ), ( $toc->{2} // '(无)' );
        $FAIL++ unless $ok;
    }

    print "\n=== 自测结果: " . ( $FAIL ? "$FAIL 项失败" : "全部通过" ) . " ===\n";
    return ( $FAIL ? 1 : 0 );
}

######
## 主流程
######

my ( $selftest, $zip, $raw_list, $mode, $list, $json );
$mode = 'auto';

GetOptions(
    'selftest'  => \$selftest,
    'zip=s'     => \$zip,
    'raw-list=s' => \$raw_list,
    'mode=s'    => \$mode,
    'list'      => \$list,
    'json'      => \$json,
) or die "参数错误\n";

$mode = 'auto' unless $mode =~ /^(?:auto|first|full)$/i;
$mode = lc $mode;

if ($selftest) {
    exit run_selftest();
}

if ( !defined $zip && !defined $raw_list ) {
    p_warn("未提供 --zip 或 --raw-list，仅运行了自测/帮助。");
    exit run_selftest();
}

my @raw = defined $zip ? list_zip($zip) : read_raw_list($raw_list);
my @images = grep { is_image($_) } @raw;

if ( !@images ) {
    p_fail("未在输入中找到图片文件。");
    print "\n=== 结果: 1 项失败 ===\n";
    exit 1;
}

my @sorted = lr_sort(@images);

p_info( "输入: " . ( defined $zip ? $zip : $raw_list ) );
p_info( "图片数: " . scalar @images . "，模式: $mode" );

if ($list) {
    print "\n--- 阅读顺序（页码从 1 开始）---\n";
    my $i = 0;
    printf "%4d  %s\n", ++$i, $_ for @sorted;
}

my ( $toc, $count ) = detect_chapters( \@sorted, $mode );
$toc //= {};

print "\n--- 检测到的章节 ---\n";
if ($count) {
    printf "第 %-5d 页  %s\n", $_, $toc->{$_} for sort { $a <=> $b } keys %$toc;
}
else {
    print "(未检测到章节目录)\n";
}
printf "共 %d 章 / %d 页\n", $count, scalar @sorted;

if ($json) {
    require JSON::PP;
    my %ordered = map { $_ => $toc->{$_} } sort { $a <=> $b } keys %$toc;
    print "\n" . JSON::PP->new->canonical->ascii->encode( \%ordered ) . "\n";
}

exit 0;
