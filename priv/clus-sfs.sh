#!/bin/bash

set -e

# aliases
PERL=${CT_PERL:-"perl"}
SSH=${CT_SSH:-"ssh -ttqx -o PasswordAuthentication=no"}
SCP=${CT_SSH:-"scp -q -o PasswordAuthentication=no"}

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
    elif [ "$CMD" = "start" ] ; then
        start
    elif [ "$CMD" = "bootstrap" ] ; then
        bootstrap
    elif [ "$CMD" = "mount" ] ; then
        mount
    elif [ "$CMD" = "umount" ] ; then
        umount
    elif [ "$CMD" = "ping" ] ; then
        ping
    elif [ "$CMD" = "stop" ] ; then
        stop
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
    init <user> <sfs.cfg> <sfs-X.Y.Z-DIST-ARCH-WORDSIZE>.tgz <hibariuser>
    start <user> <sfs.cfg>
    bootstrap <user> <sfs.cfg> <hibariuser>
    mount <user> <sfs.cfg>
    umount <user> <sfs.cfg>
    ping <user> <sfs.cfg>
    stop <user> <sfs.cfg>

  - "-f" is enable force mode.  disable safety checks to prevent
     deleting and/or overwriting an existing installation.
  - <user> is the account on the server(s) where you will be
    installing Hibarifs
  - <sfs.cfg> is Hibarifs's cluster config file
  - <hibariuser> is the account on the server(s) where Hibari is
    running

Example usage:
  $0 init sfs sfs.cfg sfs-X.Y.Z-DIST-ARCH-WORDSIZE.tgz hibari

Notes:
  - <user> and hosts in the cluster config file must be simple names
    -- no special characters etc please (only alphanumerics, dot,
    hyphen, underscore)
EOF
    exit 1;
}


