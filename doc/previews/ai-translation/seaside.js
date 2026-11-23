(() => {
  const width = 1000, height = 526;

  function drawSeaside(canvas) {
    canvas.width = width;
    canvas.height = height;
    const ctx = canvas.getContext('2d');
    if (!ctx) return;
    const ink = '#242522', black = '#181a18', paper = '#fafaf6';
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    let seed = 1908;
    function random() {
      seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
      return seed / 4294967296;
    }
    function trace(points, close = false) {
      ctx.beginPath();
      ctx.moveTo(points[0], points[1]);
      for (let i = 2; i < points.length; i += 2) ctx.lineTo(points[i], points[i + 1]);
      if (close) ctx.closePath();
    }
    function shape(points, fill, outline, weight = 1) {
      trace(points, true);
      ctx.fillStyle = fill;
      ctx.fill();
      if (outline) {
        ctx.strokeStyle = outline;
        ctx.lineWidth = weight;
        ctx.stroke();
      }
    }
    function line(points, color = ink, weight = 1) {
      trace(points);
      ctx.strokeStyle = color;
      ctx.lineWidth = weight;
      ctx.stroke();
    }
    function curve(x, y, cx, cy, ex, ey, color = ink, weight = 1) {
      ctx.beginPath();
      ctx.moveTo(x, y);
      ctx.quadraticCurveTo(cx, cy, ex, ey);
      ctx.strokeStyle = color;
      ctx.lineWidth = weight;
      ctx.stroke();
    }
    function ellipse(x, y, rx, ry, fill) {
      ctx.beginPath();
      ctx.ellipse(x, y, rx, ry, 0, 0, Math.PI * 2);
      ctx.fillStyle = fill;
      ctx.fill();
    }
    function screen(space, size, color) {
      const tile = document.createElement('canvas');
      tile.width = tile.height = space * 2;
      const pen = tile.getContext('2d');
      pen.fillStyle = color;
      for (const [x, y] of [[0.5, 0.5], [1.5, 1.5]]) {
        pen.beginPath();
        pen.arc(space * x, space * y, size, 0, Math.PI * 2);
        pen.fill();
      }
      return ctx.createPattern(tile, 'repeat');
    }
    const mist = screen(3, 0.9, '#9c9d96');
    const shade = screen(3, 1.25, '#555753');
    const gravel = screen(4, 1.6, '#73756d');
    ctx.fillStyle = paper;
    ctx.fillRect(0, 0, width, height);

    // Distant islands, ripples and a bank of low clouds.
    const hills = [-5,272, 17,267, 48,265, 74,258, 111,260, 139,254, 162,255, 190,247, 213,241, 229,242, 252,232, 272,230, 290,220, 312,216, 330,205, 348,202, 361,194, 373,196, 386,187, 398,190, 410,185, 428,192, 443,195, 462,204, 482,203, 510,220, 530,219, 557,230, 580,239, 635,273];
    shape(hills, '#dbdcd5');
    shape(hills, mist);
    line(hills, '#8a8d84', 1.15);
    for (const ridge of [[167,259,217,245,200,253,237,246], [287,242,329,217,321,225,343,212], [310,246,359,208,350,220,383,199], [353,243,395,201,388,212,408,198], [418,206,451,218,472,235]]) {
      line(ridge, '#92958a', 1.2);
    }
    for (const [x,y,s] of [[64,211,0.8], [262,195,0.5], [435,130,0.65]]) {
      curve(x,y,x+9*s,y-4*s,x+15*s,y+2*s,'#64665f',1.6);
      curve(x+15*s,y+2*s,x+19*s,y-4*s,x+26*s,y-6*s,'#64665f',1.35);
    }
    ctx.fillStyle = '#e7e8e1';
    ctx.fillRect(0,269,610,125);
    line([0,269, 122,270, 226,268, 387,270, 620,267], '#5e6258', 1.4);
    for (let i = 0; i < 460; i++) {
      const x = random()*620, depth = random(), y = 272 + depth*108;
      const length = (2 + random()*16) * (0.6 + depth*2.7);
      line([x,y, x+length*0.4,y-0.35, x+length,y], i%3 ? '#aaada2' : '#fff', 0.6+depth);
    }
    shape([210,280, 218,277, 218,261], '#fcfcf8', '#7f8276', 0.7);
    shape([205,281, 224,280, 220,283, 209,283], '#62665b');
    line([215,286, 224,286], '#b0b4a7');
    shape([-8,347, 143,326, 244,315, 368,298, 498,283, 669,274, 665,310, 0,416], '#b9bbb1', ink);
    line([0,350, 179,326, 375,300, 612,276], '#fff', 3);
    for (let x=9; x<560; x+=29) {
      const y = 350-x*0.13;
      line([x,y+3, x-8,y+17, x-4,y+22], '#64665e', 1);
    }
    shape([-20,415, 497,300, 1050,229, 1050,550, -20,550], '#d3d4ca');
    shape([-20,415, 497,300, 1050,229, 1050,550, -20,550], gravel);
    for (let i=0; i<950; i++) {
      const x=random()*width, y=251+random()*290;
      if (y < 416-x*0.205) continue;
      const size = (y-228)*0.018;
      line([x,y, x+size*1.6,y-size*0.33], i%3 ? '#74766b' : '#f6f6f0', 0.5+random());
    }
    for (const d of [0.08,0.12,0.17,0.23,0.3,0.39,0.49,0.61,0.76,0.94,1.15,1.41]) {
      const x=1006-939*d, y=237+197*d;
      shape([x,y, x+563*d,y+74*d, x+549*d,y+81*d, x-16*d,y+6*d], '#5c5d53', ink, 1);
      line([x+2,y, x+557*d,y+73*d], '#e7e8df', 1);
    }
    for (const [bottom, depth] of [[-165,526],[522,526]]) {
      shape([1007,235, bottom,depth, bottom+18,depth, 1010,236], ink);
      line([1007,236, bottom+4,depth], '#efefea', 2.5);
    }
    for (let i=0; i<80; i++) {
      const x=random()*455, y=390-x*0.19+random()*8, s=2+random()*8;
      line([x-s*0.7,y-s*0.5, x,y, x+s*0.3,y-s, x+s*0.16,y-s*0.4], '#65695c', 0.85);
    }

    // Coastal power poles and catenary cables.
    for (const [x,y,s] of [[976,158,0.42],[895,110,0.72],[479,-24,1]]) {
      shape([x,y, x+5*s,y, x+12*s,y+338*s, x+5*s,y+339*s], '#64665d', ink, 1);
      line([x+1,y+2, x+7*s,y+335*s], '#dedfd5', 1.4*s);
      line([x-25*s,y+31*s, x+55*s,y+30*s, x+7*s,y+69*s], ink, 2.4*s);
      line([x+5*s,y+138*s, x+58*s,y+126*s], ink, 2*s);
      for (const dx of [-19,12,45]) {
        line([x+dx*s,y+28*s, x+dx*s,y+17*s], ink, 2*s);
        line([x+(dx-3)*s,y+21*s, x+(dx+3)*s,y+21*s], '#464840', 2*s);
      }
    }
    curve(407,-18,691,68,934,126,ink,1.6);
    curve(450,-12,708,79,1012,151,ink,1.3);
    curve(517,-8,725,57,1006,117,'#6a6c63',1);
    curve(575,-1,803,59,1013,96,ink,1.1);
    for (const [x,y] of [[702,62],[860,101],[954,125]]) line([x,y-15,x,y], '#67695f', 1);
    shape([468,390, 580,344, 987,246, 1050,264, 750,443, 588,422], '#4c4e46');

    // Receding carriage side with inset windows and door seams.
    for (const [x,y,s] of [[909,323,0.54],[948,302,0.42],[766,405,0.9],[808,380,0.78]]) {
      ellipse(x,y,13*s,19*s,black);
      ellipse(x-2*s,y,7.5*s,13*s,'#62665b');
      ellipse(x-2*s,y,3.5*s,5*s,black);
    }
    shape([772,391, 829,360, 826,371, 770,407], '#484c41', black);
    shape([754,118, 1008,197, 1008,273, 758,420, 736,411], '#c2c3b8', ink, 3);
    shape([762,124, 1008,198, 1008,212, 761,164], shade);
    shape([757,318, 1008,241, 1008,250, 757,348], '#393c35');
    shape([754,390, 1008,260, 1008,274, 750,424], '#33362f', ink);
    const top = x => 169 + (x-760)*0.174;
    const sill = x => 281 - (x-760)*0.164;
    for (const [start,end] of [[765,809],[815,849],[858,885],[889,913],[920,938],[943,962],[968,983],[987,1002]]) {
      shape([start,top(start), end,top(end), end,sill(end), start,sill(start)], black, '#f3f2ea', 2);
      shape([start+3,top(start)+4, end-3,top(end)+3, end-3,sill(end)-9, start+3,sill(start)-11], '#63675f');
      shape([start+4,top(start)+6, end-4,top(end)+5, start+5,sill(start)-16], '#c3c6ba');
      line([start+2,sill(start)-17, end-2,sill(end)-14], ink, 1.5);
    }
    for (const x of [811,853,916,965,986]) line([x,top(x)-9, x,sill(x)+85*(1010-x)/250], '#575b50', 1.4);
    line([762,305, 1006,238], paper, 2);
    shape([710,119, 759,107, 803,112, 1011,193, 1011,200, 755,135], '#8e9187', ink, 2);
    line([783,111, 1003,192], '#e5e6df', 1.7);
    shape([748,107, 763,91, 785,96, 873,129, 868,136], '#8b8d82', ink, 1.5);
    for (let x=782; x<858; x+=8) line([x,94+(x-780)*0.37, x-5,102+(x-780)*0.37], '#f1f2ea', 1.8);
    line([779,103, 752,83, 822,56, 788,92, 800,109], ink, 3.2);
    line([789,102, 762,84, 826,57, 796,93], '#60635a', 1.4);
    line([807,52, 843,62], black, 3);

    // The rounded cab, windshields, lamps and coupling.
    const cab = [527,145, 532,125, 545,114, 566,108, 700,107, 730,111, 749,122, 761,143, 766,170, 765,346, 759,380, 743,400, 723,410, 682,412, 557,397, 539,389, 532,374, 525,195];
    shape(cab, '#eeefe7', black, 3.8);
    shape([529,151, 540,128, 558,120, 703,119, 735,125, 752,146, 759,166, 757,148, 749,130, 734,117, 706,109, 562,110, 545,116, 533,129], '#818578');
    line([539,135, 553,125, 573,122, 710,122, 739,129], ink, 1.3);
    shape([528,264, 761,268, 760,296, 530,286], '#51564b', black, 1.4);
    shape([531,290, 759,300, 756,368, 745,384, 725,393, 550,376, 534,369], '#c6c9bc');
    shape([532,322, 757,338, 755,370, 745,384, 725,393, 551,377, 536,370], mist);
    shape([536,369, 554,378, 723,395, 746,385, 756,372, 750,391, 733,405, 718,410, 552,393, 539,385], '#45483e', ink, 1.7);
    function glass(points, x, y, w, h) {
      shape(points, '#969c90', black, 4.6);
      ctx.save();
      trace(points, true);
      ctx.clip();
      shape([x,y+h*0.63, x+w*0.28,y+h*0.48, x+w*0.58,y+h*0.61, x+w,y+h*0.43, x+w,y+h, x,y+h], '#555c51');
      shape([x+w*0.76,y-8, x+w,y-8, x+w*0.27,y+h+4, x+w*0.09,y+h+4], '#d8dbd0');
      line([x,y+h*0.75, x+w,y+h*0.73], '#34392f', 2);
      ctx.restore();
    }
    glass([543,166, 547,155, 555,151, 604,150, 604,248, 599,255, 545,250], 543,151,62,103);
    glass([621,163, 628,157, 655,157, 661,162, 663,247, 656,252, 623,249], 620,157,44,95);
    glass([677,150, 725,152, 738,157, 744,169, 747,249, 743,256, 678,253], 676,150,72,106);
    shape([709,238, 709,230, 713,224, 719,220, 717,214, 715,211, 716,205, 713,204, 715,200, 722,198, 729,200, 732,204, 729,207, 729,214, 727,218, 729,222, 737,226, 741,239], '#464b40');
    line([716,205, 727,203], '#c0c3b5', 1.2);
    line([610,146, 612,339, 616,363, 669,368, 673,348, 670,145, 663,138, 619,138, 610,146], ink, 2.2);
    line([617,281, 666,283], paper, 1.65);
    line([553,243, 582,218], ink, 2.1);
    line([685,246, 714,223], ink, 2.1);
    shape([620,127, 660,127, 663,138, 618,138], '#45493f', black, 1.2);
    for (const [x,y] of [[558,302],[728,312]]) {
      ellipse(x,y,11,9,black);
      ellipse(x-1,y-1,8,6.5,'#aaa999');
      ellipse(x-2,y-2,5,4.5,'#fffff7');
      line([x-6,y+6, x+5,y+6], '#eceee1', 1.3);
    }
    for (let i=0; i<4; i++) line([560,348+i*3, 594,350+i*3], '#656a5d', 1.15);
    line([658,307, 661,307, 661,317, 658,317], ink, 1.5);
    for (const [x,y] of [[540,359],[547,369],[589,374],[705,387],[742,374]]) ellipse(x,y,1.4,1.6,'#7c8073');
    shape([603,392, 618,386, 667,390, 677,402, 672,414, 653,419, 609,412], '#494c42', black, 2.2);
    shape([624,396, 649,398, 652,409, 643,414, 623,408], '#8f9386', ink, 2);
    curve(594,394,582,425,610,421,black,3);
    curve(681,402,685,431,703,411,black,2.6);
    for (let i=0; i<2100; i++) {
      ctx.fillStyle = i%2 ? 'rgba(35,38,31,0.10)' : 'rgba(255,255,246,0.23)';
      ctx.fillRect(random()*width, random()*height, 0.45+random()*1.3, 0.55);
    }
  }

  window.drawSeaside = drawSeaside;
  function drawAll() { document.querySelectorAll('canvas[data-seaside]').forEach(drawSeaside); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', drawAll, { once: true });
  else drawAll();
})();
