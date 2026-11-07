// Host-independent state tests; these do not replace real Photoshop acceptance.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function panel() {
  const elements = new Map();
  const el = id => {
    if (!elements.has(id)) elements.set(id, {value: '0', textContent: '', disabled: false,
      style: {}, addEventListener() {}, appendChild() {}});
    return elements.get(id);
  };
  const doc = {id: 1, mode: 'RGB', bitsPerChannel: 8, width: 100, height: 80, activeHistoryState: {id: 10}};
  let failComparison = false;
  let renders = 0;
  let modal = false, requireModal = false, nativeDepthOnly = false;
  let rawFile=null, rawFailure=false, putFailure=false;
  let outputContract={'X-Pixel-Format':'rgba16le','X-Color-Space':'ProPhoto RGB','X-Transfer-Function':'romm-rgb','X-Row-Order':'top-down'};
  const imageWrites=[];
  const created=[];
  const pixelReads=[];
  const imageData = {width:100,height:80,components:3, getData:async()=>new Uint16Array(100*80*3),dispose(){}};
  const context = vm.createContext({
    require(name) {
      if (name === 'photoshop') return {app:{documents:[doc],activeDocument:doc,createDocument:async options=>{
        assert.equal(modal,true,'Document creation requires modal scope');
        const output={...options,id:2,activeLayers:[{id:3}],bitsPerChannel:16,colorProfileName:options.profile,closed:false,
          async closeWithoutSaving(){this.closed=true;}};
        created.push(output);return output;
      }},core:{executeAsModal:async fn=>{modal=true;try{return await fn();}finally{modal=false;}}},
        constants:{DocumentMode:{RGB:'RGB'},BitsPerChannelType:{THIRTYTWO:32},NewDocumentMode:{RGB:'RGB'},DocumentFill:{TRANSPARENT:'transparent'}},
        imaging:{getPixels: async options => {
          pixelReads.push(options);
          if (requireModal && !modal) throw new Error('Pixels require a modal scope');
          if (nativeDepthOnly && options.componentSize !== undefined) throw new Error('Photoshop -32005 depth conversion');
          if (options.colorProfile === 'sRGB IEC61966-2.1' && failComparison) throw new Error('comparison read failed');
          return {imageData};
        },encodeImageData:async()=>'',createImageDataFromBuffer:async(data,options)=>{
          imageWrites.push({data,options});
          assert.equal(modal,true);return {dispose(){}};
        },putPixels:async options=>{assert.equal(modal,true);assert.equal(options.documentID,2);if(putFailure)throw new Error('put failed');}}};
      if (name === 'uxp') return {entrypoints:{setup(){}},storage:{localFileSystem:{getFileForOpening:async()=>rawFile}}};
      if (name === './config.json') return {token:'test-token'};
      if (name === './film-effects.js') return require('../plugin/film-effects.js');
      throw new Error(name);
    },
    document:{getElementById:el,createElement:()=>({})},
    fetch:async (url,options) => {
      if (url.endsWith('/health')) return {ok:true,json:async()=>({catalog:[]})};
      if (url.includes('/source')) return {ok:true,json:async()=>({sourceId:url.endsWith('kind=full')?'test-full':'test-source'})};
      if (url.endsWith('/raw/open')) {
        if(rawFailure) return {ok:false,json:async()=>({error:'invalid RAW'})};
        return {ok:true,json:async()=>({sourceId:'raw-source',width:2,height:2,temperature:5500,tint:0,name:'chart',lensSupported:false})};
      }
      if (url.endsWith('/raw/render')) {
        assert.equal(modal,false,'Network and RAW rendering must be outside modal scope');
        return {ok:true,headers:{get:key=>key==='X-Width'||key==='X-Height'?'2':outputContract[key]??null},arrayBuffer:async()=>new Uint16Array(16).buffer,
          json:async()=>({image:'data:image/png;base64,test',original:'data:image/png;base64,original',width:2,height:2,ms:10})};
      }
      if (url.endsWith('/render')) {
        renders++;
        if(JSON.parse(options.body).sourceId==='test-full') return {ok:true,headers:{get:key=>key==='X-Width'?104:key==='X-Height'?120:outputContract[key]??null},arrayBuffer:async()=>new Uint16Array(104*120*4).buffer};
        return {ok:true,arrayBuffer:async()=>new Uint8Array([137,80,78,71]).buffer};
      }
      throw new Error(url);
    },
    console:{log(){},error(){}},setTimeout,clearTimeout,Uint8Array,Uint16Array,
    btoa:value=>Buffer.from(value,'binary').toString('base64')
  });
  vm.runInContext(fs.readFileSync(require.resolve('../plugin/main.js'),'utf8'),context);
  return {context,el,doc,created,pixelReads,imageWrites,setContract(key,value){outputContract[key]=value;},chooseRAW(){rawFile={nativePath:'/test/chart.dng'};},failRAW(){rawFailure=true;},failPut(){putFailure=true;},failComparison(){failComparison=true;},requireModal(){requireModal=true;},nativeDepthOnly(){nativeDepthOnly=true;},renders:()=>renders};
}

test('failed recapture invalidates the entire previous preview and apply state', async () => {
  const p = panel();
  await p.context.connect();
  p.failComparison();
  vm.runInContext("originalURL='old-original'; previewURL='old-preview';",p.context);
  await p.context.capture();
  assert.equal(vm.runInContext('source',p.context),null);
  assert.equal(p.el('apply').disabled,true);
  assert.equal(p.el('compare').disabled,true);
  assert.equal(vm.runInContext('originalURL',p.context),'');
  assert.equal(p.renders(),0);
});

