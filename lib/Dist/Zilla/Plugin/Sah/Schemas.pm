package Dist::Zilla::Plugin::Sah::Schemas;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use Moose;
use namespace::autoclean;

use Require::Hook::DzilBuild;

with (
    'Dist::Zilla::Role::FileGatherer',
    'Dist::Zilla::Role::FileMunger',
    'Dist::Zilla::Role::FileFinderUser' => {
        default_finders => [':InstallModules'],
    },
    'Dist::Zilla::Role::PrereqSource',
    #'Dist::Zilla::Role::RequireFromBuild',
);

sub _load_schema_modules {
    my $self = shift;

    return $self->{_our_schema_modules} if $self->{_loaded_schema_modules}++;

    local @INC = (Require::Hook::DzilBuild->new(zilla => $self->zilla, die=>1, debug=>1), @INC);

    my %res;
    for my $file (@{ $self->found_files }) {
        next unless $file->name =~ m!^lib/(Sah/Schema/.+\.pm)$!;

        my $pkg_pm = $1;
        (my $pkg = $pkg_pm) =~ s/\.pm$//; $pkg =~ s!/!::!g;
        $self->log_debug(["Loading schema module %s ...", $pkg_pm]);
        require $pkg_pm;
        $res{$pkg} = $file;
    }

    $self->{_our_schema_modules} = \%res;
}

sub _load_schemas_modules {
    my $self = shift;

    return $self->{_our_schemas_modules} if $self->{_loaded_schemas_modules}++;

    local @INC = (Require::Hook::DzilBuild->new(zilla => $self->zilla, die=>1, debug=>1), @INC);

    my %res;
    for my $file (@{ $self->found_files }) {
        next unless $file->name =~ m!^lib/(Sah/Schemas/.+\.pm)$!;
        my $pkg_pm = $1;
        (my $pkg = $pkg_pm) =~ s/\.pm$//; $pkg =~ s!/!::!g;
        require $pkg_pm;
        $res{$pkg} = $file;
    }

    $self->{_our_schemas_modules} = \%res;
}

