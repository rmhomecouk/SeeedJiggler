import os, pty, sys, time, select, tty, termios
m, s = pty.openpty()
tty.setraw(s)
print(os.ttyname(s), flush=True)
hb = mv = 0; buf = b""; log = []
end = time.time() + float(sys.argv[1])
t0 = time.time()
while time.time() < end:
    r,_,_ = select.select([m],[],[],0.2)
    if not r: continue
    buf += os.read(m, 256)
    while b"\n" in buf:
        line, buf = buf.split(b"\n",1); line=line.decode().strip()
        if line == "?": os.write(m, f"SEEEDJIGGLER 2 app=1 age=0 hb={hb} mv={mv}\r\n".encode()); log.append((round(time.time()-t0,1),"?"))
        elif line == "H": hb += 1; log.append((round(time.time()-t0,1),"H"))
        elif line.startswith("M"): mv += 1; os.write(m, b"OK\r\n"); log.append((round(time.time()-t0,1),line))
print("hb",hb,"mv",mv, flush=True)
print(log, flush=True)
