package LANraragi::Plugin::Metadata::TitleTagsCN;

use v5.36;
use strict;
use warnings;
no warnings 'uninitialized';
use utf8;

use LANraragi::Model::Plugins;
use LANraragi::Utils::Logging qw(get_plugin_logger);

#Meta-information about your plugin.
sub plugin_info {

    return (
        name        => "文件名标题标签_CN",
        type        => "metadata",
        namespace   => "titletagscn",
        author      => "FreeJohn&DeepSeek",
        version     => "1.0.0",
        description =>
          "从存档标题（文件名）提取作者、艺术家、团队与括号标签（兼容 [团体 (艺术家)] 与最前方 [名字] 形式）。<br/><i class='fa fa-exclamation-circle'></i> 不改动标题，只补充标签。",
        parameters => [
            { type => "bool", desc => "从文件名/标题提取作者、艺术家、团队（含 [团体 (艺术家)]，以及标题最前方无圆括号的方括号；宁滥勿缺）", default_value => 1 },
            { type => "bool", desc => "提取文件名/标题中所有括号内容为标签（明显的语言/汉化组会额外加入 语言:/汉化组: 命名空间）", default_value => 0 },
        ],
        cooldown => 4
    );

}

#Mandatory function to be implemented by your plugin
sub get_tags {

    shift;
    my $lrr_info = shift;    # Global info hash
    my ( $extract_authors, $extract_all_brackets ) = @_;    # Plugin parameters

    $extract_authors      = 1 if !defined $extract_authors;      # 默认开启
    $extract_all_brackets = 0 if !defined $extract_all_brackets; # 默认关闭

    my $logger = get_plugin_logger();
    my $title  = $lrr_info->{archive_title} // '';

    my @out;
    push @out, extract_title_author_tags( $title, 1 ) if $extract_authors;
    push @out, extract_all_bracket_tags($title)       if $extract_all_brackets;

    @out = dedupe_exact(@out);
    return () unless @out;

    my $tagstr = join( ', ', @out );
    $logger->info("Sending the following tags to LRR: $tagstr");

    return ( tags => $tagstr );

}

######
## Helpers（纯函数，方便后续直接补充/扩展）
######

sub trim ($s) {
    return '' unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

# 精确（不区分大小写）去重，保持顺序
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

# 从存档标题（文件名）提取 "[团体 (艺术家)]" 形式的原始作者名
#   作者:<完整名>  /  标签:<完整名>  /  团队:<括号外>  /  艺术家:<括号内>
# 若标题最前方是 [名字]（无圆括号），则作者/团队/艺术家都用它（宁滥勿缺）。
sub extract_title_author_tags ($title, $bare_first = 0) {

    my $t = $title // '';
    my ( %seen, @out );
    my $add = sub {
        my $tag = shift;
        return if !defined $tag || $tag eq '';
        return if $seen{$tag}++;
        push @out, $tag;
    };

    # 标题最前方（允许前导 gid）的第一个方括号；无圆括号时作者/团队/艺术家都用它
    if ( $bare_first
        && $t =~ /^\s*(?:\d{4,}\s*-\s*)?[\[【]\s*([^\]】]*?)\s*[\]】]\s*\S/ )
    {
        my $seg = trim($1);
        if ( $seg ne '' && $seg !~ /[（(]/ ) {
            $add->("作者:$seg");
            $add->("标签:$seg");
            $add->("团队:$seg");
            $add->("艺术家:$seg");
        }
    }

    while ( $t =~ /[\[【]\s*([^\]】]*?)\s*[\]】]/g ) {
        my $seg = trim($1);
        next if $seg eq '';
        next if $seg !~ /[（(]/;    # 只处理含圆括号的 "[团体 (艺术家)]"

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

# 提取标题里所有括号内容（[]【】 与 ()（））为 标签:<内容>；
# 明显的语言 / 汉化组会额外生成 语言:<中文> / 汉化组:<内容>。
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

# 从括号内容判断语言
sub detect_lang_key ($c) {
    return 'chinese'  if $c =~ /(中国语|中国語|中文|中國|简体|简中|繁體|繁体|繁中|中国翻訳|中国翻译|汉化|漢化|chinese|\bchs?\b|\bcht\b|\bchi\b)/i;
    return 'japanese' if $c =~ /(日本語|日本语|日语|日文|japanese|\bjpn?\b)/i;
    return 'english'  if $c =~ /(english|\beng\b|英语|英語)/i;
    return 'korean'   if $c =~ /(korean|한국어|한글|韩语|韓語)/i;
    return '';
}

# 是否像汉化组/翻译组
sub is_scanlation_group ($c) {
    return $c =~ /(汉化组|漢化組|汉化社|漢化社|翻译组|翻譯組|字幕组|字幕組|扫图组|掃圖組|嵌字|汉化|漢化)/ ? 1 : 0;
}

1;