sub munge_files {
    no strict 'refs';

    my $self = shift;

    $self->{_used_schema_modules} //= {};

    $self->_load_schema_modules;
    $self->_load_schemas_modules;

  SAH_SCHEMAS_MODULE:
    for my $pkg (sort keys %{ $self->{_our_schemas_modules} }) {
        # ...
    }

  SAH_SCHEMA_MODULE:
    for my $pkg (sort keys %{ $self->{_our_schema_modules} }) {
        my $file = $self->{_our_schema_modules}{$pkg};

        my $file_content = $file->content;

        my $sch = ${"$pkg\::schema"} or do {
            $self->log_fatal(["No schema defined in \$schema in %s", $file->name]);
        };
        my $nsch = Data::Sah::Normalize::normalize_schema($sch);

        # check that schema is already normalized
        {
            require Data::Dump;
            require Data::Sah::Normalize;
            require Text::Diff;
            my $sch_dmp  = Data::Dump::dump($sch);
            my $nsch_dmp = Data::Dump::dump($nsch);
            last if $sch_dmp eq $nsch_dmp;
            my $diff = Text::Diff::diff(\$sch_dmp, \$nsch_dmp);
            $self->log_fatal(["Schema in %s is not normalized, below is the dump diff (- is current, + is normalized): %s", $file->name, $diff]);
        }

        # collect other Sah::Schema::* modules that are used, this will
        # be added as prereq
      COLLECT_BASE_SCHEMAS:
        {
            require Data::Sah::Normalize;
            require Data::Sah::Resolve;
            require Data::Sah::Util::Subschema;

            $self->log_debug(["Finding schema modules required by %s", $pkg]);

            my $subschemas;
            eval {
                $subschemas = Data::Sah::Util::Subschema::extract_subschemas(
                    {schema_is_normalized => 1},
                    $nsch,
                );
            };
            if ($@) {
                $self->log(["Can't extract subschemas from schema in %s (%s), skipped", $pkg, $@]);
                last COLLECT_BASE_SCHEMAS;
            }

            for my $subsch ($nsch, @$subschemas) {
                my $nsubsch = Data::Sah::Normalize::normalize_schema($subsch);
                my $res;
                eval {
                    $res = Data::Sah::Resolve::resolve_schema(
                        {
                            schema_is_normalized => 1,
                            return_intermediates => 1,
                        },
                        $nsubsch);
                };
                if ($@) {
                    $self->log(["Can't resolve schema (%s), skipped collecting base schemas for %s", $@, $pkg]);
                    last COLLECT_BASE_SCHEMAS;
                }
                my $intermediates = $res->[2];
                for my $i (0..$#{$intermediates}-1) {
                    my $mod = "Sah::Schema::$intermediates->[$i]";
                    $self->{_used_schema_modules}{$mod}++;
                }
            }
        }

        # set ABSTRACT from schema's summary
        {
            unless ($file_content =~ m{^#[ \t]*ABSTRACT:[ \t]*([^\n]*)[ \t]*$}m) {
                $self->log_debug(["Skipping setting ABSTRACT %s: no # ABSTRACT", $file->name]);
                last;
            }
            my $abstract = $1;
            if ($abstract =~ /\S/) {
                $self->log_debug(["Skipping setting ABSTRACT %s: already filled (%s)", $file->name, $abstract]);
                last;
            }

            $file_content =~ s{^#\s*ABSTRACT:.*}{# ABSTRACT: $sch->[1]{summary}}m
                or die "Can't set abstract for " . $file->name;
            $self->log(["setting abstract for %s (%s)", $file->name, $sch->[1]{summary}]);
            $file->content($file_content);
        }

        # create lib/Sah/SchemaR/*.pm
      CREATE_SCHEMAR:
        {
            require Data::Dump;
            require Data::Sah::Resolve;
            require Dist::Zilla::File::InMemory;

            my $rschema;
            eval {
                $rschema = Data::Sah::Resolve::resolve_schema(
                    {return_intermediates => 1},
                    $sch,
                );
            };
            if ($@) {
                $self->log(["Can't resolve schema (%s), skipped creating SchemaR version for %s", $@, $pkg]);
                last CREATE_SCHEMAR;
            }

            my $rname = $file->name; $rname =~ s!^lib/Sah/Schema/!lib/Sah/SchemaR/!;
            my $rpkg  = $pkg; $rpkg =~ s/^Sah::Schema::/Sah::SchemaR::/;
            my $rfile = Dist::Zilla::File::InMemory->new(
                name => $rname,
                content => join(
                    "",
                    "package $rpkg;\n",
                    "\n",

                    "# DATE\n",
                    "# VERSION\n",
                    "\n",

                    "our \$rschema = ", Data::Dump::dump($rschema), ";\n",
                    "\n",

                    "1;\n",
                    "# ABSTRACT: $sch->[1]{summary}\n",
                    "\n",

                    "=head1 DESCRIPTION\n\n",
                    "This module is automatically generated by ".__PACKAGE__." during distribution build.\n\n",
                    "A Sah::SchemaR::* module is useful if a client wants to quickly lookup the base type of a schema without having to do any extra resolving. With Sah::Schema::*, one might need to do several lookups if a schema is based on another schema, and so on. Compare for example L<Sah::Schema::poseven> vs L<Sah::SchemaR::poseven>, where in Sah::SchemaR::poseven one can immediately get that the base type is C<int>. Currently L<Perinci::Sub::Complete> uses Sah::SchemaR::* instead of Sah::Schema::* for reduced startup overhead when doing tab completion.\n\n",
                ),
            );
            $self->log(["Creating file %s", $rname]);
            $self->add_file($rfile);
        }

    } # Sah::Schema::*
}

sub gather_files {
    # we add files in the munge_files() phase because at this point,
    # found_files() doesn't yet work
}

sub register_prereqs {
    my $self = shift;

    #use DD; dd $self->{_used_schema_modules}; dd $self->{_our_schema_modules};
    for my $mod (sort keys %{$self->{_used_schema_modules} // {}}) {
        next if $self->{_our_schema_modules}{$mod};
        $self->log(["Adding prereq to %s", $mod]);
        $self->zilla->register_prereqs({phase=>'runtime'}, $mod);
    }
}

__PACKAGE__->meta->make_immutable;
1;
# ABSTRACT: Plugin to use when building Sah-Schemas-* distribution

=for Pod::Coverage .+

=head1 SYNOPSIS

In F<dist.ini>:

 [Sah::Schemas]


=head1 DESCRIPTION

This plugin is to be used when building C<Sah-Schemas-*> distribution. It
currently does the following to C<lib/Sah/Schemas/*> .pm files:

=over

=item *

=back

It does the following to C<lib/Sah/Schema/*> .pm files:

=over

=item * Check that schema is already normalized

Otherwise, the build is aborted.

=item * Set module abstract from the schema's summary

=item * Add a prereq to other Sah::Schema::* module if schema depends on those other schemas

=item * Produce pre-resolved editions of schemas into C<lib/Sah/SchemaR/*>

These are useful if a client wants to lookup the base type of a schema without
having to do any extra resolving. Currently L<Perinci::Sub::Complete> uses this
to reduce startup overhead when doing tab completion.

=back



=head1 SEE ALSO

L<Pod::Weaver::Plugin::Sah::Schemas>

L<Sah::Schemas>

L<Sah> and L<Data::Sah>
