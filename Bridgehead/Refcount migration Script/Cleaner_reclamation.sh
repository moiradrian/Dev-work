#!/bin/bash
ctrlrpc -p 9911 show.cleaner_status | awk '
/^Resource Group[[:space:]]*:/ {
  grp = $4                       # e.g., LOCAL or CLOUD
  if (!(grp in seen)) { order[++n] = grp; seen[grp]=1 }
  next
}
$13 != 0 && grp != "" {          # use column 13; skip zeros
  total[grp] += $13
  grand += $13
}
END {
  for (i=1; i<=n; i++) {
    g = order[i]
    printf "%s total reclaimed: %d\n", g, total[g]
  }
  printf "GRAND total reclaimed: %d\n", grand
}
' | numfmt --field=4 --to=iec