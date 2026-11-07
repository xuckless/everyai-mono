#!/bin/bash
set -u
H=/helpers/everyai_x11.py
Xvfb :7 -screen 0 1024x768x24 -nolisten tcp >/dev/null 2>&1 &
sleep 1; export DISPLAY=:7
python3 /work/app.py & APP=$!
sleep 2
echo "--- windows"; python3 $H windows; echo
echo "--- windows --pid $APP"; python3 $H windows --pid $APP; echo
WID=$(python3 $H windows --pid $APP | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['id'])")
echo "--- tree"; python3 $H tree --pid $APP; echo
echo "--- shot"; python3 $H shot --window $WID --out /work/shot1.png --nested; echo
echo "--- click button (window 40,40 + ~200,25)"; python3 $H click --pid $APP --x 240 --y 62 --front --nested; echo; sleep 0.5
echo "--- click entry, type"; python3 $H click --pid $APP --x 240 --y 98 --front --nested; sleep 0.3
python3 $H key --pid $APP --text 'Hello Wörld €' --front --nested; python3 $H key --pid $APP --keyname enter --front --nested; echo; sleep 0.5
echo "--- select all + retype"; python3 $H key --pid $APP --keyname a --mods ctrl --front --nested; sleep 0.2
echo "--- scroll list"; python3 $H scroll --pid $APP --x 240 --y 160 --dy 200 --front --nested; echo; sleep 0.3
python3 $H click --pid $APP --x 240 --y 140 --front --nested; sleep 0.5
echo "--- guard (no --nested, point outside)"; python3 $H click --pid $APP --x 900 --y 700 --front; echo "exit $?"
echo "--- stream one frame"; timeout 3 python3 $H stream --window $WID --fps 4 --nested | head -c 200 | head -3
python3 $H shot --window $WID --out /work/shot2.png --nested >/dev/null
echo "--- events"; cat /work/events.txt
