#!/usr/bin/env bash
# runlist.sh <listfile> : each line "name engine scenario [ENV=VAL...]" ; one harness at a time.
source ~/.cache/int15-win-184c94d7/env.sh; cd $W/fork
while read -r name engine scen envs; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  avail=$(free -g | awk '/^Mem:/ {print $7}')
  xt=$(ssh -o BatchMode=yes $MAC 'pgrep -f xctest | tr "\n" " "' < /dev/null)
  echo "[$(date +%H:%M:%S)] $name $engine $scen $envs avail=${avail}G macXctest=[${xt}]"
  env $envs timeout 1500 $R run $name $engine $W/scen/$scen.json < /dev/null 2>&1 | tail -1
  python3 $W/tools/judge.py $I8_WORK/results $W/expected.json $name
  [[ -f $W/STOP ]] && { echo "STOP file"; break; }
done < "$1"
echo "[$(date +%H:%M:%S)] list done"
