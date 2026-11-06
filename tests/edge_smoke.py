"""Native film edge/date integration with synthetic pixels only."""
import array, json, struct, urllib.request, urllib.error
from pathlib import Path
import os
root=Path(__file__).resolve().parents[1]
config=json.loads(Path(os.environ.get('FILMLAB_CONFIG',root/'plugin/config.json')).read_text())
token=config['token']
base_url='http://127.0.0.1:'+str(config.get('port',49321))
def call(route,body):
    if isinstance(body,dict):body=json.dumps(body).encode()
    try:return urllib.request.urlopen(urllib.request.Request(base_url+route,data=body,headers={'Authorization':'Bearer '+token}),timeout=120)
    except urllib.error.HTTPError as e:raise RuntimeError(e.read().decode()) from None
w,h=900,600
pixels=array.array('H')
for y in range(h):
    for x in range(w):pixels.extend([int((.04+.65*x/(w-1))*65535),int((.04+.6*y/(h-1))*65535),20000])
base={'film_stock':'kodak_portra_400','print_stock':'kodak_portra_endura','grain_active':False,'halation_active':True,'auto_exposure':False}
edge=dict(overscan_active=True,overscan_format='135',overscan_mode='strip',overscan_holes='white',overscan_camera_seed=17,overscan_frame_seed=23,overscan_frame_number=12,overscan_edge_text='KODAK PORTRA 400',overscan_fog=1,overscan_leaks=0)
def render(params,kind='preview'):
    s=json.load(call(f'/source?width={w}&height={h}&channels=3&kind={kind}',pixels.tobytes()))
    r=call('/render',{'sourceId':s['sourceId'],'params':dict(base,**params)})
    return r.read(),dict(r.headers)
plain,_=render({})
off,_=render({'overscan_active':False,'date_imprint_active':False})
assert plain==off,'Off must leave pixels unchanged'
a,head=render(edge)
size=struct.unpack('>II',a[16:24]);assert size[0]>w and size[1]>h,(size,w,h)
assert size==(int(head['X-Width']),int(head['X-Height']))
b,_=render(edge);assert a==b,'Fixed seeds must be repeatable'
black,_=render(dict(edge,overscan_holes='black'));assert black!=a,'Perforation backing must affect pixels'
date=dict(date_imprint_active=True,date_imprint_text="'26 11 6",date_imprint_style='lcd',date_imprint_placement='frame',date_imprint_corner='br',date_imprint_size=1,date_imprint_ev=3.5)
c,_=render(dict(edge,**date));assert c!=a,'Date must visibly alter the render'
d,_=render(date);assert d!=plain;assert struct.unpack('>II',d[16:24])==(w,h)
full,fullhead=render(dict(edge,**date),'full');assert len(full)==int(fullhead['X-Width'])*int(fullhead['X-Height'])*8
out=root/'build';(out/'synthetic-film-edge.png').write_bytes(c)
report={'status':'passed','input':[w,h],'output':list(size),'checks':['off-path exact parity','expanded geometry','seed repeatability','perforation backing','date with and without film','full 16-bit dimensions']}
(out/'edge-smoke.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
