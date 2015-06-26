#!/usr/bin/perl

#
# This file is part of the coreboot project.
#
# Copyright (C) 2015 by Martin L Roth <coreboot@martinroth.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc.
#

package ktool;

use strict;
use warnings;
use English qw( -no_match_vars );
use File::Find;
use Getopt::Long;
use Getopt::Std;

my $supress_error_output = 0;      # flag to prevent warning and error text
my $print_full_output    = 0;      # flag to print wholeconfig output
my $output_file          = "-";    # filename of output - set stdout by default

#globals
my $root_dir     = "src";
my $errors_found = 0;              # count of warnings and errors
my @wholeconfig;                   # document the entire kconfig structure
my %loaded_files;                  # list of each Kconfig file loaded
my %symbols;                       # main structure of all symbols declared
my %referenced_symbols;            # list of symbols referenced by expressions or select statements

Main();

#-------------------------------------------------------------------------------
# Main
#
# Start by loading and parsing the top level Kconfig, this pulls in the other
# files.  Parsing the tree creates several arrays and hashes that can be used
# to check for errors
#-------------------------------------------------------------------------------
sub Main {

    check_arguments();
    open( STDOUT, "> $output_file" ) or die "Can't open $output_file for output: $!\n";

    #load the Kconfig tree, checking what we can and building up all the hash tables
    build_and_parse_kconfig_tree();

    #run checks based on the data that was found
    find( \&check_if_file_referenced, $root_dir );
    check_defaults();
    check_referenced_symbols();
    check_used_symbols();

    print_wholeconfig();

    exit($errors_found);
}

#-------------------------------------------------------------------------------
# check_defaults - Look for defaults that come after a default with no
# dependencies.
#
# TODO - check for defaults with the same dependencies
#-------------------------------------------------------------------------------
sub check_defaults {

    # loop through each defined symbol
    foreach my $sym ( sort ( keys %symbols ) ) {
        my $default_set      = 0;
        my $default_filename = "";
        my $default_line_no  = "";

        #loop through each instance of that symbol
        for ( my $sym_num = 0 ; $sym_num <= $symbols{$sym}{count} ; $sym_num++ ) {

            #loop through any defaults for that instance of that symbol, if there are any
            next unless ( exists $symbols{$sym}{$sym_num}{default_max} );
            for ( my $def_num = 0 ; $def_num <= $symbols{$sym}{$sym_num}{default_max} ; $def_num++ ) {

                #if a default is already set, display an error
                if ($default_set) {
                    my $filename = $symbols{$sym}{$sym_num}{file};
                    my $line_no  = $symbols{$sym}{$sym_num}{default}{$def_num}{default_line_no};
                    unless ($supress_error_output) {
                        print "#!!!!! Error: Default for '$sym' referenced in $filename at line $line_no will never be set - overridden by default set in $default_filename at line $default_line_no \n";
                    }
                    $errors_found++;
                }
                else {
                    #if no default is set, see if this is a default with no dependencies
                    unless ( ( exists $symbols{$sym}{$sym_num}{default}{$def_num}{default_depends_on} )
                        || ( exists $symbols{$sym}{$sym_num}{max_dependency} ) )
                    {
                        $default_set      = 1;
                        $default_filename = $symbols{$sym}{$sym_num}{file};
                        $default_line_no  = $symbols{$sym}{$sym_num}{default}{$def_num}{default_line_no};
                    }
                }
            }
        }
    }
}

#-------------------------------------------------------------------------------
# check_referenced_symbols - Make sure the symbols referenced by expressions and
# select statements are actually valid symbols.
#-------------------------------------------------------------------------------
sub check_referenced_symbols {

    #loop through symbols found in expressions and used by 'select' keywords
    foreach my $key ( sort ( keys %referenced_symbols ) ) {

        #make sure the symbol was defined by a 'config' or 'choice' keyword
        if ( !exists $symbols{$key} ) {

            #loop through each instance of the symbol to print out all of the invalid references
            for ( my $i = 0 ; $i <= $referenced_symbols{$key}{count} ; $i++ ) {
                my $filename = $referenced_symbols{$key}{$i}{filename};
                my $line_no  = $referenced_symbols{$key}{$i}{line_no};
                unless ($supress_error_output) {
                    print "#!!!!! Error: Undefined Symbol '$key' used in $filename at line $line_no.\n";
                }
                $errors_found++;
            }
        }
    }
}

