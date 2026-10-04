package LANraragi::Plugin::Metadata::ChapterTOC;

use v5.36;
use strict;
use warnings;
use utf8;
no warnings 'uninitialized';

# Plugins can freely use all Perl packages already installed on the system.
use Mojo::JSON qw(encode_json decode_json);

# You can also use the LRR Internal API when fitting.
use LANraragi::Model::Plugins;
use LANraragi::Utils::Logging  qw(get_plugin_logger);
use LANraragi::Utils::Archive  qw(get_filelist);
use LANraragi::Utils::Database qw(invalidate_cache);
use LANraragi::Utils::Redis    qw(redis_decode);
use LANraragi::Model::Config;

#Meta-information about your plugin.
sub plugin_info {

    return (
        #Standard metadata
        name        => "子目录章节_TOC",
        type        => "metadata",
        namespace   => "chaptertoc",
        author      => "nimalolikong&DeepSeek",
        version     => "1.0.0",
        description =>
          "检测存档内的子目录作为章节，按 LANraragi 的真实页面排序规则计算每章起始页，并自动写入存档的章节信息(ToC)。"
          . "<br/><i class='fa fa-exclamation-circle'></i> 默认(fill 模式)仅在存档尚无章节、且检测到多个章节目录时写入，不会改动其它元数据。",
        parameters => [
            {   type          => "string",
                desc          => "章节目录取法：auto=自动选择能分出多章的最浅层级(推荐)；first=只取第一层子目录；full=取完整相对目录路径",
                default_value => "auto"
            },
            {   type          => "string",
                desc          => "ToC 写入模式：fill=仅当存档尚无章节时写入(推荐)；merge=保留已有章节并合并；overwrite=覆盖重建全部章节",
                default_value => "fill"
            },
            {   type          => "bool",
                desc          => "仅当检测到 2 个及以上章节目录时才写入(推荐开启，避免单目录存档被误判)",
                default_value => 1
            },
        ],
        cooldown => 1
    );

}

#Mandatory function to be implemented by your plugin
sub get_tags {

    shift;
    my $lrr_info = shift;    # Global info hash
    my ( $dir_mode, $toc_mode, $require_multiple ) = @_;    # Plugin parameters

    $dir_mode = 'auto' unless defined $dir_mode && $dir_mode =~ /^(?:auto|first|full)$/i;
    $dir_mode = lc $dir_mode;
    $toc_mode = 'fill' unless defined $toc_mode && $toc_mode =~ /^(?:fill|merge|overwrite)$/i;
    $toc_mode = lc $toc_mode;
    $require_multiple = 1 if !defined $require_multiple;

    my $logger = get_plugin_logger();

    my $id   = $lrr_info->{archive_id};
    my $file = $lrr_info->{file_path};

    unless ( defined $id && $id ne '' && defined $file && $file ne '' && -e $file ) {
        $logger->warn("No valid archive id/file_path provided, skipping.");
        return ( tags => "" );
    }

    # Use LANraragi's own file list so our page numbers match the reader exactly.
    my @files = eval { get_filelist( $file, $id ) };
    if ($@) {
        $logger->error("Failed to list archive contents: $@");
        return ( tags => "" );
    }
    if ( !@files ) {
        $logger->info("Archive has no pages, skipping.");
        return ( tags => "" );
    }

    my ( $toc, $count ) = detect_chapters( \@files, $dir_mode );
    if ( !$toc || !$count ) {
        $logger->info("No chapter subdirectories detected, skipping.");
        return ( tags => "" );
    }
    if ( $require_multiple && $count < 2 ) {
        $logger->info("Only $count chapter directory detected; require_multiple is on, skipping.");
        return ( tags => "" );
    }

    my ( $written, $total ) = write_toc( $id, $toc, $toc_mode, scalar @files );
    if ($written) {
        $logger->info("Wrote ToC with $count chapter(s) (mode=$toc_mode, total entries=$total).");
    }
    else {
        $logger->info("ToC not written (mode=$toc_mode, existing entries kept).");
    }

    # Metadata plugins must return a tags key; empty string means "no tag changes".
    return ( tags => "" );

}

