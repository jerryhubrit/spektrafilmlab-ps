"""Exercise real Metal through the local protocol using synthetic pixels only."""
import array, json, struct, time, urllib.request, urllib.error
from pathlib import Path
import os

root = Path(__file__).resolve().parents[1]
config=json.loads(Path(os.environ.get('FILMLAB_CONFIG',root/'plugin/config.json')).read_text())
token=config['token']
base_url='http://127.0.0.1:'+str(config.get('port',49321))
def call(path, data=None, auth=True):
    headers = {'Authorization': 'Bearer '+token} if auth else {}
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        headers['Content-Type'] = 'application/json'
    return urllib.request.urlopen(urllib.request.Request(base_url+path, data=data, headers=headers),timeout=120)
def expect_error(path, data=None, auth=True, status=400):
    try: call(path,data,auth); raise AssertionError('request should fail')
    except urllib.error.HTTPError as e: assert e.code==status,(e.code,e.read())

expect_error('/health',auth=False,status=401)
health=json.load(call('/health'))
assert health['engine']=='native-metal'
assert any(s['id']=='kodak_portra_400' for s in health['catalog'])
w,h=128,96
pixels=array.array('H')
for y in range(h):
    for x in range(w): pixels.extend([int(x/(w-1)*65535),int(y/(h-1)*65535),24000,0 if x<8 else (32768 if x<16 else 65535)])
data=pixels.tobytes()
path='/source?width=%d&height=%d&channels=4&kind='%(w,h)
expect_error(path+'full',b'bad')
settings={'film_stock':'kodak_portra_400','print_stock':'kodak_portra_endura','grain_active':False,'halation_active':False,'print_exposure':1.0}
def render(kind,settings):
    source=json.load(call(path+kind,data))
    response=call('/render',{'sourceId':source['sourceId'],'params':settings})
    return response.read(),dict(response.headers),source['sourceId']
a,head,old=render('full',settings)
assert len(a)==w*h*8
assert head['X-Pixel-Format']=='rgba16le'
assert head['X-Color-Space']=='ProPhoto RGB'
assert head['X-Transfer-Function']=='romm-rgb'
assert head['X-Row-Order']=='top-down'
decoded=array.array('H');decoded.frombytes(a)
assert decoded[3::4]==pixels[3::4], 'Alpha must survive unchanged'
assert decoded[0::4]!=pixels[0::4], 'Must execute the film pipeline'
b,_,_=render('full',settings)
assert a==b,'Fresh deterministic renders must agree'
expect_error('/render',{'sourceId':old,'params':settings})
png,_,sid=render('preview',settings)
assert png.startswith(b'\x89PNG\r\n\x1a\n')
assert struct.unpack('>II',png[16:24])==(w,h)
changed=dict(settings,print_exposure=1.2)
r=call('/render',{'sourceId':sid,'params':changed}); cached=r.read(); cached_header=dict(r.headers)
fresh,_,_=render('preview',changed)
assert cached==fresh,'Cached print edit must equal fresh result'
assert cached!=png,'Print control must affect the output'
result={'tests':'auth, input validation, native render, alpha, deterministic parity, stale source rejection, PNG dimensions, cached/fresh parity','status':'passed','size':[w,h],'native_render_ms':head.get('X-Render-Ms'),'cached_negative':cached_header.get('X-Negative-Cached'),'catalog_entries':len(health['catalog'])}
(root/'build/native-smoke.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
