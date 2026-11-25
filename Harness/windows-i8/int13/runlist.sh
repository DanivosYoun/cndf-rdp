#!/usr/bin/env bash
# runlist.sh <listfile> : each line "name engine scenario [ENV=VAL...]" ; one harness at a time.
source ${I8_WORK_ROOT:-~/.cache/int13-8a11de3b}/env.sh; cd $W/hroot
while read -r name engine scen envs; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  avail=$(free -g | awk '/^Mem:/ {print $7}')
  echo "[$(date +%H:%M:%S)] $name $engine $scen $envs avail=${avail}G"
  env $envs timeout 1500 $R run $name $engine $W/scen/$scen.json < /dev/null 2>&1 | tail -1
  python3 $W/tools/count.py $I8_WORK/results $name
done < "$1"
echo "[$(date +%H:%M:%S)] list done"
