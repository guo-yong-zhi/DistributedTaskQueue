# /bin/bash
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
    -m|--master)
      master="$2"
      shift # past argument
      shift # past value
      ;;
    -n|--name)
      workername="$2"
      shift # past argument
      shift # past value
      ;;
    -i|--id)
      newid="$2"
      shift # past argument
      shift # past value
      ;;
    --lock)
      LOCK="YES"
      shift # past argument
      ;;
    -*|--*)
      echo "Unknown option $1"
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1") # save positional arg
      shift # past argument
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
taskfile="${newtask/#\~/$HOME}"
ssh -q $master bash << EOF
exec {FD}<>"$taskfile.lock"; flock \$FD
echo "$taskfile is locked (unlock it with CTRL-C)"
tail -f /dev/null
EOF
exit
fi

#task init
if [ ! -z "$newtask" ]
then
taskfile="${newtask/#\~/$HOME}"
newtask=""
wkid=$newid
newid=""
linenum=0
cmdline=""
workerid=$(ssh -q $master bash << EOF
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
export WORKERID=$workerid
export TASKFILE="$taskfile"
echo "##############################"
echo "# `date`"
echo "# export WORKERID=$WORKERID"
echo "# export TASKFILE=\"$TASKFILE\""
echo "##############################"
fi

# take task & edit taskfile
out=$(ssh -q $master bash << EOF
exec {FD}<>"$taskfile.lock"; flock \$FD
python3 << EOPY
with open("$taskfile") as f:
    L = f.readlines()
linenum2 = $linenum
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
        else:
            L.append("#?line:$linenum# " + c2 + " # worker $WORKERID # ... `date '+%m-%d %H:%M:%S'`) #$excode\n")
with open("$taskfile", "w") as f:
    f.writelines(L)        
EOPY
flock -u \$FD
EOF
)

# eval task command
cmd=`echo "$out" | sed '$ d'`
linenum=$(echo "$out" | tail -1)
if [ ! -z "$cmd" ]
then
    echo "======================="
    echo "LINE:$linenum"
    echo "$cmd"
    echo "-----------------------"
    while read -r line; do
        echo "➜ `pwd`> $line"
        if echo $line | grep "#\!"
        then
            eval "$line"
        else
            (eval "$line")
        fi
        excode=$?
        [ $excode -eq 0 ] && excode=ok
        echo "∎[$line] #$excode"
        cmdline=$line
    done <<< "$cmd"
    echo
else
    cmdline=""
fi
sleep 3

done
