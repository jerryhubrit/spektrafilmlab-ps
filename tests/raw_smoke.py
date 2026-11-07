"""Local RAW acceptance. Never writes input path, EXIF, pixels or previews.
Usage: python3 tests/raw_smoke.py /absolute/path/to/raw [--full]
Replaces active helper source; run before opening the workbench for editing.
"""
import json, sys, time, hashlib, urllib.request, urllib.error
from pathlib import Path
import os
root=Path(__file__).resolve().parents[1]
config=json.loads(Path(os.environ.get('FILMLAB_CONFIG',root/'plugin/config.json')).read_text())
token=config['token']
base_url='http://127.0.0.1:'+str(config.get('port',49321))
def call(path,body):
    try:
        return urllib.request.urlopen(urllib.request.Request(base_url+path,data=json.dumps(body).encode(),headers={'Authorization':'Bearer '+token}),timeout=300)
    except urllib.error.HTTPError as e: raise RuntimeError(e.read().decode()) from None
s=json.load(call('/raw/open',{'path':sys.argv[1]}))
params={'film_stock':'kodak_portra_400','print_stock':'kodak_portra_endura','grain_active':False,'halation_active':True,'halation_amount':1,'halation_scatter_amount':1,'dir_couplers_active':True,'dir_couplers_amount':1,'auto_exposure':True,'auto_exposure_method':'balanced','scene_latitude_active':False}
base={'sourceId':s['sourceId'],'params':params}
def preview(decode): return json.load(call('/raw/render',dict(base,decode=decode)))
a=preview({}); b=preview({})
assert a['image']==b['image'],'Cached and initial RAW outputs must agree'
assert max(a['width'],a['height'])==min(1024,max(s['width'],s['height']))
c=preview({'temperature':6200,'tint':25})
assert c['image']!=a['image'],'RAW WB must alter output'
assert c['original']!=a['original'],'Original comparison must share adjusted WB'
d=preview({})
assert d['image']==a['image'],'As-shot must restore pristine filter transform'
if s['lensSupported']:
    e=preview({'lensCorrection':True}); f=preview({})
    assert f['image']==a['image'],'Lens reset must restore initial output'
latitude=json.load(call('/raw/latitude',{'sourceId':s['sourceId'],'placement':{}}))
print('latitude keys',list(latitude), 'fit keys',list(latitude.get('fit',{})),flush=True)
fit=latitude['fit']
assert isinstance(fit['valid'],bool)
if fit['valid']:
    assert 'params_delta' in fit
    fitparams=dict(params,**fit['params_delta'])
    fitted=json.load(call('/raw/render',dict(base,params=fitparams,decode={})))
    assert fitted['image'].startswith('data:image/png;base64,')
else:
    # Some scenes cannot fit the chosen medium. The native contract refuses
    # those fits; treating every scene as fit-able was a test assumption.
    assert fit['issues'] and 'params_delta' not in fit
    assert preview({})['image']==a['image'],'Refused fit must not alter the negative'
report={'status':'passed','size':[s['width'],s['height']], 'preview_ms':a['ms'],'cached_ms':b['ms'],'white_balance_ms':c['ms'],'as_shot_reset_ms':d['ms'],'lens_supported':s['lensSupported'],'latitude_fit_valid':fit['valid'],'latitude_issues':[issue['code'] for issue in fit.get('issues',[])],'checks':['RAW decoding','preview geometry','cached parity','white balance effect','comparison WB','exact as-shot restore','lens restore' if s['lensSupported'] else 'unsupported lens correction reported','native scene latitude result or safe refusal']}
if '--full' in sys.argv:
    start=time.monotonic();r=call('/raw/render',dict(base,decode={},full=True))
    assert r.headers['X-Pixel-Format']=='rgba16le'
    assert r.headers['X-Color-Space']=='ProPhoto RGB'
    assert r.headers['X-Transfer-Function']=='romm-rgb'
    assert r.headers['X-Row-Order']=='top-down'
    w,h=int(r.headers['X-Width']),int(r.headers['X-Height']); total=0
    while True:
        block=r.read(1024*1024)
        if not block:break
        total+=len(block)
    assert (w,h)==(s['width'],s['height'])
    assert total==w*h*8
    report.update(full_seconds=round(time.monotonic()-start,2),full_bytes=total)
(root/'build/raw-smoke.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
