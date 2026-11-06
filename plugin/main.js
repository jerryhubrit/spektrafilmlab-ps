/* Local prototype. Native spectral rendering stays in the separate helper. */
const {app, core, imaging, constants} = require('photoshop');
const {entrypoints} = require('uxp');
const config = require('./config.json');
const effects = require('./film-effects.js');
const $ = id => document.getElementById(id);
let source = null, catalog = [], connected = false, busy = false;
let revision = 0, rendered = -1, rendering = false, timer = null;
let previewURL = '', originalURL = '';
let placement = {scene_latitude_active:false};
let cameraSeed=1, frameSeed=1;
const effectSelectIDs=['edgeFormat','edgeMode','edgeGate','edgeHoles','edgeCarrier','dateStyle','dateSource','dateOrder','datePlacement','dateCorner'];
const effectOtherIDs=['edgeActive','dateActive','dateWithData','dateValue','frameNumber','newCamera','newFrame'];
const sliderIDs = ['exposure','brightness','magenta','yellow','grain','halation','temperature','tint','scatter','couplers','glare','edgeFog','edgeLeaks','cropX','cropY','dateSize','dateEV'];
const controlIDs = ['capture','openRaw','connect','reset','film','paper','metering','format','wb','lens','autoFit','fit','clearFit','highlightPull','shadowPull',...sliderIDs,...effectSelectIDs,...effectOtherIDs];
const status = text => { $('status').textContent = text; console.log('[FilmLab]', text); };
function report(error) {
  const detail = error && (error.message || error.stack) || String(error);
  status('操作失败：'+detail);
  console.error('[FilmLab] failure', String(error), error && error.stack, JSON.stringify(error, Object.getOwnPropertyNames(error || {})));
}
function controls() {
  return {...placement, film_stock: $('film').value, print_stock: $('paper').value,
    exposure_compensation_ev: +$('exposure').value,
    print_exposure: Math.pow(2, -Number($('brightness').value)),
    m_filter_shift: +$('magenta').value, y_filter_shift: +$('yellow').value,
    grain_amount: +$('grain').value, grain_active: +$('grain').value > 0,
    halation_amount: +$('halation').value, halation_active: +$('halation').value > 0,
    film_format_mm: +$('format').value || 36,
    auto_exposure: $('metering').value !== 'off',
    auto_exposure_method: $('metering').value === 'off' ? 'balanced' : $('metering').value,
    halation_scatter_amount: +$('scatter').value,
    dir_couplers_active: +$('couplers').value > 0, dir_couplers_amount: +$('couplers').value,
    glare_active: +$('glare').value > 0, glare_amount: +$('glare').value,
    ...effects.params(effectOptions(),source && source.imprint || {},catalog.find(s=>s.id===$('film').value))};
}
function effectOptions() {
  const value=(id,fallback)=>$(id).value || fallback;
  const number=(id,lo,hi,fallback)=>Number.isFinite(+$(id).value)?Math.max(lo,Math.min(hi,+$(id).value)):fallback;
  return {edgeActive:$('edgeActive').checked===true,dateActive:$('dateActive').checked===true,
    format:effects.formats[$('edgeFormat').value]?$('edgeFormat').value:'135',mode:value('edgeMode','strip'),gate:value('edgeGate','auto'),
    holes:value('edgeHoles','white'),carrier:value('edgeCarrier','none'),cameraSeed,frameSeed,
    frameNumber:Math.round(number('frameNumber',0,99,1)),fog:number('edgeFog',0,4,1),leaks:number('edgeLeaks',0,4,0),
    cropX:number('cropX',0,100,50),cropY:number('cropY',0,100,50),
    style:value('dateStyle','lcd'),dateSource:value('dateSource','exif'),dateValue:value('dateValue',''),order:value('dateOrder','japan'),
    placement:value('datePlacement','frame'),corner:value('dateCorner','br'),withData:$('dateWithData').checked===true,
    size:number('dateSize',.4,3,1),ev:number('dateEV',-2,8,3.5)};
}
function effectUI() {
  const o=effectOptions(),imprint=source && source.imprint || {},d=effects.dateState(o,imprint);
  const disabled=busy || !source;
  for(const id of ['edgeActive','dateActive']) $(id).disabled=disabled;
  for(const id of ['edgeMode','edgeGate','edgeHoles','edgeCarrier','frameNumber','newCamera','newFrame','edgeFog','edgeLeaks','cropX','cropY']) $(id).disabled=disabled || !o.edgeActive;
  $('edgeFormat').disabled=disabled || !(o.edgeActive || o.dateActive);
  for(const id of ['dateStyle','dateSource','dateValue','dateOrder','datePlacement','dateCorner','dateWithData','dateSize','dateEV']) $(id).disabled=disabled || !o.dateActive;
  $('dateValue').disabled=disabled || !o.dateActive || o.dateSource!=='manual' || o.style==='data';
  $('dateWithData').disabled=disabled || !o.dateActive || !o.edgeActive || !imprint.shootingText || o.style==='data';
  $('datePlacement').disabled=disabled || !o.dateActive || o.format.startsWith('120') || o.style==='data';
  $('dateCorner').disabled=disabled || !o.dateActive || d.placement==='rebate';
  $('dateHint').textContent=o.dateActive ? d.reason || ('打印：'+d.text+(o.withData && o.edgeActive && imprint.shootingText?' · '+imprint.shootingText:'')) : '使用原生日期后背，日期曝光进入底片。';
  $('edgeHint').textContent=o.edgeActive ? '按所选画幅裁切；可调整构图位置。带边结果送入 PS 新文档。' : '整条胶片、齿孔、边码和漏光。开启后预览与输出都会带边。';
  $('seedInfo').textContent='相机 '+cameraSeed+' · 片格 '+frameSeed;
  $('compare').disabled=busy || !originalURL || o.edgeActive;
  $('compare').textContent=o.edgeActive?'带片边时关闭原图对照':'按住看显影前';
  $('apply').textContent=source && (source.kind==='raw' || o.edgeActive)?'显影并送入 Photoshop':'应用到 PS 新图层';
}
function decodeControls() {
  return {lensCorrection: $('lens').checked === true,
    ...(effects.crop(effectOptions(),source)?{crop:effects.crop(effectOptions(),source)}:{}),
    ...($('wb').value === 'custom' ? {temperature: +$('temperature').value, tint: +$('tint').value} : {})};
}
function labels() {
  for (const id of sliderIDs) {
    $(id+'Value').textContent = Number($(id).value).toFixed(['temperature','tint'].includes(id) ? 0 : id === 'exposure' || id === 'brightness' ? 1 : 2) + (id === 'exposure' || id === 'brightness' ? ' EV' : '');
  }
}
function rawControls() {
  const raw = source && source.kind === 'raw';
  for (const id of ['wb','temperature','tint']) $(id).disabled = busy || !raw;
  for (const id of ['autoFit','fit','clearFit','highlightPull','shadowPull']) $(id).disabled = busy || !raw;
  $('lens').disabled = busy || !raw || !source.lensSupported;
  $('rawHint').textContent = !raw ? 'RAW 专属控制：请使用「打开 RAW」。' : source.lensSupported ? '白平衡在 RAW 解码时处理；支持此照片的镜头校正。' : '白平衡在 RAW 解码时处理；此文件未提供可用的镜头校正。';
  $('apply').textContent = raw ? '显影并送入 Photoshop' : '应用到 PS 新图层';
  effectUI();
}
function lock(value) {
  busy = value;
  for (const id of controlIDs) $(id).disabled = value;
  $('apply').disabled = value || !source;
  rawControls();
}
async function request(path, body, binary = false) {
  const response = await fetch('http://localhost:'+(config.port || 49321)+path, {
    method: body === undefined ? 'GET' : 'POST',
    headers: {'Authorization':'Bearer '+config.token, 'Content-Type': binary ? 'application/octet-stream' : 'application/json'},
    body: body === undefined ? undefined : binary ? body : JSON.stringify(body)
  });
  if (!response.ok) { const error = await response.json(); throw new Error(error.error || '本地引擎请求失败'); }
  return response;
}
async function connect() {
  try {
    const data = await (await request('/health')).json();
    catalog = data.catalog;
    const fill = (id, stage, selected) => {
      $(id).innerHTML = '';
      for (const stock of catalog.filter(s => s.stage === stage)) {
        const option = document.createElement('option'); option.value = stock.id; option.textContent = stock.name; $(id).appendChild(option);
      }
      $(id).value = selected;
    };
    fill('film','filming','kodak_portra_400'); fill('paper','printing','kodak_portra_endura');
    connected = true; status('本地引擎已连接。打开 RAW，调整后送入 Photoshop。');
  } catch (error) { connected = false; status('引擎连接失败：'+error.message+'。请启动本地引擎后重试。'); }
}
function current() {
  if (!app.documents.length) throw new Error('请先在 Photoshop 打开一张 RGB 照片。');
  const doc = app.activeDocument;
  if (doc.mode !== constants.DocumentMode.RGB) throw new Error('第一版支持 RGB 文档，请先转换到 RGB 模式。');
  if (doc.bitsPerChannel === constants.BitsPerChannelType.THIRTYTWO) throw new Error('第一版支持 8/16 位 RGB，暂不处理 32 位 HDR。');
  if (Number(doc.width) * Number(doc.height) > 50000000) throw new Error('第一版最多支持 5000 万像素。');
  return doc;
}
function assertSource(snapshot) {
  const doc = current();
  if (!snapshot || doc.id !== snapshot.documentID || doc.activeHistoryState.id !== snapshot.historyID ||
      Number(doc.width) !== snapshot.width || Number(doc.height) !== snapshot.height) {
    throw new Error('文档或图像已变化，请重新点击「读取当前图像」。');
  }
  return doc;
}
async function pixels(snapshot, small, crop = effects.crop(effectOptions(),snapshot)) {
  const bounds=effects.bounds(snapshot,crop), w=bounds.right-bounds.left,h=bounds.bottom-bounds.top;
  return core.executeAsModal(async () => {
    assertSource(snapshot);
    const input = await imaging.getPixels({documentID: snapshot.documentID, historyStateID: snapshot.historyID,
    sourceBounds: bounds,
    ...(small ? {targetSize: w >= h ? {width:Math.min(1024,w)} : {height:Math.min(1024,h)}} : {}),
    colorSpace:'RGB', colorProfile:'ProPhoto RGB', applyAlpha:false});
    try {
      const image = input.imageData;
      const raw = await image.getData({chunky:true,fullRange:true});
      const data = raw.BYTES_PER_ELEMENT === 1 ? Uint16Array.from(raw,v=>v*257) : raw;
      return {width:image.width,height:image.height,components:image.components,
        sourceBounds:input.sourceBounds,data};
    } finally { input.imageData.dispose(); }
  }, {commandName:'FilmLab 读取图像'});
}
async function upload(image, kind) {
  const data = image.data;
  const result = await request('/source?width='+image.width+'&height='+image.height+'&channels='+image.components+'&kind='+kind, data.buffer, true);
  return result.json();
}
function setImage(url) {
  $('preview').src = url; $('preview').style.display = 'block'; $('placeholder').style.display = 'none';
}
async function capture() {
  console.log('[FilmLab] capture clicked');
  if (busy) return;
  lock(true); revision++; source = null;
  clearPlacement();
  originalURL = ''; previewURL = '';
  $('compare').disabled = true;
  $('preview').style.display = 'none'; $('placeholder').style.display = 'block';
  try {
    if (!connected) await connect();
    if (!connected) throw new Error('本地引擎尚未启动。');
    const doc = current();
    resetFrameEffects();
    const snapshot = {documentID:doc.id, historyID:doc.activeHistoryState.id, width:Number(doc.width), height:Number(doc.height)};
    status('读取当前可见图像…');
    const input = await pixels(snapshot,true);
      console.log('[FilmLab] pixels read',input.width,input.height,input.components,input.data.byteLength);
      const result = await upload(input,'preview');
      console.log('[FilmLab] preview source uploaded');
      assertSource(snapshot);
      source = {...snapshot,name:doc.name || 'Photoshop 图像',sourceId:result.sourceId,
        geometryKey:JSON.stringify(effects.crop(effectOptions(),snapshot))};
      $('fileInfo').textContent = 'Photoshop 图像 · '+snapshot.width+' × '+snapshot.height;
      // Encode comparison from the same capture, converted to sRGB by Photoshop.
      originalURL = await core.executeAsModal(async () => {
        assertSource(snapshot);
        const original = await imaging.getPixels({documentID:doc.id,historyStateID:snapshot.historyID,
        targetSize:snapshot.width>=snapshot.height?{width:Math.min(1024,snapshot.width)}:{height:Math.min(1024,snapshot.height)},
        colorSpace:'RGB',colorProfile:'sRGB IEC61966-2.1',applyAlpha:true});
        let encodedInput = original.imageData;
        try {
          if (encodedInput.componentSize === 16) {
            const fullRange = await encodedInput.getData({chunky:true,fullRange:true});
            const bytes = Uint8Array.from(fullRange,v=>Math.round(v/257));
            encodedInput = await imaging.createImageDataFromBuffer(bytes,{width:encodedInput.width,height:encodedInput.height,
              components:encodedInput.components,colorSpace:'RGB',colorProfile:'sRGB IEC61966-2.1'});
          }
          return 'data:image/jpeg;base64,' + await imaging.encodeImageData({imageData:encodedInput,base64:true});
        } finally { if(encodedInput !== original.imageData) encodedInput.dispose(); original.imageData.dispose(); }
      }, {commandName:'FilmLab 读取对照图'});
      $('compare').disabled = false;
      console.log('[FilmLab] comparison encoded');
    rendered = -1; revision++;
  } catch (error) { source = null; report(error); }
  finally { lock(false); }
  if (source) drain();
}
function changed() { labels(); effectUI(); revision++; clearTimeout(timer); timer = setTimeout(drain,60); }
async function drain() {
  if (rendering || busy || !source) return;
  rendering = true;
  try {
    while (source && !busy && rendered !== revision) {
      const wanted = revision, snapshot = source, params = controls(), started = Date.now();
      if (snapshot.kind === 'raw') {
        const result = await (await request('/raw/render',{sourceId:snapshot.sourceId,params,decode:decodeControls()})).json();
        if (wanted !== revision || source !== snapshot || busy) continue;
        previewURL = result.image; originalURL = result.original; setImage(previewURL);
        rendered = wanted; effectUI();
        $('timing').textContent = result.ms+' ms · '+result.width+' × '+result.height+' 预览';
        status('显影预览已更新；确认后送入 PS 继续精修。');
        continue;
      }
      assertSource(snapshot);
      const crop=effects.crop(effectOptions(),snapshot), geometryKey=JSON.stringify(crop);
      if(snapshot.geometryKey!==geometryKey) {
        const input=await pixels(snapshot,true,crop), uploaded=await upload(input,'preview');
        snapshot.sourceId=uploaded.sourceId;snapshot.geometryKey=geometryKey;
      }
      const response = await request('/render',{sourceId:snapshot.sourceId,params});
      const bytes = await response.arrayBuffer();
      if (wanted !== revision || source !== snapshot || busy) continue;
      const view = new Uint8Array(bytes);
      let binary = '';
      for (let i=0;i<view.length;i+=8192) binary += String.fromCharCode.apply(null,view.subarray(i,i+8192));
      const url = 'data:image/png;base64,' + btoa(binary);
      previewURL = url; setImage(url); rendered = wanted; effectUI();
      $('timing').textContent = (Date.now()-started)+' ms · 预览';
      status('预览已更新。点击应用，生成完整尺寸的新图层。');
    }
  } catch (error) { report(error); }
  finally { rendering = false; }
}
async function apply() {
  if (busy || !source) return;
  if (source.kind === 'raw') return sendRAW();
  const snapshot = source, params = controls();
  lock(true); revision++;
  try {
    assertSource(snapshot);
    // Finish any in-flight preview before changing the helper's full residency.
    while (rendering) await new Promise(resolve => setTimeout(resolve,20));
    const started = Date.now();
    status('读取完整尺寸图像…');
    const input = await pixels(snapshot,false);
    let w=input.width, h=input.height; const bounds=input.sourceBounds;
    const full=await upload(input,'full');
    status('正在计算完整尺寸胶片效果…');
    const response = await request('/render',{sourceId:full.sourceId,params});
    if(params.overscan_active) { w=Number(response.headers.get('X-Width'));h=Number(response.headers.get('X-Height')); }
    const output = new Uint16Array(await response.arrayBuffer());
    if (output.length !== w*h*4) throw new Error('引擎返回的图像尺寸不匹配。');
    assertSource(snapshot);
    if(params.overscan_active) {
      await writeNewDocument(output,w,h,snapshot.name,params);
      status('已将带片边结果送入 PS 新文档：'+w+' × '+h+' · 16 位 ProPhoto RGB。');
      return;
    }
    await core.executeAsModal(async executionContext => {
        const doc = assertSource(snapshot);
        const imageData = await imaging.createImageDataFromBuffer(output,{width:w,height:h,components:4,colorSpace:'RGB',colorProfile:'ProPhoto RGB',fullRange:true});
        try {
        const suspension = await executionContext.hostControl.suspendHistory({documentID:doc.id,name:'FilmLab 胶片效果'});
        try {
          const name = (catalog.find(s=>s.id===params.film_stock)||{}).name || '胶片';
          const layer = await doc.createLayer({name:'FilmLab · '+name});
          await imaging.putPixels({documentID:doc.id,layerID:layer.id,imageData,replace:true,targetBounds:{left:bounds.left,top:bounds.top}});
          await executionContext.hostControl.resumeHistory(suspension);
        } catch (error) { await executionContext.hostControl.resumeHistory(suspension,false); throw error; }
        } finally { imageData.dispose(); }
      },{commandName:'FilmLab 胶片效果'});
    source=null; $('compare').disabled=true;
    status('已生成 '+w+' × '+h+' 新图层，用时 '+((Date.now()-started)/1000).toFixed(2)+' 秒。可用 PS 撤销。');
  } catch (error) { report(error); }
  finally { lock(false); }
}
function reset() {
  resetEffects();
  clearPlacement();
  for (const id of ['exposure','brightness','magenta','yellow','grain']) $(id).value=0;
  for (const id of ['halation','scatter','couplers']) $(id).value=1;
  $('glare').value=0; $('format').value='36'; $('metering').value='balanced';
  $('wb').value='camera'; $('lens').checked=false;
  if (source && source.kind === 'raw') { $('temperature').value=source.temperature; $('tint').value=source.tint; }
  changed();
}
async function openRAW() {
  if (busy) return;
  lock(true);
  try {
    const file = await require('uxp').storage.localFileSystem.getFileForOpening({types:['arw','nef','dng','cr2','cr3','raf','rw2','orf','pef','srw','3fr','iiq']});
    if (!file) return;
    revision++; source=null; previewURL=''; originalURL='';
    clearPlacement();
    $('compare').disabled=true; $('preview').style.display='none'; $('placeholder').style.display='block';
    while (rendering) await new Promise(resolve=>setTimeout(resolve,20));
    if (!connected) await connect();
    if (!connected) throw new Error('请先启动本地引擎。');
    status('正在打开 RAW…');
    const info = await (await request('/raw/open',{path:file.nativePath})).json();
    source = {...info,kind:'raw'};
    resetFrameEffects();
    $('fileInfo').textContent = info.name+' · RAW · '+info.width+' × '+info.height;
    $('wb').value='camera'; $('temperature').value=Math.max(2000,Math.min(12000,info.temperature));
    $('tint').value=Math.max(-150,Math.min(150,info.tint)); $('lens').checked=false;
    labels(); rendered=-1; revision++;
  } catch(error) { report(error); }
  finally {
    lock(false);
    // A cancelled file picker can overlap an in-flight preview. Resume any
    // preview discarded while the picker held the workbench lock.
    if(source && rendered!==revision) drain();
  }
}
async function sendRAW() {
  const snapshot=source, params=controls(), decode=decodeControls();
  lock(true); revision++;
  try {
    while(rendering) await new Promise(resolve=>setTimeout(resolve,20));
    const started=Date.now(); status('正在显影完整尺寸 RAW，请稍候…');
    const response=await request('/raw/render',{sourceId:snapshot.sourceId,params,decode,full:true});
    const w=Number(response.headers.get('X-Width')), h=Number(response.headers.get('X-Height'));
    const output=new Uint16Array(await response.arrayBuffer());
    if(!w || !h || output.length!==w*h*4) throw new Error('RAW 输出尺寸不匹配。');
    status('正在创建 16 位 Photoshop 文档…');
    await writeNewDocument(output,w,h,snapshot.name,params);
    status('已送入 PS：'+w+' × '+h+' · 16 位 ProPhoto RGB，用时 '+((Date.now()-started)/1000).toFixed(1)+' 秒。可继续精修。');
  } catch(error) { report(error); }
  finally { lock(false); }
}
async function writeNewDocument(output,w,h,name,params) {
    await core.executeAsModal(async () => {
      const imageData=await imaging.createImageDataFromBuffer(output,{width:w,height:h,components:4,colorSpace:'RGB',colorProfile:'ProPhoto RGB',fullRange:true});
      let doc;
      try {
        doc=await app.createDocument({width:w,height:h,resolution:300,depth:16,mode:constants.NewDocumentMode.RGB,
          fill:constants.DocumentFill.TRANSPARENT,profile:'ProPhoto RGB',name:name+' · FilmLab'});
        if(!doc) throw new Error('Photoshop 未创建输出文档。');
        const layer=doc.activeLayers[0];
        await imaging.putPixels({documentID:doc.id,layerID:layer.id,imageData,replace:true,targetBounds:{left:0,top:0}});
        layer.name='FilmLab · '+((catalog.find(s=>s.id===params.film_stock)||{}).name||'胶片显影');
        console.log('[FilmLab] new document complete',w,h,doc.bitsPerChannel,doc.colorProfileName,'edge',!!params.overscan_active,'date',!!params.date_imprint_active);
      } catch(error) {
        if(doc) { try { await doc.closeWithoutSaving(); } catch(_) {} }
        throw error;
      } finally { imageData.dispose(); }
    },{commandName:'FilmLab RAW 显影'});
}
function resetFrameEffects() {
  frameSeed=Math.floor(Math.random()*999999)+1;
  $('cropX').value=50;$('cropY').value=50;
  $('dateSource').value='exif';$('dateValue').value='';
}
function resetEffects() {
  $('edgeActive').checked=false;$('dateActive').checked=false;$('dateWithData').checked=false;
  const defaults={edgeFormat:'135',edgeMode:'strip',edgeGate:'auto',edgeHoles:'white',edgeCarrier:'none',frameNumber:1,edgeFog:1,edgeLeaks:0,
    cropX:50,cropY:50,dateStyle:'lcd',dateSource:'exif',dateValue:'',dateOrder:'japan',datePlacement:'frame',dateCorner:'br',dateSize:1,dateEV:3.5};
  for(const id in defaults) $(id).value=defaults[id];
}
function toggleEffect(id) {
  if(busy) return;
  if(!source) { status('请先打开 RAW 或读取 PS 图像，再开启片边／日期后背。');return; }
  $(id).checked=!$(id).checked;
  if(id==='edgeActive') clearPlacement();
  changed();
}
function clearPlacement() {
  placement={scene_latitude_active:false};
  $('highlightPull').value=0; $('shadowPull').value=0;
  $('latitudeInfo').textContent='由原引擎测量场景和胶片的可用范围。';
}
async function fitLatitude(automatic) {
  if(busy || !source || source.kind!=='raw') return;
  const snapshot=source;
  // Complete latest requested preview before measuring its scene and medium.
  await drain();
  while(rendering) await new Promise(resolve=>setTimeout(resolve,20));
  if(source!==snapshot || busy) return;
  if(rendered!==revision) { status('请先完成当前预览，再调整场景宽容度。'); return; }
  lock(true);
  try {
    status('正在测量场景与胶片宽容度…');
    const requested=automatic?{}:{highlight_pull_back:+$('highlightPull').value,shadow_pull_back:+$('shadowPull').value};
    const reply=await (await request('/raw/latitude',{sourceId:snapshot.sourceId,placement:requested})).json();
    const fit=reply.fit;
    if(!fit || !fit.valid || !fit.params_delta) throw new Error('当前收回量无法适配此场景，请使用自动适配或减小收回量。');
    placement=fit.params_delta;
    $('highlightPull').value=fit.highlight.pull_back;
    $('shadowPull').value=fit.shadow.pull_back;
    $('latitudeInfo').textContent='胶片宽容度 '+Number(reply.medium.latitude_stops).toFixed(1)+' EV · 已按引擎求解应用';
    revision++;
  } catch(error) { report(error); }
  finally { lock(false); }
  if(rendered!==revision) drain();
}
$('connect').addEventListener('click',connect);
$('capture').addEventListener('click',capture);
$('openRaw').addEventListener('click',openRAW);
$('apply').addEventListener('click',apply);
$('reset').addEventListener('click',reset);
$('autoFit').addEventListener('click',()=>fitLatitude(true));
$('fit').addEventListener('click',()=>fitLatitude(false));
$('clearFit').addEventListener('click',()=>{clearPlacement();changed();});
for(const id of effectSelectIDs.concat(['edgeActive','dateActive','dateWithData','frameNumber','dateValue'])) $(id).addEventListener('change',()=>{if(['edgeActive','edgeFormat'].includes(id)) clearPlacement();changed();});
$('newCamera').addEventListener('click',()=>{cameraSeed=Math.floor(Math.random()*999)+1;changed();});
$('newFrame').addEventListener('click',()=>{frameSeed=Math.floor(Math.random()*999999)+1;changed();});
for (const id of sliderIDs) $(id).addEventListener('input',()=>{if(['temperature','tint'].includes(id)) $('wb').value='custom'; if(['cropX','cropY'].includes(id)) clearPlacement(); changed();});
for (const id of ['wb','lens','format','metering']) $(id).addEventListener('change',()=>{if(id==='wb' && $('wb').value==='camera' && source) { $('temperature').value=source.temperature; $('tint').value=source.tint; } changed();});
$('paper').addEventListener('change',changed);
$('film').addEventListener('change',()=>{const film=catalog.find(s=>s.id===$('film').value); if(film && film.target && catalog.some(s=>s.id===film.target)) $('paper').value=film.target; changed();});
$('compare').addEventListener('mousedown',()=>{if(originalURL)setImage(originalURL);});
for(const event of ['mouseup','mouseleave']) $('compare').addEventListener(event,()=>{if(previewURL)setImage(previewURL);});
entrypoints.setup({
  panels:{rawWorkbench:{show(){console.log('[FilmLab] RAW workbench shown'); if(!connected)connect();}}},
  commands:{readCurrentImage:capture,applyFilmLayer:apply,openRAW,
    toggleFilmEdge:()=>toggleEffect('edgeActive'),toggleDateBack:()=>toggleEffect('dateActive')}
});
labels();
rawControls();
status('FilmLab 已初始化，正在连接本地引擎…');
connect();
