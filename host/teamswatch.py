#!/usr/bin/env python3
"""Sample the Teams status badge; print GREEN/YELLOW/RED/OTHER. Needs window id as argv[1]."""
import warnings; warnings.simplefilter('ignore')
import subprocess, sys, colorsys
from PIL import Image
wid = sys.argv[1]
subprocess.run(["screencapture","-x","-l"+wid,"/tmp/teams.png"],check=True)
im = Image.open("/tmp/teams.png").convert("RGB"); k = im.size[0]/1022
W=im.size[0]; box = (W-80,86,W-54,114); im.crop(box).save("/tmp/teams_badge.png")
cnt = {}
for p in im.crop(box).getdata():
    h,s,v = colorsys.rgb_to_hsv(*[c/255 for c in p])
    if s>0.25 and v>0.4:
        n = "YELLOW" if 0.08<h<0.2 else "GREEN" if 0.25<h<0.45 else "RED" if (h<0.05 or h>0.93) else "OTHER"
        cnt[n]=cnt.get(n,0)+1
print(max(cnt,key=cnt.get) if cnt else "NONE", cnt)
