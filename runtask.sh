#!/bin/bash
master="$MASTER_SERVER"
[ -z "$master" ] && master="username@default_master_server.com"
taskfile="$TASK_FILE"
[ -z "$taskfile" ] && taskfile="tasklist.sh"
workername="$WORKER_NAME"
[ -z "$workername" ] && workername="`hostname` `hostname -I`"

#parse arguments
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--master) #> set the master server. (env: MASTER_SERVER)
          master="$2"
          shift
          shift
          ;;
        -n|--name) #> set the worker name. (env: WORKER_NAME)
          workername="$2"
          shift
          shift
          ;;
        -i|--id) #> set the worker id.
          newid="$2"
          shift
          shift
          ;;
        --lock) #> lock the file so that you can edit it safely.
          LOCK="YES"
          shift
          ;;
        --reset) #> reset the file to initial state.
          RESET="YES"
          shift
          ;;
        -h|--help) #> show this message.
          echo "Parameters:"
          echo '[taskfile] path to the taskfile on the master server. (env: TASK_FILE)'
          grep ") [#]>" $0 | sed 's/^[[:space:]]*//; s/) [#]>/]/' | sed 's/.*/[&/'
          exit
          ;;
        -*|--*)
          echo "Unknown option $1"
          exit 1
          ;;
        *)
          POSITIONAL_ARGS+=("$1") # save positional arg
          shift
          ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters
newtask=$1
[ -z "$newtask" ] && newtask=$taskfile

#main loop
while :
do

#lock
if [ ! -z "$LOCK" ]
then
taskfile=`echo "$newtask" | cut -s -d \: -f 2`
[ -z "$taskfile" ] && taskfile="$newtask"
taskfile="${taskfile/#\~/$HOME}"
mst=`echo "$newtask" | cut -s -d \: -f 1`
[ -z "$mst" ] && mst="$master"
ssh $mst bash << EOF
exec {FD}<>"$taskfile.lock"; flock \$FD
echo "$taskfile is locked (unlock it with CTRL-C)"
tail -f /dev/null
EOF
exit
fi
#reset
if [ ! -z "$RESET" ]
then
taskfile=`echo "$newtask" | cut -s -d \: -f 2`
[ -z "$taskfile" ] && taskfile="$newtask"
taskfile="${taskfile/#\~/$HOME}"
mst=`echo "$newtask" | cut -s -d \: -f 1`
[ -z "$mst" ] && mst="$master"
ssh $mst bash << EOF
exec {FD}<>"$taskfile.lock"; flock \$FD
python3 << EOPY
import re
L = []
with open("$taskfile") as f:
    for l in f.readlines():
        if l.startswith('#LASTWORKER'):
            continue
        l2 = re.sub(r"\s*# worker .*", "", l)
        if l2 != l and l2 and l2[0] == "#":
            l2 = l2[1:]
        if l2.strip():
            L.append(l2)
with open("$taskfile", "w") as f:
    f.writelines(L)
EOPY
flock -u \$FD
EOF
exit
fi

#task init
if [ ! -z "$newtask" ]
then
taskfile=`echo "$newtask" | cut -s -d \: -f 2`
[ -z "$taskfile" ] && taskfile="$newtask"
taskfile="${taskfile/#\~/$HOME}"
mst=`echo "$newtask" | cut -s -d \: -f 1`
[ -z "$mst" ] && mst="$master"
newtask=""
wkid=$newid
newid=""
linenum=0
cmdline=""
workerid=$(ssh $mst bash << EOF
touch "$taskfile"
exec {FD}<>"$taskfile.lock"; flock \$FD
sleep 1
num=\$(awk 'NR==1 && \$1=="#LASTWORKER" {print \$NF; exit}' $taskfile)
if [ -z "\$num" ]
then
    sed -i '1 i\#LASTWORKER -1' "$taskfile"
    [ ! -s "$taskfile" ] && echo "#LASTWORKER -1" > "$taskfile"
    num=-1
fi
if [ ! -z "$wkid" ]
then
    num=$wkid
else
    num=\$((num+1))
fi
sed -i "1s/.*/#LASTWORKER \$num/" "$taskfile"
if [[ ! -z "\$(tail -c 1 "$taskfile")" ]]
then
    echo "" >> "$taskfile"
fi
echo "# worker \$num: $workername (\$(date '+%m-%d %H:%M:%S'))" >> "$taskfile"
flock -u \$FD
echo \$num
EOF
)
sshexcode=$?
[ $sshexcode -ne 0 ] && echo "error code: $sshexcode" && exit $sshexcode
export WORKERID=$workerid
export TASKFILE="$taskfile"
echo "##############################"
echo "# `date`"
echo "# export WORKERID=$WORKERID"
echo "# export TASKFILE=\"$TASKFILE\""
echo "##############################"
fi

# take task & edit taskfile
out=$(ssh $mst bash << EOF
exec {FD}<>"$taskfile.lock"; flock \$FD
python3 << EOPY
with open("$taskfile") as f:
    L = f.readlines()
linenum2 = $linenum
edited = False
for i,l in enumerate(L, 1):
    l = l.strip()
    if "#!" in l:
        if i>$linenum:
            if "#@" not in l or "@$WORKERID" in {i.rstrip() for i in l.split("#")}:
                print(l)
                linenum2 = i
                break
    elif l and not l.startswith("#"):
        if "#@" not in l or "@$WORKERID" in {i.rstrip() for i in l.split("#")}:
            print(l)
            L[i-1] = "#" + l + " # worker $WORKERID # (`date '+%m-%d %H:%M:%S'` ...\n"
            linenum2 = i
            edited = True
            break
print(linenum2)
ind = $linenum-1
if 0 <= ind < len(L):
    c1 = L[ind].strip("#").split("#")[0].strip()
    c2 = """`echo $cmdline`""".strip("#").split("#")[0].strip()
    if c2 != "":
        if c1 == c2:
            if "#!" not in L[ind]:
                L[ind] = L[ind].strip() + " `date '+%m-%d %H:%M:%S'`) #$excode\n"
                edited = True
        else:
            L.append("#?line:$linenum# " + c2 + " # worker $WORKERID # ... `date '+%m-%d %H:%M:%S'`) #$excode\n")
            edited = True
if edited:
    with open("$taskfile", "w") as f:
        f.writelines(L)        
EOPY
flock -u \$FD
EOF
)
sshexcode=$?
[ $sshexcode -ne 0 ] && echo "error code: $sshexcode" && out=""

# eval task command
cmd=`echo "$out" | sed '$ d'`
if [ ! -z "$cmd" ]
then
    linenum=$(echo "$out" | tail -1)
    echo "======================="
    echo "LINE:$linenum"
    echo "$cmd"
    echo "-----------------------"
    while read -r line; do
        echo "(worker $WORKERID)➜ `pwd`> $line"
        if echo $line | grep "#\!"
        then
            eval "$line"
        else
            (eval "$line")
        fi
        excode=$?
        [ $excode -eq 0 ] && excode=ok
        echo "∎(worker $WORKERID)[$line] #$excode"
        cmdline=$line
    done <<< "$cmd"
    echo
else
    cmdline=""
    sleep 3
fi

done
