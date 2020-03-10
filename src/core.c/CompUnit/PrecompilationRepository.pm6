role CompUnit::PrecompilationRepository {
    method try-load(
        CompUnit::PrecompilationDependency::File $dependency,
        IO::Path :$source,
        CompUnit::PrecompilationStore :@precomp-stores,
        --> CompUnit::Handle:D) {
        Nil
    }

    method load(CompUnit::PrecompilationId $id --> Nil) { }

    method may-precomp(--> True) {
        # would be a good place to check an environment variable
    }
}

BEGIN CompUnit::PrecompilationRepository::<None> :=
  CompUnit::PrecompilationRepository.new;

class CompUnit { ... }
class CompUnit::PrecompilationRepository::Default
  does CompUnit::PrecompilationRepository
{
    has CompUnit::PrecompilationStore:D $.store is required is built(:bind);
    has $!RMD;

    method TWEAK() { $!RMD := $*RAKUDO_MODULE_DEBUG }

    my $loaded        := nqp::hash;
    my $resolved      := nqp::hash;
    my $loaded-lock   := Lock.new;
    my $first-repo-id;

    my $compiler-id :=
      CompUnit::PrecompilationId.new-without-check(Compiler.id);

    my $lle        := Rakudo::Internals.LL-EXCEPTION;
    my $profile    := Rakudo::Internals.PROFILE;
    my $optimize   := Rakudo::Internals.OPTIMIZE;
    my $stagestats := Rakudo::Internals.STAGESTATS;
    my $target     := "--target=" ~ Rakudo::Internals.PRECOMP-TARGET;

    sub CHECKSUM(IO::Path:D $path --> Str:D) {
        my \slurped := $path.slurp(:enc<iso-8859-1>);
        nqp::istype(slurped,Failure)
          ?? slurped
          !! nqp::sha1(slurped)
    }

    method try-load(
      CompUnit::PrecompilationDependency::File:D $dependency,
      IO::Path:D :$source = $dependency.src.IO,
      CompUnit::PrecompilationStore :@precomp-stores =
        Array[CompUnit::PrecompilationStore].new($.store),
     --> CompUnit::Handle:D) {

        my $id := $dependency.id;
        $!RMD("try-load $id: $source")
          if $!RMD;

        # Even if we may no longer precompile, we should use already loaded files
        $loaded-lock.protect: {
            if nqp::atkey($loaded,$id.Str) -> \precomped {
                return precomped;
            }
        }

        my ($handle, $checksum) = (
            self.may-precomp and (
                my $precomped := self.load($id, :source($source), :checksum($dependency.checksum), :@precomp-stores) # already precompiled?
                or self.precompile($source, $id, :source-name($dependency.source-name), :force(nqp::hllbool(nqp::istype($precomped,Failure))), :@precomp-stores)
                    and self.load($id, :@precomp-stores) # if not do it now
            )
        );

        if $*W -> $World {
            if $World.record_precompilation_dependencies {
                if $handle {
                    $dependency.checksum = $checksum;
                    say $dependency.serialize;
                    $*OUT.flush;
                }
                else {
                    nqp::exit(0);
                }
            }
        }

        $handle ?? $handle !! Nil
    }

    method !load-handle-for-path(CompUnit::PrecompilationUnit:D $unit) {
        $!RMD("Loading precompiled\n$unit")
          if $!RMD;

        my $preserve_global := nqp::ifnull(nqp::gethllsym('Raku','GLOBAL'),Mu);
#?if !jvm
        my $handle := CompUnit::Loader.load-precompilation-file($unit.bytecode-handle);
#?endif
#?if jvm
        my $handle := CompUnit::Loader.load-precompilation($unit.bytecode);
#?endif
        nqp::bindhllsym('Raku', 'GLOBAL', $preserve_global);
        CATCH {
            default {
                nqp::bindhllsym('Raku', 'GLOBAL', $preserve_global);
                .throw;
            }
        }
        $handle
    }

    method !load-file(
      CompUnit::PrecompilationStore @precomp-stores,
      CompUnit::PrecompilationId:D $id,
      Bool :$repo-id,
      Bool :$refresh,
    ) {
        for @precomp-stores -> $store {
            $!RMD("Trying to load {
                $id ~ ($repo-id ?? '.repo-id' !! '')
            } from $store.prefix()")
              if $!RMD;

            $store.remove-from-cache($id) if $refresh;
            my $file := $repo-id
                ?? $store.load-repo-id($compiler-id, $id)
                !! $store.load-unit($compiler-id, $id);
            return $file if $file;
        }
        Nil
    }

    method !load-dependencies(
      CompUnit::PrecompilationUnit:D $precomp-unit,
      @precomp-stores
    --> Bool:D) {
        my $resolve    := False;
        my $REPO       := $*REPO;
        my $REPO-id    := $REPO.id;
        $first-repo-id := $REPO-id unless $first-repo-id;
        my $unit-id    := self!load-file(
                            @precomp-stores, $precomp-unit.id, :repo-id);

        if $unit-id ne $REPO-id {
            $!RMD("Repo changed:
  $unit-id
  $REPO-id
Need to re-check dependencies.")
              if $!RMD;

            $resolve := True;
        }

        if $unit-id ne $first-repo-id {
            $!RMD("Repo chain changed:
  $unit-id
  $first-repo-id
Need to re-check dependencies.")
              if $!RMD;

            $resolve := True;
        }

        $resolve := False unless %*ENV<RAKUDO_RERESOLVE_DEPENDENCIES> // 1;

        my @dependencies;
        for $precomp-unit.dependencies -> $dependency {
            $!RMD("dependency: $dependency")
              if $!RMD;

            if $resolve {
                $loaded-lock.protect: {
                    my str $serialized-id = $dependency.serialize;
                    nqp::ifnull(
                      nqp::atkey($resolved,$serialized-id),
                      nqp::bindkey($resolved,$serialized-id, do {
                        my $comp-unit := $REPO.resolve($dependency.spec);
                        $!RMD("Old id: $dependency.id(), new id: {
                            $comp-unit.repo-id
                        }")
                          if $!RMD;

                        return False
                          unless $comp-unit
                             and $comp-unit.repo-id eq $dependency.id;

                        True
                      })
                    );
                }
            }

            my $dependency-precomp = @precomp-stores
                .map({ $_.load-unit($compiler-id, $dependency.id) })
                .first(*.defined)
                or do {
                    $!RMD("Could not find $dependency.spec()") if $!RMD;
                    return False;
                }
            unless $dependency-precomp.is-up-to-date(
              $dependency,
              :check-source($resolve)
            ) {
                $dependency-precomp.close;
                return False;
            }

            @dependencies.push: $dependency-precomp;
        }

        $loaded-lock.protect: {
            for @dependencies -> $dependency-precomp {
                nqp::bindkey(
                  $loaded,
                  $dependency-precomp.id.Str,
                  self!load-handle-for-path($dependency-precomp)
                ) unless nqp::existskey($loaded,$dependency-precomp.id.Str);

                $dependency-precomp.close;
            }
        }

        # report back id and source location of dependency to dependant
        if $*W -> $World {
            if $World.record_precompilation_dependencies {
                for $precomp-unit.dependencies -> $dependency {
                    say $dependency.serialize;
                }
                $*OUT.flush;
            }
        }

        if $resolve {
            if self.store.destination(
                 $compiler-id,
                 $precomp-unit.id,
                 :extension<.repo-id>
            ) {
                self.store.store-repo-id(
                  $compiler-id,
                  $precomp-unit.id,
                  :repo-id($unit-id)
                );
                self.store.unlock;
            }
        }
        True
    }

    proto method load(|) {*}

    multi method load(
      Str:D $id,
      Instant :$since,
      IO::Path :$source,
      CompUnit::PrecompilationStore :@precomp-stores =
        Array[CompUnit::PrecompilationStore].new($.store),
    ) {
        self.load(
          CompUnit::PrecompilationId.new($id), :$since, :@precomp-stores)
    }

    multi method load(
      CompUnit::PrecompilationId:D $id,
      IO::Path :$source,
      Str :$checksum is copy,
      Instant :$since,
      CompUnit::PrecompilationStore :@precomp-stores =
        Array[CompUnit::PrecompilationStore].new($.store),
    ) {
        $loaded-lock.protect: {
            if nqp::atkey($loaded,$id.Str) -> \precomped {
                return precomped;
            }
        }

        if self!load-file(@precomp-stores, $id) -> $unit {
            if (not $since or $unit.modified > $since)
                and (not $source or ($checksum //= CHECKSUM($source)) eq $unit.source-checksum)
                and self!load-dependencies($unit, @precomp-stores)
            {
                my $unit-checksum := $unit.checksum;
                my $precomped := self!load-handle-for-path($unit);
                $unit.close;
                $loaded-lock.protect: {
                    nqp::bindkey($loaded,$id.Str,$precomped)
                }
                ($precomped, $unit-checksum)
            }
            else {
                $!RMD("Outdated precompiled {$unit}{
                    $source ?? " for $source" !! ''
                }\n    mtime: {$unit.modified}{
                    $since ?? ", since: $since" !! ''}
                \n    checksum: {
                    $unit.source-checksum
                }, expected: $checksum")
                  if $!RMD;

                $unit.close;
                Failure.new("Outdated precompiled $unit");
            }
        }
        else {
            Nil
        }
    }

    proto method precompile(|) {*}

    multi method precompile(
        IO::Path:D $path,
        Str $id,
        Bool :$force = False,
        :$source-name = $path.Str
    ) {
        self.precompile($path, CompUnit::PrecompilationId.new($id), :$force, :$source-name)
    }

    multi method precompile(
        IO::Path:D $path,
        CompUnit::PrecompilationId $id,
        Bool :$force = False,
        :$source-name = $path.Str,
        :$precomp-stores,
    ) {
        my $io = self.store.destination($compiler-id, $id);
        return False unless $io;
        if $force
            ?? (
                $precomp-stores
                and my $unit = self!load-file($precomp-stores, $id, :refresh)
                and do {
                    LEAVE $unit.close;
                    CHECKSUM($path) eq $unit.source-checksum
                    and self!load-dependencies($unit, $precomp-stores)
                }
            )
            !! ($io.e and $io.s)
        {
            $!RMD("$source-name\nalready precompiled into\n{$io}{
                $force ?? ' by another process' !! ''
            }")
              if $!RMD;

            if $stagestats {
                note "\n    load    $path.relative()";
                $*ERR.flush;
            }
            self.store.unlock;
            return True;
        }
        my $source-checksum = CHECKSUM($path);
        my $bc = "$io.bc".IO;

        # Local copy for us to tweak
        my $env := nqp::clone(nqp::getattr(%*ENV,Map,'$!storage'));

        nqp::bindkey($env,'RAKUDO_PRECOMP_WITH',
          $*REPO.repo-chain.map(*.path-spec).join(',')
        );

        if nqp::atkey($env,'RAKUDO_PRECOMP_LOADING') -> $rpl {
            my @modules := Rakudo::Internals::JSON.from-json: $rpl;
            die "Circular module loading detected trying to precompile $path"
              if $path.Str (elem) @modules;
            nqp::bindkey($env,'RAKUDO_PRECOMP_LOADING',
              $rpl.chop
                ~ ','
                ~ Rakudo::Internals::JSON.to-json($path.Str)
                ~ ']');
        }
        else {
            nqp::bindkey($env,'RAKUDO_PRECOMP_LOADING',
              '[' ~ Rakudo::Internals::JSON.to-json($path.Str) ~ ']');
        }

        if $*DISTRIBUTION -> $distribution {
            nqp::bindkey($env,'RAKUDO_PRECOMP_DIST',$distribution.serialize);
        }
        else {
            nqp::bindkey($env,'RAKUDO_PRECOMP_DIST','{}');
        }

        $!RMD("Precompiling $path into $bc ($lle $profile $optimize $stagestats)")
          if $!RMD;

        my $raku = $*EXECUTABLE.absolute
            .subst('perl6-debug', 'perl6') # debugger would try to precompile it's UI
            .subst('perl6-gdb', 'perl6')
            .subst('perl6-jdb-server', 'perl6-j') ;

#?if !moarvm
        if nqp::atkey($env,'RAKUDO_PRECOMP_NESTED_JDB') {
            $raku.subst-mutate('perl6-j', 'perl6-jdb-server');
            note "starting jdb on port "
              ~ nqp::bindkey($env,'RAKUDO_JDB_PORT',
                  nqp::ifnull(nqp::atkey($env,'RAKUDO_JDB_PORT'),0) + 1
                );
        }
#?endif

        if $stagestats {
            note "\n    precomp $path.relative()";
            $*ERR.flush;
        }

        my $out := nqp::list_s;
        my $err := nqp::list_s;
        my $status;
        react {
            my $proc = Proc::Async.new(
                $raku,
                $lle,
                $profile,
                $optimize,
                $target,
                $stagestats,
                "--output=$bc",
                "--source-name=$source-name",
                $path
            );

            whenever $proc.stdout {
                nqp::push_s($out,$_);
            }
            unless $!RMD {
                whenever $proc.stderr {
                    nqp::push_s($err,$_);
                }
            }
            if $stagestats {
                whenever $proc.stderr.lines {
                    note("    $stagestats");
                    $*ERR.flush;
                }
            }
            whenever $proc.start(ENV => nqp::hllize($env)) {
                $status = .exitcode
            }
        }

        if $status {  # something wrong
            self.store.unlock;
            $!RMD("Precompiling $path failed: $status")
              if $!RMD;

            Rakudo::Internals.VERBATIM-EXCEPTION(1);
            die $!RMD
              ?? nqp::join('',$out).lines.unique.List
              !! nqp::join('',$err);
        }

        if not $!RMD and not $stagestats and nqp::elems($err) {
            $*ERR.print(nqp::join('',$err));
        }

        unless $bc.e {
            $!RMD("$path aborted precompilation without failure")
              if $!RMD;

            self.store.unlock;
            return False;
        }

        $!RMD("Precompiled $path into $bc")
          if $!RMD;

        my $dependencies := nqp::create(IterationBuffer);
        my $seen := nqp::hash;

        for nqp::join('',$out).lines.unique -> str $outstr {
            if nqp::atpos(nqp::radix_I(16,$outstr,0,0,Int),2) == 40
              && nqp::eqat($outstr,"\0",40)
              && nqp::chars($outstr) > 41 {
                my $dependency :=
                  CompUnit::PrecompilationDependency::File.deserialize($outstr);
                if $dependency && $dependency.Str -> str $dependency-str {
                    unless nqp::existskey($seen,$dependency-str) {
                        $!RMD($dependency-str)
                          if $!RMD;

                        nqp::bindkey($seen,$dependency-str,1);
                        nqp::push($dependencies,$dependency);
                    }
                }
            }

            # huh?  malformed dependency?
            else {
                say $outstr;
            }
        }

        my CompUnit::PrecompilationDependency::File @dependencies;
        nqp::bindattr(@dependencies,List,'$!reified',$dependencies);

        $!RMD("Writing dependencies and byte code to $io.tmp for source checksum: $source-checksum")
          if $!RMD;

        self.store.store-unit(
            $compiler-id,
            $id,
            self.store.new-unit(
              :$id,
              :@dependencies
              :$source-checksum,
              :bytecode($bc.slurp(:bin))
            ),
        );
        $bc.unlink;
        self.store.store-repo-id($compiler-id, $id, :repo-id($*REPO.id));
        self.store.unlock;
        True
    }
}

# vim: ft=perl6 expandtab sw=4
