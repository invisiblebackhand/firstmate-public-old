use strict;
use warnings;
use JSON::PP;

# Lavish emits flat prompt rows as TOON CSV, and switches the entire block to
# expanded mappings when one row has a nested target. Return the same hashes
# for both shapes so presentation and keyed-answer intake share one verdict.
# A text selection's target nests one level further: its `start` and `end` are
# mappings of scalars and inline arrays (`path[2]: 0,1`, or `path: []` when
# empty). Nothing deeper or different is understood, and it is refused.
sub lavish_rows {
  my ($path, $allow_empty) = @_;
  open my $fh, '<:encoding(UTF-8)', $path or die "cannot read Lavish result: $!\n";
  my @lines = <$fh>;
  close $fh or die "cannot read Lavish result: $!\n";

  my ($header, $want, $shape, @fields);
  for my $i (0 .. $#lines) {
    my $line = $lines[$i];
    if ($line =~ /^(prompts|feedback)\[(\d+)\]\{([^}]*)\}:\s*$/) {
      ($header, $want, $shape, @fields) = ($i, $2, 'table', split /,/, $3);
      die "cannot read Lavish table fields: empty field list\n" unless @fields;
      last;
    }
    if ($line =~ /^(prompts|feedback)\[(\d+)\]:\s*$/) {
      ($header, $want, $shape) = ($i, $2, 'expanded');
      last;
    }
    die "cannot read Lavish content block header: $line"
      if $line =~ /^(?:prompts|feedback|[A-Za-z][A-Za-z0-9_-]*\[)/;
  }
  if (!defined $header) {
    die "cannot read Lavish content block: no recognized header\n" unless $allow_empty;
    return (0, [], 0);
  }

  my @rows;
  my $malformed = 0;
  my ($boundary, $boundary_name);  # the start/end mapping the current lines fill
  for my $i ($header + 1 .. $#lines) {
    my $line = $lines[$i];
    last unless $line =~ /^\s/;
    chomp $line;
    if ($shape eq 'table') {
      die "cannot read Lavish table items: more than $want rows\n"
        if @rows + $malformed >= $want;
      $line =~ s/^\s+//;
      my @vals;
      while (length $line) {
        if ($line =~ s/^"((?:[^"\\]|\\.)*)"//) {
          push @vals, $1;
        } else {
          $line =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $line =~ s/^,//;
      }
      if (@vals > @fields) {
        my ($preserve) = grep { $fields[$_] eq 'prompt' } 0 .. $#fields;
        ($preserve) = grep { $fields[$_] eq 'text' } 0 .. $#fields unless defined $preserve;
        if (defined $preserve) {
          my @parts = splice @vals, $preserve, @vals - @fields + 1;
          splice @vals, $preserve, 0, join(',', @parts);
        }
      }
      if (@vals != @fields) {
        $malformed++;
        next;
      }
      s/\\(.)/$1 eq 'n' ? "\n" : $1 eq 't' ? "\t" : $1 eq 'r' ? "\r" : $1/ge for @vals;
      my %row;
      $row{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      push @rows, \%row;
      next;
    }

    if ($line =~ /^  - ([A-Za-z][A-Za-z0-9]*):\s*(.*)$/) {
      die "cannot read Lavish expanded item: too many rows\n" if @rows >= $want;
      push @rows, {};
      $boundary = undef;
      my ($key, $value) = ($1, $2);
      $rows[-1]{$key} = lavish_scalar($value);
    } elsif ($line =~ /^    ([A-Za-z][A-Za-z0-9]*):\s*(.*)$/) {
      die "cannot read Lavish expanded item: field before item\n" unless @rows;
      $boundary = undef;
      my ($key, $value) = ($1, $2);
      if ($key eq 'target') {
        die "cannot read Lavish expanded target: expected mapping\n" if length $value;
        $rows[-1]{target} = {};
      } else {
        die "cannot read Lavish expanded field $key: expected scalar\n" unless length $value;
        $rows[-1]{$key} = lavish_scalar($value);
      }
    } elsif ($line =~ /^      ([A-Za-z][A-Za-z0-9]*):\s*(.*)$/) {
      die "cannot read Lavish expanded target: field outside target\n"
        unless @rows && ref($rows[-1]{target}) eq 'HASH';
      $boundary = undef;
      my ($key, $value) = ($1, $2);
      if (!length $value && ($key eq 'start' || $key eq 'end')) {
        $boundary = $rows[-1]{target}{$key} = {};
        $boundary_name = $key;
      } else {
        die "cannot read Lavish expanded target field $key: expected scalar\n" unless length $value;
        $rows[-1]{target}{$key} = lavish_scalar($value);
      }
    } elsif ($line =~ /^        ([A-Za-z][A-Za-z0-9]*)(?:\[(\d+)\])?:\s*(.*)$/) {
      die "cannot read Lavish expanded target: field outside mapping\n" unless $boundary;
      my ($key, $count, $value) = ($1, $2, $3);
      $boundary->{$key} = lavish_boundary_value("$boundary_name.$key", $count, $value);
    } else {
      die "cannot read Lavish expanded item line: $line\n";
    }
  }
  if ($shape eq 'expanded') {
    die "cannot read Lavish expanded items: declared $want, found " . scalar(@rows) . "\n"
      unless @rows == $want;
    for my $row (@rows) {
      for my $field (qw(uid prompt selector tag text)) {
        die "cannot read Lavish expanded item: missing $field\n" unless exists $row->{$field};
      }
    }
  }
  return ($want, \@rows, $malformed);
}

sub lavish_scalar {
  my ($value) = @_;
  return $value unless $value =~ /^"/;
  my $decoded = eval { JSON::PP->new->utf8(0)->decode($value) };
  die "cannot read Lavish expanded quoted scalar: $value\n" if $@ || ref($decoded);
  return $decoded;
}

# One field of a start/end mapping: a scalar, or an inline array `key[N]: a,b`
# whose declared count must match what follows. An empty array is the literal
# `key: []` or a declared count of zero. Arrays Lavish would spread over
# following lines are refused.
sub lavish_boundary_value {
  my ($name, $count, $value) = @_;
  if (defined $count) {
    my @items = length $value ? lavish_inline_items($name, $value) : ();
    die "cannot read Lavish expanded target field $name: declared $count, found " . scalar(@items) . "\n"
      unless @items == $count;
    return \@items;
  }
  die "cannot read Lavish expanded target field $name: expected scalar\n" unless length $value;
  return [] if $value eq '[]';
  return lavish_scalar($value);
}

sub lavish_inline_items {
  my ($name, $text) = @_;
  my @items;
  while (1) {
    if ($text =~ s/^("(?:[^"\\]|\\.)*")//) {
      push @items, lavish_scalar($1);
    } else {
      $text =~ s/^([^,"]*)//;
      push @items, $1;
    }
    last unless length $text;
    $text =~ s/^,//
      or die "cannot read Lavish expanded target field $name: malformed inline array\n";
  }
  return @items;
}

1;