#-------------------------------------------------------------------------------
# check_used_symbols - Checks to see whether or not the created symbols are
# actually used.
#-------------------------------------------------------------------------------
sub check_used_symbols {

    # find all references to CONFIG_ statements in the tree
    my @used_symbols = `grep -shr --exclude-dir="build" -- "CONFIG_"`;
    my %used_symbols;

    #sort through symbols found by grep and store them in a hash for easy access
    while ( my $line = shift @used_symbols ) {
        while ( $line =~ /[^A-Za-z0-9_]CONFIG_([A-Za-z0-9_]+)/g ) {
            my $conf = $1;
            $used_symbols{$conf} = 1;
        }
    }

    # loop through all defined symbols and see if they're used anywhere
    foreach my $key ( sort ( keys %symbols ) ) {

        #see if they're used internal to Kconfig
        next if ( exists $referenced_symbols{$key} );

        #see if they're used externally
        next if exists $used_symbols{$key};

        #loop through the definitions to print out all the places the symbol is defined.
        for ( my $i = 0 ; $i <= $symbols{$key}{count} ; $i++ ) {
            my $filename = $symbols{$key}{$i}{file};
            my $line_no  = $symbols{$key}{$i}{line_no};
            unless ($supress_error_output) {
                print "#!!!!! Warning: Unused symbol '$key' referenced in $filename at line $line_no.\n";
            }
            $errors_found++;
        }
    }
}

