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
    init <user> <hibari.cfg> <hibari-X.Y.Z-DIST-ARCH-WORDSIZE>.tgz
    start <user> <hibari.cfg>
    bootstrap <user> <hibari.cfg>
    ping <user> <hibari.cfg>
    stop <user> <hibari.cfg>

  - "-f" is enable force mode.  disable safety checks to prevent
     deleting and/or overwriting an existing installation.
  - <user> is the account on the server(s) where you will be
    installing Hibari
  - <hibari.cfg> is Hibari's cluster config file


Example usage:
  $0 init hibari hibari.cfg hibari-X.Y.Z-DIST-ARCH-WORDSIZE.tgz

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
        if [ -z $4 ] ; then
            usage
        elif [ ! -f "$4" ] ; then
            usage
        else
            SRCTARBALL=$4
            DSTTARBALL=`basename $4`
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

    source $CONFIG_FILE || \
        die "source '$CONFIG_FILE' failed"

    for i in $ADMIN_NODES $BRICK_NODES $ALL_NODES ; do
        echo $i | $PERL -lne 'exit 1 if /[^a-zA-Z0-9._-]/' || \
            die "host '$i' invalid"
    done

    if [ ${#ALL_NODES[@]} -lt 1 ] ; then
        die "missing ALL_NODES in '$CONFIG_FILE'"
    fi
    if [ ${#ADMIN_NODES[@]} -lt 1 ] ; then
        die "missing ADMIN_NODES in '$CONFIG_FILE'"
    fi
    if [ ${#BRICK_NODES[@]} -lt 1 ] ; then
        die "missing BRICK_NODES in '$CONFIG_FILE'"
    fi
    if [ -z $BRICKS_PER_CHAIN ] ; then
        die "missing BRICKS_PER_CHAIN in '$CONFIG_FILE'"
    fi
    if [ $BRICKS_PER_CHAIN -lt 1 ] ; then
        die "invalid BRICKS_PER_CHAIN in '$CONFIG_FILE'"
    fi
    if [ ${#ALL_NETA_ADDRS[@]} -lt 1 ] ; then
        die "missing ALL_NETA_ADDRS in '$CONFIG_FILE'"
    fi
    if [ ${#ALL_NETB_ADDRS[@]} -lt 1 ] ; then
        die "missing ALL_NETB_ADDRS in '$CONFIG_FILE'"
    fi
    if [ -z $ALL_NETA_BCAST ] ; then
        die "missing ALL_NETA_BCAST in '$CONFIG_FILE'"
    fi
    if [ -z $ALL_NETB_BCAST ] ; then
        die "missing ALL_NETB_BCAST in '$CONFIG_FILE'"
    fi
    if [ -z $ALL_NETA_TIEBREAKER ] ; then
        die "missing ALL_NETA_TIEBREAKER in '$CONFIG_FILE'"
    fi
    if [ -z $ALL_HEART_UDP_PORT ] ; then
        die "missing ALL_HEART_UDP_PORT in '$CONFIG_FILE'"
    fi
    if [ -z $ALL_HEART_XMIT_UDP_PORT ] ; then
        die "missing ALL_HEART_XMIT_UDP_PORT in '$CONFIG_FILE'"
    fi

    if [ ${#ALL_NODES[@]} -lt ${#ADMIN_NODES[@]} ] ; then
        die "ALL_NODES is less than ADMIN_NODES"
    fi
    if [ ${#ADMIN_NODES[@]} -eq 1 ] ; then
        true
    elif [ ${#ADMIN_NODES[@]} -eq 2 ] ; then
        die "2 ADMIN_NODES is not supported"
    fi
    if [ ${#ALL_NODES[@]} -lt ${#BRICK_NODES[@]} ] ; then
        die "ALL_NODES is less than BRICK_NODES"
    fi
    if [ ${#ALL_NODES[@]} -ne ${#ALL_NETA_ADDRS[@]} ] ; then
        die "nonequal # of ALL_NODES and ALL_NETA_ADDRS"
    fi
    if [ ${#ALL_NODES[@]} -ne ${#ALL_NETB_ADDRS[@]} ] ; then
        die "nonequal # of ALL_NODES and ALL_NETB_ADDRS"
    fi
}


# ----------------------------------------------------------------------
# init
# ----------------------------------------------------------------------
init() {
    local N0=${#ALL_NODES[@]}
    local N=$(($N0 - 1))

    # generate cookie
    local COOKIE=`randcookie`
    if [ -z $COOKIE ] ; then
        die "generate cookie failed"
    fi

    # setup NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${ALL_NODES[$I]}
            local ADMIN_NODES_MINUSMOI=(`echo ${ADMIN_NODES[@]} | xargs -n 1 echo | grep -v $NODE | xargs echo`)

            local WS_NODE=(`hibari_nodes_ws $NODE`)
            local CS_ALL_NODES=(`hibari_nodes_cs_squote ${ALL_NODES[@]}`)
            local CS_ADMIN_NODES=(`hibari_nodes_cs_squote ${ADMIN_NODES[@]}`)
            local CS_ADMIN_NODES_MINUSMOI=(`hibari_nodes_cs_squote ${ADMIN_NODES_MINUSMOI[@]}`)

            # stop Hibari
            $SSH $NODE_USER@$NODE "(source .bashrc; cd hibari &> $NULLFILE; ./bin/hibari stop &> $NULLFILE) || true" || \
                die "node $NODE stop failed"
            # kill all Hibari beam.smp processes
            $SSH $NODE_USER@$NODE "pkill -9 -u $NODE_USER beam.smp || true" || \
                die "node $NODE pkill beam.smp failed"

            # scp Hibari tarball
            $SCP $SRCTARBALL $NODE_USER@$NODE:$DSTTARBALL || \
                die "node $NODE scp tarball failed"

            # untar Hibari package
            $SSH $NODE_USER@$NODE "rm -rf hibari; tar -xzf $DSTTARBALL" || \
                die "node $NODE untar tarball failed"

            # configure Hibari package
            $SSH $NODE_USER@$NODE "sed -i.bak \
-e \"s/-sname .*/-sname $WS_NODE/\" \
-e \"s/-name .*/-sname $WS_NODE/\" \
-e \"s/-setcookie .*/-setcookie $COOKIE/\" \
hibari/releases/*/vm.args" || \
                die "node $NODE vm.args setup failed"

            $SSH $NODE_USER@$NODE "sed -i.bak \
-e \"s/{distributed, \[{gdss_admin, \(.*\), .*}\]}/{distributed, \[{gdss_admin, \1, [$CS_ADMIN_NODES]}\]}/\" \
-e \"s/{sync_nodes_optional,.*}/{sync_nodes_optional, [$CS_ADMIN_NODES_MINUSMOI]}/\" \
-e \"s/{admin_server_distributed_nodes,.*}/{admin_server_distributed_nodes, [$CS_ADMIN_NODES]}/\" \
-e \"s/{network_a_address,.*}/{network_a_address, \\\"${ALL_NETA_ADDRS[$I]}\\\"}/\" \
-e \"s/{network_b_address,.*}/{network_b_address, \\\"${ALL_NETB_ADDRS[$I]}\\\"}/\" \
-e \"s/{network_a_broadcast_address,.*}/{network_a_broadcast_address, \\\"$ALL_NETA_BCAST\\\"}/\" \
-e \"s/{network_b_broadcast_address,.*}/{network_b_broadcast_address, \\\"$ALL_NETB_BCAST\\\"}/\" \
-e \"s/{network_a_tiebreaker,.*}/{network_a_tiebreaker, \\\"$ALL_NETA_TIEBREAKER\\\"}/\" \
-e \"s/{network_monitor_enable,.*}/{network_monitor_enable, true}/\" \
-e \"s/{network_monitor_monitored_nodes,.*}/{network_monitor_monitored_nodes, [$CS_ALL_NODES]}/\" \
-e \"s/{heartbeat_status_udp_port,.*}/{heartbeat_status_udp_port, $ALL_HEART_UDP_PORT}/\" \
-e \"s/{heartbeat_status_xmit_udp_port,.*}/{heartbeat_status_xmit_udp_port, $ALL_HEART_XMIT_UDP_PORT}/\" \
hibari/releases/*/sys.config" || \
                die "node $NODE sys.config setup failed"

            echo $NODE_USER@$NODE
        ) &
    done

    wait
}

randcookie() {
    echo `(cat /dev/urandom | strings | tr -c -d "a-zA-Z0-9_" | fold -w 25 | head -1) 2> $NULLFILE`
}


# ----------------------------------------------------------------------
# start
# ----------------------------------------------------------------------
start() {
    local N0=${#ALL_NODES[@]}
    local N=$(($N0 - 1))

    # start NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${ALL_NODES[$I]}

            # start Hibari package
            $SSH $NODE_USER@$NODE "source .bashrc; cd hibari; ./bin/hibari start" || \
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
    local NODE=${ADMIN_NODES[0]}
    local WS_BRICK_NODES=`hibari_nodes_ws ${BRICK_NODES[@]}`

    # bootstrap Hibari package
    $SSH $NODE_USER@$NODE "source .bashrc; cd hibari; ./bin/hibari-admin bootstrap -bricksperchain $BRICKS_PER_CHAIN $WS_BRICK_NODES" || \
        die "node $NODE bootstrap failed"

    echo "$NODE_USER@$NODE => $WS_BRICK_NODES"
}


# ----------------------------------------------------------------------
# ping
# ----------------------------------------------------------------------
ping() {
    local N0=${#ALL_NODES[@]}
    local N=$(($N0 - 1))

    # ping NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${ALL_NODES[$I]}

            # ping Hibari package
            echo -n "$NODE_USER@$NODE ... "
            $SSH $NODE_USER@$NODE "source .bashrc; cd hibari; ./bin/hibari ping" || \
                die "node $NODE ping failed"
        )
    done
}


# ----------------------------------------------------------------------
# stop
# ----------------------------------------------------------------------
stop() {
    local N0=${#ALL_NODES[@]}
    local N=$(($N0 - 1))

    # stop NODE
    for I in `seq 0 $N`; do
        (
            local NODE=${ALL_NODES[$I]}

            # stop Hibari package
            $SSH $NODE_USER@$NODE "source .bashrc; cd hibari; ./bin/hibari stop" || \
                die "node $NODE stop failed"

            echo $NODE_USER@$NODE
        ) &
    done

    wait
}


# ----------------------------------------------------------------------
# hibari_nodes_cs
# ----------------------------------------------------------------------
hibari_nodes_cs() {
    local NODES=($@)
    local N0=${#NODES[@]}

    if [ $N0 -gt 0 ] ; then
        local N=$(($N0 - 1))
        local nodes=""

        for X in `seq 0 $N`; do
            local node=`echo ${NODES[$X]} | sed "s/'//g"`
            nodes="$nodes,hibari@$node"
        done
        echo `echo $nodes | sed 's/^,//'`
    else
        echo
    fi
}


# ----------------------------------------------------------------------
# hibari_nodes_cs_squote
# ----------------------------------------------------------------------
hibari_nodes_cs_squote() {
    local NODES=($@)
    local N0=${#NODES[@]}

    if [ $N0 -gt 0 ] ; then
        local N=$(($N0 - 1))
        local nodes=""

        for X in `seq 0 $N`; do
            local node=`echo ${NODES[$X]} | sed "s/'//g"`
            nodes="$nodes,'hibari@$node'"
        done
        echo `echo $nodes | sed 's/^,//'`
    else
        echo
    fi
}


# ----------------------------------------------------------------------
# hibari_nodes_ws
# ----------------------------------------------------------------------
hibari_nodes_ws() {
    local NODES=($@)
    local N0=${#NODES[@]}

    if [ $N0 -gt 0 ] ; then
        local N=$(($N0 - 1))
        local nodes=""

        for X in `seq 0 $N`; do
            local node=`echo ${NODES[$X]} | sed "s/'//g"`
            nodes="$nodes hibari@$node"
        done
        echo `echo $nodes | sed 's/^ //'`
    else
        echo
    fi
}


# ----------------------------------------------------------------------
# hibari_nodes_ws_squote
# ----------------------------------------------------------------------
hibari_nodes_ws_squote() {
    local NODES=($@)
    local N0=${#NODES[@]}

    if [ $N0 -gt 0 ] ; then
        local N=$(($N0 - 1))
        local nodes=""

        for X in `seq 0 $N`; do
            local node=`echo ${NODES[$X]} | sed "s/'//g"`
            nodes="$nodes 'hibari@$node'"
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