# ----------------------------------------------------------------------
# environment checks
# ----------------------------------------------------------------------
env_sanity() {
    local PERL=($PERL)
    local SSH=($SSH)
    local SCP=($SCP)

    for i in ${PERL[0]} ${SSH[0]} ${SCP[0]} ; do
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

    if [[ -z $1 || -z $2 || -z $3 ]] ; then
        usage
    elif [ "$1" = "init" ] ; then
        if [[ -z $4 || -z $5 ]] ; then
            usage
        elif [ ! -f "$4" ] ; then
            usage
        else
            SRCTARBALL=$4
            DSTTARBALL=`basename $4`
            HIBARI_NODE_USER=$5
        fi
    elif [ "$1" = "bootstrap" ] ; then
        if [ -z "$4" ] ; then
            usage
        else
            HIBARI_NODE_USER=$4
        fi
    fi

    CMD=$1
    NODE_USER=$2
    CONFIG_FILE=$3

    echo $NODE_USER | $PERL -lne 'exit 1 if /[^a-zA-Z0-9._-]/' || \
        die "user '$NODE_USER' invalid"
    if [ "$NODE_USER" = "root" ] ; then
        die "user '$NODE_USER' unsupported"
    fi
    echo $HIBARI_NODE_USER | $PERL -lne 'exit 1 if /[^a-zA-Z0-9._-]/' || \
        die "user '$HIBARI_NODE_USER' invalid"
    if [ "$HIBARI_NODE_USER" = "root" ] ; then
        die "user '$HIBARI_NODE_USER' unsupported"
    fi

    source $CONFIG_FILE || \
        die "source '$CONFIG_FILE' failed"

    for i in $ADMIN_NODES $CLIENT_NODES ; do
        echo $i | $PERL -lne 'exit 1 if /[^a-zA-Z0-9._-]/' || \
            die "host '$i' invalid"
    done

    if [ ${#ADMIN_NODES[@]} -lt 1 ] ; then
        die "missing ADMIN_NODES in '$CONFIG_FILE'"
    fi
    if [ ${#CLIENT_NODES[@]} -lt 1 ] ; then
        die "missing CLIENT_NODES in '$CONFIG_FILE'"
    fi
}


# ----------------------------------------------------------------------
# init
# ----------------------------------------------------------------------
init() {
    local N0=${#CLIENT_NODES[@]}
    local N=$(($N0 - 1))

    # fetch cookie
    local COOKIE=`fetchcookie`
    if [ -z $COOKIE ] ; then
        die "fetch cookie failed"
    fi

    # setup NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${CLIENT_NODES[$I]}
            local WS_NODE=(`sfs_nodes_ws $NODE`)

            # stop Hibarifs
            $SSH $NODE_USER@$NODE "(source .bashrc; cd sfs &> $NULLFILE; ./bin/sfs stop &> $NULLFILE) || true" || \
                die "node $NODE stop failed"
            # kill all Hibarifs beam.smp processes
            $SSH $NODE_USER@$NODE "pkill -9 -u $NODE_USER beam.smp || true" || \
                die "node $NODE pkill beam.smp failed"

            # scp Hibarifs tarball
            $SCP $SRCTARBALL $NODE_USER@$NODE:$DSTTARBALL || \
                die "node $NODE scp tarball failed"

            # untar Hibarifs package
            $SSH $NODE_USER@$NODE "rm -rf sfs; tar -xzf $DSTTARBALL" || \
                die "node $NODE untar tarball failed"

            # configure Hibarifs package
            $SSH $NODE_USER@$NODE "sed -i.bak \
-e 's/-sname .*/-sname $WS_NODE/' \
-e 's/-name .*/-sname $WS_NODE/' \
-e 's/-setcookie .*/-setcookie $COOKIE/' \
sfs/etc/vm.args" || \
                die "node $NODE vm.args setup failed"

            echo $NODE_USER@$NODE
        ) &
    done

    wait
}

fetchcookie() {
    local NODE=${ADMIN_NODES[0]}
    $SSH $HIBARI_NODE_USER@$NODE "grep setcookie hibari/etc/vm.args | xargs -n 1 echo | grep -v setcookie | tr -c -d 'a-zA-Z0-9_'" || \
        die "node $NODE vm.args setup failed"
}


# ----------------------------------------------------------------------
# start
# ----------------------------------------------------------------------
start() {
    local N0=${#CLIENT_NODES[@]}
    local N=$(($N0 - 1))

    # start NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${CLIENT_NODES[$I]}

            # start Hibarifs package
            $SSH $NODE_USER@$NODE "source .bashrc; cd sfs; ./bin/sfs start" || \
                die "node $NODE start failed"

            echo $NODE_USER@$NODE
        ) &
    done

    wait
}


# ----------------------------------------------------------------------
# bootstrap
# ----------------------------------------------------------------------
bootstrap() {
    local ADMIN_NODE=${ADMIN_NODES[0]}
    local WS_NODES=`sfs_nodes_ws ${CLIENT_NODES[@]}`

    # bootstrap Hibarifs package
    $SSH $HIBARI_NODE_USER@$ADMIN_NODE "source .bashrc; cd hibari; ./bin/hibari-admin client-add $WS_NODES" || \
        die "node $NODE bootstrap failed"
    $SSH $HIBARI_NODE_USER@$ADMIN_NODE "source .bashrc; cd hibari; ./bin/hibari-admin client-list" || \
        die "node $NODE bootstrap failed"
}


# ----------------------------------------------------------------------
# mount
# ----------------------------------------------------------------------
mount() {
    local N0=${#CLIENT_NODES[@]}
    local N=$(($N0 - 1))

    # mount NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${CLIENT_NODES[$I]}

            # mount Hibarifs package
            $SSH $NODE_USER@$NODE "source .bashrc; cd sfs; ./bin/sfs-admin mount" || \
                die "node $NODE mount failed"

            echo $NODE_USER@$NODE
        ) &
    done

    wait
}


# ----------------------------------------------------------------------
# umount
# ----------------------------------------------------------------------
umount() {
    local N0=${#CLIENT_NODES[@]}
    local N=$(($N0 - 1))

    # umount NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${CLIENT_NODES[$I]}

            # umount Hibarifs package
            $SSH $NODE_USER@$NODE "source .bashrc; cd sfs; ./bin/sfs-admin umount" || \
                die "node $NODE umount failed"

            echo $NODE_USER@$NODE
        ) &
    done

    wait
}


# ----------------------------------------------------------------------
# ping
# ----------------------------------------------------------------------
ping() {
    local N0=${#CLIENT_NODES[@]}
    local N=$(($N0 - 1))

    # ping NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${CLIENT_NODES[$I]}

            # ping Hibarifs package
            echo -n "$NODE_USER@$NODE ... "
            $SSH $NODE_USER@$NODE "source .bashrc; cd sfs; ./bin/sfs ping" || \
                die "node $NODE ping failed"
        )
    done
}


# ----------------------------------------------------------------------
# stop
# ----------------------------------------------------------------------
stop() {
    local N0=${#CLIENT_NODES[@]}
    local N=$(($N0 - 1))

    # stop NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${CLIENT_NODES[$I]}

            # stop Hibarifs package
            $SSH $NODE_USER@$NODE "source .bashrc; cd sfs; ./bin/sfs stop" || \
                die "node $NODE stop failed"

            echo $NODE_USER@$NODE
        ) &
    done

    wait
}


# ----------------------------------------------------------------------
# sfs_nodes_cs
# ----------------------------------------------------------------------
sfs_nodes_cs() {
    local NODES=($@)
    local N0=${#NODES[@]}

    if [ $N0 -gt 0 ] ; then
        local N=$(($N0 - 1))
        local nodes=""

        for X in `seq 0 $N`; do
            local node=`echo ${NODES[$X]} | sed "s/'//g"`
            nodes="$nodes,sfs@$node"
        done
        echo `echo $nodes | sed 's/^,//'`
    else
        echo
    fi
}


# ----------------------------------------------------------------------
# sfs_nodes_cs_squote
# ----------------------------------------------------------------------
sfs_nodes_cs_squote() {
    local NODES=($@)
    local N0=${#NODES[@]}

    if [ $N0 -gt 0 ] ; then
        local N=$(($N0 - 1))
        local nodes=""

        for X in `seq 0 $N`; do
            local node=`echo ${NODES[$X]} | sed "s/'//g"`
            nodes="$nodes,'sfs@$node'"
        done
        echo `echo $nodes | sed 's/^,//'`
    else
        echo
    fi
}


# ----------------------------------------------------------------------
# sfs_nodes_ws
# ----------------------------------------------------------------------
sfs_nodes_ws() {
    local NODES=($@)
    local N0=${#NODES[@]}

    if [ $N0 -gt 0 ] ; then
        local N=$(($N0 - 1))
        local nodes=""

        for X in `seq 0 $N`; do
            local node=`echo ${NODES[$X]} | sed "s/'//g"`
            nodes="$nodes sfs@$node"
        done
        echo `echo $nodes | sed 's/^ //'`
    else
        echo
    fi
}


# ----------------------------------------------------------------------
# sfs_nodes_ws_squote
# ----------------------------------------------------------------------
sfs_nodes_ws_squote() {
    local NODES=($@)
    local N0=${#NODES[@]}

    if [ $N0 -gt 0 ] ; then
        local N=$(($N0 - 1))
        local nodes=""

        for X in `seq 0 $N`; do
            local node=`echo ${NODES[$X]} | sed "s/'//g"`
            nodes="$nodes 'sfs@$node'"
        done
        echo `echo $nodes | sed 's/^ //'`
    else
        echo
    fi
}


# ----------------------------------------------------------------------
# is_int
# ----------------------------------------------------------------------
is_int() {
    return $(test "$@" -eq "$@" >/dev/null 2>&1);
}


# ----------------------------------------------------------------------
# seq
# ----------------------------------------------------------------------
seq() {
    declare incr n1 n2 num1 num2
    if [[ $# -eq 1 ]]; then
        if ! $(is_int "$1"); then echo 'No integer!'; return 1; fi
        for ((i=1; i<=${1}; i++)) { printf "%d\n" ${i}; }
    elif [[ $# -eq 2 ]]; then
        if ! $(is_int "$1") || ! $(is_int "$2"); then echo 'Not all arguments are integers!'; return 1; fi

        if [[ $1 -eq $2 ]]; then
            echo $1
        elif [[ $2 -gt $1 ]]; then
            for ((i=${1}; i<=${2}; i++)) { printf "%d\n" ${i}; }
        elif [[ $1 -gt $2 ]]; then
            for ((i=${1}; i>=${2}; i--)) { printf "%d\n" ${i}; }
        fi

    elif [[ $# -eq 3 ]]; then
        num1=${1}
        incr=${2}
        num2=${3}
        /usr/bin/awk -v n1=${num1} -v n2=${num2} -v add=${incr} 'BEGIN{ for(i=n1; i<=n2; i+=add) print i;}' | /usr/bin/sed -E '/e/s/^.+e.+$/0/'
    fi
    return 0
}
