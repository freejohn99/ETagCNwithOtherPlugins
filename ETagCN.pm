package LANraragi::Plugin::Metadata::ETagCN;

use v5.36;
use experimental 'try';

use strict;
use warnings;
no warnings 'uninitialized';
use utf8;

#Plugins can freely use all Perl packages already installed on the system
#Try however to restrain yourself to the ones already installed for LRR (see tools/cpanfile) to avoid extra installations by the end-user.
use URI::Escape;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw(html_unescape trim);
use Mojo::UserAgent;
use Mojo::Cookie::Response;
use Digest::MD5;
use Digest::SHA;

#You can also use the LRR Internal API when fitting.
use LANraragi::Model::Plugins;
use LANraragi::Utils::Logging qw(get_plugin_logger);

#Meta-information about your plugin.
sub plugin_info {

    return (
        #Standard metadata
        name        => "E-Hentai_CN",
        type        => "metadata",
        namespace   => "etagcn",
        login_from  => "ehlogin",
        author      => "FreeJohn&DeepSeek",
        version     => "2.6.5",
        description =>
          "搜索 g.e-hentai 以查找与您的存档匹配的标签,并将原标签翻译为中文标签. <br/><i class='fa fa-exclamation-circle'></i> 此插件将使用存档的 source: tag （如果存在）",
        icon =>
          "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAAEnQAABJ0Ad5mH3gAAAOASURBVDhPjVNbaFRXFF3n3puZyZ3EzJ1HkpIohthAP0InYMAKUUpfVFDylY9Bg1CJ+UllfLSEIoIEtBan7Y9t8KO0pSU0lH74oQZsMWImkSBalUADqR8mTVOTyXMymcfd7nPuNZpo2yzm3DmPfdZZZ+91MDyYJA0g+AMkStY3i8Brn392jjYKIclK7hP0rNzK7XkIIM8BdlRgkdYvvhya7bcUGT0ugKbXNZ4zcsCS+Qoycyl3y39DCL5qoJ+DpUKvM6mwzIcsFQCfjtmfL+LQX5cRa+9AOp12A57Btm1UV1ejoaHBIbTupDB/YB/yg5fcEKDo3VaUnPoWlLZBfg1zOwU6OjqQSr2o1DAMJJNJNDU1OYTBeynMNFbBPHoRwirnxOWgVW2DVhbh4wsQQR2p3VWgxXGX4uWQxJxyFyvLKHpzDzy7tsOz+w1olkMmQfKW+z/Gmc7javxvKC0t5SSywtCfRFplDYlNIRJlES65QYEbRNYQrf77bxFtKRauOYj6+vook8m4IweBAFtNXfl+CtP1FszD56VuLo6J/O/XYT98AL1+FwojQxChSuRuXsV3X55mywbR1taGlpYWlbfx8XHEYjFVFEfhQ2UyCriKAv2sapjIF/+agndZ3dmrZP1GpH/4Fb1eu0XF9vT0UHd3t+onEgkaGxuj8vJy+UieQfPzASxQNqxwyyyD2D5YmoU9PwfP3naETS+i0Siam5vBJOjq6kI8HkdNTQ2y2SzkVmZQXyydPMIEC+y/eRQfuQAU8mreznBVhIAvBFwb+YeLdA+6z0RFRQUmJiZUzFMohVKFr/UUq5jmAU/ofM5KGkWN74HY8MarnBtv8Wq1T350DLquw+PxyO1rIOC3KJicQbZ/SFpeKUGBvVfGchhaZDOEybnIs4U0HTYfOP+OABcVvb29qjCyL2FZlrysTqHJPBY+OMwbpGBJmIPx2g5FbuzYC30ze9KxJEQYmIlWclom1Xh0dBR1dXWKNBwOQxxtP0SJn/qBne+vGlmBXwtHATmujtfDP9nn3Hj9WBn4FefiB3Gi8xM32IFSKA05cvc2Jh894rysKbqCaZq48MWn+OaPrUBjTKUD37+Fqam/EYnwM30OklBK/V8spqYIRh3hB8evd4YH3ZW1YELaEKGE32sQKt6mK7/86M68CHnYhgkTifNqQ21trVKyvsm1gYEBegL+M2W04901FQAAAABJRU5ErkJggg==",
        parameters => [
            { type => "string", desc => "在搜索中强制使用语言标签（由于 EH 限制，日语标签无法使用）" },
            { type => "bool",   desc => "使用搜刮到的标题" },
            { type => "bool",   desc => "优先使用缩略图获取（如果失败，则使用标题搜索）" },
            { type => "bool",   desc => "优先使用标题的 gID 进行搜索（如果失败，则使用标题搜索）" },
            { type => "bool",   desc => "使用 ExHentai（可以在没有 star cookie 的情况下搜索 fjorded 内容）" },
            {   type => "bool",
                desc => "该功能请先启用“使用搜刮到的标题”。若开启，漫画标题会使用搜刮到的日文标题；若关闭，则使用英文或罗马拼音标题"
            },
            { type => "bool", desc => "获取额外的时间戳（发布时间）和上传者元数据" },
            { type => "bool", desc => "搜索已删除的画廊" },
            { type => "string", desc => "EhTagTranslation项目的JSON数据库文件(db.text.json)的绝对路径" },
            { type => "bool", desc => "自动更新标签数据库（从 EhTagTranslation releases 下载最新 db.text.json，需联网）" },
            { type => "int",  desc => "标签数据库更新检查间隔（天），默认 1；填 0 表示每次都检查" },
            { type => "bool", desc => "从文件名/标题提取作者、艺术家、团队（含 [团体 (艺术家)]，以及标题最前方无圆括号的方括号；宁滥勿缺）" },
            { type => "bool", desc => "提取文件名/标题中所有括号内容为标签（明显的语言/汉化组会额外加入 语言:/汉化组: 命名空间）" },
            { type => "string", desc => "sk cookie（可选）：搜索刚发布的新画廊时需要；从浏览器复制 sk 的值填这里" },
        ],
        oneshot_arg => "该漫画在e-hentai的URL(将于确切的漫画相匹配的标签到你的档案中)",
        cooldown    => 4
    );

}

