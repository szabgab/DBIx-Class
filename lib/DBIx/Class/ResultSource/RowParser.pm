package # hide from the pauses
  DBIx::Class::ResultSource::RowParser;

use strict;
use warnings;

use Try::Tiny;
use List::Util qw(first max);
use B 'perlstring';

use namespace::clean;

use base 'DBIx::Class';

# Accepts one or more relationships for the current source and returns an
# array of column names for each of those relationships. Column names are
# prefixed relative to the current source, in accordance with where they appear
# in the supplied relationships.
sub _resolve_prefetch {
  my ($self, $pre, $alias, $alias_map, $order, $pref_path) = @_;
  $pref_path ||= [];

  if (not defined $pre or not length $pre) {
    return ();
  }
  elsif( ref $pre eq 'ARRAY' ) {
    return
      map { $self->_resolve_prefetch( $_, $alias, $alias_map, $order, [ @$pref_path ] ) }
        @$pre;
  }
  elsif( ref $pre eq 'HASH' ) {
    my @ret =
    map {
      $self->_resolve_prefetch($_, $alias, $alias_map, $order, [ @$pref_path ] ),
      $self->related_source($_)->_resolve_prefetch(
         $pre->{$_}, "${alias}.$_", $alias_map, $order, [ @$pref_path, $_] )
    } keys %$pre;
    return @ret;
  }
  elsif( ref $pre ) {
    $self->throw_exception(
      "don't know how to resolve prefetch reftype ".ref($pre));
  }
  else {
    my $p = $alias_map;
    $p = $p->{$_} for (@$pref_path, $pre);

    $self->throw_exception (
      "Unable to resolve prefetch '$pre' - join alias map does not contain an entry for path: "
      . join (' -> ', @$pref_path, $pre)
    ) if (ref $p->{-join_aliases} ne 'ARRAY' or not @{$p->{-join_aliases}} );

    my $as = shift @{$p->{-join_aliases}};

    my $rel_info = $self->relationship_info( $pre );
    $self->throw_exception( $self->source_name . " has no such relationship '$pre'" )
      unless $rel_info;

    my $as_prefix = ($alias =~ /^.*?\.(.+)$/ ? $1.'.' : '');

    return map { [ "${as}.$_", "${as_prefix}${pre}.$_", ] }
      $self->related_source($pre)->columns;
  }
}

