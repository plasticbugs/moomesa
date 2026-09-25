import struct, math, sys
def rd(p):
    d=open(p,'rb').read(); i=12
    while i+8<=len(d):
        cid=d[i:i+4]; n=struct.unpack('<I',d[i+4:i+8])[0]; body=d[i+8:i+8+n]
        if cid==b'data':
            s=struct.unpack('<%dh'%(len(body)//2), body[:len(body)//2*2]); return s[0::2], s[1::2]
        i+=8+n+(n&1)
def bands(x):
    # one-pole splits at ~300 Hz and ~2.5 kHz (48 kHz)
    a1=1-math.exp(-2*math.pi*300/48000); a2=1-math.exp(-2*math.pi*2500/48000)
    l1=l2=0.0; e=[0.0,0.0,0.0]
    for v in x:
        l1+=a1*(v-l1); l2+=a2*(v-l2)
        e[0]+=l1*l1; e[1]+=(l2-l1)**2; e[2]+=(v-l2)**2
    n=max(len(x),1); return [math.sqrt(t/n) for t in e]
(ml,mr),(cl,cr)=rd(sys.argv[1]),rd(sys.argv[2])
secs=int(min(len(ml),len(cl))/48000)
print(' s   MAME L/R rms      core L/R rms    | low/mid/high  MAME L          core L')
logs=[]
for s in range(secs):
    a,b=s*48000,(s+1)*48000
    mr_=[math.sqrt(sum(v*v for v in x[a:b])/48000) for x in (ml,mr)]
    cr_=[math.sqrt(sum(v*v for v in x[a:b])/48000) for x in (cl,cr)]
    bm=bands(ml[a:b]); bc=bands(cl[a:b])
    print('%2d  %6.0f %6.0f   %6.0f %6.0f   | %5.0f %5.0f %5.0f   %5.0f %5.0f %5.0f'%(s,*mr_,*cr_,*bm,*bc))
    if mr_[0]>50 and cr_[0]>50: logs.append(abs(math.log(cr_[0]/mr_[0])))
print('seconds with sound in both:',len(logs),' mean |log(core/MAME)| rms =', round(sum(logs)/max(len(logs),1),3))