test('changing history rejects applying a captured source', () => {
  const p = panel();
  const snapshot = {documentID:1,historyID:10,width:100,height:80};
  p.doc.activeHistoryState.id = 11;
  assert.throws(()=>p.context.assertSource(snapshot),/重新点击/);
});

test('capture reads both working pixels and comparison within Photoshop modal scope', async () => {
  const p=panel();
  await p.context.connect();
  p.requireModal();
  await p.context.capture();
  assert.notEqual(vm.runInContext('source',p.context),null,p.el('status').textContent);
});

test('capture avoids requesting a cross-depth conversion from Photoshop',async()=>{
  const p=panel(); await p.context.connect(); p.nativeDepthOnly();
  await p.context.capture();
  assert.notEqual(vm.runInContext('source',p.context),null,p.el('status').textContent);
});

test('RAW transfer creates a separate 16-bit ProPhoto document using modal imaging',async()=>{
  const p=panel(); await p.context.connect();p.chooseRAW();await p.context.openRAW();
  await p.context.sendRAW();
  assert.equal(p.created.length,1);assert.equal(p.created[0].depth,16);
  assert.equal(p.created[0].profile,'ProPhoto RGB');assert.equal(p.doc.activeHistoryState.id,10);
  assert.notEqual(vm.runInContext('source',p.context),null,'RAW remains editable after transfer');
});

test('failed RAW write closes only the new incomplete document',async()=>{
  const p=panel();await p.context.connect();p.chooseRAW();await p.context.openRAW();p.failPut();
  await p.context.sendRAW();assert.equal(p.created[0].closed,true);
  assert.equal(p.doc.activeHistoryState.id,10);assert.match(p.el('status').textContent,/put failed/);
});

test('failed RAW open invalidates previous preview and prevents stale transfer',async()=>{
  const p=panel();await p.context.connect();p.chooseRAW();p.failRAW();
  vm.runInContext("source={kind:'raw',sourceId:'old'};previewURL='old';",p.context);
  await p.context.openRAW();assert.equal(vm.runInContext('source',p.context),null);
  assert.equal(p.el('apply').disabled,true);assert.equal(vm.runInContext('previewURL',p.context),'');
});

test('cancelling the RAW picker preserves the existing source',async()=>{
  const p=panel();await p.context.connect();
  vm.runInContext("source={kind:'raw',sourceId:'old'};",p.context);
  await p.context.openRAW();assert.equal(vm.runInContext('source.sourceId',p.context),'old');
});

test('film edge from Photoshop uses actual expanded result dimensions in a new document',async()=>{
  const p=panel();await p.context.connect();await p.context.capture();
  p.el('edgeActive').checked=true;p.el('edgeFormat').value='120_6x6';p.el('cropX').value=100;p.el('cropY').value=50;
  await p.context.apply();
  assert.equal(p.created.length,1,p.el('status').textContent);
  assert.equal(p.created[0].width,104);assert.equal(p.created[0].height,120);
  assert.equal(p.doc.width,100);assert.equal(p.doc.height,80);assert.equal(p.doc.activeHistoryState.id,10);
  const full=p.pixelReads.filter(r=>!r.targetSize).at(-1);
  assert.equal(full.sourceBounds.left,20);assert.equal(full.sourceBounds.right,100);
  assert.equal(full.sourceBounds.bottom,80);
});

test('RAW framing and stable effect seeds are shared by preview and full requests',async()=>{
  const p=panel();await p.context.connect();p.chooseRAW();await p.context.openRAW();
  p.el('edgeActive').checked=true;p.el('edgeFormat').value='135_xpan';p.el('cropX').value=50;p.el('cropY').value=100;
  const first=p.context.controls(),second=p.context.controls();
  assert.equal(first.overscan_frame_seed,second.overscan_frame_seed);
  assert.equal(first.overscan_camera_seed,second.overscan_camera_seed);
  assert.equal(p.context.decodeControls().crop.aspect,65/24);
  assert.equal(p.context.decodeControls().crop.y,1);
});

for (const [key,value] of [
  ['X-Pixel-Format','rgba32f'],['X-Color-Space','sRGB'],
  ['X-Transfer-Function','linear'],['X-Row-Order','bottom-up'],['X-Pixel-Format',null]
]) test('RAW transfer refuses mismatched or missing pixel contract: '+key+'='+value,async()=>{
  const p=panel();await p.context.connect();p.chooseRAW();await p.context.openRAW();p.setContract(key,value);
  await p.context.sendRAW();
  assert.equal(p.created.length,0,'Unsafe pixels must not create a PS document');
  assert.match(p.el('status').textContent,/像素|引擎/);
});

test('Photoshop RGB transfer also rejects a mismatched profile',async()=>{
  const p=panel();await p.context.connect();await p.context.capture();
  p.el('edgeActive').checked=true;p.setContract('X-Color-Space','sRGB');await p.context.apply();
  assert.equal(p.created.length,0);
});

test('RAW writes keep full-range UInt16 pixels and ProPhoto tagging together',async()=>{
  const p=panel();await p.context.connect();p.chooseRAW();await p.context.openRAW();await p.context.sendRAW();
  const image=p.imageWrites.at(-1);
  assert.ok(image.data instanceof Uint16Array);
  assert.equal(image.options.colorProfile,'ProPhoto RGB');assert.equal(image.options.fullRange,true);
});
