#!/bin/bash

set -e

# aliases
EXPECT=${CT_EXPECT:-"expect"}
GROUPADD=${CT_GROUPADD:-"/usr/sbin/groupadd"}
GROUPDEL=${CT_GROUPDEL:-"/usr/sbin/groupdel"}
PERL=${CT_PERL:-"perl"}
SSH=${CT_SSH:-"ssh -ttqx -o PasswordAuthentication=no"}
SSHCOPYID=${CT_SSHCOPYID:-"ssh-copy-id"}
SUDO=${CT_SUDO:-"sudo -H"}
USERADD=${CT_USERADD:-"/usr/sbin/useradd"}
USERDEL=${CT_USERDEL:-"/usr/sbin/userdel"}
USERMOD=${CT_USERMOD:-"/usr/sbin/usermod"}

# files
GROUPFILE=${CT_GROUPFILE:-"/etc/group"}
NULLFILE=${CT_NULLFILE:-"/dev/null"}
PASSWDFILE=${CT_PASSWDFILE:-"/etc/passwd"}

# directories
HOMEBASEDIR=${CT_HOMEBASEDIR:-"/usr/local/var/lib"}

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
    elif [ "$CMD" = "delete" ] ; then
        delete
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
    init <user> <host> [<installer_user>]
    delete <user> <host> [<installer_user>]

  - "-f" is enable force mode.  disable safety checks to prevent
     deleting and/or overwriting an existing installation.
  - <user> is the account on the server where you will be installing
  - <host> is that server's hostname (or IP address)
  - <installer_user> is *your* loginname

Example usage:
  $0 init skylark `hostname`

Notes:
  - <user>, <host>, and <installer_user> must be simple names -- no
    special characters etc please (only alphanumerics, dot, hyphen,
    underscore)
  - <user> must be different than <installer_user>.
  - <installer_user> should be your name, for clarity, or whoever will
    be the installer user.  The default <installer_user> is "$USER"

EOF
    exit 1;
}


# ----------------------------------------------------------------------
# environment checks
# ----------------------------------------------------------------------
env_sanity() {
    local EXPECT=($EXPECT)
    local PERL=($PERL)
    local SSH=($SSH)
    local SSHCOPYID=($SSHCOPYID)
    local SUDO=($SUDO)

    for i in ${EXPECT[0]} ${PERL[0]} ${SSH[0]} ${SSHCOPYID[0]} ${SUDO[0]} ; do
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
    fi

    CMD=$1
    NODE_USER=$2
    NODE_HOST=$3
    if [ -z $4 ] ; then
        INSTALLER_USER=$USER
    else
        INSTALLER_USER=$4
    fi

    echo $NODE_USER | $PERL -lne 'exit 1 if /[^a-zA-Z0-9._-]/' || \
        die "user '$NODE_USER' invalid"
    if [[ "$NODE_USER" = "root" || "$NODE_USER" = "$INSTALLER_USER" ]] ; then
        die "user '$NODE_USER' unsupported"
    fi
    echo $NODE_HOST | $PERL -lne 'exit 1 if /[^a-zA-Z0-9._-]/' || \
        die "user '$NODE_HOST' invalid"
    echo $INSTALLER_USER | $PERL -lne 'exit 1 if /[^a-zA-Z0-9._-]/' || \
        die "installer_user '$INSTALLER_USER' invalid"
}


