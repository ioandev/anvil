# jq helpers: UK local time without tzdata (BST = last Sunday of March 01:00 UTC .. last Sunday of October 01:00 UTC).
def _lastsun($y; $m): ([$y, $m, 31, 1, 0, 0, 0, 0] | mktime) as $d | $d - (($d | gmtime | .[6]) * 86400);
def uk_offset: . as $t | ($t | gmtime | .[0]) as $y
  | if $t >= _lastsun($y; 2) and $t < _lastsun($y; 9) then 3600 else 0 end;
def uk_local: . + (. | uk_offset);
# Post-mortem day: the UK date, minus one day before 08:00 local
def pm_date: (uk_local) as $l | (if ($l | gmtime | .[3]) < 8 then $l - 86400 else $l end) | strftime("%Y-%m-%d");
def uk_hhmm: uk_local | strftime("%H:%M");