# Takes an arrayref selection list and generates a collapse-map representing
# row-object fold-points. Every relationship is assigned a set of unique,
# non-nullable columns (which may *not even be* from the same resultset)
# and the collapser will use this information to correctly distinguish
# data of individual to-be-row-objects. See t/resultset/rowparser_internals.t
# for extensive RV examples
sub _resolve_collapse {
  my ($self, $args, $common_args) = @_;

  # for comprehensible error messages put ourselves at the head of the relationship chain
  $args->{_rel_chain} ||= [ $self->source_name ];

  # record top-level fully-qualified column index, start nodecount
  $common_args ||= {
    _as_fq_idx => { %{$args->{as}} },
    _node_idx => 1, # this is *deliberately* not 0-based
  };

  my ($my_cols, $rel_cols);
  for (keys %{$args->{as}}) {
    if ($_ =~ /^ ([^\.]+) \. (.+) /x) {
      $rel_cols->{$1}{$2} = 1;
    }
    else {
      $my_cols->{$_} = {};  # important for ||='s below
    }
  }

  my $relinfo;
  # run through relationships, collect metadata
  for my $rel (keys %$rel_cols) {
    my $rel_src = __get_related_source($self, $rel, $rel_cols->{$rel});

    my $inf = $self->relationship_info ($rel);

    $relinfo->{$rel}{is_single} = $inf->{attrs}{accessor} && $inf->{attrs}{accessor} ne 'multi';
    $relinfo->{$rel}{is_inner} = ( $inf->{attrs}{join_type} || '' ) !~ /^left/i;
    $relinfo->{$rel}{rsrc} = $rel_src;

    # FIME - need to use _resolve_cond here instead
    my $cond = $inf->{cond};

    if (
      ref $cond eq 'HASH'
        and
      keys %$cond
        and
      ! defined first { $_ !~ /^foreign\./ } (keys %$cond)
        and
      ! defined first { $_ !~ /^self\./ } (values %$cond)
    ) {
      for my $f (keys %$cond) {
        my $s = $cond->{$f};
        $_ =~ s/^ (?: foreign | self ) \.//x for ($f, $s);
        $relinfo->{$rel}{fk_map}{$s} = $f;
      }
    }
  }

  # inject non-left fk-bridges from *INNER-JOINED* children (if any)
  for my $rel (grep { $relinfo->{$_}{is_inner} } keys %$relinfo) {
    my $ri = $relinfo->{$rel};
    for (keys %{$ri->{fk_map}} ) {
      # need to know source from *our* pov, hence $rel.col
      $my_cols->{$_} ||= { via_fk => "$rel.$ri->{fk_map}{$_}" }
        if defined $rel_cols->{$rel}{$ri->{fk_map}{$_}} # in fact selected
    }
  }

  # if the parent is already defined, assume all of its related FKs are selected
  # (even if they in fact are NOT in the select list). Keep a record of what we
  # assumed, and if any such phantom-column becomes part of our own collapser,
  # throw everything assumed-from-parent away and replace with the collapser of
  # the parent (whatever it may be)
  my $assumed_from_parent;
  unless ($args->{_parent_info}{underdefined}) {
    for my $col ( values %{$args->{_parent_info}{rel_condition} || {}} ) {
      next if exists $my_cols->{$col};
      $my_cols->{$col} = { via_collapse => $args->{_parent_info}{collapse_on_idcols} };
      $assumed_from_parent->{columns}{$col}++;
    }
  }

  # get colinfo for everything
  if ($my_cols) {
    my $ci = $self->columns_info;
    $my_cols->{$_}{colinfo} = $ci->{$_} for keys %$my_cols;
  }

  my $collapse_map;

  # first try to reuse the parent's collapser (i.e. reuse collapser over 1:1)
  # (makes for a leaner coderef later)
  unless ($collapse_map->{-idcols_current_node}) {
    $collapse_map->{-idcols_current_node} = $args->{_parent_info}{collapse_on_idcols}
      if $args->{_parent_info}{collapser_reusable};
  }


  # Still dont know how to collapse - try to resolve based on our columns (plus already inserted FK bridges)
  if (
    ! $collapse_map->{-idcols_current_node}
      and
    $my_cols
      and
    my $idset = $self->_identifying_column_set ({map { $_ => $my_cols->{$_}{colinfo} } keys %$my_cols})
  ) {
    # see if the resulting collapser relies on any implied columns,
    # and fix stuff up if this is the case
    my @reduced_set = grep { ! $assumed_from_parent->{columns}{$_} } @$idset;

    $collapse_map->{-idcols_current_node} = [ __unique_numlist(
      @{ $args->{_parent_info}{collapse_on_idcols}||[] },

      (map
        {
          my $fqc = join ('.',
            @{$args->{_rel_chain}}[1 .. $#{$args->{_rel_chain}}],
            ( $my_cols->{$_}{via_fk} || $_ ),
          );

          $common_args->{_as_fq_idx}->{$fqc};
        }
        @reduced_set
      ),
    )];
  }

  # Stil don't know how to collapse - keep descending down 1:1 chains - if
  # a related non-LEFT 1:1 is resolvable - its condition will collapse us
  # too
  unless ($collapse_map->{-idcols_current_node}) {
    my @candidates;

    for my $rel (keys %$relinfo) {
      next unless ($relinfo->{$rel}{is_single} && $relinfo->{$rel}{is_inner});

      if ( my $rel_collapse = $relinfo->{$rel}{rsrc}->_resolve_collapse ({
        as => $rel_cols->{$rel},
        _rel_chain => [ @{$args->{_rel_chain}}, $rel ],
        _parent_info => { underdefined => 1 },
      }, $common_args)) {
        push @candidates, $rel_collapse->{-idcols_current_node};
      }
    }

    # get the set with least amount of columns
    # FIXME - maybe need to implement a data type order as well (i.e. prefer several ints
    # to a single varchar)
    if (@candidates) {
      ($collapse_map->{-idcols_current_node}) = sort { scalar @$a <=> scalar @$b } (@candidates);
    }
  }

  # Stil don't know how to collapse, and we are the root node. Last ditch
  # effort in case we are *NOT* premultiplied.
  # Run through *each multi* all the way down, left or not, and all
  # *left* singles (a single may become a multi underneath) . When everything
  # gets back see if all the rels link to us definitively. If this is the
  # case we are good - either one of them will define us, or if all are NULLs
  # we know we are "unique" due to the "non-premultiplied" check
  if (
    ! $collapse_map->{-idcols_current_node}
      and
    ! $args->{premultiplied}
      and
    $common_args->{_node_idx} == 1
  ) {
    my (@collapse_sets, $uncollapsible_chain);

    for my $rel (keys %$relinfo) {

      # we already looked at these higher up
      next if ($relinfo->{$rel}{is_single} && $relinfo->{$rel}{is_inner});

      if (my $clps = $relinfo->{$rel}{rsrc}->_resolve_collapse ({
        as => $rel_cols->{$rel},
        _rel_chain => [ @{$args->{_rel_chain}}, $rel ],
        _parent_info => { underdefined => 1 },
      }, $common_args) ) {

        # for singles use the idcols wholesale (either there or not)
        if ($relinfo->{$rel}{is_single}) {
          push @collapse_sets, $clps->{-idcols_current_node};
        }
        elsif (! $relinfo->{$rel}{fk_map}) {
          $uncollapsible_chain = 1;
          last;
        }
        else {
          my $defined_cols_parent_side;

          for my $fq_col ( grep { /^$rel\.[^\.]+$/ } keys %{$args->{as}} ) {
            my ($col) = $fq_col =~ /([^\.]+)$/;

            $defined_cols_parent_side->{$_} = $args->{as}{$fq_col} for grep
              { $relinfo->{$rel}{fk_map}{$_} eq $col }
              keys %{$relinfo->{$rel}{fk_map}}
            ;
          }

          if (my $set = $self->_identifying_column_set([ keys %$defined_cols_parent_side ]) ) {
            push @collapse_sets, [ sort map { $defined_cols_parent_side->{$_} } @$set ];
          }
          else {
            $uncollapsible_chain = 1;
            last;
          }
        }
      }
      else {
        $uncollapsible_chain = 1;
        last;
      }
    }

    unless ($uncollapsible_chain) {
      # if we got here - we are good to go, but the construction is tricky
      # since our children will want to include our collapse criteria - we
      # don't give them anything (safe, since they are all collapsible on their own)
      # in addition we record the individual collapse posibilities
      # of all left children node collapsers, and merge them in the rowparser
      # coderef later
      $collapse_map->{-idcols_current_node} = [];
      $collapse_map->{-root_node_idcol_variants} = [ sort {
        (scalar @$a) <=> (scalar @$b) or max(@$a) <=> max(@$b)
      } @collapse_sets ];
    }
  }

  # stop descending into children if we were called by a parent for first-pass
  # and don't despair if nothing was found (there may be other parallel branches
  # to dive into)
  if ($args->{_parent_info}{underdefined}) {
    return $collapse_map->{-idcols_current_node} ? $collapse_map : undef
  }
  # nothing down the chain resolved - can't calculate a collapse-map
  elsif (! $collapse_map->{-idcols_current_node}) {
    $self->throw_exception ( sprintf
      "Unable to calculate a definitive collapse column set for %s%s: fetch more unique non-nullable columns",
      $self->source_name,
      @{$args->{_rel_chain}} > 1
        ? sprintf (' (last member of the %s chain)', join ' -> ', @{$args->{_rel_chain}} )
        : ''
      ,
    );
  }

  # If we got that far - we are collapsable - GREAT! Now go down all children
  # a second time, and fill in the rest

  $collapse_map->{-is_optional} = 1 if $args->{_parent_info}{is_optional};
  $collapse_map->{-node_index} = $common_args->{_node_idx}++;


  my @id_sets;
  for my $rel (sort keys %$relinfo) {

    $collapse_map->{$rel} = $relinfo->{$rel}{rsrc}->_resolve_collapse ({
      as => { map { $_ => 1 } ( keys %{$rel_cols->{$rel}} ) },
      _rel_chain => [ @{$args->{_rel_chain}}, $rel],
      _parent_info => {
        # shallow copy
        collapse_on_idcols => [ @{$collapse_map->{-idcols_current_node}} ],

        rel_condition => $relinfo->{$rel}{fk_map},

        is_optional => $collapse_map->{-is_optional},

        # if this is a 1:1 our own collapser can be used as a collapse-map
        # (regardless of left or not)
        collapser_reusable => @{$collapse_map->{-idcols_current_node}} && $relinfo->{$rel}{is_single},
      },
    }, $common_args );

    $collapse_map->{$rel}{-is_single} = 1 if $relinfo->{$rel}{is_single};
    $collapse_map->{$rel}{-is_optional} ||= 1 unless $relinfo->{$rel}{is_inner};
    push @id_sets, ( map { @$_ } (
      $collapse_map->{$rel}{-idcols_current_node},
      $collapse_map->{$rel}{-idcols_extra_from_children} || (),
    ));
  }

  if (@id_sets) {
    my $cur_nodeid_hash = { map { $_ => 1 } @{$collapse_map->{-idcols_current_node}} };
    $collapse_map->{-idcols_extra_from_children} = [ grep
      { ! $cur_nodeid_hash->{$_} }
      __unique_numlist( @id_sets )
    ];
  }

  return $collapse_map;
}

# Takes an arrayref of {as} dbic column aliases and the collapse and select
# attributes from the same $rs (the selector requirement is a temporary
# workaround... I hope), and returns a coderef capable of:
# my $me_pref_clps = $coderef->([$rs->cursor->next/all])
# Where the $me_pref_clps arrayref is the future argument to inflate_result()
#
# For an example of this coderef in action (and to see its guts) look at
# t/resultset/rowparser_internals.t
#
# This is a huge performance win, as we call the same code for every row
# returned from the db, thus avoiding repeated method lookups when traversing
# relationships
#
# Also since the coderef is completely stateless (the returned structure is
# always fresh on every new invocation) this is a very good opportunity for
# memoization if further speed improvements are needed
#
# The way we construct this coderef is somewhat fugly, although the result is
# really worth it. The final coderef does not perform any kind of recursion -
# the entire nested structure constructor is rolled out into a single scope.
#
# In any case - the output of this thing is meticulously micro-tested, so
# any sort of adjustment/rewrite should be relatively easy (fsvo relatively)
#
sub _mk_row_parser {
  my ($self, $args) = @_;

  my $inflate_index = { map
    { $args->{inflate_map}[$_] => $_ }
    ( 0 .. $#{$args->{inflate_map}} )
  };

  my $parser_src;

  # the non-collapsing assembler is easy
  # FIXME SUBOPTIMAL there could be a yet faster way to do things here, but
  # need to try an actual implementation and benchmark it:
  #
  # <timbunce_> First setup the nested data structure you want for each row
  #   Then call bind_col() to alias the row fields into the right place in
  #   the data structure, then to fetch the data do:
  # push @rows, dclone($row_data_struct) while ($sth->fetchrow);
  #
  if (!$args->{collapse}) {
    $parser_src = sprintf('$_ = %s for @{$_[0]}', __visit_infmap_simple(
      $inflate_index,
      { rsrc => $self }, # need the $rsrc to sanity-check inflation map once
    ));

    # change the quoted placeholders to unquoted alias-references
    $parser_src =~ s/ \' \xFF__VALPOS__(\d+)__\xFF \' /"\$_->[$1]"/gex;
  }

  # the collapsing parser is more complicated - it needs to keep a lot of state
  #
  else {
    my $collapse_map = $self->_resolve_collapse ({
      premultiplied => $args->{premultiplied},
      # FIXME
      # only consider real columns (not functions) during collapse resolution
      # this check shouldn't really be here, as fucktards are not supposed to
      # alias random crap to existing column names anyway, but still - just in
      # case
      # FIXME !!!! - this does not yet deal with unbalanced selectors correctly
      # (it is now trivial as the attrs specify where things go out of sync
      # needs MOAR tests)
      as => { map
        { ref $args->{selection}[$inflate_index->{$_}] ? () : ( $_ => $inflate_index->{$_} ) }
        keys %$inflate_index
      }
    });

    my @all_idcols = sort { $a <=> $b } map { @$_ } (
      $collapse_map->{-idcols_current_node},
      $collapse_map->{-idcols_extra_from_children} || (),
    );

    my ($top_node_id_path, $top_node_id_cacher, @path_variants);
    if (scalar @{$collapse_map->{-idcols_current_node}}) {
      $top_node_id_path = join ('', map
        { "{'\xFF__IDVALPOS__${_}__\xFF'}" }
        @{$collapse_map->{-idcols_current_node}}
      );
    }
    elsif( my @variants = @{$collapse_map->{-root_node_idcol_variants}} ) {
      my @path_parts;

      for (@variants) {

        push @path_variants, sprintf "(join qq(\xFF), '', %s, '')",
          ( join ', ', map { "'\xFF__VALPOS__${_}__\xFF'" } @$_ )
        ;

        push @path_parts, sprintf "( %s && %s)",
          ( join ' && ', map { "( defined '\xFF__VALPOS__${_}__\xFF' )" } @$_ ),
          $path_variants[-1];
        ;
      }

      $top_node_id_cacher = sprintf '$cur_row_ids[%d] = (%s);',
        $all_idcols[-1] + 1,
        "\n" . join( "\n  or\n", @path_parts, qq{"\0\$rows_pos\0"} );
      $top_node_id_path = sprintf '{$cur_row_ids[%d]}', $all_idcols[-1] + 1;
    }
    else {
      $self->throw_exception('Unexpected collapse map contents');
    }

    my $rel_assemblers = __visit_infmap_collapse (
      $inflate_index, { %$collapse_map, -custom_node_id => $top_node_id_path },
    );

    $parser_src = sprintf (<<'EOS', join(', ', @all_idcols), $top_node_id_path, $top_node_id_cacher||'', $rel_assemblers);
### BEGIN LITERAL STRING EVAL
  my ($rows_pos, $result_pos, $cur_row, @cur_row_ids, @collapse_idx, $is_new_res) = (0,0);

  # this loop is a bit arcane - the rationale is that the passed in
  # $_[0] will either have only one row (->next) or will have all
  # rows already pulled in (->all and/or unordered). Given that the
  # result can be rather large - we reuse the same already allocated
  # array, since the collapsed prefetch is smaller by definition.
  # At the end we cut the leftovers away and move on.
  while ($cur_row =
    ( ( $rows_pos >= 0 and $_[0][$rows_pos++] ) or do { $rows_pos = -1; undef } )
      ||
    ($_[1] and $_[1]->())
  ) {

    # due to left joins some of the ids may be NULL/undef, and
    # won't play well when used as hash lookups
    # we also need to differentiate NULLs on per-row/per-col basis
    #(otherwise folding of optional 1:1s will be greatly confused
    $cur_row_ids[$_] = defined $cur_row->[$_] ? $cur_row->[$_] : "\0NULL\xFF$rows_pos\xFF$_\0"
      for (%1$s);

    # maybe(!) cache the top node id calculation
    %3$s

    $is_new_res = ! $collapse_idx[1]%2$s and (
      $_[1] and $result_pos and (unshift @{$_[2]}, $cur_row) and last
    );

    %4$s

    $_[0][$result_pos++] = $collapse_idx[1]%2$s
      if $is_new_res;
  }

  splice @{$_[0]}, $result_pos; # truncate the passed in array for cases of collapsing ->all()
### END LITERAL STRING EVAL
EOS

    # !!! note - different var than the one above
    # change the quoted placeholders to unquoted alias-references
    $parser_src =~ s/ \' \xFF__VALPOS__(\d+)__\xFF \' /"\$cur_row->[$1]"/gex;
    $parser_src =~ s/ \' \xFF__IDVALPOS__(\d+)__\xFF \' /"\$cur_row_ids[$1]"/gex;
  }

  $parser_src;
}

# the simple non-collapsing nested structure recursor
sub __visit_infmap_simple {
  my ($val_idx, $args) = @_;

  my $my_cols = {};
  my $rel_cols;
  for (keys %$val_idx) {
    if ($_ =~ /^ ([^\.]+) \. (.+) /x) {
      $rel_cols->{$1}{$2} = $val_idx->{$_};
    }
    else {
      $my_cols->{$_} = $val_idx->{$_};
    }
  }
  my @relperl;
  for my $rel (sort keys %$rel_cols) {

    # DISABLEPRUNE
    #my $optional = $args->{is_optional};
    #$optional ||= ($args->{rsrc}->relationship_info($rel)->{attrs}{join_type} || '') =~ /^left/i;

    push @relperl, join ' => ', perlstring($rel), __visit_infmap_simple($rel_cols->{$rel}, {
      rsrc => __get_related_source($args->{rsrc}, $rel, $rel_cols->{$rel}),
      # DISABLEPRUNE
      #non_top => 1,
      #is_optional => $optional,
    });

    # FIXME SUBOPTIMAL DISABLEPRUNE - disabled to satisfy t/resultset/inflate_result_api.t
    #if ($optional and my @branch_null_checks = map
    #  { "(! defined '\xFF__VALPOS__${_}__\xFF')" }
    #  sort { $a <=> $b } values %{$rel_cols->{$rel}}
    #) {
    #  $relperl[-1] = sprintf ( '(%s) ? ( %s => [] ) : ( %s )',
    #    join (' && ', @branch_null_checks ),
    #    perlstring($rel),
    #    $relperl[-1],
    #  );
    #}
  }

  my $me_struct = keys %$my_cols
    ? __visit_dump({ map { $_ => "\xFF__VALPOS__$my_cols->{$_}__\xFF" } (keys %$my_cols) })
    : 'undef'
  ;

  return sprintf '[%s]', join (',',
    $me_struct,
    @relperl ? sprintf ('{ %s }', join (',', @relperl)) : (),
  );
}

# the collapsing nested structure recursor
sub __visit_infmap_collapse {

  my ($val_idx, $collapse_map, $parent_info) = @_;

  my $my_cols = {};
  my $rel_cols;
  for (keys %$val_idx) {
    if ($_ =~ /^ ([^\.]+) \. (.+) /x) {
      $rel_cols->{$1}{$2} = $val_idx->{$_};
    }
    else {
      $my_cols->{$_} = $val_idx->{$_};
    }
  }

  my $sequenced_node_id = $collapse_map->{-custom_node_id} || join ('', map
    { "{'\xFF__IDVALPOS__${_}__\xFF'}" }
    @{$collapse_map->{-idcols_current_node}}
  );

  my $me_struct = keys %$my_cols
    ? __visit_dump([{ map { $_ => "\xFF__VALPOS__$my_cols->{$_}__\xFF" } (keys %$my_cols) }])
    : undef
  ;
  my $node_idx_ref = sprintf '$collapse_idx[%d]%s', $collapse_map->{-node_index}, $sequenced_node_id;

  my $parent_idx_ref = sprintf( '$collapse_idx[%d]%s[1]{%s}',
    @{$parent_info}{qw/node_idx sequenced_node_id/},
    perlstring($parent_info->{relname}),
  ) if $parent_info;

  my @src;
  if ($collapse_map->{-node_index} == 1) {
    push @src, sprintf( '%s ||= %s;',
      $node_idx_ref,
      $me_struct,
    ) if $me_struct;
  }
  elsif ($collapse_map->{-is_single}) {
    push @src, sprintf ( '%s ||= %s%s;',
      $parent_idx_ref,
      $node_idx_ref,
      $me_struct ? " ||= $me_struct" : '',
    );
  }
  else {
    push @src, sprintf('push @{%s}, %s%s unless %s;',
      $parent_idx_ref,
      $node_idx_ref,
      $me_struct ? " ||= $me_struct" : '',
      $node_idx_ref,
    );
  }

  # DISABLEPRUNE
  #my $known_defined = { %{ $parent_info->{known_defined} || {} } };
  #$known_defined->{$_}++ for @{$collapse_map->{-idcols_current_node}};
  for my $rel (sort keys %$rel_cols) {

#    push @src, sprintf(
#      '%s[1]{%s} ||= [];', $node_idx_ref, perlstring($rel)
#    ) unless $collapse_map->{$rel}{-is_single};

    push @src,  __visit_infmap_collapse($rel_cols->{$rel}, $collapse_map->{$rel}, {
      node_idx => $collapse_map->{-node_index},
      sequenced_node_id => $sequenced_node_id,
      relname => $rel,
      # DISABLEPRUNE
      #known_defined => $known_defined,
    });

    # FIXME SUBOPTIMAL DISABLEPRUNE - disabled to satisfy t/resultset/inflate_result_api.t
    #if ($collapse_map->{$rel}{-is_optional} and my @null_checks = map
    #  { "(! defined '\xFF__IDVALPOS__${_}__\xFF')" }
    #  sort { $a <=> $b } grep
    #    { ! $known_defined->{$_} }
    #    @{$collapse_map->{$rel}{-idcols_current_node}}
    #) {
    #  $src[-1] = sprintf( '(%s) or %s',
    #    join (' || ', @null_checks ),
    #    $src[-1],
    #  );
    #}
  }

  join "\n", @src;
}

# adding a dep on MoreUtils *just* for this is retarded
sub __unique_numlist {
  sort { $a <=> $b } keys %{ {map { $_ => 1 } @_ }}
}

# This error must be thrown from two distinct codepaths, joining them is
# rather hard. Go for this hack instead.
sub __get_related_source {
  my ($rsrc, $rel, $relcols) = @_;
  try {
    $rsrc->related_source ($rel)
  } catch {
    $rsrc->throw_exception(sprintf(
      "Can't inflate prefetch into non-existent relationship '%s' from '%s', "
    . "check the inflation specification (columns/as) ending in '...%s.%s'.",
      $rel,
      $rsrc->source_name,
      $rel,
      (sort { length($a) <=> length ($b) } keys %$relcols)[0],
  ))};
}

# keep our own DD object around so we don't have to fitz with quoting
my $dumper_obj;
sub __visit_dump {
  # we actually will be producing functional perl code here,
  # thus no second-guessing of what these globals might have
  # been set to. DO NOT CHANGE!
  ($dumper_obj ||= do {
    require Data::Dumper;
    Data::Dumper->new([])
      ->Useperl (0)
      ->Purity (1)
      ->Pad ('')
      ->Useqq (0)
      ->Terse (1)
      ->Quotekeys (1)
      ->Deepcopy (0)
      ->Deparse (0)
      ->Maxdepth (0)
      ->Indent (0)  # faster but harder to read, perhaps leave at 1 ?
  })->Values ([$_[0]])->Dump;
}

1;
