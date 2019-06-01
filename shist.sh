

SHIST_DB=$HOME/.shist.db

function shist-cwd () {
    cat <<EOF | shist-query
    select
      c.session_id as "session",
      datetime(c.start_time, 'unixepoch', 'localtime') as "when",
      c.command as "what",
      c.rval as 'rc',
      c.duration as 'dur'
    from
      commands as c
    where
      c.cwd = '${PWD}' or c.cwd = '/${PWD}' or c.cwd = '/${PWD#//}'
    order by 2, 1
    ;
EOF

}

function shist-here () {
    cat <<EOF | shist-query | uniq | fzf --tac +s +m -e --ansi --reverse
    select
      c.command as "what"
    from
      commands as c
    where
      c.cwd = '${PWD}' or c.cwd = '/${PWD}' or c.cwd = '/${PWD#//}'
    order by c.start_time, c.session_id
    ;
EOF
}

function shist-now () {
    cat <<EOF | shist-query | sed 's/^.*|//' | uniq | fzf --tac +s +m -e --ansi --reverse
    select
      c.cwd as 'cwd',
      c.command
    from
      commands as c
      left outer join sessions as s
        on c.session_id = s.id
    where
      c.session_id = ${__SHIST_SESSION_ID:-0}
    order by
      c.id
    ;
EOF
}

function shist-dbinit () {
    if [ -f "$SHIST_DB" ] ; then
        return
    fi
    cat <<EOF| sqlite3 $SHIST_DB
CREATE TABLE sessions ( 
  id integer primary key autoincrement, 
  hostname varchar(128), 
  host_ip varchar(40), 
  ppid int(5) not null, 
  pid int(5) not null, 
  time_zone str(3) not null, 
  start_time integer not null, 
  end_time integer, 
  duration integer, 
  tty varchar(20) not null, 
  uid int(16) not null, 
  euid int(16) not null, 
  logname varchar(48), 
  shell varchar(50) not null, 
  sudo_user varchar(48), 
  sudo_uid int(16), 
  ssh_client varchar(60), 
  ssh_connection varchar(100) 
);
CREATE TABLE commands (
  id integer primary key autoincrement,
  session_id integer not null,
  shell_level integer not null,
  command_no integer,
  tty varchar(20) not null,
  euid int(16) not null,
  cwd varchar(256) not null,
  rval int(5) not null,
  start_time integer not null,
  end_time integer not null,
  duration integer not null,
  pipe_cnt int(3),
  pipe_vals varchar(80),
  command varchar(1000) not null,
UNIQUE(session_id, command_no)
);
EOF
}

function shist-query () {
    shist-dbinit
    sqlite3 $@ $SHIST_DB
}
        

__SHIST_NUM=""
__SHIST_START=""
__SHIST_COMMAND=""
function __shist_postexec() {
    # record command
    local et=$(date +%s)
    local dt=$(( $et - $__SHIST_START ))

    cat <<EOF | shist-query 
INSERT INTO 
commands(       'session_id','shell_level','command_no',  'tty',   'euid',  'cwd', 'rval',              'start_time',    'end_time','duration','pipe_cnt','pipe_vals','command')
VALUES('$__SHIST_SESSION_ID','$SHLVL',     '$__SHIST_NUM','$(tty)','$EUID', '$PWD','$__SHIST_EXIT_CODE','$__SHIST_START','$et',     '$dt','$__SHIST_PIPESTATUS','',
'${__SHIST_COMMAND//\'/''}')
EOF
}

__SHIST_EXECUTING=""
function __shist_preexec() {
    __SHIST_EXECUTING=t
    __SHIST_PWD="$PWD"
}

function __shist_precmd() {
    __SHIST_EXIT_CODE="$1"
    shift
    __SHIST_PIPESTATUS=("$@")
    __SHIST_OPTS=()
    if [ -n "$__SHIST_EXECUTING" ]
    then
        local num start command
        local hist="$(HISTTIMEFORMAT="%s " builtin history 1)"
        read -r num start command <<< "$hist"
        # history number doesn't change for an empty command.
        if [ "$__SHIST_NUM" != "$num" -a -n "$command" ] ; then
            __SHIST_NUM="$num"
            __SHIST_START="$start"
            __SHIST_COMMAND="$command"
            __shist_postexec
            __SHIST_EXECUTING=""
        fi
    fi
    __shist_preexec
}

export PROMPT_COMMAND="__shist_precmd \${?} \${PIPESTATUS[@]}"

if [ -z "$__SHIST_SESSION_ID" ]
then
    cat <<EOF | shist-query
INSERT INTO
sessions('hostname','host_ip','ppid','pid','time_zone','start_time','tty','uid','euid','logname','shell','sudo_user','sudo_uid','ssh_client','ssh_connection')
VALUES('$(hostname)','$(hostname -I)','$PPID','$$','$(date +%Z)','$(date +%s)','$(tty)','$(id -ur)','$(id -u)','$(id -un)','$SHELL','','','$SSH_CLIENT','$SSH_CONNECTION')
EOF
    __SHIST_SESSION_ID=$(echo 'select seq from sqlite_sequence where name="sessions"'|shist-query)
fi

function __shist_onexit() {
    # record session end
    local st=$(echo select start_time from sessions where id = $__SHIST_SESSION_ID|shist-query)
    local nt=$(date +%s)
    local dt=$(( $nt - $st ))
    cat <<EOF | shist-query
UPDATE sessions SET end_time = '$nt', duration = '$dt'
WHERE id = '$__SHIST_SESSION_ID'
EOF
}

trap "__shist_onexit" EXIT TERM

