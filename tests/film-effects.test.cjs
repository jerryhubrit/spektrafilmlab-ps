const test=require('node:test'),assert=require('node:assert/strict');
const f=require('../plugin/film-effects.js');
const o={format:'135',dateActive:true,edgeActive:false,dateSource:'exif',style:'lcd',order:'japan',placement:'frame',size:1};
test('date uses capture day, validates calendar, never invents today',()=>{
  assert.equal(f.formatDate('2026-11-06','japan'),"'26 11 6");
  assert.equal(f.formatDate('2026-11-06','us'),"11 6 '26");
  assert.equal(f.formatDate('2026-02-30','us'),'');
  assert.equal(f.dateState(o,{}).active,false);
  assert.equal(f.dateState({...o,dateSource:'manual',dateValue:'2024-02-29'},{}).active,true);
});
test('camera constraints prevent dates being silently omitted by engine',()=>{
  const meta={captureDate:'2026-11-06',shootingText:'1/125 F2.8 A'};
  assert.equal(f.dateState({...o,format:'135_xpan',edgeActive:true},meta).active,false);
  assert.equal(f.dateState({...o,format:'120_6x7'},meta).active,false);
  assert.equal(f.dateState({...o,style:'data'},meta).active,false);
  assert.equal(f.dateState({...o,format:'120_6x7',edgeActive:true},meta).placement,'rebate');
});
test('stock edge lettering matches real gauge-specific original labels',()=>{
  assert.equal(f.edgeText({id:'kodak_gold_200',name:'Kodak Gold 200'},'135'),'KODAK GB 200-7');
  assert.equal(f.edgeText({id:'kodak_gold_200',name:'Kodak Gold 200'},'120_645'),'KODAK 200');
});
test('square and panoramic framing crops without stretching or leaving source',()=>{
  const source={width:6000,height:4000};
  assert.deepEqual(f.bounds(source,f.crop({...o,edgeActive:true,format:'120_6x6',cropX:100,cropY:50},source)),{left:2000,top:0,right:6000,bottom:4000});
  const portrait={width:4000,height:6000},c=f.crop({...o,edgeActive:true,format:'135_xpan',cropX:0,cropY:0},portrait),b=f.bounds(portrait,c);
  assert.equal(b.top,0);assert.equal(b.bottom,6000);assert.equal(b.right,Math.floor(6000*24/65));
});
test('disabled effects send explicit off flags without changing grain format',()=>{
  assert.deepEqual(f.params({...o,dateActive:false}, {}, null),{overscan_active:false,date_imprint_active:false});
});
