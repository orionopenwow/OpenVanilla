# Generates the realm list art in www/assets/realm_ui/v2 (frame, corners, plaque, gems, buttons, divider, runes).
# Usage: python3 tools/gen_realm_ui_v2.py  -> writes PNGs to ./out, then copy them to www/assets/realm_ui/v2/
import numpy as np, math
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage as nd
rng=np.random.default_rng(7)
OUT='out'; import os; os.makedirs(OUT,exist_ok=True)

def lerp_pal(stops, t):
    t=np.clip(t,0,1); xs=[s[0] for s in stops]; cs=np.array([s[1] for s in stops],float)
    return np.stack([np.interp(t,xs,cs[:,i]) for i in range(3)],-1)
GOLD=[(0,(26,15,3)),(0.28,(84,52,14)),(0.5,(150,100,32)),(0.7,(205,156,64)),(0.88,(246,210,128)),(1,(255,246,214))]
BRONZE=[(0,(8,6,4)),(0.35,(30,21,12)),(0.6,(58,41,22)),(0.85,(102,74,40)),(1,(160,124,74))]
IRON=[(0,(10,10,12)),(0.35,(30,30,34)),(0.65,(62,60,62)),(0.9,(110,104,98)),(1,(170,160,150))]

def bevel(mask, w, round_=True):
    dt=nd.distance_transform_edt(mask)
    x=np.clip(dt/w,0,1)
    return np.sqrt(1-(1-x)**2) if round_ else x

def shade(h, pal, strength=6.0, light=(-0.55,-0.75,1.0), spec=0.55, sp=24, base=0.0, noise=0.0, mask=None, gain=0.8):
    gy,gx=np.gradient(h*strength)
    n=np.stack([-gx,-gy,np.ones_like(h)],-1); n/=np.linalg.norm(n,axis=-1,keepdims=True)
    L=np.array(light,float); L/=np.linalg.norm(L)
    d=np.clip((n*L).sum(-1),0,1)
    H=L+np.array([0,0,1.0]); H/=np.linalg.norm(H)
    s=np.clip((n*H).sum(-1),0,1)**sp
    t=base+gain*d
    if noise:
        nz=nd.gaussian_filter(rng.standard_normal(h.shape),(0.6,6))
        t=t+noise*6*nz
    col=lerp_pal(pal,t)+spec*255*s[...,None]
    return np.clip(col,0,255)