#-------------------------------------------------------------------------------
# build_and_parse_kconfig_tree
#-------------------------------------------------------------------------------
#load the initial file and start parsing it
sub build_and_parse_kconfig_tree {
    my @config_to_parse = load_kconfig_file( "$root_dir/Kconfig", "", 0, 0 );
    my @parseline;
    my $inside_help   = 0;     # set to line number of 'help' keyword if this line is inside a help block
    my @inside_if     = ();    # stack of if dependencies
    my $inside_config = "";    # set to symbol name of the config section
    my @inside_menu   = ();    # stack of menu names
    my $inside_choice = "";
    my $configs_inside_choice;

    while ( ( @parseline = shift(@config_to_parse) ) && ( exists $parseline[0]{text} ) ) {
        my $line     = $parseline[0]{text};
        my $filename = $parseline[0]{filename};
        my $line_no  = $parseline[0]{file_line_no};

        #handle help - help text: "help" or "---help---"
        $inside_help = handle_help( $line, $inside_help, $inside_config, $inside_choice, $filename, $line_no );
        $parseline[0]{inside_help} = $inside_help;

        #look for basic issues in the line, strip crlf
        $line = simple_line_checks( $line, $filename, $line_no );

        #strip comments
        $line =~ s/\s*#.*$//;

        #don't parse any more if we're inside a help block
        if ($inside_help) {

            #do nothing
        }

        #handle config
        elsif ( $line =~ /^\s*config/ ) {
            $line =~ /^\s*config\s+([^"\s]+)\s*(?>#.*)?$/;
            my $symbol = $1;
            $inside_config = $symbol;
            if ($inside_choice) {
                $configs_inside_choice++;
            }
            add_symbol( $symbol, \@inside_menu, $filename, $line_no, \@inside_if );
        }

        #bool|hex|int|string|tristate <expr> [if <expr>]
        elsif ( $line =~ /^\s*(bool|string|hex|int|tristate)/ ) {
            $line =~ /^\s*(bool|string|hex|int|tristate)\s*(.*)/;
            my ( $type, $prompt ) = ( $1, $2 );
            handle_type( $type, $inside_config, $filename, $line_no );
            handle_prompt( $prompt, $type, \@inside_menu, $inside_config, $inside_choice, $filename, $line_no );
        }

        # def_bool|def_tristate <expr> [if <expr>]
        elsif ( $line =~ /^\s*(def_bool|def_tristate)/ ) {
            $line =~ /^\s*(def_bool|def_tristate)\s+(.*)/;
            my ( $orgtype, $default ) = ( $1, $2 );
            ( my $type = $orgtype ) =~ s/def_//;
            handle_type( $type, $inside_config, $filename, $line_no );
            handle_default( $default, $orgtype, $inside_config, $inside_choice, $filename, $line_no );
        }

        #prompt <prompt> [if <expr>]
        elsif ( $line =~ /^\s*prompt/ ) {
            $line =~ /^\s*prompt\s+(.+)/;
            handle_prompt( $1, "prompt", \@inside_menu, $inside_config, $inside_choice, $filename, $line_no );
        }

        # default <expr> [if <expr>]
        elsif ( $line =~ /^\s*default/ ) {
            $line =~ /^\s*default\s+(.*)/;
            my $default = $1;
            handle_default( $default, "default", $inside_config, $inside_choice, $filename, $line_no );
        }

        # depends on <expr>
        elsif ( $line =~ /^\s*depends\s+on/ ) {
            $line =~ /^\s*depends\s+on\s+(.*)$/;
            my $expr = $1;
            handle_depends( $expr, $inside_config, $inside_choice, $filename, $line_no );
            handle_expressions( $expr, $inside_config, $filename, $line_no );
        }

        # comment <prompt>
        elsif ( $line =~ /^\s*comment/ ) {
            $inside_config = "";
        }

        # choice [symbol]
        elsif ( $line =~ /^\s*choice/ ) {
            if ( $line =~ /^\s*choice\s*([A-Za-z0-9_]+)$/ ) {
                my $symbol = $1;
                add_symbol( $symbol, \@inside_menu, $filename, $line_no, \@inside_if );
                handle_type( "bool", $symbol, $filename, $line_no );
            }
            $inside_config         = "";
            $inside_choice         = "$filename $line_no";
            $configs_inside_choice = 0;
        }

        # endchoice
        elsif ( $line =~ /^\s*endchoice/ ) {
            $inside_config = "";
            if ( !$inside_choice ) {
                unless ($supress_error_output) {
                    print "#!!!!! Warning: 'endchoice' keyword not within a choice block in $filename at line $line_no.\n";
                }
                $errors_found++;
            }

            $inside_choice = "";
            if ( $configs_inside_choice == 0 ) {
                unless ($supress_error_output) {
                    print "#!!!!! Warning: choice block has no symbols in $filename at line $line_no.\n";
                }
                $errors_found++;
            }
            $configs_inside_choice = 0;
        }

        # [optional]
        elsif ( $line =~ /^\s*optional/ ) {
            if ($inside_config) {
                unless ($supress_error_output) {
                    print "#!!!!! Error: Keyword 'optional' appears inside config for  '$inside_config' in $filename at line $line_no.  This is not valid.\n";
                }
                $errors_found++;
            }
            if ( !$inside_choice ) {
                unless ($supress_error_output) {
                    print "#!!!!! Error: Keyword 'optional' appears outside of a choice block in $filename at line $line_no.  This is not valid.\n";
                }
                $errors_found++;
            }
        }

        # mainmenu <prompt>
        elsif ( $line =~ /^\s*mainmenu/ ) {
            $inside_config = "";
        }

        # menu <prompt>
        elsif ( $line =~ /^\s*menu/ ) {
            $line =~ /^\s*menu\s+(.*)/;
            my $menu = $1;
            if ( $menu =~ /^\s*"([^"]*)"\s*$/ ) {
                $menu = $1;
            }

            $inside_config = "";
            $inside_choice = "";
            push( @inside_menu, $menu );
        }

        # endmenu
        elsif ( $line =~ /^\s*endmenu/ ) {
            $inside_config = "";
            $inside_choice = "";
            pop @inside_menu;
        }

        # "if" <expr>
        elsif ( $line =~ /^\s*if/ ) {
            $inside_config = "";
            $line =~ /^\s*if\s+(.*)$/;
            my $expr = $1;
            push( @inside_if, $expr );
            handle_expressions( $expr, $inside_config, $filename, $line_no );

        }

        # endif
        elsif ( $line =~ /^\s*endif/ ) {
            $inside_config = "";
            pop(@inside_if);
        }

        #range <symbol> <symbol> [if <expr>]
        elsif ( $line =~ /^\s*range/ ) {
            $line =~ /^\s*range\s+(\S+)\s+(.*)$/;
            handle_range( $1, $2, $inside_config, $filename, $line_no );
        }

        # select <symbol> [if <expr>]
        elsif ( $line =~ /^\s*select/ ) {
            unless ($inside_config) {
                unless ($supress_error_output) {
                    print "#!!!!! Error: Keyword 'select' appears outside of config in $filename at line $line_no.  This is not valid.\n";
                }
                $errors_found++;
            }

            if ( $line =~ /^\s*select\s+(.*)$/ ) {
                $line = $1;
                my $expression;
                ( $line, $expression ) = handle_if_line( $line, $inside_config, $filename, $line_no );
                if ($line) {
                    add_referenced_symbol( $line, $filename, $line_no );
                }
            }
        }

        # source <prompt>
        elsif ( $line =~ /^\s*source\s+"?([^"\s]+)"?\s*(?>#.*)?$/ ) {
            my @newfile = load_kconfig_file( $1, $filename, $line_no, 0 );
            unshift( @config_to_parse, @newfile );
            $parseline[0]{text} = "##### KTOOL EVALUATED '$line' #####\n";
        }
        elsif (
            ( $line =~ /^\s*#/ ) ||    #comments
            ( $line =~ /^\s*$/ )       #blank lines
          )
        {
            # do nothing
        }
        else {
            unless ($supress_error_output) {
                print "### $line  ($filename line $line_no unrecognized)\n";
            }
            $errors_found++;
        }

        push @wholeconfig, @parseline;
    }
}

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
sub handle_depends {
    my ( $expr, $inside_config, $inside_choice, $filename, $line_no ) = @_;

    if ($inside_config) {
        my $sym_num = $symbols{$inside_config}{count};
        if ( exists $symbols{$inside_config}{$sym_num}{max_dependency} ) {
            $symbols{$inside_config}{$sym_num}{max_dependency}++;
        }
        else {
            $symbols{$inside_config}{$sym_num}{max_dependency} = 0;
        }

        my $dep_num = $symbols{$inside_config}{$sym_num}{max_dependency};
        $symbols{$inside_config}{$sym_num}{dependency}{$dep_num} = $expr;
    }
}