######
## Chapter detection helpers (pure functions, easy to unit-test)
######

# Normalize Windows/POSIX separators to '/'.
sub norm_path ($p) {
    ( my $x = $p // '' ) =~ tr{\\}{/};
    return $x;
}

# Return the directory segments of an in-archive path (filename removed).
sub dir_segments ($p) {
    my @segs = split m{/}, norm_path($p), -1;
    pop @segs if @segs;
    return @segs;
}

# Full relative directory of a file ("" for files at the archive root).
sub dir_full ($p) {
    my @d = dir_segments($p);
    return @d ? join( '/', @d ) : '';
}

# Directory prefix of a file truncated to $depth levels.
sub dir_at ( $p, $depth ) {
    my @d = dir_segments($p);
    return '' if @d < $depth;
    return join( '/', @d[ 0 .. $depth - 1 ] );
}

# Pick the directory depth that yields the most meaningful chapter split.
#   first -> always depth 1
#   auto  -> shallowest depth that yields >= 2 distinct directory groups,
#            so a single wrapping folder (Series/Ch1, Series/Ch2) is handled
# Returns undef when the archive has no subdirectories at all.
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

# Longest common leading directory prefix (in segments) shared by all keys.
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

    # Never strip an entire key away.
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

# detect_chapters(\@ordered_files, $mode)
# Returns ( { page => title }, chapter_count ).
# Page numbers are 1-based and match the reader's page order, because we use
# the exact @files order returned by LANraragi::Utils::Archive::get_filelist.
sub detect_chapters ( $files, $mode ) {

    # get_filelist returns in-archive filenames as raw bytes. LANraragi decodes
    # them with redis_decode before serving/displaying them (see
    # build_reader_JSON), so we must do the same here. Otherwise the chapter
    # titles are stored as double-encoded UTF-8 and show up as mojibake.
    my @paths = map { redis_decode($_) } @$files;

    my $depth = ( $mode eq 'full' ) ? undef : choose_depth( \@paths, $mode );

    # No subdirectories at all -> nothing to split.
    return ( undef, 0 ) if $mode ne 'full' && !defined $depth;

    # A chapter key is the directory a page belongs to; root pages ("") are
    # treated as front/back matter and don't start a chapter.
    my ( %seen, %page_key );
    my $index = 0;
    for my $path (@paths) {
        $index++;
        my $key = ( $mode eq 'full' ) ? dir_full($path) : dir_at( $path, $depth );
        next if $key eq '';
        next if $seen{$key}++;    # first occurrence = chapter start page
        $page_key{$index} = $key;
    }

    return ( undef, 0 ) unless %page_key;

    # Strip a shared wrapping folder from the displayed titles (Series/Ch1 -> Ch1).
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
## ToC persistence
######

# write_toc($id, \%toc, $mode, $pagecount)
# The ToC is stored in the archive's Redis hash field "toc" as a JSON object
# mapping 1-based page numbers to chapter titles (same format LRR uses).
# Returns ($written, $total_entries).
sub write_toc ( $id, $toc, $mode, $pagecount ) {

    my $logger = get_plugin_logger();
    my $redis  = LANraragi::Model::Config->get_redis;

    my $existing_raw = $redis->hget( $id, 'toc' );
    my %existing;
    if ( defined $existing_raw && $existing_raw ne '' ) {
        my $decoded = eval { decode_json($existing_raw) };
        %existing = %$decoded if ref $decoded eq 'HASH';
    }

    if ( $mode eq 'fill' && %existing ) {
        $redis->quit;
        return ( 0, scalar keys %existing );
    }

    my %final = ( $mode eq 'merge' ) ? %existing : ();
    for my $page ( keys %$toc ) {
        next unless $page =~ /^\d+$/ && $page >= 1;
        next if defined $pagecount && $page > $pagecount;
        $final{$page} = $toc->{$page};
    }

    $redis->hset( $id, 'toc', encode_json( \%final ) );
    $redis->quit;

    # The archive JSON (which embeds toc) can be part of the search cache.
    eval { invalidate_cache(); 1 } or $logger->warn("Could not invalidate search cache: $@");

    return ( 1, scalar keys %final );
}

1;
