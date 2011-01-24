# An Operator is fragment of code that can have operands plugged in;
# they abstract functions, macros, and some syntactic forms like
# method calls.
#
class Operator;

use Body;
use Sig;

has $.whatever_curry;
has $.assignish;

method with_args ($/, *@_) { !!! }

sub node($M) { { line => $M.cursor.lineof($M.to) } }

sub mklet($value, $body) {
    my $var = ::GLOBAL::NieczaActions.gensym;
    ::Op::Let.new(var => $var, to => $value,
        in => $body(::Op::LetVar.new(name => $var)));
}

sub mklex($/, $name) { ::Op::Lexical.new(|node($/), :$name); }

sub mkcall($/, $name, *@positionals) {
    ::Op::CallSub.new(|node($/),
        invocant => ::Op::Lexical.new(|node($/), :$name), :@positionals);
}

method as_function($/) {
    $/.CURSOR.sorry("This macro cannot be used as a function");
    mklex($/, '&die');
}

method whatever_curry() { False }
method assignish() { False }

method meta_assign() { ::Operator::CompoundAssign.new(base => self); }
method meta_not() { ::Operator::MetaNot.new(base => self); }
method meta_fun($/, $fun, *@extra) {
    ::Operator::Function.new(function => mklex($/, $fun),
        preargs => [ @extra, self.as_function($/) ])
}

method funop($name, *@args) {
    ::Operator::Function.new(function => ::Op::Lexical.new(name => $name),
        args => @args)
}

method wrap_in_function($/) {
    my @args;
    my $i = -self.arity;
    while $i++ { push @args, ::GLOBAL::NieczaActions.gensym }
    my $do = self.with_args($/, map { mklex($/, $_) }, @args);
    ::Op::SubDef.new(|node($/), var => ::GLOBAL::NieczaActions.gensym,
        body => Body.new( :transparent, signature => Sig.simple(@args), :$do));
}

class Function is Operator {
    has $.function; # Op; .++; use args for assuming-nature (but at end)
    has $.arity;
    constant $empty = [];
    has $.args = $empty; # Array of Op
    has $.preargs = $empty; # Array of Op

    method as_function($/) {
        if $.args || $.preargs {
            self.wrap_in_function($/)
        } else {
            $.function
        }
    }

    method with_args($/, *@args) {
        ::Op::CallSub.new(|node($/), invocant => $.function,
            positionals => [ @$.preargs, @args, @$.args ])
    }

    method !name() {
        $.function.^isa(::Op::Lexical) ?? $.function.name !! ""
    }

    method assignish() { self!name eq '&infix:<=>' }

    my %nowhatever = map { ($_ => True) }, '&infix:<..>', '&infix:<..^>',
        '&infix:<^..>', '&infix:<^..^>', '&infix:<...>', '&infix:<...^>',
        '&infix:<,>', '&infix:<=>', '&infix:<xx>';
    method whatever_curry() { !%nowhatever{self!name} }
}

class PostCall is Operator {
    # .(12); use args
    has $.args = [];

    method with_args($/, *@args) {
        ::Op::CallSub.new(|node($/),
            invocant => @args[0],
            args => [ @$.args ]);
    }

    method as_function($/) { self.wrap_in_function($/, 1) }
    method arity() { 1 }
}

class Method is Operator {
    has $.name; # Str | Op; .foo; use args, meta, private, path
    has $.args = [];
    has $.meta; # Bool
    has $.private; # Bool
    has $.path; # Array of Str

    method clone(*%_) {
        self.new(name => $!name, args => $!args, meta => $!meta,
            private => $!private, path => $!path, |%_);
    }

    method as_function($/) { self.wrap_in_function($/) }
    method arity() { 1 }

    method with_args($/, *@args) {
        if ($.name eq 'HOW' || $.name eq 'WHAT') && !$.private && !$.meta {
            if $.args {
                $/.CURSOR.sorry("Interrogative operator $.name does not take arguments");
                return ::Op::StatementList.new;
            }
            ::Op::Interrogative.new(|node($/), receiver => @args[0],
                name => $.name);
        } else {
            if defined($.path) && !$.private {
                $/.CURSOR.sorry("Qualified references to non-private methods NYI");
            }
            ::Op::CallMethod.new(|node($/),
                receiver => @args[0],
                ismeta   => $.meta,
                name     => $.name,
                private  => $.private,
                ppath    => $.path,
                args     => [ @$.args ]);
        }
    }
    method whatever_curry() { True }
}

class ShortCircuit is Operator {
    has $.kind; # Str

    method with_args($/, *@args) {
        ::Op::ShortCircuit.new(|node($/), kind => $.kind, args => [ @args ])
    }

    method whatever_curry() { True }
}

class CompoundAssign is Operator {
    has $.base; # Operator

    method with_args($/, $left, *@rest) {
        if $left.^isa(::Op::Lexical) {
            my $nlft = ::Op::Lexical.new(|node($/), name => $left.name);
            mkcall($/, '&infix:<=>', $left, $.base.with_args($/, $nlft, @rest));
        } else {
            mklet($left, -> $ll {
                mkcall($/, '&infix:<=>', $ll, $.base.with_args($/, $ll, @rest)) });
        }
    }

    method as_function($/) { self.wrap_in_function($/) }
    method arity() { $.base.arity }

    method assignish() { True }
}

class MetaNot is Operator {
    has $.base; # Operator

    method with_args($/, *@args) {
        mkcall($/, '&prefix:<!>', $.base.with_args($/, @args));
    }

    method whatever_curry() { True }
}

class Binding is Operator {
    has $.readonly; # Bool

    method with_args($/, *@args) {
        ::Op::Bind.new(|node($/), readonly => $.readonly, lhs => @args[0],
            rhs => @args[1]);
    }

    method assignish() { True }
}

class Comma is Operator {
    method with_args($/, *@args) {
        my @bits;
        for @args -> $a {
            push @bits, $a.^isa(::Op::SimpleParcel) ?? @( $a.items ) !! $a;
        }
        ::Op::SimpleParcel.new(|node($/), items => @bits);
    }
    method as_function($/) { mklex($/, '&infix:<,>') }
}

class Ternary is Operator {
    has $.middle; # Op
    method with_args($/, *@args) {
        ::Op::Conditional.new(|node($/), check => @args[0], true => $.middle,
            false => @args[1]);
    }
}

class Temp is Operator {
    method with_args($/, *@args) {
        my $rarg = @args[0];
        if !$rarg.^isa(::Op::ContextVar) || $rarg.uplevel {
            $/.CURSOR.sorry('Non-contextual case of temp NYI');
            return ::Op::StatementList.new;
        }
        mkcall($/, '&infix:<=>',
            ::Op::Lexical.new(name => $rarg.name, declaring => True,
                        hash => substr($rarg.name,0,1) eq '%',
                        list => substr($rarg.name,0,1) eq '@'),
            ::Op::ContextVar.new(name => $rarg.name, uplevel => 1));
    }
}