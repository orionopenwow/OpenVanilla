# Cuts the painted realm-list asset sheet into www/assets/realm_ui/v3 pieces.
# Usage: put the sheet at src.png (1021x575 layout), run: python3 cut_realm_ui_sheet.py, then python3 -c the finish step below.
# Step 1: crop + colour-to-alpha (only white connected to the crop edge is removed).
import numpy as np
from PIL import Image
from scipy import ndimage as nd
src=np.array(Image.open('src.png').convert('RGB')).astype(float)
WHITE=252.0; T=95.0
def c2a(region, glow=True):
    c=region.copy()
    d=np.clip(WHITE-c,0,None).max(-1)
    a=np.clip(d/T,0,1)
    # remove faint paper noise
    a[a<0.06]=0
    safe=np.maximum(a,1e-3)[...,None]
    col=(c-WHITE*(1-a[...,None]))/safe
    col=np.clip(col,0,255)
    return col,a
def cut(name,box,keep_largest=False,pad=2,scale=1.0):
    x0,y0,x1,y1=box
    reg=src[y0:y1,x0:x1]
    col,a=c2a(reg)
    # only light pixels connected to the crop edge are background; interior lights (text, highlights) stay solid
    light=np.clip(WHITE-reg,0,None).max(-1)<T
    lab,n=nd.label(light)
    edge=set(np.unique(np.concatenate([lab[0],lab[-1],lab[:,0],lab[:,-1]])))-{0}
    bgreg=np.isin(lab,list(edge))
    band=nd.binary_dilation(bgreg,iterations=2)
    a=np.where(band,a,1.0); col=np.where(band[...,None],col,reg)
    np.save(f'band_{name}.npy',band)
    if keep_largest:
        lab,n=nd.label(a>0.35)
        if n>1:
            sizes=nd.sum(np.ones_like(a),lab,range(1,n+1)); big=np.argmax(sizes)+1
            keep=nd.binary_dilation(lab==big,iterations=6)
            a=a*keep
    im=Image.fromarray(np.dstack([col,a*255]).astype(np.uint8),'RGBA')
    bb=im.getbbox(); im=im.crop(bb)
    if scale!=1.0: im=im.resize((round(im.width*scale),round(im.height*scale)),Image.LANCZOS)
    im.save(f'p_{name}.png'); return im
parts={
 'corner_tl':((0,0,180,202),True),
 'corner_tr':((828,0,1021,207),True),
 'plaque':((284,14,734,144),True),
 'btn_enter':((266,172,512,263),True),
 'btn_cancel':((521,177,747,259),True),
 'gem_online':((758,170,851,264),False),
 'gem_soon':((858,170,950,264),False),
 'row_active':((44,295,508,396),True),
 'div_gold':((519,296,968,334),True),
 'div_gem':((519,348,968,396),True),
 'div_steel':((519,421,968,461),True),
 'div_dark':((51,419,503,469),True),
 'bar_dark':((51,492,503,518),True),
 'edge_v':((0,300,22,440),False),
 'edge_h':((150,552,480,575),False),
}
ims={k:cut(k,b,kl) for k,(b,kl) in parts.items()}
# preview on dark
W=1000; H=sum(i.height+16 for i in ims.values())+16
bg=Image.new('RGBA',(W,H),(18,14,12,255)); y=16
for k,i in ims.items():
    bg.alpha_composite(i,(16,y)); y+=i.height+16
bg.save('preview.png'); print({k:i.size for k,i in ims.items()})

# ---- Step 2: de-halo, darken the selected-row bar, build the frame, export WebP to ./v3 ----
import numpy as np
from PIL import Image
import os
os.makedirs('v3',exist_ok=True)
def load(n): return np.array(Image.open(f'p_{n}.png').convert('RGBA')).astype(float)
def dehalo(a, keep_colour=False, th=0.65):
    rgb=a[...,:3]; al=a[...,3]/255
    if not keep_colour:
        k=np.clip(al/th,0,1)[...,None]
        # low-alpha fringe -> dark shadow
        rgb=rgb*k + np.array([10,7,4])*(1-k)
        mx=rgb.max(-1); mn=rgb.min(-1); sat=(mx-mn)/np.maximum(mx,1); lum=rgb.mean(-1)
        from scipy import ndimage as nd
        solid=al>0.995
        fringe=(sat<0.22)&(lum>95)&~solid
        rgb=np.where(fringe[...,None], rgb*0.18, rgb)
        al=np.where(fringe, al*0.7, al); a[...,3]=al*255
    a[...,:3]=rgb; return a
def save(n,a,scale=1.0,name=None):
    im=Image.fromarray(np.clip(a,0,255).astype(np.uint8),'RGBA')
    if scale!=1: im=im.resize((round(im.width*scale),round(im.height*scale)),Image.LANCZOS)
    im.save(f'v3/{name or n}.webp','WEBP',quality=92,method=6); return im.size
out={}
for n in ['corner_tl','corner_tr','plaque','btn_enter','btn_cancel','div_gold','div_gem','div_steel','div_dark','bar_dark']:
    out[n]=save(n,dehalo(load(n)))
for n in ['gem_online','gem_soon']:
    out[n]=save(n,dehalo(load(n),keep_colour=True))
# offline gem: recolour soon gem to red
g=load('gem_soon'); rgb=g[...,:3]; lum=rgb.mean(-1,keepdims=True)
warm=(rgb[...,0:1]-rgb[...,2:3])>40
red=np.concatenate([np.clip(rgb[...,0:1]*1.05,0,255),rgb[...,1:2]*0.35,rgb[...,2:3]*0.35],-1)
rgb=np.where(warm & (lum<230), red, rgb)
g[...,:3]=rgb; out['gem_offline']=save('x',dehalo(g,True),name='gem_offline')
# active row: darken interior
r=dehalo(load('row_active'),keep_colour=True); H,W=r.shape[:2]
yy,xx=np.mgrid[0:H,0:W]
ins=(xx>18)&(xx<W-18)&(yy>16)&(yy<H-16)
from scipy import ndimage as nd
m=nd.gaussian_filter(ins.astype(float),3)
r[...,:3]=r[...,:3]*(1-0.5*m[...,None])
out['row_active']=save('row_active',r)
# frame 9-slice from strips
ev=Image.open('p_edge_v.png').convert('RGBA'); eh=Image.open('p_edge_h.png').convert('RGBA')
S=96; B=20
fr=Image.new('RGBA',(S,S),(0,0,0,0))
L=ev.resize((B,S)); fr.alpha_composite(L,(0,0)); fr.alpha_composite(L.transpose(Image.FLIP_LEFT_RIGHT),(S-B,0))
Hh=eh.resize((S,B)); fr.alpha_composite(Hh,(0,S-B)); fr.alpha_composite(Hh.transpose(Image.FLIP_TOP_BOTTOM),(0,0))
fr.save('v3/frame.webp','WEBP',quality=92); out['frame']=fr.size
print(out)
# preview
ims=[Image.open('v3/'+f) for f in sorted(os.listdir('v3'))]
Hh=sum(i.height+12 for i in ims)+12; bg=Image.new('RGBA',(520,Hh),(18,14,12,255)); y=12
for i in ims: bg.alpha_composite(i.convert('RGBA'),(12,y)); y+=i.height+12
bg.save('preview2.png')
