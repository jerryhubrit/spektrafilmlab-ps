/* Film/date conventions ported from SpektraLab FilmEdge.swift and
 * Session+FilmEdge.swift (GPL-3.0-or-later). No photographic data is stored. */
const formats = {
  '135':[36,24], '135_half':[24,18], '120_645':[56,41.5], '120_6x6':[56,56],
  '120_6x7':[69.5,56], '120_6x8':[76,56], '120_6x9':[84,56],
  '135_xpan':[65,24], '120_6x12':[112,56], '120_6x17':[168,56]
};
const panoramic = ['135_xpan','120_6x12','120_6x17'];
function formatDate(value, order) {
  const m=/^(\d{4})-(\d{2})-(\d{2})$/.exec(value || '');
  if(!m) return '';
  const y=+m[1], month=+m[2], day=+m[3], date=new Date(Date.UTC(y,month-1,day));
  if(y<1801 || date.getUTCFullYear()!==y || date.getUTCMonth()!==month-1 || date.getUTCDate()!==day) return '';
  const yy="'"+String(y%100).padStart(2,'0');
  return order==='us' ? month+' '+day+' '+yy : yy+' '+month+' '+day;
}
function edgeText(stock, format) {
  if(!stock) return '';
  const own={
    kodak_gold_200:['KODAK GB 200-7','KODAK 200'],kodak_portra_800:['KODAK PORTRA 800-3','KODAK PORTRA 800'],
    kodak_ultramax_400:['KODAK GC 400','KODAK GC 400'],kodak_ektachrome_100:['KODAK E100','KODAK E100'],
    fujifilm_c200:['FUJI 200','FUJI 200'],fujifilm_xtra_400:['S-400','FUJI S-400'],
    fujifilm_pro_400h:['PRO400H','FUJI PRO400H'],fujifilm_provia_100f:['FUJI RDPIII','FUJI RDPIII'],
    fujifilm_velvia_100:['RVP100','FUJI RVP100'],kodak_vision3_50d:['EASTMAN 5203','EASTMAN 5203'],
    kodak_vision3_250d:['EASTMAN 5207','EASTMAN 5207'],kodak_vision3_200t:['EASTMAN 5213','EASTMAN 5213'],
    kodak_vision3_500t:['EASTMAN 5219','EASTMAN 5219'],cinestill_800t:['CINESTILL 800T','CINESTILL 800T'],
    kodak_tri_x_400:['KODAK 400TX','KODAK 400TX'],kodak_tmax_100:['KODAK 100TMX','KODAK 100TMX'],
    fujifilm_neopan_acros_100_ii:['FUJI 100 ACROS II','FUJI 100 ACROS II'],ilford_hp5_plus_400:['ILFORD HP5 PLUS','ILFORD HP5 PLUS']
  };
  const text=own[stock.id.replace(/_push[12]$/,'')];
  return text ? text[format.startsWith('120')?1:0] : stock.name.split('(')[0].trim().toUpperCase();
}
function dateState(o, imprint={}) {
  let reason='';
  const margin=o.format.startsWith('120');
  if(panoramic.includes(o.format)) reason='宽幅画幅不支持日期后背。';
  else if(!o.edgeActive && (margin || o.style==='data' || o.placement==='rebate')) reason='这个日期位置或样式需要开启片边。';
  const date=formatDate(o.dateSource==='manual'?o.dateValue:imprint.captureDate,o.order);
  const text=o.style==='data' ? (imprint.shootingText||'') : date;
  if(!reason && !text) reason=o.style==='data' ? '未读取到拍摄参数，不能打印数据行。' : o.dateSource==='manual' ? '请输入有效日期，例如 2026-11-06。' : '照片没有可用拍摄日期，可改为手动日期。';
  return {active:o.dateActive && !reason,reason,text,placement:margin || o.style==='data'?'rebate':o.placement};
}
function params(o, imprint, stock) {
  const d=dateState(o,imprint), edge=o.edgeActive;
  const p={overscan_active:edge,date_imprint_active:!!d.active};
  if(edge || d.active) { p.overscan_format=o.format;p.film_format_mm=formats[o.format][0]; }
  if(edge) Object.assign(p,{overscan_mode:o.mode,overscan_gate:o.gate,overscan_holes:o.holes,overscan_carrier:o.carrier,
    overscan_camera_seed:o.cameraSeed,overscan_frame_seed:o.frameSeed,overscan_frame_number:o.frameNumber,
    overscan_fog:o.fog,overscan_leaks:o.leaks,overscan_edge_text:edgeText(stock,o.format),overscan_f_number:imprint.fNumber||0});
  if(d.active) Object.assign(p,{date_imprint_style:o.style,date_imprint_text:d.text,
    date_imprint_data_text:o.withData && edge && o.style!=='data' ? imprint.shootingText||'' : '',
    date_imprint_placement:d.placement,date_imprint_corner:o.corner,
    date_imprint_size:o.style==='data' && o.format==='135_half'?Math.min(1,o.size):o.size,
    date_imprint_ev:o.ev,date_imprint_inset_x:3,date_imprint_inset_y:2.4});
  return p;
}
function crop(o, source) {
  if(!o.edgeActive || !source) return null;
  const f=formats[o.format], ratio=f[0]/f[1];
  return {aspect:source.width>=source.height?ratio:1/ratio,x:o.cropX/100,y:o.cropY/100};
}
function bounds(source, c) {
  if(!c) return {left:0,top:0,right:source.width,bottom:source.height};
  const w=Math.floor(Math.min(source.width,source.height*c.aspect)),h=Math.floor(Math.min(source.height,source.width/c.aspect));
  const left=Math.floor((source.width-w)*c.x),top=Math.floor((source.height-h)*c.y);
  return {left,top,right:left+w,bottom:top+h};
}
module.exports={formats,formatDate,edgeText,dateState,params,crop,bounds};