def to_img(col, alpha, scale=1):
    a=np.clip(alpha,0,1)*255
    im=Image.fromarray(np.dstack([col,a]).astype(np.uint8),'RGBA')
    if scale!=1: im=im.resize((im.width//scale,im.height//scale),Image.LANCZOS)
    return im

def mask_from(draw_fn, W, H):
    im=Image.new('L',(W,H),0); draw_fn(ImageDraw.Draw(im)); return np.array(im)>127

def spiral_pts(cx,cy,r0,r1,turns,ang0=0,dir=1,n=200):
    pts=[]
    for i in range(n):
        t=i/(n-1); r=r0+(r1-r0)*t; a=ang0+dir*turns*2*math.pi*t
        pts.append((cx+r*math.cos(a),cy+r*math.sin(a)))
    return pts

def thick_line(d,pts,w0,w1=None):
    w1=w0 if w1 is None else w1
    for i in range(len(pts)-1):
        w=w0+(w1-w0)*i/(len(pts)-1)
        d.line([pts[i],pts[i+1]],fill=255,width=max(1,int(w)))
        d.ellipse([pts[i][0]-w/2,pts[i][1]-w/2,pts[i][0]+w/2,pts[i][1]+w/2],fill=255)

def metal(mask, pal, w, **kw):
    h=bevel(mask,w)
    col=shade(h,pal,**kw)
    return col, mask.astype(float)

def comp(layers, W, H):
    out=np.zeros((H,W,3)); A=np.zeros((H,W))
    for col,a in layers:
        out=out*(1-a[...,None])+col*a[...,None]; A=A+a*(1-A)
    return out,A

def shadow(alpha, blur, off=(0,0), op=0.8):
    a=Image.fromarray((alpha*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(blur))
    a=np.roll(np.array(a)/255.0,off,axis=(0,1))*op
    return np.zeros(alpha.shape+(3,)), a

# ---------------- GEMS (3 colours), 192px -> 64px ----------------
def gem(name, c_dark, c_mid, c_light):
    S=4; W=64*S; c=W/2
    yy,xx=np.mgrid[0:W,0:W]; r=np.hypot(xx-c,yy-c)
    bez=(r<W*0.47); hole=(r<W*0.33)
    # bezel gold ring with 8 prongs
    ring=bez&~(r<W*0.30)
    hb=bevel(ring,W*0.07)
    gcol=shade(hb,GOLD,strength=40,spec=0.7,sp=30)
    # gem: faceted dome
    ang=np.arctan2(yy-c,xx-c); fac=np.floor((ang+math.pi)/(2*math.pi)*10)
    rr=np.clip(r/(W*0.33),0,1)
    dome=np.sqrt(np.clip(1-rr**2,0,1))
    facet=dome + 0.08*np.cos((ang+math.pi)*10/ (1)) * rr  # facet ripple
    t=0.25+0.55*(1-rr)+0.12*((fac%2)-0.5)
    pal=[(0,c_dark),(0.5,c_mid),(0.85,c_light),(1,(255,255,255))]
    gc=lerp_pal(pal,t)
    # inner glow + highlights
    hl=np.exp(-(((xx-c+W*0.1)**2+(yy-c+W*0.12)**2)/(2*(W*0.06)**2)))
    hl2=np.exp(-(((xx-c-W*0.09)**2+(yy-c-W*0.1)**2)/(2*(W*0.1)**2)))*0.35
    gc=np.clip(gc+255*hl[...,None]*0.95+np.array(c_light)*hl2[...,None],0,255)
    edge=np.clip((rr-0.85)/0.15,0,1); gc=gc*(1-0.55*edge[...,None])
    col=np.where(hole[...,None],gc,gcol)
    alpha=bez.astype(float)
    # outer glow
    glow=np.exp(-((r-W*0.40)/(W*0.08))**2)*(r>W*0.4)*0.0
    im=to_img(col,alpha,S); im.save(f'{OUT}/gem_{name}.png')
gem('online',(5,60,20),(30,190,80),(150,255,170))
gem('soon',(80,30,0),(230,120,20),(255,210,120))
gem('offline',(70,5,5),(200,40,40),(255,150,140))

# ---------------- CORNER filigree, 400px -> 100px ----------------
def corner():
    S=4; W=100*S
    def dr(d):
        # L bracket along top and left edges
        t=11*S//4*2
        d.rectangle([0,0,W*0.92,t],fill=255); d.rectangle([0,0,t,W*0.92],fill=255)
        d.rectangle([0,0,W*0.36,W*0.36],fill=0)
        d.polygon([(0,0),(W*0.40,0),(0,W*0.40)],fill=255)
        # big scroll from corner
        thick_line(d,spiral_pts(W*0.31,W*0.31,W*0.17,W*0.02,1.05,ang0=math.pi*1.25,dir=1),S*6.5,S*2.5)
        thick_line(d,spiral_pts(W*0.60,W*0.13,W*0.09,W*0.015,0.9,ang0=math.pi*0.9,dir=-1),S*4.5,S*2)
        thick_line(d,spiral_pts(W*0.13,W*0.60,W*0.09,W*0.015,0.9,ang0=math.pi*1.6,dir=1),S*4.5,S*2)
        # leaf tips
        d.polygon([(W*0.86,t),(W*0.98,t*0.5),(W*0.86,0)],fill=255)
        d.polygon([(t,W*0.86),(t*0.5,W*0.98),(0,W*0.86)],fill=255)
    m=mask_from(dr,W,W)
    h=bevel(m,S*3.2)
    col=shade(h,GOLD,strength=7,spec=0.6,sp=26,noise=0.02)
    # gem in the corner
    yy,xx=np.mgrid[0:W,0:W]; cx=cy=W*0.155; r=np.hypot(xx-cx,yy-cy)
    g=r<W*0.075
    t=0.3+0.6*(1-r/(W*0.075))
    gc=lerp_pal([(0,(20,40,90)),(0.6,(60,130,230)),(1,(210,240,255))],t)
    hl=np.exp(-(((xx-cx+W*0.025)**2+(yy-cy+W*0.025)**2)/(2*(W*0.015)**2)))
    gc=np.clip(gc+255*hl[...,None],0,255)
    col=np.where(g[...,None],gc,col)
    a=m.astype(float)
    sh=shadow(a,S*3,(S*2,S*2),0.85)
    c,A=comp([sh,(col,a)],W,W)
    to_img(c,A,S).save(f'{OUT}/corner.png')
corner()

# ---------------- FRAME 9-slice: bronze bevel border with gold inner line, 96px (slice 24) ----------------
def frame():
    S=4; W=96*S; b=24*S
    yy,xx=np.mgrid[0:W,0:W]
    outer=np.ones((W,W),bool)
    inner=(xx>=b)&(xx<W-b)&(yy>=b)&(yy<W-b)
    ring=outer&~inner
    h=bevel(ring,S*7)
    # gold lip inside
    lip=ring&~((xx>=b-S*4)&(xx<W-b+S*4)&(yy>=b-S*4)&(yy<W-b+S*4))==False
    lip=ring&((xx>=b-S*5)&(xx<W-b+S*5)&(yy>=b-S*5)&(yy<W-b+S*5))
    outerlip=ring&~((xx>=S*4)&(xx<W-S*4)&(yy>=S*4)&(yy<W-S*4))
    col=shade(h,BRONZE,strength=6,spec=0.3,sp=18,noise=0.02,gain=1.0)
    hl=bevel(lip,S*2); gl=shade(hl,GOLD,strength=12,spec=0.6)
    col=np.where(lip[...,None],gl,col)
    ho=bevel(outerlip,S*1.5); go=shade(ho,GOLD,strength=12,spec=0.5,base=0.05)
    col=np.where(outerlip[...,None],go*0.85,col)
    a=ring.astype(float)
    to_img(col,a,S).save(f'{OUT}/frame.png')
frame()

# ---------------- PLAQUE 600x120 ----------------
def plaque():
    S=3; W=600*S; H=120*S; cx=W/2
    def outline(d,inset,fill):
        p=12*S+inset; y0=26*S+inset; y1=H-26*S-inset; tip=W*0.12
        pts=[(tip+inset,y0),(W-tip-inset,y0),(W-p-inset*0.4,H/2),(W-tip-inset,y1),(tip+inset,y1),(p+inset*0.4,H/2)]
        d.polygon(pts,fill=fill)
    def dr(d):
        outline(d,0,255)
        # top crest
        d.polygon([(cx-60*S,26*S),(cx,6*S),(cx+60*S,26*S)],fill=255)
        d.polygon([(cx-60*S,H-26*S),(cx,H-8*S),(cx+60*S,H-26*S)],fill=255)
        # wing scrolls
        for sgn in (-1,1):
            x=cx+sgn*(W/2-6*S)
            xs=cx+sgn*(W*0.455)
            thick_line(d,spiral_pts(xs,H*0.28,20*S,3*S,1.1,ang0=math.pi*(1.0 if sgn>0 else 0.0),dir=-sgn),S*6,S*2.5)
            thick_line(d,spiral_pts(xs,H*0.72,20*S,3*S,1.1,ang0=math.pi*(1.0 if sgn>0 else 0.0),dir=sgn),S*6,S*2.5)
    m=mask_from(dr,W,H)
    inner=mask_from(lambda d: outline(d,9*S,255),W,H)
    rim=m&~inner
    h=bevel(rim,S*5)
    col=shade(h,GOLD,strength=7,spec=0.6,sp=28,noise=0.012)
    # inner engraved line
    inner2=mask_from(lambda d: outline(d,13*S,255),W,H)
    groove=inner&~inner2
    yy,xx=np.mgrid[0:H,0:W]
    # center panel navy/black gradient with vignette
    t=0.15+0.35*np.exp(-((yy-H*0.42)/(H*0.25))**2)*np.exp(-((xx-cx)/(W*0.32))**2)
    pc=lerp_pal([(0,(6,8,16)),(0.5,(22,28,52)),(1,(60,70,110))],t)
    col=np.where(inner[...,None],pc,col)
    gg=shade(bevel(groove,S*1.2),GOLD,strength=10,spec=0.3,base=0.0)*0.75
    col=np.where(groove[...,None],gg,col)
    a=m.astype(float)
    sh=shadow(a,S*5,(S*4,0),0.9)
    c,A=comp([sh,(col,a)],W,H)
    to_img(c,A,S).save(f'{OUT}/plaque.png')
plaque()

# ---------------- BUTTONS 9-slice 360x96 (slice 48) ----------------
def button(name, center_pal, rim_pal, rim_w):
    S=3; W=360*S; H=96*S
    def shape(d,inset):
        r=10*S
        d.rounded_rectangle([6*S+inset,8*S+inset,W-6*S-inset,H-8*S-inset],radius=max(2,r-inset*0.6),fill=255)
    def outer(d):
        shape(d,0)
        # end points / flourishes
        for sgn in (-1,1):
            x0=W/2+sgn*(W/2-6*S)
            d.polygon([(x0,H*0.30),(x0+sgn*5*S,H/2),(x0,H*0.70)],fill=255)
    m=mask_from(outer,W,H)
    inner=mask_from(lambda d: shape(d,rim_w*S),W,H)
    rim=m&~inner
    col=shade(bevel(rim,S*4),rim_pal,strength=6,spec=0.6,sp=26,noise=0.015)
    yy,xx=np.mgrid[0:H,0:W]
    hin=bevel(inner,S*10,round_=True)
    tex=nd.gaussian_filter(rng.standard_normal((H,W)),S*1.2)*0.6
    ic=shade(hin+tex*0.05,center_pal,strength=3,spec=0.08,sp=10,base=0.0,gain=0.55,light=(-0.2,-1,1.2))
    glow=np.exp(-(((xx-W/2)/(W*0.32))**2+((yy-H*0.55)/(H*0.30))**2))
    ic=np.clip(ic+np.array(center_pal[-1][1])[None,None,:]*glow[...,None]*0.35,0,255)
    # top gloss
    gloss=np.clip(1-(yy-12*S)/(H*0.30),0,1)**2*0.10
    ic=np.clip(ic+255*gloss[...,None],0,255)
    col=np.where(inner[...,None],ic,col)
    a=m.astype(float)
    sh=shadow(a,S*4,(S*3,0),0.85)
    c,A=comp([sh,(col,a)],W,H)
    to_img(c,A,S).save(f'{OUT}/btn_{name}.png')
RED=[(0,(14,3,3)),(0.4,(48,12,11)),(0.75,(92,26,22)),(1,(160,70,60))]
AMBER=[(0,(14,9,3)),(0.4,(40,26,8)),(0.75,(82,54,16)),(1,(150,104,44))]
button('cancel',RED,BRONZE,5)
button('enter',AMBER,GOLD,7)

# ---------------- DIVIDER gem 160x48 ----------------
def divider():
    S=4; W=160*S; H=48*S; cx,cy=W/2,H/2
    def dr(d):
        d.polygon([(cx-30*S,cy),(cx,cy-16*S),(cx+30*S,cy),(cx,cy+16*S)],fill=255)
        d.rectangle([0,cy-1.6*S,W,cy+1.6*S],fill=255)
        for sgn in (-1,1):
            d.polygon([(cx+sgn*30*S,cy),(cx+sgn*46*S,cy-6*S),(cx+sgn*62*S,cy),(cx+sgn*46*S,cy+6*S)],fill=255)
    m=mask_from(dr,W,H)
    col=shade(bevel(m,S*3),GOLD,strength=8,spec=0.6,sp=26)
    yy,xx=np.mgrid[0:H,0:W]
    g=(np.abs(xx-cx)/(20*S)+np.abs(yy-cy)/(10*S))<1
    t=0.35+0.6*(1-(np.abs(xx-cx)/(20*S)+np.abs(yy-cy)/(10*S)))
    gc=lerp_pal([(0,(10,25,60)),(0.6,(70,140,230)),(1,(220,245,255))],t)
    col=np.where(g[...,None],gc,col)
    # fade line ends
    fade=np.clip(1-np.abs(xx-cx)/(W/2),0,1)**0.6
    a=m.astype(float)*np.where(np.abs(xx-cx)>62*S,fade,1)
    to_img(col,a,S).save(f'{OUT}/divider.png')
divider()

# ---------------- RUNE strip 480x40 (tile) ----------------
def runes():
    S=4; W=480*S; H=40*S
    R={'F':[[(0,0),(0,1)],[(0,.15),(.5,0)],[(0,.4),(.5,.25)]],'U':[[(0,1),(0,0),(.5,.3),(.5,1)]],'TH':[[(0,0),(0,1)],[(0,.25),(.4,.5),(0,.75)]],
       'R':[[(0,1),(0,0),(.45,.22),(0,.45),(.5,1)]],'K':[[(.4,0),(0,.5),(.4,1)]],'G':[[(0,0),(.5,1)],[(.5,0),(0,1)]],'W':[[(0,1),(0,0),(.45,.22),(0,.45)]],
       'H':[[(0,0),(0,1)],[(.5,0),(.5,1)],[(0,.3),(.5,.55)]],'N':[[(.25,0),(.25,1)],[(0,.35),(.5,.6)]],'I':[[(.25,0),(.25,1)]],'J':[[(.1,.2),(.3,.5),(.1,.8)],[(.4,.2),(.2,.5),(.4,.8)]],
       'P':[[(0,1),(0,0),(.3,.2)],[(0,1),(.3,.8)],[(0,0),(.4,.15)]],'Z':[[(.25,0),(.25,1)],[(0,.3),(.25,0),(.5,.3)]],'S':[[(.4,0),(.1,.45),(.4,.55),(.1,1)]],
       'T':[[(.25,0),(.25,1)],[(0,.3),(.25,0),(.5,.3)]],'B':[[(0,0),(0,1)],[(0,0),(.4,.25),(0,.5),(.4,.75),(0,1)]],'E':[[(0,1),(0,0),(.25,.3),(.5,0),(.5,1)]],
       'M':[[(0,1),(0,0),(.5,.6)],[(.5,1),(.5,0),(0,.6)]],'L':[[(0,0),(0,1)],[(0,0),(.4,.25)]],'O':[[(0,1),(.4,.5),(.1,.2),(.25,0),(.4,.2),(.1,.5),(.5,1)]]}
    seq='F U TH R K G W H N I J P Z S T B E M L O'.split()
    im=Image.new('L',(W,H),0); d=ImageDraw.Draw(im)
    x=10*S; h=24*S; y0=(H-h)/2; step=W/len(seq)
    for i,k in enumerate(seq):
        ox=i*step+step*0.32
        for line in R[k]:
            pts=[(ox+p[0]*h*0.75,y0+p[1]*h) for p in line]
            d.line(pts,fill=255,width=int(2.2*S),joint='curve')
    m=np.array(im)>127
    h2=bevel(m,S*1.2)
    col=shade(h2,GOLD,strength=8,spec=0.3,base=0.05)
    blur=nd.gaussian_filter(m.astype(float),S*3)
    a=np.clip(m*0.55+blur*0.5,0,1)
    gl=lerp_pal(GOLD,0.6)
    col=np.where(m[...,None],col,gl)
    to_img(col,a,S).save(f'{OUT}/runes.png')
runes()