#-------------------------------------------------------------------------------
#-------------------------------------------------------------------------------
sub add_symbol {
    my ( $symbol, $menu_array_ref, $filename, $line_no, $ifref ) = @_;
    my @inside_if = @{$ifref};

    if ( !exists $symbols{$symbol} ) {
        $symbols{$symbol}{count} = 0;
    }
    else {
        $symbols{$symbol}{count}++;
    }
    my $symcount = $symbols{$symbol}{count};
    $symbols{$symbol}{$symcount}{file}    = $filename;
    $symbols{$symbol}{$symcount}{line_no} = $line_no;

    if ( defined @$menu_array_ref[0] ) {
        $symbols{$symbol}{$symcount}{menu} = $menu_array_ref;
    }

    if (@inside_if) {
        my $dep_num = 0;
        for my $dependency (@inside_if) {
            $symbols{$symbol}{$symcount}{dependency}{$dep_num} = $dependency;
            $symbols{$symbol}{$symcount}{max_dependency} = $dep_num;
            $dep_num++;
        }
    }
}

#-------------------------------------------------------------------------------
# handle range
#-------------------------------------------------------------------------------
sub handle_range {
    my ( $range1, $range2, $inside_config, $filename, $line_no ) = @_;

    my $expression;
    ( $range2, $expression ) = handle_if_line( $range2, $inside_config, $filename, $line_no );

    $range1 =~ /^\s*(?:0x)?([A-Fa-f0-9]+)\s*$/;
    my $checkrange1 = $1;
    $range2 =~ /^\s*(?:0x)?([A-Fa-f0-9]+)\s*$/;
    my $checkrange2 = $1;

    if ( $checkrange1 && $checkrange2 && ( hex($checkrange1) > hex($checkrange2) ) ) {
        unless ($supress_error_output) {
            print "#!!!!! Error: Range entry in $filename line $line_no value 1 ($range1) is greater than value 2 ($range2).\n";
        }
        $errors_found++;

    }

    if ($inside_config) {
        if ( exists( $symbols{$inside_config}{range1} ) ) {
            if ( ( $symbols{$inside_config}{range1} != $range1 ) || ( $symbols{$inside_config}{range2} != $range2 ) ) {
                unless ($supress_error_output) {
                    print "#!!!!! Note: Config '$inside_config' range entry $range1 $range2 at $filename line $line_no does";
                    print " not match the previously defined range $symbols{$inside_config}{range1} $symbols{$inside_config}{range2}";
                    print " defined in $symbols{$inside_config}{range_file} on line";
                    print " $symbols{$inside_config}{range_line_no}.\n";
                }
            }
        }
        else {
            $symbols{$inside_config}{range1}        = $range1;
            $symbols{$inside_config}{range2}        = $range2;
            $symbols{$inside_config}{range_file}    = $filename;
            $symbols{$inside_config}{range_line_no} = $line_no;
        }
    }
    else {
        unless ($supress_error_output) {
            print "#!!!!! Error: Range entry in $filename line $line_no is not inside a config block.\n";
        }
        $errors_found++;
    }
}