# ----------------------------------------------------------------------
# init
# ----------------------------------------------------------------------
init() {
    # check ssh w/ sudo
    $SSH $NODE_HOST '$SUDO true' || \
        die "ssh '$NODE_HOST' sudo failed"

    # force check
    if [ -z $FORCE ] ; then
        $SSH $NODE_HOST "grep $Q '^$NODE_USER:' $PASSWDFILE" && \
            die "remote user '$NODE_USER@$NODE_HOST' exists"
        $SSH $NODE_HOST "grep $Q '^$NODE_USER:' $GROUPFILE" && \
            die "remote group '$NODE_USER@$NODE_HOST' exists"
    fi

    # kill all old user processes
    $SSH $NODE_HOST "$SUDO pkill -9 -u $NODE_USER &> $NULLFILE || true" || \
        die "remote user '$NODE_USER@$NODE_HOST' kill failed"

    # delete old user and group
    $SSH $NODE_HOST "grep $Q '^$NODE_USER:' $PASSWDFILE" && \
        ($SSH $NODE_HOST "$SUDO $USERDEL -r $NODE_USER" || \
        die "remote user '$NODE_USER@$NODE_HOST' del failed")
    $SSH $NODE_HOST "grep $Q '^$NODE_USER:' $GROUPFILE" && \
        ($SSH $NODE_HOST "$SUDO $GROUPDEL $NODE_USER" || \
        die "remote group '$NODE_USER@$NODE_HOST' del failed")

    # add new group and user
    $SSH $NODE_HOST "$SUDO $GROUPADD -r $NODE_USER" || \
        die "remote group '$NODE_USER@$NODE_HOST' add failed"
    $SSH $NODE_HOST "$SUDO mkdir -p $HOMEBASEDIR" || \
        die "remote group '$NODE_USER@$NODE_HOST' mkdir failed"
    $SSH $NODE_HOST "$SUDO $USERADD -m -r -g $NODE_USER -d $HOMEBASEDIR/$NODE_USER -c '$NODE_USER node' $NODE_USER" || \
        die "remote user '$NODE_USER@$NODE_HOST' add failed"

    # copy ssh identity
    local passwd=`randpasswd`
    if [ -z $passwd ] ; then
        die "remote user '$NODE_USER@$NODE_HOST' passwd gen failed"
    fi
    $SSH $NODE_HOST "echo $passwd | $SUDO passwd --stdin $NODE_USER &> $NULLFILE" || \
        die "user '$NODE_USER@$NODE_HOST' passwd failed"
    $SSH $NODE_HOST "$SUDO $USERMOD -U $NODE_USER" || \
        die "remote user '$NODE_USER@$NODE_HOST' mod failed"
    { eval "$EXPECT -c 'spawn $SSHCOPYID $NODE_USER@$NODE_HOST' -c 'expect password:' -c 'send $passwd\n' -c 'expect eof' &> $NULLFILE"; } || \
        die "remote user '$NODE_USER@$NODE_HOST' ssh-copy-id failed"
    $SSH $NODE_HOST "$SUDO $USERMOD -L $NODE_USER" || \
        die "remote user '$NODE_USER@$NODE_HOST' mod failed"

    # check ssh
    $SSH $NODE_USER@$NODE_HOST 'echo `whoami`@`hostname`' || \
        die "remote ssh '$NODE_USER@$NODE_HOST' user failed"
}


randpasswd() {
    echo `(cat /dev/urandom | strings | tr -c -d "a-zA-Z0-9-_" | fold -w 25 | head -1) 2> $NULLFILE`
}


# ----------------------------------------------------------------------
# delete
# ----------------------------------------------------------------------
delete() {
    # check ssh w/ sudo
    $SSH $NODE_HOST '$SUDO true' || \
        die "ssh '$NODE_HOST' sudo failed"

    # force check
    if [ -z $FORCE ] ; then
        $SSH $NODE_HOST "grep $Q '^$NODE_USER:' $PASSWDFILE" || \
            die "remote user '$NODE_USER@$NODE_HOST' does not exist"
        $SSH $NODE_HOST "grep $Q '^$NODE_USER:' $GROUPFILE" || \
            die "remote group '$NODE_USER@$NODE_HOST' does not exist"
        die "-f option is required"
    fi

    # kill all old user processes
    $SSH $NODE_HOST "$SUDO pkill -9 -u $NODE_USER &> $NULLFILE || true" || \
        die "remote user '$NODE_USER@$NODE_HOST' kill failed"

    # delete old user and group
    $SSH $NODE_HOST "grep $Q '^$NODE_USER:' $PASSWDFILE" && \
        ($SSH $NODE_HOST "$SUDO $USERDEL -r $NODE_USER" || \
        die "remote user '$NODE_USER@$NODE_HOST' del failed")
    $SSH $NODE_HOST "grep $Q '^$NODE_USER:' $GROUPFILE" && \
        ($SSH $NODE_HOST "$SUDO $GROUPDEL $NODE_USER" || \
        die "remote group '$NODE_USER@$NODE_HOST' del failed")
}