#Mandatory function to be implemented by your plugin
sub get_tags {

    no warnings 'experimental::try';

    shift;
    my $lrr_info = shift;                                                                               # Global info hash
    my $ua       = $lrr_info->{user_agent};
    my ( $lang, $savetitle, $usethumbs, $search_gid, $enablepanda, $jpntitle, $additionaltags, $expunged, $db_path,
        $autoupdate_db, $db_update_days, $extract_authors, $extract_all_brackets, $sk_cookie ) = @_;    # Plugin parameters

    $db_update_days = 1 if !defined $db_update_days || $db_update_days !~ /^\d+$/;
    $extract_authors = 1 if !defined $extract_authors;    # 默认开启：文件名/标题里的作者名
    $extract_all_brackets = 0 if !defined $extract_all_brackets;

    # Use the logger to output status - they'll be passed to a specialized logfile and written to STDOUT.
    my $logger = get_plugin_logger();

    # EH 的搜索会隐藏“刚发布”的新画廊，除非会话带 sk cookie（sk 只在访问画廊页时下发）。
    # 若配置了 sk，就注入到 UA，让 gid / 标题搜索也能命中新画廊。
    if ( defined $sk_cookie && $sk_cookie ne '' ) {
        for my $domain ( 'e-hentai.org', 'exhentai.org' ) {
            $ua->cookie_jar->add(
                Mojo::Cookie::Response->new( name => 'sk', value => $sk_cookie, domain => $domain, path => '/' )
            );
        }
        $logger->info("Injected sk cookie for e-/exhentai search");
    }

    # Work your magic here - You can create subroutines below to organize the code better
    my $gID    = "";
    my $gToken = "";
    my $domain = ( $enablepanda ? 'https://exhentai.org' : 'https://e-hentai.org' );
    my $hasSrc = 0;

    # Quick regex to get the E-H archive ids from the provided url or source tag
    if ( $lrr_info->{oneshot_param} =~ /.*\/g\/([0-9]*)\/([0-z]*)\/*.*/ ) {
        $gID    = $1;
        $gToken = $2;
        $logger->debug("Skipping search and using gallery $gID / $gToken from oneshot args");
    } elsif ( $lrr_info->{existing_tags} =~ /.*source:\s*(?:https?:\/\/)?e(?:x|-)hentai\.org\/g\/([0-9]*)\/([0-z]*)\/*.*/gi ) {
        $gID    = $1;
        $gToken = $2;
        $hasSrc = 1;
        $logger->debug("Skipping search and using gallery $gID / $gToken from source tag");
    } elsif ( $lrr_info->{archive_title} =~ m{(?:https?://)?e(?:x|-)hentai\.org/g/(\d+)/([0-9a-z]+)|/g/(\d+)/([0-9a-z]+)}i ) {

        # 文件名里直接带 EH 画廊 URL 或 /g/<gid>/<token>/ 时，跳过搜索直接用
        $gID    = ( $1 // $3 );
        $gToken = ( $2 // $4 );
        $logger->info("Using gallery $gID / $gToken parsed from archive title");
    } else {

        # Craft URL for Text Search on EH if there's no user argument
        try {
            ( $gID, $gToken ) = &lookup_gallery(
                $lrr_info->{archive_title},
                $lrr_info->{existing_tags},
                $lrr_info->{thumbnail_hash},
                $ua, $domain, $lang, $usethumbs, $search_gid, $expunged
            );
        } catch ($e) {
            $logger->error($e);
            die $e;
        }
    }

    # If an error occured, return a hash containing an error message.
    # LRR will display that error to the client.
    # Using the GToken to store error codes - not the cleanest but it's convenient
    if ( $gID eq "" ) {
        my $message = "No matching EH Gallery Found!";
        my $message_cn = "没有匹配的 E-Hentai 画廊！";
        $logger->info($message);
        die "${message_cn}\n";
    } else {
        $logger->info("Using gallery $gID / $gToken");
    }

    my ( $ehtags, $ehtitle ) = &get_tags_from_EH(
        $ua,            $gID,              $gToken,     $jpntitle,   $additionaltags, $db_path,
        $autoupdate_db, $db_update_days,   $lrr_info->{archive_title}, $extract_authors, $extract_all_brackets
    );

    my %hashdata = ( tags => $ehtags );

    # Add source URL and title if possible/applicable
    if ( $hashdata{tags} ne "" ) {

        if ( !$hasSrc ) { $hashdata{tags} .= ", source:" . ( split( '://', $domain ) )[1] . "/g/$gID/$gToken"; }
        if ( $savetitle ) { $hashdata{title} = $ehtitle; }
    }

    #Return a hash containing the new metadata - it will be integrated in LRR.
    return %hashdata;
}

######
## EH Specific Methods
######

# extract_gid_from_title(title)
# Tries to pull the E-H gallery id out of an archive title.
# Handles the common layouts used by EH downloaders/scrapers:
#   "4210316-[artist] title"      -> leading id followed by a dash
#   "[4210316] title"             -> id wrapped in square brackets
#   "title (4210316)"             -> id wrapped in parentheses
sub extract_gid_from_title ($title) {

    # Leading gallery id, e.g. "4210316-[artist] title"
    if ( $title =~ /^\s*(\d{4,})\s*-/ ) {
        return $1;
    }

    # Bracketed ids anywhere in the title
    if ( $title =~ /(?:\[|\()\s*(\d{4,})\s*(?:\]|\))/ ) {
        return $1;
    }

    return "";
}

# extract_title_author_tags(title)
# 从存档标题（文件名）里提取 "[团体 (艺术家)]" 形式的原始（通常为日文）作者名，
# 逻辑与 WnacgCN/PicacgCN 的 title_author_tags 一致：
#   作者:<完整名>  /  团队:<括号外>  /  艺术家:<括号内>
# JSON 标签数据库里没有日文原名（key 是罗马字、name 是中文译文），所以日文原名要从标题里取。
sub extract_title_author_tags ($title, $bare_first = 0) {

    my $t = $title // '';
    my ( %seen, @out );
    my $add = sub {
        my $tag = shift;
        return if !defined $tag || $tag eq '';
        return if $seen{$tag}++;
        push @out, $tag;
    };

    # 标题最前方（允许前导 gid，如 "4210316-[...] 标题"）的第一个方括号，
    # 若内部没有圆括号，则作者/团队/艺术家都用它（宁滥勿缺）。要求 ] / 】 后面还有标题文字。
    if ($bare_first
        && $t =~ /^\s*(?:\d{4,}\s*-\s*)?[\[【]\s*([^\]】]*?)\s*[\]】]\s*\S/ )
    {
        my $seg = trim($1);
        if ( $seg ne '' && $seg !~ /[（(]/ ) {
            # 无圆括号：作者/团队/艺术家 都用该内容，并保留 标签:完整名
            $add->("作者:$seg");
            $add->("标签:$seg");
            $add->("团队:$seg");
            $add->("艺术家:$seg");
        }
    }

    while ( $t =~ /[\[【]\s*([^\]】]*?)\s*[\]】]/g ) {
        my $seg = trim($1);
        next if $seg eq '';
        next if $seg !~ /[（(]/;    # 含圆括号的 "[团体 (艺术家)]"

        $add->("作者:$seg");
        $add->("标签:$seg");

        # 括号剥离：外层=团队，括号内=艺术家；拆分出的名字再各补一个 标签: 形态
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

# extract_all_bracket_tags(title)
# 提取标题里所有括号内容（[]【】 与 ()（）），每项生成 "标签:<内容>"。
# 明显是语言/汉化组的，额外生成 "语言:<key>" / "汉化组:<内容>"。
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
        $add->("language:$lang") if $lang ne '';    # 用英文命名空间，便于与 EH 的 language:xxx 去重
        $add->("汉化组:$c")      if is_scanlation_group($c);
    };

    # 方括号内容（可能包含圆括号）
    while ( $t =~ /[\[【]\s*([^\]】]*?)\s*[\]】]/g ) { $emit->( trim($1) ) }
    # 圆括号内容
    while ( $t =~ /[（(]\s*([^）)]*?)\s*[）)]/g )     { $emit->( trim($1) ) }

    return @out;
}

# 从括号内容判断语言，返回数据库 language 命名空间的 key（用英文 key 才能被翻译成中文）
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

# 精确（不区分大小写）去重，保持顺序
sub dedupe_tags (@list) {
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

sub lookup_gallery ( $title, $tags, $thumbhash, $ua, $domain, $defaultlanguage, $usethumbs, $search_gid, $expunged ) {

    my $logger = get_plugin_logger();
    my $URL    = "";

    #Thumbnail reverse image search
    if ( $thumbhash ne "" && $usethumbs ) {

        $logger->info("Reverse Image Search Enabled, trying now.");

        #search with image SHA hash
        $URL = $domain . "?f_shash=" . $thumbhash . "&fs_similar=on&fs_covers=on";

        $logger->debug("Using URL $URL (archive thumbnail hash)");

        my ( $gId, $gToken ) = &ehentai_parse( $URL, $ua );

        if ( $gId ne "" && $gToken ne "" ) {
            return ( $gId, $gToken );
        }
        $logger->info("Thumbnail search returned no match, trying next method");
    }

    # Search using gID if present in title name
    # Supported formats: "4210316-[artist] title", "[4210316] title", "title (4210316)"
    my $title_gid = extract_gid_from_title($title);
    if ( $search_gid && !$title_gid ) {
        $logger->info("gID search is enabled but no gID could be parsed from title: '$title'");
    }
    if ( $search_gid && $title_gid ) {
        # 先普通 gid 搜索；未命中再带上 f_sh=on 试试（可能命中的是已删除/隐藏的画廊）
        my $base_q  = uri_escape_utf8("gid:$title_gid");
        my @suffix  = ( $expunged ? ('&f_sh=on') : ( '', '&f_sh=on' ) );

        for my $suffix (@suffix) {
            $URL = $domain . "?f_search=" . $base_q . $suffix;
            $logger->info("gID search: gid=$title_gid, URL=$URL");

            my ( $gId, $gToken ) = &ehentai_parse( $URL, $ua );

            if ( $gId ne "" && $gToken ne "" ) {
                return ( $gId, $gToken );
            }
        }
        $logger->info("gID search (gid=$title_gid) returned no match, falling back to title search");
    }

    # Strip a leading gallery id (e.g. "4210316-[artist] title") so it does not pollute the text search
    my $search_title = $title;
    $search_title =~ s/^\s*\d{4,}\s*-\s*//;

    # Regular text search (advanced options: Disable default filters for: Language, Uploader, Tags)
    $URL = $domain . "?advsearch=1&f_sfu=on&f_sft=on&f_sfl=on" . "&f_search=" . uri_escape_utf8( qw(") . $search_title . qw(") );

    my $has_artist = 0;

    # Add artist tag from the OG tags if it exists (and only contains ASCII characters)
    if ( $tags =~ /.*artist:\s?([^,]*),*.*/gi ) {
        my $artist = $1;
        if ( $artist =~ /^[\x00-\x7F]*$/ ) {
            $URL        = $URL . "+" . uri_escape_utf8("artist:$artist");
            $has_artist = 1;
        }
    }

    # Add the language override, if it's defined.
    if ( $defaultlanguage ne "" ) {
        $URL = $URL . "+" . uri_escape_utf8("language:$defaultlanguage");
    }

    # Search expunged galleries if the option is enabled.
    if ($expunged) {
        $URL = $URL . "&f_sh=on";
    }

    $logger->info("Title search: URL=$URL");
    my ( $gId, $gToken ) = &ehentai_parse( $URL, $ua );
    $logger->info("Title search returned no match") if $gId eq "";
    return ( $gId, $gToken );
}

# ehentai_parse(URL, UA)
# Performs a remote search on e- or exhentai, and returns the ID/token matching the found gallery.
# 注意：搜索无结果时不再直接 die，而是返回空串并记录诊断日志，让上层继续尝试其它搜索方式。
sub ehentai_parse ( $url, $ua ) {

    my $logger = get_plugin_logger();

    my ( $dom, $err ) = search_gallery( $url, $ua );
    if ( !$dom ) {
        $logger->info("Search failed ($url): $err");
        return ( "", "" );
    }

    my ( $gID, $gToken, $how ) = extract_gallery_from_dom($dom);
    if ( !$gID ) {
        $logger->info( "No gallery in search results ($url): " . diagnose_search_page($dom) );
        return ( "", "" );
    }

    $logger->info("Matched gallery $gID / $gToken (via $how)");

    if ( index( $dom->to_string, "You are opening" ) != -1 ) {
        my $rand = 15 + int( rand( 51 - 15 ) );
        $logger->info("Sleeping for $rand seconds due to EH excessive requests warning");
        sleep($rand);
    }

    #Returning shit yo
    return ( $gID, $gToken );
}

# extract_gallery_from_dom(dom)
# 取搜索结果里第一个画廊，返回 (gid, token, 匹配方式)。
# 兼容两种布局：
#   布局A（访客/冷会话）: .glink 的父级是 <a href=".../g/ID/TOKEN/">
#   布局B（登录后 gl4e/glname）: .glink 只是纯文本 div，真正的 <a href> 在行内其它位置
sub extract_gallery_from_dom ($dom) {

    # 1) .glink 自身或其父级 <a>
    for my $el ( @{ $dom->find('.glink') } ) {
        for my $node ( $el, $el->parent ) {
            next unless $node;
            my $href = $node->attr('href') // '';
            if ( $href =~ m{hentai\.org/g/(\d+)/([0-9a-z]+)}i ) {
                return ( $1, $2, 'glink' );
            }
        }
    }

    # 2) 兜底：页面上第一个指向画廊的 <a>
    for my $a ( @{ $dom->find('a') } ) {
        my $href = $a->attr('href') // '';
        if ( $href =~ m{hentai\.org/g/(\d+)/([0-9a-z]+)}i ) {
            return ( $1, $2, 'anchor' );
        }
    }

    return ();
}

# diagnose_search_page(dom)
# 汇总一个“没找到画廊”页面的关键信息，便于定位真正的失败原因。
sub diagnose_search_page ($dom) {

    my $html  = $dom->to_string;
    my $title = $dom->at('title') ? $dom->at('title')->text : '';
    $title =~ s/[^\x20-\x7e]/./g;

    my @notes;
    push @notes, "title='$title'";
    push @notes, ".glink=" . scalar( @{ $dom->find('.glink') } );
    push @notes, "gallery_links="
      . scalar( grep { ( $_->attr('href') // '' ) =~ m{hentai\.org/g/\d+/[0-9a-z]+}i } @{ $dom->find('a') } );

    push @notes, "SadPanda"          if $html =~ /Sad Panda|sadpanda/i;
    push @notes, "login_page"        if $html =~ /name="ipb_pass_hash"|act=Login/i;
    push @notes, "ip_banned"         if $html =~ /Your IP address has been/i;
    push @notes, "offensive_warning" if $html =~ /You are opening/i;
    push @notes, "no_results"        if $html =~ /No hits found|No results|not found/i;

    my $text = $html;
    $text =~ s/<[^>]*>/ /g;
    $text =~ s/\s+/ /g;
    $text =~ s/[^\x20-\x7e]/./g;    # 只保留 ASCII，避免日志乱码
    push @notes, "text='" . substr( $text, 0, 160 ) . "'";

    return join( '; ', @notes );
}

sub search_gallery ( $url, $ua ) {

    my $logger = get_plugin_logger();

    my $tx  = $ua->max_redirects(5)->get($url);
    my $res = $tx->result;

    if ( !$res || !$res->is_success ) {
        my $msg  = $tx->error ? $tx->error->{message} : 'unknown error';
        my $code = $res ? $res->code : '-';
        $logger->info("GET $url -> HTTP $code ($msg)");
        return ( undef, "HTTP 请求失败: $msg" );
    }

    my $body = $res->body;
    $logger->info( "GET $url -> HTTP " . $res->code . ", " . length($body) . " bytes" );

    if ( $body eq '' ) {
        $logger->info("The `igneous cookie` parameter of the login plugin `E-Hentai` may have expired, please update it in time!");
        return ( undef, "响应为空：登录插件 `E-Hentai` 的 `igneous cookie` 可能已过期" );
    }

    if ( index( $body, "Your IP address has been" ) != -1 ) {
        $logger->info("Temporarily banned from EH for excessive pageloads.");
        return ( undef, "IP 被 E-Hentai 暂时封禁（页面加载过多）" );
    }

    return ( $res->dom, undef );
}

# get_tags_from_EH(userAgent, gID, gToken, jpntitle, additionaltags, db_path, autoupdate_db, db_update_days, archive_title, extract_authors, extract_all_brackets)
# Executes an e-hentai API request with the given JSON and returns tags and title.
sub get_tags_from_EH ( $ua, $gID, $gToken, $jpntitle, $additionaltags, $db_path, $autoupdate_db, $db_update_days, $archive_title, $extract_authors, $extract_all_brackets ) {

    my $uri = 'https://api.e-hentai.org/api.php';

    my $logger = get_plugin_logger();

    # 按需自动更新标签数据库（失败不影响本次抓取，继续用现有数据库）
    if ($autoupdate_db) {
        $logger->info( "Tag DB auto-update enabled (check interval: " . ( $db_update_days // 1 ) . " day(s))" );
        eval { update_db_if_needed( $ua, $db_path, $db_update_days ); 1 }
          or $logger->error( "自动更新标签数据库失败: " . ( $@ // 'unknown' ) );
    }
    else {
        $logger->info("Tag DB auto-update disabled (enable it in plugin settings to fetch updates)");
    }

    my $jsonresponse = get_json_from_EH( $ua, $gID, $gToken );

    my $data    = $jsonresponse->{"gmetadata"};
    my @tags    = @{ @$data[0]->{"tags"} };
    my $ehtitle = @$data[0]->{ ( $jpntitle ? "title_jpn" : "title" ) };
    if ( $ehtitle eq "" && $jpntitle ) {
        $ehtitle = @$data[0]->{"title"};
    }
    my $ehcat = lc @$data[0]->{"category"};
    $ehcat =~ s/\s+//g;

    push( @tags, "gid:$gID" );
    push( @tags, "reclass:$ehcat" );
    if ($additionaltags) {
        my $ehuploader  = @$data[0]->{"uploader"};
        my $ehtimestamp = @$data[0]->{"posted"};
        push( @tags, "上传者:$ehuploader" );
        push( @tags, "时间戳:$ehtimestamp" );
    }

    # Unescape title received from the API as it might contain some HTML characters
    $ehtitle = html_unescape($ehtitle);

    # 从文件名与刮到的（日文）标题里补充原始作者名 / 括号标签。
    # 放在翻译之前，这样 语言:chinese 这类会被数据库统一翻译成“语言:汉语”。
    if ($extract_authors) {
        push @tags, extract_title_author_tags( $archive_title // '', 1 );
        push @tags, extract_title_author_tags( $ehtitle,        1 );
    }
    if ($extract_all_brackets) {
        push @tags, extract_all_bracket_tags( $archive_title // '' );
        push @tags, extract_all_bracket_tags( $ehtitle );
    }
    @tags = dedupe_tags(@tags);

    # 中文转换
    my $cntags = translate_tag_to_cn( \@tags, $db_path );
    $cntags = [ dedupe_tags(@$cntags) ];    # 翻译后可能产生重复（如 language:chinese 与 语言:chinese）

    my $ehtags = join( ', ', @$cntags );
    $logger->info("Sending the following tags to LRR: $ehtags");

    return ( $ehtags, $ehtitle );
}

sub get_json_from_EH ( $ua, $gID, $gToken ) {

    my $uri = 'https://api.e-hentai.org/api.php';

    my $logger = get_plugin_logger();

    #Execute the request
    my $rep = $ua->post(
        $uri => json => {
            method    => "gdata",
            gidlist   => [ [ $gID, $gToken ] ],
            namespace => 1
        }
    )->result;

    my $textrep = $rep->body;
    $logger->debug("E-H API returned this JSON: $textrep");

    my $jsonresponse = $rep->json;
    if ( exists $jsonresponse->{"error"} ) {
        $logger->error( $jsonresponse->{"error"} );
        die "E-H API returned an error.\n";
    }

    return $jsonresponse;
}

# 标签数据库的常见默认位置（用于回退与自动下载目标）
sub default_db_paths {
    return (
        '/home/koyomi/lanraragi/database/db.text.json',
        ( $ENV{LRR_DATA_DIR} ? "$ENV{LRR_DATA_DIR}/db.text.json" : () ),
        './db.text.json',
    );
}

# 自动下载/更新时的目标路径：优先插件参数，否则用第一个默认位置
sub db_target_path ($db_path) {
    return $db_path if defined $db_path && $db_path ne '';
    my ($first) = default_db_paths();
    return $first;
}

# 插件自身的“上次检查标签库更新”时间戳文件。
# 用单独的时间戳而不是 db 文件 mtime：这样即使远端没有变化、db 文件没被改写，
# 也能正确节流，不会“超过一天后每次请求都去检查一次”。
sub db_check_marker_path ($target) {
    my $marker = "$target.lastcheck";

    # 优先放在 db 同目录（通常可写）；目录不可写时退回系统临时目录
    ( my $dir = $marker ) =~ s{[\\/][^\\/]+$}{};
    return $marker if $dir ne '' && -w $dir;

    require File::Spec;
    ( my $key = $target ) =~ s{\W}{_}g;
    return File::Spec->catfile( File::Spec->tmpdir, "etagcn_lastcheck_$key" );
}

sub read_last_check ($marker) {
    return 0 unless defined $marker && $marker ne '' && -f $marker;
    open( my $fh, '<', $marker ) or return 0;
    my $t = <$fh>;
    close $fh;
    return 0 unless defined $t;
    $t =~ s/\s+//g;
    return ( $t =~ /^\d+$/ ) ? $t : 0;
}

sub write_last_check ($marker) {
    return unless defined $marker && $marker ne '';
    open( my $fh, '>', $marker ) or do {
        get_plugin_logger()->warn("无法写入标签库更新检查时间戳 $marker: $!");
        return;
    };
    print $fh time();
    close $fh;
}

# 解析标签数据库路径：优先用插件参数，失败则回退到常见位置
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

sub file_md5 ($path) {
    open( my $fh, '<:raw', $path ) or return '';
    my $d = Digest::MD5->new->addfile($fh);
    close $fh;
    return $d->hexdigest;
}

sub file_sha256 ($path) {
    open( my $fh, '<:raw', $path ) or return '';
    my $d = Digest::SHA->new(256)->addfile($fh);
    close $fh;
    return $d->hexdigest;
}

# 按需从 EhTagTranslation releases 更新 db.text.json
# - $days 天内已更新过则跳过（默认 1 天）
# - 先比对 GitHub API 提供的 sha256 digest，再比对下载文件的 md5，都相同则不替换
sub update_db_if_needed ( $ua, $db_path, $days ) {

    my $logger = get_plugin_logger();
    $days = 1 if !defined $days || $days !~ /^\d+$/;

    my $target = db_target_path($db_path);
    return unless defined $target && $target ne '';

    my $marker = db_check_marker_path($target);
    $logger->debug("Tag DB target: $target, check marker: $marker (interval=${days}d)");

    # 频率限制：距离插件“上次检查”不足 $days 天则跳过（$days==0 表示每次都检查）。
    # 用插件自己的时间戳节流，而不是 db 文件的 mtime，避免远端无变化时被反复检查。
    # 首次（还没有时间戳）时退回用 db 文件 mtime 作基线。
    my $last_check = read_last_check($marker);
    $last_check = ( stat($target) )[9] || 0 if !$last_check && -f $target;

    if ( $days > 0 && $last_check ) {
        my $age   = time() - $last_check;
        my $limit = $days * 86400;
        if ( $age < $limit ) {
            my $left_h = int( ( $limit - $age ) / 3600 );
            $logger->info("Tag DB check skipped (last checked ${age}s ago); next check in ~${left_h}h. "
                  . "Set the interval to 0 to force a check now." );
            return;
        }
    }

    my $api = 'https://api.github.com/repos/EhTagTranslation/Database/releases/latest';
    $logger->info("Checking EhTagTranslation latest release: $api");

    my $res = $ua->max_redirects(5)->get($api)->result;
    if ( !$res || !$res->is_success ) {
        $logger->error( "获取 EhTagTranslation 最新版本失败: " . ( $res ? "HTTP " . $res->code : 'no response' ) );
        return;
    }

    my $release = eval { $res->json } // {};
    my ($asset) = grep { ( $_->{name} // '' ) eq 'db.text.json' } @{ $release->{assets} // [] };
    if ( !$asset ) {
        $logger->error("最新 release 中未找到 db.text.json 资源（可能被限流或结构变化）");
        return;
    }

    my $url         = $asset->{browser_download_url};
    my $remote_dig  = $asset->{digest} // '';    # 形如 "sha256:...."
    my $local_md5   = -f $target ? file_md5($target) : '';
    my $local_sha   = -f $target ? file_sha256($target) : '';

    # 优先用 API 的 sha256 摘要判断，无需下载
    if ( $remote_dig =~ /^sha256:([0-9a-f]{64})$/i && $local_sha ne '' && lc($1) eq lc($local_sha) ) {
        $logger->info("Tag DB already up to date (sha256 match), skip download");
        write_last_check($marker);
        return;
    }

    $logger->info("Downloading latest tag DB: $url");
    my $dl = $ua->max_redirects(5)->get($url)->result;
    if ( !$dl || !$dl->is_success ) {
        $logger->error( "下载 db.text.json 失败: " . ( $dl ? "HTTP " . $dl->code : 'no response' ) );
        return;
    }

    my $tmp    = "$target.download.tmp";
    my $out_fh;
    if ( !open( $out_fh, '>:raw', $tmp ) ) {
        $logger->error("无法写入临时文件 $tmp: $!");
        return;
    }
    print $out_fh $dl->body;
    close $out_fh;

    my $new_md5 = file_md5($tmp);
    if ( $local_md5 ne '' && $new_md5 ne '' && $new_md5 eq $local_md5 ) {
        unlink $tmp;
        $logger->info("Tag DB unchanged (md5=$new_md5), skip replace");
        write_last_check($marker);
        return;
    }

    if ( !rename( $tmp, $target ) ) {
        # rename 失败（跨设备/权限）时退化为覆盖写入
        if ( open( my $in, '<:raw', $tmp ) ) {
            my $data = do { local $/; <$in> };
            close $in;
            if ( open( my $out2, '>:raw', $target ) ) {
                print $out2 $data;
                close $out2;
                unlink $tmp;
            }
            else {
                $logger->error("无法写入 $target: $!");
                unlink $tmp;
                return;
            }
        }
        else {
            $logger->error("无法读取临时文件 $tmp: $!");
            return;
        }
    }

    $logger->info( "Tag DB updated: " . ( $local_md5 ne '' ? $local_md5 : '(none)' ) . " -> " . ( $new_md5 // '' ) );
    write_last_check($marker);
}

# 将原tag翻译为中文tag
sub translate_tag_to_cn ( $list, $db_path ) {

    my $logger = get_plugin_logger();

    my $filename = resolve_db_path($db_path);
    if ( !$filename ) {
        $logger->error(
            "找不到 EhTagTranslation 标签数据库 db.text.json（插件参数路径: '"
              . ( $db_path // '' )
              . "'）。将返回未翻译的原始标签；请把 db.text.json 放入容器并修正参数路径。"
        );
        return $list;
    }
    $logger->info("Using tag database: $filename");

    open( my $json_fh, '<', $filename )
      or do {
        $logger->error("无法打开标签数据库 $filename: $!；将返回未翻译的原始标签。");
        return $list;
      };
    my $json_text = do { local $/; <$json_fh> };
    close $json_fh;

    my $json = eval { decode_json($json_text) };
    if ( !$json || ref $json->{data} ne 'ARRAY' ) {
        $logger->error("标签数据库解析失败（不是有效的 EhTagTranslation db.text.json？）: $filename；将返回未翻译的原始标签。");
        return $list;
    }
    my $target = $json->{'data'};

    for my $item (@$list) {
        my ($namespace, $key) = split(/:/, $item);
        for my $element (@$target) {
            # 如果$namespace与'namespace'字段相同，则进行替换
            if ($element->{'namespace'} eq $namespace) {
                my $name = $element->{'frontMatters'}->{'name'};
                $item =~ s/$namespace/$name/;
                my $data = $element->{'data'};
                # 如果在'data'字段中存在$key，则进行替换
                if (exists $data->{$key}) {
                    my $value = $data->{$key}->{'name'};
                    $item =~ s/$key/$value/;
                }
                last;
            }
        }
    }
    
    return $list;
}

1;