#-------------------------------------------------------------------------------
# handle_default
#-------------------------------------------------------------------------------
sub handle_default {
    my ( $default, $name, $inside_config, $inside_choice, $filename, $line_no ) = @_;
    my $expression;
    ( $default, $expression ) = handle_if_line( $default, $inside_config, $filename, $line_no );

    if ($inside_config) {
        handle_expressions( $default, $inside_config, $filename, $line_no );
        my $sym_num = $symbols{$inside_config}{count};

        unless ( exists $symbols{$inside_config}{$sym_num}{default_max} ) {
            $symbols{$inside_config}{$sym_num}{default_max} = 0;
        }
        my $default_max = $symbols{$inside_config}{$sym_num}{default_max};
        $symbols{$inside_config}{$sym_num}{default}{$default_max}{default}         = $default;
        $symbols{$inside_config}{$sym_num}{default}{$default_max}{default_line_no} = $line_no;
        if ($expression) {
            $symbols{$inside_config}{$sym_num}{default}{$default_max}{default_depends_on} = $expression;
        }
    }
    elsif ($inside_choice) {
        handle_expressions( $default, $inside_config, $filename, $line_no );
    }
    else {
        unless ($supress_error_output) {
            print "#!!!!! Error: $name entry in $filename line $line_no is not inside a config or choice block.\n";
        }
        $errors_found++;
    }
}

#-------------------------------------------------------------------------------
# handle_if_line
#-------------------------------------------------------------------------------
sub handle_if_line {
    my ( $exprline, $inside_config, $filename, $line_no ) = @_;

    if ( $exprline !~ /if/ ) {
        return ( $exprline, "" );
    }

    #remove any quotes that might have an 'if' in them
    my $savequote;
    if ( $exprline =~ /^\s*("[^"]+")/ ) {
        $savequote = $1;
        $exprline =~ s/^\s*("[^"]+")//;
    }

    my $expr = "";
    if ( $exprline =~ /\s*if\s+(.*)$/ ) {
        $expr = $1;
        $exprline =~ s/\s*if\s+.*$//;

        if ($expr) {
            handle_expressions( $expr, $inside_config, $filename, $line_no );
        }
    }

    if ($savequote) {
        $exprline = $savequote;
    }

    return ( $exprline, $expr );
}

