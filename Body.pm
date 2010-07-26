use strict;
use warnings;
use 5.010;
use CodeGen ();
use CgOp ();

{
    package Body;
    use Moose;

    has name      => (isa => 'Str', is => 'rw', default => "anon");
    has do        => (isa => 'Op', is => 'rw');
    has enter     => (isa => 'ArrayRef[Op]', is => 'ro',
        default => sub { [] });
    has outer     => (isa => 'Body', is => 'rw', init_arg => undef);
    has setting   => (is => 'rw');
    has decls     => (isa => 'ArrayRef', is => 'ro', default => sub { [] });
    has code      => (isa => 'CodeGen', is => 'ro', init_arg => undef,
        lazy => 1, builder => 'gen_code');
    has signature => (isa => 'Maybe[Sig]', is => 'ro');
    has mainline  => (isa => 'Bool', is => 'ro', lazy => 1,
        builder => 'is_mainline');
    # currently used types are phaser, loop, cond, class, mainline, bare, sub
    # also '' for incorrectly contextualized {p,x,}block, blast
    has type      => (isa => 'Str', is => 'rw');

    has lexical   => (isa => 'HashRef[Str]', is => 'ro', lazy_build => 1);
    # my $x inside, floats out; mostly for blasts; set by context so must be rw
    has transparent => (isa => 'Bool', is => 'rw', default => 0);

    sub _build_lexical {
        my ($self) = @_;

        +{ map { $_->used_slots } @{ $self->_alldecls } };
    }

    sub is_mainline {
        my $self = shift;

        if ($self->type && $self->type eq 'mainline') {
            return 1;
        }

        if (!($self->type) || !($self->outer)) {
            die "Critical phase error";
        }

        if ($self->type =~ /^(?:bare|package|module|class|grammar|role|slang|knowhow)$/) {
            return $self->outer->mainline;
        } else {
            return 0;
        }
    }

    sub floated_decls {
        my ($self) = @_;
        my @r;
        push @r, $self->do->local_decls if $self->transparent;
        push @r, map { $_->outer_decls } @{ $self->_alldecls }
            if $self->type ne 'mainline';
        @r;
    }

    has _alldecls => (isa => 'ArrayRef[Decl]', is => 'ro', lazy_build => 1);
    sub _build__alldecls {
        my ($self) = @_;
        my @x = @{ $self->decls };
        unshift @x, $self->do->local_decls if !$self->transparent;
        unshift @x, $self->signature->local_decls if $self->signature;
        @x = map { $_->extra_decls, $_ } @x;
        @x = map { $_->outer_decls, $_ } @x if $self->type eq 'mainline';
        unshift @x, Decl::PackageLink->new(name => '$?GLOBAL')
            if $self->type eq 'mainline';
        unshift @x, Decl::PackageLink->new(name => '$?CURPKG')
            if $self->type =~ /mainline|class|package|grammar|module|role|slang|knowhow/;
        \@x;
    }

    sub gen_code {
        my ($self) = @_;
        # TODO: Bind a return value here to catch non-ro sub use
        CodeGen->new(name => $self->name, body => $self,
            lex2type => +{ %{ $self->lexical } },
            ops => CgOp::prog($self->enter_code,
                CgOp::return($self->do->code($self))));
    }

    sub enter_code {
        my ($self) = @_;
        my @p;
        push @p, map { $_->enter_code($self) } @{ $self->_alldecls };
        push @p, $self->signature->binder if $self->signature;
        push @p, map { CgOp::sink($_->code($self)) } @{ $self->enter };
        CgOp::prog(@p);
    }

    sub write {
        my ($self) = @_;
        $self->code->write;
        $_->write($self) for (@{ $self->_alldecls });
    }

    sub preinit_code {
        my ($self) = @_;
        CgOp::prog(map { $_->preinit_code($self) } @{ $self->_alldecls });
    }

    sub lex_level {
        my ($self, $var) = @_;

        if ($self->lexical->{$var}) {
            return 0;
        } elsif ($self->outer) {
            return 1 + $self->outer->lex_level($var);
        } else {
            my $i = 1;
            my $st = $self->setting;
            while ($st) {
                return $i if ($st->{$var});
                $i++;
                $st = $st->{'OUTER::'};
            }
            return -1e99999;
        }
    }

    sub gen_setting {
        my ($self) = @_;
        my %h = %{ $self->lexical };
        $h{'OUTER::'} = $self->outer ? $self->outer->gen_setting :
            $self->setting;
        \%h;
    }

    # In order to support proper COMMON semantics on package variables
    # we have only one operation here - autovivifying lookup.
    #
    # This should be used for all accesses like $a::b, $::b.  $a is a simple
    # lexical.
    sub lookup_var {
        my ($self, $name, @path) = @_;

        if (@path) {
            return $self->lookup_pkg((map { $_ . "::" } @path),
                (defined $name) ? ($name) : ());
        } else {
            # This is supposed to dwimmily do MY:: or OUR::, neither of which
            # is implemented.  So...
            die "\$::x is not yet implemented";
        }
    }

    sub lookup_pkg {
        my ($self, @components) = @_;

        my $pkgcg;
        # TODO: S02 says PROCESS:: and GLOBAL:: are also accessible as lexical
        # packages in UNIT::.
        if ($components[0] eq 'PROCESS::') {
            $pkgcg = CgOp::rawsget('Kernel.Process');
            shift @components;
        } elsif ($components[0] eq 'GLOBAL::') {
            $pkgcg = CgOp::scopedlex('$?GLOBAL');
            shift @components;
        } elsif ($components[0] eq 'OUR::') {
            $pkgcg = CgOp::scopedlex('$?CURPKG');
            shift @components;
        } elsif ($self->lex_level($components[0]) >= 0) {
            $pkgcg = CgOp::scopedlex($components[0]);
            shift @components;
        } else {
            $pkgcg = CgOp::scopedlex('$?GLOBAL');
        }

        for my $c (@components) {
            $pkgcg = CgOp::rawscall('Kernel.PackageLookup', CgOp::fetch($pkgcg),
                CgOp::clr_string($c));
        }

        $pkgcg;
    }

    __PACKAGE__->meta->make_immutable;
    no Moose;
}

1;
