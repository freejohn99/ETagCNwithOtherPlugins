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
use Mojo::Util qw(html_unescape);
use Mojo::UserAgent;

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
        author      => "GrayZhao & Difegue and FreeJohn",
        version     => "2.6.1",
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
            { type => "bool", desc => "仅搜索已删除的画廊" },
            { type => "string", desc => "EhTagTranslation项目的JSON数据库文件(db.text.json)的绝对路径" },
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
    my ( $lang, $savetitle, $usethumbs, $search_gid, $enablepanda, $jpntitle, $additionaltags, $expunged, $db_path ) = @_;    # Plugin parameters

    # Use the logger to output status - they'll be passed to a specialized logfile and written to STDOUT.
    my $logger = get_plugin_logger();

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

    my ( $ehtags, $ehtitle ) = &get_tags_from_EH( $ua, $gID, $gToken, $jpntitle, $additionaltags, $db_path );
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
        $URL = $domain . "?f_search=" . uri_escape_utf8("gid:$title_gid");

        $logger->info("gID search: gid=$title_gid, URL=$URL");

        my ( $gId, $gToken ) = &ehentai_parse( $URL, $ua );

        if ( $gId ne "" && $gToken ne "" ) {
            return ( $gId, $gToken );
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

# get_tags_from_EH(userAgent, gID, gToken, jpntitle, additionaltags)
# Executes an e-hentai API request with the given JSON and returns tags and title.
sub get_tags_from_EH ( $ua, $gID, $gToken, $jpntitle, $additionaltags, $db_path ) {

    my $uri = 'https://api.e-hentai.org/api.php';

    my $logger = get_plugin_logger();

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

    # 中文转换
    my $cntags = translate_tag_to_cn( \@tags, $db_path );

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

# 解析标签数据库路径：优先用插件参数，失败则回退到常见位置
sub resolve_db_path ($db_path) {
    my @candidates;
    push @candidates, $db_path if defined $db_path && $db_path ne '';
    push @candidates, (
        '/home/koyomi/lanraragi/database/db.text.json',
        ( $ENV{LRR_DATA_DIR} ? "$ENV{LRR_DATA_DIR}/db.text.json" : () ),
        './db.text.json',
    );
    for my $f (@candidates) {
        next if !defined $f || $f eq '';
        return $f if -f $f;
    }
    return undef;
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