#-------------------------------------------------------------------------------
# handle_expressions - log which symbols are being used
#-------------------------------------------------------------------------------
sub handle_expressions {
    my ( $exprline, $inside_config, $filename, $line_no ) = @_;

    return unless ($exprline);

    #filter constant symbols first
    if ( $exprline =~ /^\s*"?([yn])"?\s*$/ ) {                           # constant y/n
        return;
    }
    elsif ( $exprline =~ /^\s*"?((?:-)\d+)"?\s*$/ ) {                    # int values
        return;
    }
    elsif ( $exprline =~ /^\s*"?((?:-)?(?:0x)?\p{XDigit})+"?\s*$/ ) {    # hex values
        return;
    }
    elsif ( $exprline =~ /^\s*("[^"]*")\s*$/ ) {                         # String values
        return;
    }
    elsif ( $exprline =~ /^\s*([A-Za-z0-9_]+)\s*$/ ) {                   # <symbol>                             (1)
        add_referenced_symbol( $1, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*!(.+)$/ ) {                                # '!' <expr>                           (5)

        handle_expressions( $1, $inside_config, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*\(([^)]+)\)\s*$/ ) {                       # '(' <expr> ')'                       (4)
        handle_expressions( $1, $inside_config, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*(.+)\s*!=\s*(.+)\s*$/ ) {                  # <symbol> '!=' <symbol>               (3)
        handle_expressions( $1, $inside_config, $filename, $line_no );
        handle_expressions( $2, $inside_config, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*(.+)\s*=\s*(.+)\s*$/ ) {                   # <symbol> '=' <symbol>                (2)
        handle_expressions( $1, $inside_config, $filename, $line_no );
        handle_expressions( $2, $inside_config, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*([^(]+|\(.+\))\s*&&\s*(.+)\s*$/ ) {        # <expr> '&&' <expr>                   (6)
        handle_expressions( $1, $inside_config, $filename, $line_no );
        handle_expressions( $2, $inside_config, $filename, $line_no );
    }
    elsif ( $exprline =~ /^\s*([^(]+|\(.+\))\s*\|\|\s*(.+)\s*$/ ) {      # <expr> '||' <expr>                   (7)
        handle_expressions( $1, $inside_config, $filename, $line_no );
        handle_expressions( $2, $inside_config, $filename, $line_no );
    }

    # work around kconfig spec violation for now - paths not in quotes
    elsif ( $exprline =~ /^\s*([A-Za-z0-9_\-\/]+)\s*$/ ) {               # <symbol>                             (1)
        return;
    }
    else {
        unless ($supress_error_output) {
            print "#### Unrecognized expression '$exprline' in $filename line $line_no.\n";
        }
        $errors_found++;
    }

    return;
}

#-------------------------------------------------------------------------------
# add_referenced_symbol
#-------------------------------------------------------------------------------
sub add_referenced_symbol {
    my ( $symbol, $filename, $line_no ) = @_;
    if ( exists $referenced_symbols{$symbol} ) {
        $referenced_symbols{$symbol}{count}++;
        $referenced_symbols{$symbol}{ $referenced_symbols{$symbol}{count} }{filename} = $filename;
        $referenced_symbols{$symbol}{ $referenced_symbols{$symbol}{count} }{line_no}  = $line_no;
    }
    else {
        $referenced_symbols{$symbol}{count}       = 0;
        $referenced_symbols{$symbol}{0}{filename} = $filename;
        $referenced_symbols{$symbol}{0}{line_no}  = $line_no;
    }
}

#-------------------------------------------------------------------------------
# handle_help
#-------------------------------------------------------------------------------
{
    #create a non-global static variable by enclosing it and the subroutine
    my $help_whitespace = "";    #string to show length of the help whitespace

    sub handle_help {
        my ( $line, $inside_help, $inside_config, $inside_choice, $filename, $line_no ) = @_;

        if ($inside_help) {

            #get the indentation level if it's not already set.
            if ( ( !$help_whitespace ) && ( $line !~ /^[\r\n]+/ ) ) {
                $line =~ /^(\s+)/;    #find the indentation level.
                $help_whitespace = $1;
                if ( !$help_whitespace ) {
                    unless ($supress_error_output) {
                        print "# Warning: $filename line $line_no help text starts with no whitespace.\n";
                    }
                    return $inside_help;
                    $errors_found++;
                }
            }

            #help ends at the first line which has a smaller indentation than the first line of the help text.
            if ( ( $line !~ /$help_whitespace/ ) && ( $line !~ /^[\r\n]+/ ) ) {
                $inside_help     = 0;
                $help_whitespace = "";
            }
            else {    #if it's not ended, add the line to the helptext array for the symbol's instance
                if ($inside_config) {
                    my $sym_num = $symbols{$inside_config}{count};
                    if ($help_whitespace) { $line =~ s/^$help_whitespace//; }
                    push( @{ $symbols{$inside_config}{$sym_num}{helptext} }, $line );
                }
            }
        }
        elsif ( ( $line =~ /^(\s*)help/ ) || ( $line =~ /^(\s*)---help---/ ) ) {
            $inside_help = $line_no;
            if ( ( !$inside_config ) && ( !$inside_choice ) ) {
                unless ($supress_error_output) {
                    print "# Note: $filename line $line_no help is not inside a config or choice block.\n";
                }
                $errors_found++;
            }
            elsif ($inside_config) {
                $help_whitespace = "";
                my $sym_num = $symbols{$inside_config}{count};
                $symbols{$inside_config}{$sym_num}{help_line_no} = $line_no;
                $symbols{$inside_config}{$sym_num}{helptext}     = ();
            }
        }
        return $inside_help;
    }
}

#-------------------------------------------------------------------------------
# handle_type
#-------------------------------------------------------------------------------
sub handle_type {
    my ( $type, $inside_config, $filename, $line_no ) = @_;

    my $expression;
    ( $type, $expression ) = handle_if_line( $type, $inside_config, $filename, $line_no );

    if ($inside_config) {
        if ( exists( $symbols{$inside_config}{type} ) ) {
            if ( $symbols{$inside_config}{type} !~ /$type/ ) {
                print "#!!!!! Error: Config '$inside_config' type entry $type at $filename line $line_no does not match";
                print " the previously defined type $symbols{$inside_config}{type}";
                print " defined in $symbols{$inside_config}{type_file} on line";
                print " $symbols{$inside_config}{type_line_no}.\n";
                $errors_found++;
            }
        }
        else {
            $symbols{$inside_config}{type}         = $type;
            $symbols{$inside_config}{type_file}    = $filename;
            $symbols{$inside_config}{type_line_no} = $line_no;
        }
    }
    else {
        unless ($supress_error_output) {
            print "#!!!!! Error: Type entry in $filename line $line_no is not inside a config block.\n";
        }
        $errors_found++;
    }
}

#-------------------------------------------------------------------------------
# handle_prompt
#-------------------------------------------------------------------------------
sub handle_prompt {
    my ( $prompt, $name, $menu_array_ref, $inside_config, $inside_choice, $filename, $line_no ) = @_;

    my $expression;
    ( $prompt, $expression ) = handle_if_line( $prompt, $inside_config, $filename, $line_no );

    if ($inside_config) {
        if ( $prompt !~ /^\s*$/ ) {
            if ( $prompt =~ /^\s*"([^"]*)"\s*$/ ) {
                $prompt = $1;
            }

            if ( !defined @$menu_array_ref[0] ) {
                unless ($supress_error_output) {
                    print "#!!!!! Warning: Symbol  '$inside_config' with prompt '$prompt' appears outside of a menu in $filename at line $line_no.  This is discouraged.\n";
                }
                $errors_found++;
            }

            my $sym_num = $symbols{$inside_config}{count};
            unless ( exists $symbols{$inside_config}{$sym_num}{prompt_max} ) {
                $symbols{$inside_config}{$sym_num}{prompt_max} = 0;
            }
            my $prompt_max = $symbols{$inside_config}{$sym_num}{prompt_max};
            $symbols{$inside_config}{$sym_num}{prompt}{$prompt_max}{prompt}         = $prompt;
            $symbols{$inside_config}{$sym_num}{prompt}{$prompt_max}{prompt_line_no} = $line_no;
            if ($expression) {
                $symbols{$inside_config}{$sym_num}{prompt}{$prompt_max}{prompt_depends_on} = $expression;
            }

            #need to loop through the symbols and look for defined prompts.
            #if ((exists $symbols{$inside_config}{prompt}) && ($symbols{$inside_config}{prompt} !~ /$prompt/)) {
            #        print "# Note: A prompt entry for the config '$inside_config' '$prompt' in";
            #        print " $filename line $line_no is different than '$symbols{$inside_config}{prompt}'";
            #        print " in $symbols{$inside_config}{prompt_file} on line";
            #        print " $symbols{$inside_config}{prompt_line_no}.\n";
            #}
        }
    }
    elsif ($inside_choice) {

        #do nothing
    }
    else {
        unless ($supress_error_output) {
            print "#!!!!! Error: $name entry in $filename line $line_no is not inside a config or choice block.\n";
        }
        $errors_found++;
    }
}

#-------------------------------------------------------------------------------
# simple_line_checks - Does some basic checks on the current line, then cleans the line
#  up for further processing.
#-------------------------------------------------------------------------------
sub simple_line_checks {
    my ( $line, $filename, $line_no ) = @_;

    #check for spaces instead of tabs
    if ( $line =~ /^ +/ ) {
        unless ($supress_error_output) {
            print "# Note: $filename line $line_no starts with a space.\n";
        }
        $errors_found++;
    }

    #verify a linefeed at the end of the line
    if ( $line !~ /.*\n/ ) {
        unless ($supress_error_output) {
            print "#!!!!! Warning: $filename line $line_no does not end with linefeed.  This can cause the line to not be recognized by the Kconfig parser.\n";
        }
        $errors_found++;
        $line =~ s/\s*$//;
    }
    else {
        chop($line);
    }

    return $line;
}

#-------------------------------------------------------------------------------
# load_kconfig_file - Loads a single Kconfig file or expands * wildcard
#-------------------------------------------------------------------------------
sub load_kconfig_file {
    my ( $input_file, $loadfile, $loadline, $expanded ) = @_;
    my @file_data;
    my @dir_file_data;

    #recursively handle coreboot's new source glob operator
    if ( $input_file =~ /^(.*?)\/\*\/(.*)$/ ) {
        my $dir_prefix = $1;
        my $dir_suffix = $2;
        if ( -d "$dir_prefix" ) {

            opendir( D, "$dir_prefix" ) || die "Can't open directory '$dir_prefix'\n";
            my @dirlist = sort { $a cmp $b } readdir(D);
            closedir(D);

            while ( my $directory = shift @dirlist ) {

                #ignore non-directory files
                if ( ( -d "$dir_prefix/$directory" ) && !( $directory =~ /^\..*/ ) ) {
                    push @dir_file_data, load_kconfig_file( "$dir_prefix/$directory/$dir_suffix", $input_file, $loadline, 1 );
                }
            }
        }
        else {
            unless ($supress_error_output) {
                print "#!!!!! Warning: Could not find dir '$dir_prefix'\n";
            }
            $errors_found++;
        }
    }
    elsif ( -e "$input_file" ) {
        if ( exists $loaded_files{$input_file} ) {
            unless ($supress_error_output) {
                print "#!!!!! Warning: '$input_file' sourced in '$loadfile' at line $loadline was already loaded by $loaded_files{$input_file}\n";
            }
            $errors_found++;
        }
        $loaded_files{$input_file} = "'$loadfile' line $loadline";

        open( my $HANDLE, "<", "$input_file" ) or die "Error: could not open file '$input_file'\n";
        @file_data = <$HANDLE>;
        close $HANDLE;
    }
    elsif ( $expanded == 0 ) {
        unless ($supress_error_output) {
            print "#!!!!! Warning: Could not find file '$input_file' sourced in $loadfile at line $loadline\n";
        }
        $errors_found++;
    }

    my $i = 0;
    while ( my $line = shift @file_data ) {

        #handle line continuation.
        my $j = 0;
        while ($line =~ /(.*)\s+\\$/) {
            $dir_file_data[$i]{text} .= $1;
            $line = shift @file_data;
            $j++;

            #put the data into the continued lines (other than the first)
            $line =~ /^\s*(.*)\s*$/;
            $dir_file_data[$i + $j]{text} = "#continued line ( " . $1 . " )\n";
            $dir_file_data[$i+ $j]{filename}     = $input_file;
            $dir_file_data[$i+ $j]{file_line_no} = $i + $j + 1;
        }

        $dir_file_data[$i]{text}         .= $line;
        $dir_file_data[$i]{filename}     = $input_file;
        $dir_file_data[$i]{file_line_no} = $i + 1;

        $i++;
        if ($j) {
            $i += $j
        }
    }

    return @dir_file_data;
}

#-------------------------------------------------------------------------------
# print_wholeconfig - prints out the parsed Kconfig file
#-------------------------------------------------------------------------------
sub print_wholeconfig {

    return unless $print_full_output;

    for ( my $i = 0 ; $i < $#wholeconfig ; $i++ ) {
        my $line = $wholeconfig[$i];
        chop( $line->{text} );

        #replace tabs with spaces for consistency
        $line->{text} =~ s/\t/        /g;
        printf "%-100s #( $line->{file_line_no} - line $line->{filename} ) [$line->{inside_help}]\n", $line->{text};
    }
}

#-------------------------------------------------------------------------------
# check_if_file_referenced - checks for kconfig files that are not being parsed
#-------------------------------------------------------------------------------
sub check_if_file_referenced {
    my $filename = $File::Find::name;
    if ( ( $filename =~ /Kconfig/ ) && ( !exists $loaded_files{$filename} ) ) {
        unless ($supress_error_output) {
            print "#!!!!! Warning: '$filename' is never referenced\n";
        }
        $errors_found++;
    }
}

#-------------------------------------------------------------------------------
# check_arguments parse the command line arguments
#-------------------------------------------------------------------------------
sub check_arguments {
    my $show_usage = 0;
    GetOptions(
        'help|?'         => sub { usage() },
        'o|output=s'     => \$output_file,
        'p|print'        => \$print_full_output,
        'w|warnings_off' => \$supress_error_output,
    );
}

#-------------------------------------------------------------------------------
# usage - Print the arguments for the user
#-------------------------------------------------------------------------------
sub usage {
    print "Ktool <options>\n";
    print " -o|--output=file    set output filename\n";
    print " -p|--print          Print full output\n";
    print " -w|--warnings_off   Don't print warnings\n";

    exit(0);
}

1;
