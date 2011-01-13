#!/bin/bash

set -e

# aliases
PERL=${CT_PERL:-"perl"}
SSH=${CT_SSH:-"ssh -ttqx -o PasswordAuthentication=no"}

# files
NULLFILE=${CT_NULLFILE:-"/dev/null"}

# directories

# quiet
Q=${CT_Q:-"-q"}

# ----------------------------------------------------------------------
# main
# ----------------------------------------------------------------------
if [ "$1" != "boot/strap" ] ; then
    . $0 boot/strap
    main "$@"
    exit 0
fi


# ----------------------------------------------------------------------
# main function
# ----------------------------------------------------------------------
main() {
        env_sanity "$@"
        args_sanity "$@"

        if [ "$CMD" = "init" ] ; then
            init
        else
            usage;
        fi
    }


# ----------------------------------------------------------------------
# helper functions
# ----------------------------------------------------------------------
    die() {
        cat <<EOF
$@

run $0 without any arguments for usage
EOF
        exit 1
    }

    usage() {
        cat <<EOF

Usage: $0 [-f] <command> ...

  <command> is one of the following:
    init <erlang_dir> <user> <host> ...

  - "-f" is enable force mode.  disable safety checks to prevent
     deleting and/or overwriting an existing installation.
  - <erlang_dir> is that root director for erlang
  - <user> is the account on the server where you will be installing
    Hibari
  - <host> is server's name


Example usage:
  $0 init /usr/local/lib/erlang hibari `hostname`

Notes:
  - <user> must be simple names -- no special characters etc please
    (only alphanumerics, dot, hyphen, underscore)

EOF
        exit 1;
    }


# ----------------------------------------------------------------------
# environment checks
# ----------------------------------------------------------------------
    env_sanity() {
        local PERL=($PERL)
        local SSH=($SSH)

        for i in ${PERL[0]} ${SSH[0]} ; do
            `test -f $i &> $NULLFILE` || `which $i &> $NULLFILE` ||
            die "$i does not exist or not found in ($PATH)"
        done
    }


# ----------------------------------------------------------------------
# arguments checks
# ----------------------------------------------------------------------
    args_sanity() {
        FORCE=
        if [ "$1" = "-f" ] ; then
            FORCE=-f
            shift
        fi

        if [[ -z $1 || -z $2 || -z $3 || -z $4 ]] ; then
            usage
        fi

        CMD=$1
        ERLANG_DIR=$2
        NODE_USER=$3
        shift
        shift
        shift
        NODE_HOSTS=($*)

        echo $NODE_USER | $PERL -lne 'exit 1 if /[^a-zA-Z0-9._-]/' || \
            die "user '$NODE_USER' invalid"
        if [ "$NODE_USER" = "root" ] ; then
            die "user '$NODE_USER' unsupported"
        fi
    }


# ----------------------------------------------------------------------
# init
# ----------------------------------------------------------------------
    init() {
        echo $ERLANG_DIR $NODE_USER ${NODE_HOSTS[@]}
    }

