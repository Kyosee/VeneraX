// ImageScript v4.0.1 AVIF decoder. See LICENSE.txt and tool/avif/build.mjs.
(() => {
  var __defProp = Object.defineProperty;
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, {
        get: all[name],
        enumerable: true,
        configurable: true,
        set: (newValue) => all[name] = () => newValue
      });
  };

  // src/util/icc.ts
  var s15Fixed16 = (view, o) => view.getInt32(o) / 65536;
  function curve(view, o, size) {
    if (size < 12)
      return null;
    const type = view.getUint32(o);
    if (type === 1668641398) {
      const n = view.getUint32(o + 8);
      if (12 + n * 2 > size)
        return null;
      if (n === 0)
        return (v) => v;
      if (n === 1) {
        const gamma = view.getUint16(o + 12) / 256;
        return (v) => v ** gamma;
      }
      const table = new Float64Array(n);
      for (let i = 0;i < n; i++)
        table[i] = view.getUint16(o + 12 + i * 2) / 65535;
      return (v) => {
        const x = Math.min(1, Math.max(0, v)) * (n - 1), i = Math.min(n - 2, Math.floor(x));
        return table[i] + (table[i + 1] - table[i]) * (x - i);
      };
    }
    if (type === 1885434465) {
      const kind = view.getUint16(o + 8), counts = [1, 3, 4, 5, 7];
      if (kind > 4 || 12 + counts[kind] * 4 > size)
        return null;
      const p = Array.from({ length: counts[kind] }, (_, i) => s15Fixed16(view, o + 12 + i * 4));
      const [g, a, b, c, d, e, f] = p;
      switch (kind) {
        case 0:
          return (v) => v ** g;
        case 1:
          return (v) => v >= -b / a ? (a * v + b) ** g : 0;
        case 2:
          return (v) => v >= -b / a ? (a * v + b) ** g + c : c;
        case 3:
          return (v) => v >= d ? (a * v + b) ** g : c * v;
        default:
          return (v) => v >= d ? (a * v + b) ** g + e : c * v + f;
      }
    }
    return null;
  }
  function parseProfile(icc) {
    if (icc.length < 132)
      return null;
    const view = new DataView(icc.buffer, icc.byteOffset, icc.byteLength);
    const space = view.getUint32(16), pcs = view.getUint32(20);
    if (pcs !== 1482250784)
      return null;
    const gray = space === 1196573017;
    if (!gray && space !== 1380401696)
      return null;
    const tags = new Map;
    const count = view.getUint32(128);
    for (let i = 0;i < count && 132 + i * 12 + 12 <= icc.length; i++) {
      const e = 132 + i * 12, offset = view.getUint32(e + 4), size = view.getUint32(e + 8);
      if (offset + size <= icc.length)
        tags.set(String.fromCharCode(...icc.subarray(e, e + 4)), [offset, size]);
    }
    const curveOf = (tag) => {
      const t = tags.get(tag);
      return t ? curve(view, t[0], t[1]) : null;
    };
    if (gray) {
      const k = curveOf("kTRC");
      return k ? { gray, matrix: [], curves: [k] } : null;
    }
    const xyz = (tag) => {
      const t = tags.get(tag);
      if (!t || t[1] < 20 || view.getUint32(t[0]) !== 1482250784)
        return null;
      return [s15Fixed16(view, t[0] + 8), s15Fixed16(view, t[0] + 12), s15Fixed16(view, t[0] + 16)];
    };
    const r = xyz("rXYZ"), g = xyz("gXYZ"), b = xyz("bXYZ");
    const curves = [curveOf("rTRC"), curveOf("gTRC"), curveOf("bTRC")];
    if (!r || !g || !b || curves.some((c) => !c))
      return null;
    return { gray, matrix: [r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]], curves };
  }

  // src/util/limits.ts
  class LimitError extends RangeError {
    name = "LimitError";
  }
  var MAX_PIXELS = 16383 * 16383;
  var FRAME_PIXELS = 1024;
  function checkPixels(width, height, limit, count = 1) {
    const floor = count > 1 && width * height < FRAME_PIXELS;
    if (!((floor ? FRAME_PIXELS : width * height) * count <= limit))
      throw new LimitError(`Image too large: ${count > 1 ? `${count} frames of ` : ""}${width}x${height} pixels exceed the limit of ${limit}${floor ? ` (each frame counts at least ${FRAME_PIXELS})` : ""} (the decode options' maxPixels)`);
  }

  // src/codecs/av1/obu.ts
  /*!
   * AV1 open bitstream units: the sequence header, the frame headers of intra frames and the tile groups, ported from
   * dav1d (src/obu.c, src/getbits.c). Copyright (c) 2018-2019, VideoLAN and dav1d authors, BSD-2-Clause License (see
   * THIRD_PARTY_NOTICES.md)
   */

  class BitReader {
    data;
    end;
    pos;
    constructor(data, start, end) {
      this.data = data;
      this.end = end;
      this.pos = start * 8;
    }
    bit() {
      if (this.pos >= this.end * 8)
        throw new Error("AV1: truncated header");
      const v = this.data[this.pos >> 3] >> 7 - (this.pos & 7) & 1;
      this.pos++;
      return v;
    }
    bits(n) {
      let v = 0;
      for (let i = 0;i < n; i++)
        v = v * 2 + this.bit();
      return v;
    }
    sbits(n) {
      const v = this.bits(n + 1);
      return v >= 2 ** n ? v - 2 ** (n + 1) : v;
    }
    uvlc() {
      let zeros = 0;
      while (!this.bit())
        if (++zeros >= 32)
          return 4294967295;
      return 2 ** zeros - 1 + this.bits(zeros);
    }
    uniform(max) {
      let l = 0;
      while (2 ** l <= max)
        l++;
      const m = 2 ** l - max;
      const v = this.bits(l - 1);
      return v < m ? v : (v << 1) - m + this.bit();
    }
    leb128() {
      let v = 0;
      for (let i = 0;i < 8; i++) {
        const b = this.bits(8);
        v += (b & 127) * 2 ** (i * 7);
        if (!(b & 128))
          return v;
      }
      throw new Error("AV1: invalid leb128");
    }
    align() {
      this.pos = this.pos + 7 & ~7;
    }
    get byte() {
      return this.pos + 7 >> 3;
    }
  }
  var ADAPTIVE = 2;
  function parseSequenceHeader(r) {
    const profile = r.bits(3);
    if (profile > 2)
      throw new Error(`AV1: unsupported profile ${profile}`);
    r.bit();
    const reducedStillPicture = !!r.bit();
    const operatingPoints = [];
    let decoderModelInfo = false, equalPictureInterval = false, bufferDelayLength = 0, bufferRemovalDelayLength = 0, framePresentationDelayLength = 0;
    if (reducedStillPicture) {
      r.bits(5);
      operatingPoints.push({ idc: 0, decoderModel: false });
    } else {
      if (r.bit()) {
        r.bits(32);
        r.bits(32);
        equalPictureInterval = !!r.bit();
        if (equalPictureInterval)
          r.uvlc();
        decoderModelInfo = !!r.bit();
        if (decoderModelInfo) {
          bufferDelayLength = r.bits(5) + 1;
          r.bits(32);
          bufferRemovalDelayLength = r.bits(5) + 1;
          framePresentationDelayLength = r.bits(5) + 1;
        }
      }
      const displayModelInfo = !!r.bit();
      const count = r.bits(5) + 1;
      for (let i = 0;i < count; i++) {
        const idc = r.bits(12);
        const level = r.bits(5);
        if (level >> 2 > 1)
          r.bit();
        let decoderModel = false;
        if (decoderModelInfo && (decoderModel = !!r.bit())) {
          r.bits(bufferDelayLength);
          r.bits(bufferDelayLength);
          r.bit();
        }
        if (displayModelInfo && r.bit())
          r.bits(4);
        operatingPoints.push({ idc, decoderModel });
      }
    }
    const widthBits = r.bits(4) + 1, heightBits = r.bits(4) + 1;
    const maxWidth = r.bits(widthBits) + 1, maxHeight = r.bits(heightBits) + 1;
    let frameIdBits = 0, deltaFrameIdBits = 0;
    if (!reducedStillPicture && r.bit()) {
      deltaFrameIdBits = r.bits(4) + 2;
      frameIdBits = r.bits(3) + deltaFrameIdBits + 1;
    }
    const sb128 = !!r.bit(), filterIntra = !!r.bit(), intraEdgeFilter = !!r.bit();
    let screenContentTools = ADAPTIVE, forceIntegerMv = ADAPTIVE, orderHintBits = 0;
    if (!reducedStillPicture) {
      r.bit();
      r.bit();
      r.bit();
      r.bit();
      const orderHint = r.bit();
      if (orderHint) {
        r.bit();
        r.bit();
      }
      screenContentTools = r.bit() ? ADAPTIVE : r.bit();
      forceIntegerMv = screenContentTools ? r.bit() ? ADAPTIVE : r.bit() : ADAPTIVE;
      if (orderHint)
        orderHintBits = r.bits(3) + 1;
    }
    const superres = !!r.bit(), cdef = !!r.bit(), restoration = !!r.bit();
    let bitDepth = 8;
    if (r.bit())
      bitDepth = profile === 2 && r.bit() ? 12 : 10;
    const monochrome = profile !== 1 && !!r.bit();
    let colorPrimaries = 2, transferCharacteristics = 2, matrixCoefficients = 2;
    if (r.bit()) {
      colorPrimaries = r.bits(8);
      transferCharacteristics = r.bits(8);
      matrixCoefficients = r.bits(8);
    }
    let fullRange, ssx = 1, ssy = 1;
    if (monochrome)
      fullRange = !!r.bit();
    else if (colorPrimaries === 1 && transferCharacteristics === 13 && matrixCoefficients === 0) {
      fullRange = true;
      ssx = ssy = 0;
    } else {
      fullRange = !!r.bit();
      if (profile === 1)
        ssx = ssy = 0;
      else if (profile === 2) {
        if (bitDepth === 12) {
          ssx = r.bit();
          ssy = ssx ? r.bit() : 0;
        } else
          ssy = 0;
      }
      if (ssx && ssy)
        r.bits(2);
    }
    const separateUvDeltaQ = !monochrome && !!r.bit();
    const filmGrain = !!r.bit();
    return {
      profile,
      reducedStillPicture,
      maxWidth,
      maxHeight,
      widthBits,
      heightBits,
      frameIdBits,
      deltaFrameIdBits,
      decoderModelInfo,
      equalPictureInterval,
      bufferRemovalDelayLength,
      framePresentationDelayLength,
      operatingPoints,
      sb128,
      filterIntra,
      intraEdgeFilter,
      screenContentTools,
      forceIntegerMv,
      orderHintBits,
      superres,
      cdef,
      restoration,
      bitDepth,
      monochrome,
      colorPrimaries,
      transferCharacteristics,
      matrixCoefficients,
      fullRange,
      ssx,
      ssy,
      separateUvDeltaQ,
      filmGrain
    };
  }
  var FRAME_KEY = 0;
  var FRAME_INTRA_ONLY = 2;

  class InterFrameError extends Error {
  }
  var RESTORATION_NONE = 0;
  var RESTORATION_SWITCHABLE = 1;
  var RESTORATION_WIENER = 2;
  var RESTORATION_SGRPROJ = 3;
  var tileLog2 = (size, target) => {
    let k = 0;
    while (size << k < target)
      k++;
    return k;
  };
  function parseFrameHeader(r, seq, temporalId, spatialId) {
    const reduced = seq.reducedStillPicture;
    const showExistingFrame = !reduced && !!r.bit();
    const header = { showExistingFrame };
    if (showExistingFrame) {
      header.existingFrameIdx = r.bits(3);
      if (seq.decoderModelInfo && !seq.equalPictureInterval)
        r.bits(seq.framePresentationDelayLength);
      if (seq.frameIdBits)
        r.bits(seq.frameIdBits);
      return header;
    }
    const frameType = reduced ? FRAME_KEY : r.bits(2);
    if (frameType !== FRAME_KEY && frameType !== FRAME_INTRA_ONLY)
      throw new InterFrameError("AV1: inter frames are not supported");
    const showFrame = reduced || !!r.bit();
    let showable = false;
    if (showFrame) {
      if (seq.decoderModelInfo && !seq.equalPictureInterval)
        r.bits(seq.framePresentationDelayLength);
    } else
      showable = !!r.bit();
    const errorResilient = frameType === FRAME_KEY && showFrame || reduced || !!r.bit();
    const disableCdfUpdate = !!r.bit();
    const allowScreenContentTools = !!(seq.screenContentTools === ADAPTIVE ? r.bit() : seq.screenContentTools);
    if (allowScreenContentTools && seq.forceIntegerMv === ADAPTIVE)
      r.bit();
    if (seq.frameIdBits)
      r.bits(seq.frameIdBits);
    const frameSizeOverride = !reduced && !!r.bit();
    if (seq.orderHintBits)
      r.bits(seq.orderHintBits);
    if (seq.decoderModelInfo && r.bit()) {
      for (const op of seq.operatingPoints) {
        if (!op.decoderModel)
          continue;
        const inTemporal = op.idc >> temporalId & 1, inSpatial = op.idc >> spatialId + 8 & 1;
        if (!op.idc || inTemporal && inSpatial)
          r.bits(seq.bufferRemovalDelayLength);
      }
    }
    const refreshFrameFlags = frameType === FRAME_KEY && showFrame ? 255 : r.bits(8);
    if (refreshFrameFlags !== 255 && errorResilient && seq.orderHintBits)
      for (let i = 0;i < 8; i++)
        r.bits(seq.orderHintBits);
    let { maxWidth: upscaledWidth, maxHeight: height } = seq;
    if (frameSizeOverride) {
      upscaledWidth = r.bits(seq.widthBits) + 1;
      height = r.bits(seq.heightBits) + 1;
    }
    let superresDenominator = 8, width = upscaledWidth;
    if (seq.superres && r.bit()) {
      superresDenominator = 9 + r.bits(3);
      width = Math.max(Math.floor((upscaledWidth * 8 + (superresDenominator >> 1)) / superresDenominator), Math.min(16, upscaledWidth));
    }
    if (r.bit()) {
      r.bits(16);
      r.bits(16);
    }
    const allowIntrabc = allowScreenContentTools && superresDenominator === 8 && !!r.bit();
    if (!reduced && !disableCdfUpdate)
      r.bit();
    const uniform = r.bit();
    const sbLog2 = seq.sb128 ? 7 : 6;
    const sbw = width + (1 << sbLog2) - 1 >> sbLog2, sbh = height + (1 << sbLog2) - 1 >> sbLog2;
    const maxTileWidthSb = 4096 >> sbLog2;
    let maxTileAreaSb = 4096 * 2304 >> 2 * sbLog2;
    const minLog2Cols = tileLog2(maxTileWidthSb, sbw);
    const maxLog2Cols = tileLog2(1, Math.min(sbw, 64)), maxLog2Rows = tileLog2(1, Math.min(sbh, 64));
    const minLog2Tiles = Math.max(tileLog2(maxTileAreaSb, sbw * sbh), minLog2Cols);
    const colStarts = [], rowStarts = [];
    let log2Cols, log2Rows;
    if (uniform) {
      for (log2Cols = minLog2Cols;log2Cols < maxLog2Cols && r.bit(); log2Cols++)
        ;
      const tileW = 1 + (sbw - 1 >> log2Cols);
      for (let x = 0;x < sbw; x += tileW)
        colStarts.push(x);
      const minLog2Rows = Math.max(minLog2Tiles - log2Cols, 0);
      for (log2Rows = minLog2Rows;log2Rows < maxLog2Rows && r.bit(); log2Rows++)
        ;
      const tileH = 1 + (sbh - 1 >> log2Rows);
      for (let y = 0;y < sbh; y += tileH)
        rowStarts.push(y);
    } else {
      let widest = 0;
      for (let x = 0;x < sbw && colStarts.length < 64; ) {
        const size = Math.min(sbw - x, maxTileWidthSb);
        const w = size > 1 ? 1 + r.uniform(size) : 1;
        colStarts.push(x);
        x += w;
        widest = Math.max(widest, w);
      }
      log2Cols = tileLog2(1, colStarts.length);
      maxTileAreaSb = sbw * sbh;
      if (minLog2Tiles)
        maxTileAreaSb >>= minLog2Tiles + 1;
      const maxTileHeightSb = Math.max(Math.floor(maxTileAreaSb / widest), 1);
      for (let y = 0;y < sbh && rowStarts.length < 64; ) {
        const size = Math.min(sbh - y, maxTileHeightSb);
        const h = size > 1 ? 1 + r.uniform(size) : 1;
        rowStarts.push(y);
        y += h;
      }
      log2Rows = tileLog2(1, rowStarts.length);
    }
    const cols = colStarts.length, rows = rowStarts.length;
    colStarts.push(sbw);
    rowStarts.push(sbh);
    let contextUpdateId = 0, sizeBytes = 0;
    if (log2Cols || log2Rows) {
      contextUpdateId = r.bits(log2Cols + log2Rows);
      if (contextUpdateId >= cols * rows)
        throw new Error("AV1: invalid tile info");
      sizeBytes = r.bits(2) + 1;
    }
    const delta = () => r.bit() ? r.sbits(6) : 0;
    const yac = r.bits(8), ydcDelta = delta();
    let udcDelta = 0, uacDelta = 0, vdcDelta = 0, vacDelta = 0;
    if (!seq.monochrome) {
      const diffUv = seq.separateUvDeltaQ && !!r.bit();
      udcDelta = delta();
      uacDelta = delta();
      if (diffUv) {
        vdcDelta = delta();
        vacDelta = delta();
      } else {
        vdcDelta = udcDelta;
        vacDelta = uacDelta;
      }
    }
    const qm = !!r.bit();
    let qmY = 15, qmU = 15, qmV = 15;
    if (qm) {
      qmY = r.bits(4);
      qmU = r.bits(4);
      qmV = seq.separateUvDeltaQ ? r.bits(4) : qmU;
    }
    const segmentData = [];
    const enabled = !!r.bit();
    let preskip = false, lastActiveSegId = -1;
    for (let i = 0;i < 8; i++) {
      const seg = { deltaQ: 0, deltaLf: [0, 0, 0, 0], ref: -1, skip: false, globalMv: false };
      if (enabled) {
        if (r.bit()) {
          seg.deltaQ = r.sbits(8);
          lastActiveSegId = i;
        }
        for (let k = 0;k < 4; k++)
          if (r.bit()) {
            seg.deltaLf[k] = r.sbits(6);
            lastActiveSegId = i;
          }
        if (r.bit()) {
          seg.ref = r.bits(3);
          lastActiveSegId = i;
          preskip = true;
        }
        if (seg.skip = !!r.bit()) {
          lastActiveSegId = i;
          preskip = true;
        }
        if (seg.globalMv = !!r.bit()) {
          lastActiveSegId = i;
          preskip = true;
        }
      }
      segmentData.push(seg);
    }
    const deltaQPresent = yac ? !!r.bit() : false;
    const deltaQResLog2 = deltaQPresent ? r.bits(2) : 0;
    const deltaLfPresent = deltaQPresent && !allowIntrabc && !!r.bit();
    const deltaLfResLog2 = deltaLfPresent ? r.bits(2) : 0;
    const deltaLfMulti = deltaLfPresent && !!r.bit();
    const deltaLossless = !ydcDelta && !udcDelta && !uacDelta && !vdcDelta && !vacDelta;
    const qidx = [], lossless = [];
    let allLossless = true;
    for (let i = 0;i < 8; i++) {
      qidx.push(enabled ? Math.min(255, Math.max(0, yac + segmentData[i].deltaQ)) : yac);
      lossless.push(!qidx[i] && deltaLossless);
      allLossless &&= lossless[i];
    }
    const loopFilter = { levelY: [0, 0], levelU: 0, levelV: 0, sharpness: 0, modeRefDeltaEnabled: true, refDeltas: [1, 0, 0, 0, -1, 0, -1, -1], modeDeltas: [0, 0] };
    if (!allLossless && !allowIntrabc) {
      loopFilter.levelY = [r.bits(6), r.bits(6)];
      if (!seq.monochrome && (loopFilter.levelY[0] || loopFilter.levelY[1])) {
        loopFilter.levelU = r.bits(6);
        loopFilter.levelV = r.bits(6);
      }
      loopFilter.sharpness = r.bits(3);
      loopFilter.modeRefDeltaEnabled = !!r.bit();
      if (loopFilter.modeRefDeltaEnabled && r.bit()) {
        for (let i = 0;i < 8; i++)
          if (r.bit())
            loopFilter.refDeltas[i] = r.sbits(6);
        for (let i = 0;i < 2; i++)
          if (r.bit())
            loopFilter.modeDeltas[i] = r.sbits(6);
      }
    }
    const cdef = { damping: 3, bits: 0, yStrengths: [0], uvStrengths: [0] };
    if (!allLossless && seq.cdef && !allowIntrabc) {
      cdef.damping = r.bits(2) + 3;
      cdef.bits = r.bits(2);
      cdef.yStrengths = [];
      cdef.uvStrengths = [];
      for (let i = 0;i < 1 << cdef.bits; i++) {
        cdef.yStrengths.push(r.bits(6));
        cdef.uvStrengths.push(seq.monochrome ? 0 : r.bits(6));
      }
    }
    const restoration = { types: [RESTORATION_NONE, RESTORATION_NONE, RESTORATION_NONE], unitSizeLog2: [8, 8] };
    if ((!allLossless || superresDenominator !== 8) && seq.restoration && !allowIntrabc) {
      restoration.types[0] = r.bits(2);
      if (!seq.monochrome) {
        restoration.types[1] = r.bits(2);
        restoration.types[2] = r.bits(2);
      }
      if (restoration.types.some((t) => t)) {
        let size = 6 + (seq.sb128 ? 1 : 0);
        if (r.bit()) {
          size++;
          if (!seq.sb128)
            size += r.bit();
        }
        restoration.unitSizeLog2 = [size, size];
        if ((restoration.types[1] || restoration.types[2]) && seq.ssx && seq.ssy)
          restoration.unitSizeLog2[1] -= r.bit();
      }
    }
    const txMode = allLossless ? 0 : r.bit() ? 2 : 1;
    const reducedTxSet = !!r.bit();
    let filmGrain = null;
    if (seq.filmGrain && (showFrame || showable) && r.bit()) {
      const seed = r.bits(16);
      const yPoints = [];
      const numY = r.bits(4);
      if (numY > 14)
        throw new Error("AV1: invalid film grain");
      for (let i = 0;i < numY; i++) {
        yPoints.push([r.bits(8), r.bits(8)]);
        if (i && yPoints[i - 1][0] >= yPoints[i][0])
          throw new Error("AV1: invalid film grain");
      }
      const chromaScalingFromLuma = !seq.monochrome && !!r.bit();
      const uvPoints = [[], []];
      if (!seq.monochrome && !chromaScalingFromLuma && !(seq.ssx && seq.ssy && !numY)) {
        for (let pl = 0;pl < 2; pl++) {
          const n = r.bits(4);
          if (n > 10)
            throw new Error("AV1: invalid film grain");
          for (let i = 0;i < n; i++) {
            uvPoints[pl].push([r.bits(8), r.bits(8)]);
            if (i && uvPoints[pl][i - 1][0] >= uvPoints[pl][i][0])
              throw new Error("AV1: invalid film grain");
          }
        }
      }
      if (seq.ssx && seq.ssy && !uvPoints[0].length !== !uvPoints[1].length)
        throw new Error("AV1: invalid film grain");
      const scalingShift = r.bits(2) + 8;
      const arCoeffLag = r.bits(2);
      const numPos = 2 * arCoeffLag * (arCoeffLag + 1);
      const arCoeffsY = [];
      for (let i = 0;i < numPos; i++)
        arCoeffsY.push(numY ? r.bits(8) - 128 : 0);
      const arCoeffsUv = [[], []];
      for (let pl = 0;pl < 2; pl++) {
        if (uvPoints[pl].length || chromaScalingFromLuma) {
          const n = numPos + (numY ? 1 : 0);
          for (let i = 0;i < n; i++)
            arCoeffsUv[pl].push(r.bits(8) - 128);
          if (!numY)
            arCoeffsUv[pl].push(0);
        }
      }
      const arCoeffShift = r.bits(2) + 6;
      const grainScaleShift = r.bits(2);
      const uvMult = [0, 0], uvLumaMult = [0, 0], uvOffset = [0, 0];
      for (let pl = 0;pl < 2; pl++) {
        if (uvPoints[pl].length) {
          uvMult[pl] = r.bits(8) - 128;
          uvLumaMult[pl] = r.bits(8) - 128;
          uvOffset[pl] = r.bits(9) - 256;
        }
      }
      const overlap = !!r.bit(), clipToRestrictedRange = !!r.bit();
      filmGrain = {
        seed,
        yPoints,
        chromaScalingFromLuma,
        uvPoints,
        scalingShift,
        arCoeffLag,
        arCoeffsY,
        arCoeffsUv,
        arCoeffShift,
        grainScaleShift,
        uvMult,
        uvLumaMult,
        uvOffset,
        overlap,
        clipToRestrictedRange
      };
    }
    return Object.assign(header, {
      existingFrameIdx: 0,
      frameType,
      showFrame,
      refreshFrameFlags,
      disableCdfUpdate,
      allowScreenContentTools,
      allowIntrabc,
      width,
      upscaledWidth,
      height,
      superresDenominator,
      tiles: { cols, rows, log2Cols, log2Rows, colStarts, rowStarts, contextUpdateId, sizeBytes },
      quant: { yac, ydcDelta, udcDelta, uacDelta, vdcDelta, vacDelta, qm, qmY, qmU, qmV },
      segmentation: { enabled, updateMap: enabled, data: segmentData, preskip, lastActiveSegId, qidx, lossless },
      allLossless,
      deltaQ: { present: deltaQPresent, resLog2: deltaQResLog2 },
      deltaLf: { present: deltaLfPresent, resLog2: deltaLfResLog2, multi: deltaLfMulti },
      loopFilter,
      cdef,
      restoration,
      txMode,
      reducedTxSet,
      filmGrain
    });
  }
  var OBU_SEQUENCE_HEADER = 1;
  var OBU_TEMPORAL_DELIMITER = 2;
  var OBU_FRAME_HEADER = 3;
  var OBU_TILE_GROUP = 4;
  var OBU_FRAME = 6;
  var OBU_REDUNDANT_FRAME_HEADER = 7;
  function* obus(data, start = 0, end = data.length) {
    let o = start;
    while (o < end) {
      const r = new BitReader(data, o, end);
      r.bit();
      const type = r.bits(4);
      const extension = r.bit(), hasSize = r.bit();
      r.bit();
      let temporalId = 0, spatialId = 0;
      if (extension) {
        temporalId = r.bits(3);
        spatialId = r.bits(2);
        r.bits(3);
      }
      const size = hasSize ? r.leb128() : end - r.byte;
      const payload = r.byte;
      if (payload + size > end)
        throw new Error("AV1: truncated OBU");
      yield { type, temporalId, spatialId, start: payload, end: payload + size };
      o = payload + size;
    }
  }

  // src/codecs/av1/msac.ts
  /*!
   * The AV1 symbol decoder (a multi-symbol arithmetic decoder with adapting CDFs), ported from dav1d (src/msac.c).
   * Copyright (c) 2018-2021, VideoLAN and dav1d authors, Copyright (c) 2018, Two Orioles, LLC, BSD-2-Clause License
   * (see THIRD_PARTY_NOTICES.md)
   */
  var PROB_SHIFT = 6;
  var MIN_PROB = 4;
  var WIN = 32;

  class SymbolDecoder {
    data;
    end;
    allowUpdate;
    pos;
    dif = 0;
    rng = 32768;
    cnt = -15;
    constructor(data, start, end, allowUpdate) {
      this.data = data;
      this.end = end;
      this.allowUpdate = allowUpdate;
      this.pos = start;
      this.refill();
    }
    refill() {
      let c = WIN - this.cnt - 24;
      let dif = this.dif;
      do {
        if (this.pos >= this.end) {
          dif = (dif | ~(~255 << c)) >>> 0;
          break;
        }
        dif = (dif | (this.data[this.pos++] ^ 255) << c) >>> 0;
        c -= 8;
      } while (c >= 0);
      this.dif = dif;
      this.cnt = WIN - c - 24;
    }
    norm(dif, rng) {
      const d = 15 ^ (31 ^ Math.clz32(rng));
      const cnt = this.cnt;
      this.dif = dif << d >>> 0;
      this.rng = rng << d;
      this.cnt = cnt - d;
      if (cnt >= 0 && cnt < d)
        this.refill();
    }
    bool() {
      const r = this.rng;
      let dif = this.dif;
      let v = (r >> 8 << 7) + MIN_PROB;
      const vw = v * 65536;
      const ret = dif >= vw ? 1 : 0;
      if (ret) {
        dif -= vw;
        v = r - v;
      }
      this.norm(dif, v);
      return ret ^ 1;
    }
    boolProb(f) {
      const r = this.rng;
      let dif = this.dif;
      let v = ((r >> 8) * (f >> PROB_SHIFT) >> 7 - PROB_SHIFT) + MIN_PROB;
      const vw = v * 65536;
      const ret = dif >= vw ? 1 : 0;
      if (ret) {
        dif -= vw;
        v = r - v;
      }
      this.norm(dif, v);
      return ret ^ 1;
    }
    bools(n) {
      let v = 0;
      while (n--)
        v = v << 1 | this.bool();
      return v;
    }
    uniform(n) {
      const l = 32 - Math.clz32(n);
      const m = (1 << l) - n;
      const v = this.bools(l - 1);
      return v < m ? v : (v << 1) - m + this.bool();
    }
    symbol(cdf, o, n) {
      const c = this.dif >>> 16, r = this.rng >> 8;
      let u, v = this.rng, val = -1;
      do {
        val++;
        u = v;
        v = r * (cdf[o + val] >> PROB_SHIFT) >> 7 - PROB_SHIFT;
        v += MIN_PROB * (n - val);
      } while (c < v);
      this.norm(this.dif - v * 65536, u - v);
      if (this.allowUpdate) {
        const count = cdf[o + n];
        const rate = 4 + (count >> 4) + (n > 2 ? 1 : 0);
        let i = 0;
        for (;i < val; i++)
          cdf[o + i] += 32768 - cdf[o + i] >> rate;
        for (;i < n; i++)
          cdf[o + i] -= cdf[o + i] >> rate;
        cdf[o + n] = count + (count < 32 ? 1 : 0);
      }
      return val;
    }
    boolAdapt(cdf, o) {
      const bit = this.boolProb(cdf[o]);
      if (this.allowUpdate) {
        const count = cdf[o + 1];
        const rate = 4 + (count >> 4);
        if (bit)
          cdf[o] += 32768 - cdf[o] >> rate;
        else
          cdf[o] -= cdf[o] >> rate;
        cdf[o + 1] = count + (count < 32 ? 1 : 0);
      }
      return bit;
    }
    hiTok(cdf, o) {
      let br = this.symbol(cdf, o, 3);
      let tok = 3 + br;
      if (br === 3) {
        br = this.symbol(cdf, o, 3);
        tok = 6 + br;
        if (br === 3) {
          br = this.symbol(cdf, o, 3);
          tok = 9 + br;
          if (br === 3)
            tok = 12 + this.symbol(cdf, o, 3);
        }
      }
      return tok;
    }
    golomb() {
      let len = 0;
      while (!this.bool() && len < 32)
        len++;
      let v = 1;
      while (len--)
        v = v * 2 + this.bool();
      return v - 1;
    }
    subexp(ref, n, k) {
      let a = 0;
      if (this.bool()) {
        if (this.bool())
          k += this.bool() + 1;
        a = 1 << k;
      }
      const v = this.bools(k) + a;
      return ref * 2 <= n ? inverseRecenter(ref, v) : n - 1 - inverseRecenter(n - 1 - ref, v);
    }
    get overread() {
      return this.cnt <= -15;
    }
  }
  function inverseRecenter(r, v) {
    if (v > r << 1)
      return v;
    return v & 1 ? r - (v + 1 >> 1) : r + (v >> 1);
  }

  // src/codecs/av1/data.ts
  var exports_data = {};
  __export(exports_data, {
    TX_TYPE_CLASS: () => TX_TYPE_CLASS,
    TX_TYPES_PER_SET: () => TX_TYPES_PER_SET,
    TXTP_FROM_UVMODE: () => TXTP_FROM_UVMODE,
    TXFM_DIMENSIONS: () => TXFM_DIMENSIONS,
    SM_WEIGHTS: () => SM_WEIGHTS,
    SKIP_CTX: () => SKIP_CTX,
    SGR_X_BY_X: () => SGR_X_BY_X,
    SGR_PARAMS: () => SGR_PARAMS,
    SCAN_OFFSETS: () => SCAN_OFFSETS,
    RESIZE_FILTER: () => RESIZE_FILTER,
    PARTITION_TYPE_COUNT: () => PARTITION_TYPE_COUNT,
    PACKED_AT: () => PACKED_AT,
    PACKED: () => PACKED,
    MAX_TXFM_SIZE_FOR_BS: () => MAX_TXFM_SIZE_FOR_BS,
    LO_CTX_OFFSETS: () => LO_CTX_OFFSETS,
    INTRA_MODE_CONTEXT: () => INTRA_MODE_CONTEXT,
    FILTER_MODE_TO_Y_MODE: () => FILTER_MODE_TO_Y_MODE,
    FILTER_INTRA_TAPS: () => FILTER_INTRA_TAPS,
    DR_INTRA_DERIVATIVE: () => DR_INTRA_DERIVATIVE,
    CDF: () => CDF,
    CDEF_DIRECTIONS: () => CDEF_DIRECTIONS,
    BLOCK_SIZES: () => BLOCK_SIZES,
    BLOCK_DIMENSIONS: () => BLOCK_DIMENSIONS,
    AL_PART_CTX: () => AL_PART_CTX
  });
  /*!
   * Generated by scripts/av1-tables.c from dav1d, don't edit. Copyright (c) 2018-2021, VideoLAN and dav1d authors,
   * Copyright (c) 2018, Two Orioles, LLC, BSD-2-Clause License (see THIRD_PARTY_NOTICES.md)
   */
  var CDF = {
    kfYMode: 0,
    uvMode: 400,
    partition: 816,
    cflAlpha: 1136,
    txtpIntra1: 1232,
    txtpIntra2: 1440,
    cflSign: 1752,
    angleDelta: 1760,
    filterIntra: 1824,
    segId: 1832,
    palSize: 1856,
    colorMap: 1968,
    txSize: 2528,
    deltaQ: 2576,
    deltaLf: 2580,
    restoreSwitchable: 2600,
    restoreWiener: 2604,
    restoreSgrproj: 2606,
    useFilterIntra: 2608,
    skip: 2652,
    palY: 2658,
    palUv: 2700,
    intrabc: 2704,
    txPart: 2706,
    txtpInter1: 2748,
    txtpInter2: 2780,
    txtpInter3: 2796,
    mvJoint: 2804,
    mvClasses0: 2808,
    mvSign0: 2824,
    mvClass00: 2826,
    mvClassN0: 2828,
    mvClasses1: 2848,
    mvSign1: 2864,
    mvClass01: 2866,
    mvClassN1: 2868,
    eobBin16: 2888,
    eobBin32: 2920,
    eobBin64: 2952,
    eobBin128: 2984,
    eobBin256: 3016,
    eobBin512: 3080,
    eobBin1024: 3112,
    eobBaseTok: 3144,
    baseTok: 3304,
    brTok: 4944,
    eobHiBit: 5616,
    coefSkip: 5836,
    dcSign: 5966,
    size: 5978
  };
  var SCAN_OFFSETS = [0, 16, 80, 336, 1360, 2384, 2416, 2448, 2576, 2704, 3216, 3728, 4752, 5776, 5840, 5904, 6160, 6416, 6928];
  var AL_PART_CTX = [
    0,
    0,
    16,
    255,
    0,
    16,
    16,
    16,
    255,
    255,
    16,
    16,
    24,
    255,
    16,
    24,
    24,
    24,
    16,
    28,
    24,
    24,
    28,
    255,
    24,
    28,
    28,
    28,
    24,
    30,
    28,
    28,
    30,
    255,
    28,
    30,
    30,
    30,
    28,
    31,
    30,
    30,
    31,
    31,
    255,
    255,
    255,
    255,
    255,
    255,
    0,
    16,
    0,
    255,
    16,
    16,
    0,
    16,
    255,
    255,
    16,
    24,
    16,
    255,
    24,
    24,
    16,
    24,
    28,
    16,
    24,
    28,
    24,
    255,
    28,
    28,
    24,
    28,
    30,
    24,
    28,
    30,
    28,
    255,
    30,
    30,
    28,
    30,
    31,
    28,
    30,
    31,
    30,
    31,
    255,
    255,
    255,
    255,
    255,
    255
  ];
  var BLOCK_SIZES = [
    0,
    0,
    1,
    0,
    2,
    0,
    0,
    0,
    3,
    1,
    1,
    3,
    3,
    2,
    2,
    3,
    0,
    0,
    0,
    0,
    3,
    0,
    4,
    0,
    6,
    0,
    0,
    0,
    7,
    4,
    4,
    7,
    7,
    6,
    6,
    7,
    5,
    0,
    10,
    0,
    7,
    0,
    8,
    0,
    11,
    0,
    0,
    0,
    12,
    8,
    8,
    12,
    12,
    11,
    11,
    12,
    9,
    0,
    15,
    0,
    12,
    0,
    13,
    0,
    16,
    0,
    0,
    0,
    17,
    13,
    13,
    17,
    17,
    16,
    16,
    17,
    14,
    0,
    19,
    0,
    17,
    0,
    18,
    0,
    20,
    0,
    21,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0
  ];
  var BLOCK_DIMENSIONS = [
    32,
    32,
    5,
    5,
    32,
    16,
    5,
    4,
    16,
    32,
    4,
    5,
    16,
    16,
    4,
    4,
    16,
    8,
    4,
    3,
    16,
    4,
    4,
    2,
    8,
    16,
    3,
    4,
    8,
    8,
    3,
    3,
    8,
    4,
    3,
    2,
    8,
    2,
    3,
    1,
    4,
    16,
    2,
    4,
    4,
    8,
    2,
    3,
    4,
    4,
    2,
    2,
    4,
    2,
    2,
    1,
    4,
    1,
    2,
    0,
    2,
    8,
    1,
    3,
    2,
    4,
    1,
    2,
    2,
    2,
    1,
    1,
    2,
    1,
    1,
    0,
    1,
    4,
    0,
    2,
    1,
    2,
    0,
    1,
    1,
    1,
    0,
    0
  ];
  var TXFM_DIMENSIONS = [
    1,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
    2,
    2,
    1,
    1,
    1,
    1,
    0,
    1,
    4,
    4,
    2,
    2,
    2,
    2,
    1,
    2,
    8,
    8,
    3,
    3,
    3,
    3,
    2,
    3,
    16,
    16,
    4,
    4,
    4,
    4,
    3,
    4,
    1,
    2,
    0,
    1,
    0,
    1,
    0,
    1,
    2,
    1,
    1,
    0,
    0,
    1,
    0,
    1,
    2,
    4,
    1,
    2,
    1,
    2,
    1,
    2,
    4,
    2,
    2,
    1,
    1,
    2,
    1,
    2,
    4,
    8,
    2,
    3,
    2,
    3,
    2,
    3,
    8,
    4,
    3,
    2,
    2,
    3,
    2,
    3,
    8,
    16,
    3,
    4,
    3,
    4,
    3,
    4,
    16,
    8,
    4,
    3,
    3,
    4,
    3,
    4,
    1,
    4,
    0,
    2,
    0,
    2,
    5,
    1,
    4,
    1,
    2,
    0,
    0,
    2,
    6,
    1,
    2,
    8,
    1,
    3,
    1,
    3,
    7,
    2,
    8,
    2,
    3,
    1,
    1,
    3,
    8,
    2,
    4,
    16,
    2,
    4,
    2,
    4,
    9,
    3,
    16,
    4,
    4,
    2,
    2,
    4,
    10,
    3
  ];
  var MAX_TXFM_SIZE_FOR_BS = [
    4,
    3,
    3,
    3,
    4,
    3,
    3,
    3,
    4,
    3,
    0,
    3,
    4,
    3,
    3,
    3,
    12,
    10,
    3,
    3,
    18,
    16,
    10,
    10,
    11,
    9,
    0,
    3,
    3,
    2,
    9,
    3,
    10,
    8,
    2,
    10,
    16,
    14,
    8,
    16,
    17,
    15,
    0,
    9,
    9,
    7,
    0,
    9,
    2,
    1,
    7,
    2,
    8,
    6,
    1,
    8,
    14,
    6,
    6,
    14,
    15,
    13,
    0,
    15,
    7,
    5,
    0,
    7,
    1,
    0,
    5,
    1,
    6,
    0,
    0,
    6,
    13,
    5,
    0,
    13,
    5,
    0,
    0,
    5,
    0,
    0,
    0,
    0
  ];
  var TXTP_FROM_UVMODE = [0, 1, 2, 0, 3, 1, 2, 2, 1, 3, 1, 2, 3, 0];
  var PARTITION_TYPE_COUNT = [7, 9, 9, 9, 3];
  var TX_TYPES_PER_SET = [
    9,
    0,
    3,
    1,
    2,
    9,
    0,
    10,
    11,
    3,
    1,
    2,
    9,
    10,
    11,
    0,
    1,
    2,
    4,
    5,
    3,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
    0,
    1,
    2,
    4,
    5,
    3,
    6,
    7,
    8
  ];
  var FILTER_MODE_TO_Y_MODE = [0, 1, 2, 6, 0];
  var LO_CTX_OFFSETS = [
    0,
    1,
    6,
    6,
    21,
    1,
    6,
    6,
    21,
    21,
    6,
    6,
    21,
    21,
    21,
    6,
    21,
    21,
    21,
    21,
    21,
    21,
    21,
    21,
    21,
    0,
    16,
    6,
    6,
    21,
    16,
    16,
    6,
    21,
    21,
    16,
    16,
    21,
    21,
    21,
    16,
    16,
    21,
    21,
    21,
    16,
    16,
    21,
    21,
    21,
    0,
    11,
    11,
    11,
    11,
    11,
    11,
    11,
    11,
    11,
    6,
    6,
    21,
    21,
    21,
    6,
    21,
    21,
    21,
    21,
    21,
    21,
    21,
    21,
    21
  ];
  var SKIP_CTX = [1, 2, 2, 2, 3, 2, 4, 4, 4, 5, 2, 4, 4, 4, 5, 2, 4, 4, 4, 5, 3, 5, 5, 5, 6];
  var TX_TYPE_CLASS = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 1, 2, 1, 0];
  var INTRA_MODE_CONTEXT = [0, 1, 2, 3, 4, 4, 4, 4, 3, 0, 1, 2, 0];
  var CDEF_DIRECTIONS = [12, 24, 12, 23, -11, -22, 1, -10, 1, 2, 1, 14, 13, 26, 12, 25, 12, 24, 12, 23, -11, -22, 1, -10];
  var SGR_PARAMS = [140, 3236, 112, 2158, 93, 1618, 80, 1438, 70, 1295, 58, 1177, 47, 1079, 37, 996, 30, 925, 25, 863, 0, 2589, 0, 1618, 0, 1177, 0, 925, 56, 0, 22, 0];
  var SGR_X_BY_X = [
    255,
    128,
    85,
    64,
    51,
    43,
    37,
    32,
    28,
    26,
    23,
    21,
    20,
    18,
    17,
    16,
    15,
    14,
    13,
    13,
    12,
    12,
    11,
    11,
    10,
    10,
    9,
    9,
    9,
    9,
    8,
    8,
    8,
    8,
    7,
    7,
    7,
    7,
    7,
    6,
    6,
    6,
    6,
    6,
    6,
    6,
    5,
    5,
    5,
    5,
    5,
    5,
    5,
    5,
    5,
    5,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    4,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    3,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    2,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    1,
    0
  ];
  var SM_WEIGHTS = [
    0,
    0,
    255,
    128,
    255,
    149,
    85,
    64,
    255,
    197,
    146,
    105,
    73,
    50,
    37,
    32,
    255,
    225,
    196,
    170,
    145,
    123,
    102,
    84,
    68,
    54,
    43,
    33,
    26,
    20,
    17,
    16,
    255,
    240,
    225,
    210,
    196,
    182,
    169,
    157,
    145,
    133,
    122,
    111,
    101,
    92,
    83,
    74,
    66,
    59,
    52,
    45,
    39,
    34,
    29,
    25,
    21,
    17,
    14,
    12,
    10,
    9,
    8,
    8,
    255,
    248,
    240,
    233,
    225,
    218,
    210,
    203,
    196,
    189,
    182,
    176,
    169,
    163,
    156,
    150,
    144,
    138,
    133,
    127,
    121,
    116,
    111,
    106,
    101,
    96,
    91,
    86,
    82,
    77,
    73,
    69,
    65,
    61,
    57,
    54,
    50,
    47,
    44,
    41,
    38,
    35,
    32,
    29,
    27,
    25,
    22,
    20,
    18,
    16,
    15,
    13,
    12,
    10,
    9,
    8,
    7,
    6,
    6,
    5,
    5,
    4,
    4,
    4
  ];
  var DR_INTRA_DERIVATIVE = [
    0,
    1023,
    0,
    547,
    372,
    0,
    0,
    273,
    215,
    0,
    178,
    151,
    0,
    132,
    116,
    0,
    102,
    0,
    90,
    80,
    0,
    71,
    64,
    0,
    57,
    51,
    0,
    45,
    0,
    40,
    35,
    0,
    31,
    27,
    0,
    23,
    19,
    0,
    15,
    0,
    11,
    0,
    7,
    3
  ];
  var FILTER_INTRA_TAPS = [
    -6,
    10,
    0,
    0,
    0,
    12,
    0,
    -5,
    2,
    10,
    0,
    0,
    9,
    0,
    -3,
    1,
    1,
    10,
    0,
    7,
    0,
    -3,
    1,
    1,
    2,
    10,
    5,
    0,
    -4,
    6,
    0,
    0,
    0,
    2,
    12,
    -3,
    2,
    6,
    0,
    0,
    2,
    9,
    -3,
    2,
    2,
    6,
    0,
    2,
    7,
    -3,
    1,
    2,
    2,
    6,
    3,
    5,
    -10,
    16,
    0,
    0,
    0,
    10,
    0,
    -6,
    0,
    16,
    0,
    0,
    6,
    0,
    -4,
    0,
    0,
    16,
    0,
    4,
    0,
    -2,
    0,
    0,
    0,
    16,
    2,
    0,
    -10,
    16,
    0,
    0,
    0,
    0,
    10,
    -6,
    0,
    16,
    0,
    0,
    0,
    6,
    -4,
    0,
    0,
    16,
    0,
    0,
    4,
    -2,
    0,
    0,
    0,
    16,
    0,
    2,
    -8,
    8,
    0,
    0,
    0,
    16,
    0,
    -8,
    0,
    8,
    0,
    0,
    16,
    0,
    -8,
    0,
    0,
    8,
    0,
    16,
    0,
    -8,
    0,
    0,
    0,
    8,
    16,
    0,
    -4,
    4,
    0,
    0,
    0,
    0,
    16,
    -4,
    0,
    4,
    0,
    0,
    0,
    16,
    -4,
    0,
    0,
    4,
    0,
    0,
    16,
    -4,
    0,
    0,
    0,
    4,
    0,
    16,
    -2,
    8,
    0,
    0,
    0,
    10,
    0,
    -1,
    3,
    8,
    0,
    0,
    6,
    0,
    -1,
    2,
    3,
    8,
    0,
    4,
    0,
    0,
    1,
    2,
    3,
    8,
    2,
    0,
    -1,
    4,
    0,
    0,
    0,
    3,
    10,
    -1,
    3,
    4,
    0,
    0,
    4,
    6,
    -1,
    2,
    3,
    4,
    0,
    4,
    4,
    -1,
    2,
    2,
    3,
    4,
    3,
    3,
    -12,
    14,
    0,
    0,
    0,
    14,
    0,
    -10,
    0,
    14,
    0,
    0,
    12,
    0,
    -9,
    0,
    0,
    14,
    0,
    11,
    0,
    -8,
    0,
    0,
    0,
    14,
    10,
    0,
    -10,
    12,
    0,
    0,
    0,
    0,
    14,
    -9,
    1,
    12,
    0,
    0,
    0,
    12,
    -8,
    0,
    0,
    12,
    0,
    1,
    11,
    -7,
    0,
    0,
    1,
    12,
    1,
    9
  ];
  var RESIZE_FILTER = [
    0,
    0,
    0,
    -128,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    -128,
    -2,
    1,
    0,
    0,
    0,
    -1,
    3,
    -127,
    -4,
    2,
    -1,
    0,
    0,
    -1,
    4,
    -127,
    -6,
    3,
    -1,
    0,
    0,
    -2,
    6,
    -126,
    -8,
    3,
    -1,
    0,
    0,
    -2,
    7,
    -125,
    -11,
    4,
    -1,
    0,
    1,
    -2,
    8,
    -125,
    -13,
    5,
    -2,
    0,
    1,
    -3,
    9,
    -124,
    -15,
    6,
    -2,
    0,
    1,
    -3,
    10,
    -123,
    -18,
    6,
    -2,
    1,
    1,
    -3,
    11,
    -122,
    -20,
    7,
    -3,
    1,
    1,
    -4,
    12,
    -121,
    -22,
    8,
    -3,
    1,
    1,
    -4,
    13,
    -120,
    -25,
    9,
    -3,
    1,
    1,
    -4,
    14,
    -118,
    -28,
    9,
    -3,
    1,
    1,
    -4,
    15,
    -117,
    -30,
    10,
    -4,
    1,
    1,
    -5,
    16,
    -116,
    -32,
    11,
    -4,
    1,
    1,
    -5,
    16,
    -114,
    -35,
    12,
    -4,
    1,
    1,
    -5,
    17,
    -112,
    -38,
    12,
    -4,
    1,
    1,
    -5,
    18,
    -111,
    -40,
    13,
    -5,
    1,
    1,
    -5,
    18,
    -109,
    -43,
    14,
    -5,
    1,
    1,
    -6,
    19,
    -107,
    -45,
    14,
    -5,
    1,
    1,
    -6,
    19,
    -105,
    -48,
    15,
    -5,
    1,
    1,
    -6,
    19,
    -103,
    -51,
    16,
    -5,
    1,
    1,
    -6,
    20,
    -101,
    -53,
    16,
    -6,
    1,
    1,
    -6,
    20,
    -99,
    -56,
    17,
    -6,
    1,
    1,
    -6,
    20,
    -97,
    -58,
    17,
    -6,
    1,
    1,
    -6,
    20,
    -95,
    -61,
    18,
    -6,
    1,
    2,
    -7,
    20,
    -93,
    -64,
    18,
    -6,
    2,
    2,
    -7,
    20,
    -91,
    -66,
    19,
    -6,
    1,
    2,
    -7,
    20,
    -88,
    -69,
    19,
    -6,
    1,
    2,
    -7,
    20,
    -86,
    -71,
    19,
    -6,
    1,
    2,
    -7,
    20,
    -84,
    -74,
    20,
    -7,
    2,
    2,
    -7,
    20,
    -81,
    -76,
    20,
    -7,
    1,
    2,
    -7,
    20,
    -79,
    -79,
    20,
    -7,
    2,
    1,
    -7,
    20,
    -76,
    -81,
    20,
    -7,
    2,
    2,
    -7,
    20,
    -74,
    -84,
    20,
    -7,
    2,
    1,
    -6,
    19,
    -71,
    -86,
    20,
    -7,
    2,
    1,
    -6,
    19,
    -69,
    -88,
    20,
    -7,
    2,
    1,
    -6,
    19,
    -66,
    -91,
    20,
    -7,
    2,
    2,
    -6,
    18,
    -64,
    -93,
    20,
    -7,
    2,
    1,
    -6,
    18,
    -61,
    -95,
    20,
    -6,
    1,
    1,
    -6,
    17,
    -58,
    -97,
    20,
    -6,
    1,
    1,
    -6,
    17,
    -56,
    -99,
    20,
    -6,
    1,
    1,
    -6,
    16,
    -53,
    -101,
    20,
    -6,
    1,
    1,
    -5,
    16,
    -51,
    -103,
    19,
    -6,
    1,
    1,
    -5,
    15,
    -48,
    -105,
    19,
    -6,
    1,
    1,
    -5,
    14,
    -45,
    -107,
    19,
    -6,
    1,
    1,
    -5,
    14,
    -43,
    -109,
    18,
    -5,
    1,
    1,
    -5,
    13,
    -40,
    -111,
    18,
    -5,
    1,
    1,
    -4,
    12,
    -38,
    -112,
    17,
    -5,
    1,
    1,
    -4,
    12,
    -35,
    -114,
    16,
    -5,
    1,
    1,
    -4,
    11,
    -32,
    -116,
    16,
    -5,
    1,
    1,
    -4,
    10,
    -30,
    -117,
    15,
    -4,
    1,
    1,
    -3,
    9,
    -28,
    -118,
    14,
    -4,
    1,
    1,
    -3,
    9,
    -25,
    -120,
    13,
    -4,
    1,
    1,
    -3,
    8,
    -22,
    -121,
    12,
    -4,
    1,
    1,
    -3,
    7,
    -20,
    -122,
    11,
    -3,
    1,
    1,
    -2,
    6,
    -18,
    -123,
    10,
    -3,
    1,
    0,
    -2,
    6,
    -15,
    -124,
    9,
    -3,
    1,
    0,
    -2,
    5,
    -13,
    -125,
    8,
    -2,
    1,
    0,
    -1,
    4,
    -11,
    -125,
    7,
    -2,
    0,
    0,
    -1,
    3,
    -8,
    -126,
    6,
    -2,
    0,
    0,
    -1,
    3,
    -6,
    -127,
    4,
    -1,
    0,
    0,
    -1,
    2,
    -4,
    -127,
    3,
    -1,
    0,
    0,
    0,
    1,
    -2,
    -128,
    1,
    0,
    0
  ];
  var PACKED_AT = {
    modeCdfs: [0, 5776],
    coefCdfs0: [5776, 6180],
    coefCdfs1: [11956, 6180],
    coefCdfs2: [18136, 6180],
    coefCdfs3: [24316, 6180],
    scans: [30496, 14880],
    dq: [45376, 3072],
    qm: [48448, 31200],
    gaussianSequence: [79648, 4096],
    size: [0, 83744]
  };
  var PACKED = "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";

  // src/util/bytes.ts
  var fromBase64 = Uint8Array.fromBase64;
  function base64(text) {
    if (fromBase64)
      return fromBase64(text);
    const binary = atob(text), bytes = new Uint8Array(binary.length);
    for (let i = 0;i < binary.length; i++)
      bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  // src/codecs/zlib.ts
  /*!
   * zlib deflate/inflate, derived from fflate (https://github.com/101arrowz/fflate)
   * Copyright (c) 2020 Arjun Barrett, MIT License (see THIRD_PARTY_NOTICES.md)
   */
  var u8 = Uint8Array;
  var u16 = Uint16Array;
  var u32 = Uint32Array;
  var clim = u8.of(16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);
  var fleb = u8.of(0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0, 0, 0, 0);
  var fdeb = u8.of(0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13, 0, 0);
  function freb(eb, start) {
    const b = new u16(31);
    for (let i = 0;i < 31; ++i)
      b[i] = start += 1 << eb[i - 1];
    const r = new u32(b[30]);
    for (let i = 1;i < 30; ++i)
      for (let j = b[i];j < b[i + 1]; ++j)
        r[j] = j - b[i] << 5 | i;
    return [b, r];
  }
  var [fl, revfl] = freb(fleb, 2);
  fl[28] = 258;
  revfl[258] = 28;
  var [fd, revfd] = freb(fdeb, 0);
  var rev = new u16(32768);
  for (let i = 0;i < 32768; ++i) {
    let x = (i & 43690) >>> 1 | (i & 21845) << 1;
    x = (x & 52428) >>> 2 | (x & 13107) << 2;
    x = (x & 61680) >>> 4 | (x & 3855) << 4;
    rev[i] = ((x & 65280) >>> 8 | (x & 255) << 8) >>> 1;
  }
  function hMap(cd, mb, r) {
    const s = cd.length;
    const l = new u16(mb);
    for (let i = 0;i < s; ++i)
      if (cd[i])
        ++l[cd[i] - 1];
    const le = new u16(mb);
    for (let i = 1;i < mb; ++i)
      le[i] = le[i - 1] + l[i - 1] << 1;
    let co;
    if (r) {
      co = new u16(1 << mb);
      const rvb = 15 - mb;
      for (let i = 0;i < s; ++i) {
        if (!cd[i])
          continue;
        const sv = i << 4 | cd[i];
        const r1 = mb - cd[i];
        let v = le[cd[i] - 1]++ << r1;
        for (const m = v | (1 << r1) - 1;v <= m; ++v)
          co[rev[v] >>> rvb] = sv;
      }
    } else {
      co = new u16(s);
      for (let i = 0;i < s; ++i)
        if (cd[i])
          co[i] = rev[le[cd[i] - 1]++] >>> 15 - cd[i];
    }
    return co;
  }
  var flt = new u8(288);
  for (let i = 0;i < 144; ++i)
    flt[i] = 8;
  for (let i = 144;i < 256; ++i)
    flt[i] = 9;
  for (let i = 256;i < 280; ++i)
    flt[i] = 7;
  for (let i = 280;i < 288; ++i)
    flt[i] = 8;
  var fdt = new u8(32);
  for (let i = 0;i < 32; ++i)
    fdt[i] = 5;
  var flm = hMap(flt, 9, false);
  var flrm = hMap(flt, 9, true);
  var fdm = hMap(fdt, 5, false);
  var fdrm = hMap(fdt, 5, true);
  function max(a) {
    let m = a[0];
    for (let i = 1;i < a.length; ++i)
      if (a[i] > m)
        m = a[i];
    return m;
  }
  var bits = (d, p, m) => {
    const o = p / 8 | 0;
    return (d[o] | d[o + 1] << 8) >> (p & 7) & m;
  };
  var bits16 = (d, p) => {
    const o = p / 8 | 0;
    return (d[o] | d[o + 1] << 8 | d[o + 2] << 16) >> (p & 7);
  };
  var shft = (p) => (p + 7) / 8 | 0;
  function inflate(dat, buf) {
    const sl = dat.length;
    if (!sl)
      return buf.subarray(0, 0);
    const tbts = sl * 8;
    let final, pos = 0, bt = 0;
    do {
      let lm, dm, lbt, dbt;
      final = bits(dat, pos, 1);
      const type = bits(dat, pos + 1, 3);
      pos += 3;
      if (!type) {
        const s = shft(pos) + 4, l = dat[s - 4] | dat[s - 3] << 8, t = s + l;
        if (t > sl)
          throw new Error("zlib: unexpected end of data");
        if (bt < buf.length)
          buf.set(dat.subarray(s, Math.min(t, s + buf.length - bt)), bt);
        bt += l;
        pos = t * 8;
        continue;
      } else if (type === 1) {
        lm = flrm;
        dm = fdrm;
        lbt = 9;
        dbt = 5;
      } else if (type === 2) {
        const hLit = bits(dat, pos, 31) + 257, hcLen = bits(dat, pos + 10, 15) + 4;
        const tl = hLit + bits(dat, pos + 5, 31) + 1;
        pos += 14;
        const ldt = new u8(tl);
        const clt = new u8(19);
        for (let i = 0;i < hcLen; ++i)
          clt[clim[i]] = bits(dat, pos + i * 3, 7);
        pos += hcLen * 3;
        const clb = max(clt), clbmsk = (1 << clb) - 1;
        const clm = hMap(clt, clb, true);
        for (let i = 0;i < tl; ) {
          const r = clm[bits(dat, pos, clbmsk)];
          pos += r & 15;
          const s = r >> 4;
          if (s < 16)
            ldt[i++] = s;
          else {
            let c = 0, n = 0;
            if (s === 16) {
              n = 3 + bits(dat, pos, 3);
              pos += 2;
              c = ldt[i - 1];
            } else if (s === 17) {
              n = 3 + bits(dat, pos, 7);
              pos += 3;
            } else if (s === 18) {
              n = 11 + bits(dat, pos, 127);
              pos += 7;
            }
            while (n--)
              ldt[i++] = c;
          }
        }
        const lt = ldt.subarray(0, hLit), dt = ldt.subarray(hLit);
        lbt = max(lt);
        dbt = max(dt);
        lm = hMap(lt, lbt, true);
        dm = hMap(dt, dbt, true);
      } else
        throw new Error("zlib: invalid block type");
      if (pos > tbts)
        throw new Error("zlib: unexpected end of data");
      const lms = (1 << lbt) - 1, dms = (1 << dbt) - 1;
      for (;; ) {
        const c = lm[bits16(dat, pos) & lms], sym = c >> 4;
        pos += c & 15;
        if (pos > tbts)
          throw new Error("zlib: unexpected end of data");
        if (!c)
          throw new Error("zlib: invalid length/literal");
        if (sym < 256)
          buf[bt++] = sym;
        else if (sym === 256)
          break;
        else {
          let add = sym - 254;
          if (sym > 264) {
            const i = sym - 257, b = fleb[i];
            add = bits(dat, pos, (1 << b) - 1) + fl[i];
            pos += b;
          }
          const d = dm[bits16(dat, pos) & dms], dsym = d >> 4;
          if (!d)
            throw new Error("zlib: invalid distance");
          pos += d & 15;
          let dt = fd[dsym];
          if (dsym > 3) {
            const b = fdeb[dsym];
            dt += bits16(dat, pos) & (1 << b) - 1;
            pos += b;
          }
          if (pos > tbts)
            throw new Error("zlib: unexpected end of data");
          if (bt >= buf.length) {
            bt += add;
            continue;
          }
          const end = bt + add;
          for (;bt < end; bt += 4) {
            buf[bt] = buf[bt - dt];
            buf[bt + 1] = buf[bt + 1 - dt];
            buf[bt + 2] = buf[bt + 2 - dt];
            buf[bt + 3] = buf[bt + 3 - dt];
          }
          bt = end;
        }
      }
    } while (!final);
    return buf.subarray(0, Math.min(bt, buf.length));
  }
  var et = new u8(0);
  var deo = u32.of(65540, 131080, 131088, 131104, 262176, 1048704, 1048832, 2114560, 2117632);
  function decompress(data, limit) {
    if ((data[0] & 15) !== 8 || data[0] >> 4 > 7 || (data[0] << 8 | data[1]) % 31)
      throw new Error("zlib: invalid header");
    if (data[1] & 32)
      throw new Error("zlib: preset dictionaries are not supported");
    return inflate(data.subarray(2), new u8(limit));
  }
  var { process: runtime, CompressionStream: NativeCompression, DecompressionStream: NativeDecompression, Blob: NativeBlob } = globalThis;
  var nodeZlib = (() => {
    try {
      return runtime && runtime.getBuiltinModule && runtime.getBuiltinModule("node:zlib") || null;
    } catch {
      return null;
    }
  })();
  var PIECE = 1 << 20;
  var WINDOW = 1 << 15;

  // src/codecs/av1/tables.ts
  /*!
   * Constants and tables of the AV1 decoder, ported from dav1d (src/levels.h, src/intra_edge.c, src/qm.c, src/cdf.c).
   * Copyright (c) 2018-2021, VideoLAN and dav1d authors, Copyright (c) 2018, Two Orioles, LLC, BSD-2-Clause License
   * (see THIRD_PARTY_NOTICES.md)
   */
  var BL_128X128 = 0;
  var BL_64X64 = 1;
  var BL_8X8 = 4;
  var BS_128x128 = 0;
  var BS_64x64 = 3;
  var BS_4x4 = 21;
  var PARTITION_NONE = 0;
  var PARTITION_H = 1;
  var PARTITION_V = 2;
  var PARTITION_SPLIT = 3;
  var PARTITION_T_TOP_SPLIT = 4;
  var PARTITION_T_BOTTOM_SPLIT = 5;
  var PARTITION_T_LEFT_SPLIT = 6;
  var PARTITION_T_RIGHT_SPLIT = 7;
  var PARTITION_H4 = 8;
  var PARTITION_V4 = 9;
  var DC_PRED = 0;
  var VERT_PRED = 1;
  var HOR_PRED = 2;
  var VERT_LEFT_PRED = 8;
  var SMOOTH_PRED = 9;
  var SMOOTH_V_PRED = 10;
  var SMOOTH_H_PRED = 11;
  var PAETH_PRED = 12;
  var CFL_PRED = 13;
  var FILTER_PRED = 13;
  var LEFT_DC_PRED = 3;
  var TOP_DC_PRED = 4;
  var DC_128_PRED = 5;
  var Z1_PRED = 6;
  var Z2_PRED = 7;
  var Z3_PRED = 8;
  var TX_4X4 = 0;
  var TX_8X8 = 1;
  var TX_16X16 = 2;
  var TX_32X32 = 3;
  var TX_64X64 = 4;
  var RTX_4X8 = 5;
  var DCT_DCT = 0;
  var IDTX = 9;
  var WHT_WHT = 16;
  var TX_CLASS_2D = 0;
  var TX_CLASS_H = 1;
  var EDGE_I444_TOP_HAS_RIGHT = 1;
  var EDGE_I420_TOP_HAS_RIGHT = 4;
  var EDGE_I444_LEFT_HAS_BOTTOM = 8;
  var EDGE_I422_LEFT_HAS_BOTTOM = 16;
  var EDGE_I420_LEFT_HAS_BOTTOM = 32;
  var EDGE_ALL_TOP_HAS_RIGHT = 7;
  var EDGE_ALL_LEFT_HAS_BOTTOM = 56;
  var EDGE_ALL_TR_AND_BL = 63;
  var {
    AL_PART_CTX: AL_PART_CTX2,
    BLOCK_SIZES: BLOCK_SIZES2,
    BLOCK_DIMENSIONS: BLOCK_DIMENSIONS2,
    TXFM_DIMENSIONS: TXFM_DIMENSIONS2,
    MAX_TXFM_SIZE_FOR_BS: MAX_TXFM_SIZE_FOR_BS2,
    TXTP_FROM_UVMODE: TXTP_FROM_UVMODE2,
    PARTITION_TYPE_COUNT: PARTITION_TYPE_COUNT2,
    TX_TYPES_PER_SET: TX_TYPES_PER_SET2,
    FILTER_MODE_TO_Y_MODE: FILTER_MODE_TO_Y_MODE2,
    LO_CTX_OFFSETS: LO_CTX_OFFSETS2,
    SKIP_CTX: SKIP_CTX2,
    TX_TYPE_CLASS: TX_TYPE_CLASS2,
    INTRA_MODE_CONTEXT: INTRA_MODE_CONTEXT2,
    CDEF_DIRECTIONS: CDEF_DIRECTIONS2,
    SGR_PARAMS: SGR_PARAMS2,
    SGR_X_BY_X: SGR_X_BY_X2,
    SM_WEIGHTS: SM_WEIGHTS2,
    DR_INTRA_DERIVATIVE: DR_INTRA_DERIVATIVE2,
    FILTER_INTRA_TAPS: FILTER_INTRA_TAPS2,
    RESIZE_FILTER: RESIZE_FILTER2,
    CDF: CDF2,
    SCAN_OFFSETS: SCAN_OFFSETS2
  } = exports_data;
  var CFL_ALLOWED_MASK = 1 << 7 | 1 << 8 | 1 << 9 | 1 << 11 | 1 << 12 | 1 << 13 | 1 << 14 | 1 << 15 | 1 << 16 | 1 << 17 | 1 << 18 | 1 << 19 | 1 << 20 | 1 << 21;
  var tables = null;
  function load() {
    if (tables)
      return tables;
    const at = PACKED_AT;
    const blob = decompress(base64(PACKED), at.size[1]);
    const bytes = ([offset, size]) => blob.subarray(offset, offset + size);
    const words = ([offset, size]) => {
      const w = new Uint16Array(size >> 1);
      for (let i = 0;i < w.length; i++)
        w[i] = blob[offset + i * 2] | blob[offset + i * 2 + 1] << 8;
      return w;
    };
    return tables = {
      modeCdfs: words(at.modeCdfs),
      coefCdfs: [at.coefCdfs0, at.coefCdfs1, at.coefCdfs2, at.coefCdfs3].map(words),
      scans: words(at.scans),
      dq: words(at.dq),
      qm: buildQm(bytes(at.qm)),
      gaussianSequence: new Int16Array(words(at.gaussianSequence))
    };
  }
  function gaussianSequence() {
    return load().gaussianSequence;
  }
  function defaultCdfs(qidx) {
    const t = load();
    const cdf = new Uint16Array(CDF2.size);
    cdf.set(t.modeCdfs);
    cdf.set(t.coefCdfs[(qidx > 20 ? 1 : 0) + (qidx > 60 ? 1 : 0) + (qidx > 120 ? 1 : 0)], t.modeCdfs.length);
    return cdf;
  }
  function scan(tx) {
    const t = load();
    const w = Math.min(TXFM_DIMENSIONS2[tx * 8] * 4, 32), h = Math.min(TXFM_DIMENSIONS2[tx * 8 + 1] * 4, 32);
    return t.scans.subarray(SCAN_OFFSETS2[tx], SCAN_OFFSETS2[tx] + w * h);
  }
  function dequant(hbd, qidx, ac) {
    return load().dq[(hbd * 256 + qidx) * 2 + ac];
  }
  function quantizerMatrix(level, chroma, tx) {
    return load().qm[level][chroma][tx];
  }
  function buildQm(src) {
    const subsample = (s, o, h, hstep, vstep) => {
      const out = [];
      for (let y = 0;y < h; y += vstep)
        for (let x = 0;x < 32; x += hstep)
          out.push(s[o + y * 32 + x]);
      return Uint8Array.from(out);
    };
    const transpose = (s, w, h) => {
      const d = new Uint8Array(w * h);
      for (let y = 0;y < h; y++)
        for (let x = 0;x < w; x++)
          d[x * h + y] = s[y * w + x];
      return d;
    };
    const result = [];
    for (let i = 0;i < 15; i++) {
      const level = [];
      for (let j = 0;j < 2; j++) {
        const t32x16 = src.subarray((i * 2 + j) * 512, (i * 2 + j + 1) * 512);
        const tri = src.subarray(15 * 2 * 512 + (i * 2 + j) * 528);
        const t32x32 = new Uint8Array(1024);
        for (let y = 0, o = 0;y < 32; y++)
          for (let x = 0;x <= y; x++, o++)
            t32x32[y * 32 + x] = t32x32[x * 32 + y] = tri[o];
        const t4x4 = subsample(t32x32, 32 * 3 + 3, 32, 8, 8);
        const t8x4 = subsample(t32x16, 32 + 1, 16, 4, 4);
        const t8x8 = subsample(t32x32, 32 + 1, 32, 4, 4);
        const t16x4 = subsample(t32x16, 32, 16, 2, 4);
        const t16x8 = subsample(t32x16, 0, 16, 2, 2);
        const t16x16 = subsample(t32x32, 0, 32, 2, 2);
        const t32x8 = subsample(t32x16, 0, 16, 1, 2);
        const t4x8 = transpose(t8x4, 8, 4), t4x16 = transpose(t16x4, 16, 4), t8x16 = transpose(t16x8, 16, 8);
        const t8x32 = transpose(t32x8, 32, 8), t16x32 = transpose(t32x16, 32, 16);
        const byTx = [];
        byTx[TX_4X4] = t4x4;
        byTx[TX_8X8] = t8x8;
        byTx[TX_16X16] = t16x16;
        byTx[TX_32X32] = t32x32;
        byTx[TX_64X64] = t32x32;
        byTx[5] = t8x4;
        byTx[6] = t4x8;
        byTx[7] = t16x8;
        byTx[8] = t8x16;
        byTx[9] = t32x16;
        byTx[10] = t16x32;
        byTx[11] = t32x32;
        byTx[12] = t32x32;
        byTx[13] = t16x4;
        byTx[14] = t4x16;
        byTx[15] = t32x8;
        byTx[16] = t8x32;
        byTx[17] = t32x16;
        byTx[18] = t16x32;
        level.push(byTx);
      }
      result.push(level);
    }
    return result;
  }
  function initEdges(bl, flags) {
    const node = { o: flags, h: [flags | EDGE_ALL_LEFT_HAS_BOTTOM, 0], v: [flags | EDGE_ALL_TOP_HAS_RIGHT, 0], h4: 0, v4: 0, split: [], tip: [] };
    if (bl === BL_8X8) {
      node.h[1] = flags & (EDGE_ALL_LEFT_HAS_BOTTOM | EDGE_I420_TOP_HAS_RIGHT);
      node.v[1] = flags & (EDGE_ALL_TOP_HAS_RIGHT | EDGE_I420_LEFT_HAS_BOTTOM | EDGE_I422_LEFT_HAS_BOTTOM);
      node.tip = [
        flags & EDGE_ALL_TOP_HAS_RIGHT | EDGE_I422_LEFT_HAS_BOTTOM,
        flags | EDGE_I444_TOP_HAS_RIGHT,
        flags & (EDGE_I420_TOP_HAS_RIGHT | EDGE_I420_LEFT_HAS_BOTTOM | EDGE_I422_LEFT_HAS_BOTTOM)
      ];
    } else {
      node.h[1] = flags & EDGE_ALL_LEFT_HAS_BOTTOM;
      node.v[1] = flags & EDGE_ALL_TOP_HAS_RIGHT;
      node.h4 = EDGE_ALL_LEFT_HAS_BOTTOM;
      node.v4 = EDGE_ALL_TOP_HAS_RIGHT;
      if (bl === 3) {
        node.h4 |= flags & EDGE_I420_TOP_HAS_RIGHT;
        node.v4 |= flags & (EDGE_I420_LEFT_HAS_BOTTOM | EDGE_I422_LEFT_HAS_BOTTOM);
      }
    }
    return node;
  }
  function initModeNode(bl, topHasRight, leftHasBottom) {
    const node = initEdges(bl, (topHasRight ? EDGE_ALL_TOP_HAS_RIGHT : 0) | (leftHasBottom ? EDGE_ALL_LEFT_HAS_BOTTOM : 0));
    for (let n = 0;n < 4; n++) {
      const tr = !(n === 3 || n === 1 && !topHasRight), lb = n === 0 || n === 2 && leftHasBottom;
      node.split.push(bl === 3 ? initEdges(bl + 1, (tr ? EDGE_ALL_TOP_HAS_RIGHT : 0) | (lb ? EDGE_ALL_LEFT_HAS_BOTTOM : 0)) : initModeNode(bl + 1, tr, lb));
    }
    return node;
  }
  var edgeTrees = null;
  function edgeTree(sb128) {
    edgeTrees ??= [initModeNode(BL_128X128, true, false), initModeNode(BL_64X64, true, false)];
    return edgeTrees[sb128 ? 0 : 1];
  }

  // src/codecs/av1/ipred.ts
  /*!
   * AV1 intra prediction: the edges of a block, and DC, directional, smooth, Paeth, filter, chroma from luma and
   * palette prediction, ported from dav1d (src/ipred_prepare_tmpl.c, src/ipred_tmpl.c). Copyright (c) 2018-2021,
   * VideoLAN and dav1d authors, Copyright (c) 2018, Two Orioles, LLC, BSD-2-Clause License (see THIRD_PARTY_NOTICES.md)
   */
  var ANGLE_USE_EDGE_FILTER = 1024;
  var ANGLE_SMOOTH_EDGE = 512;
  var EDGE = 128;
  var edgeBuffer = new Uint16Array(2 * EDGE + 1);
  var MODE_TO_ANGLE = [90, 180, 45, 135, 113, 157, 203, 67];
  var NEEDS_LEFT = 1;
  var NEEDS_TOP = 2;
  var NEEDS_TOPLEFT = 4;
  var NEEDS_TOPRIGHT = 8;
  var NEEDS_BOTTOMLEFT = 16;
  var NEEDS = [];
  NEEDS[DC_PRED] = NEEDS_TOP | NEEDS_LEFT;
  NEEDS[VERT_PRED] = NEEDS_TOP;
  NEEDS[HOR_PRED] = NEEDS_LEFT;
  NEEDS[LEFT_DC_PRED] = NEEDS_LEFT;
  NEEDS[TOP_DC_PRED] = NEEDS_TOP;
  NEEDS[DC_128_PRED] = 0;
  NEEDS[Z1_PRED] = NEEDS_TOP | NEEDS_TOPRIGHT | NEEDS_TOPLEFT;
  NEEDS[Z2_PRED] = NEEDS_LEFT | NEEDS_TOP | NEEDS_TOPLEFT;
  NEEDS[Z3_PRED] = NEEDS_LEFT | NEEDS_BOTTOMLEFT | NEEDS_TOPLEFT;
  NEEDS[SMOOTH_PRED] = NEEDS[SMOOTH_V_PRED] = NEEDS[SMOOTH_H_PRED] = NEEDS_LEFT | NEEDS_TOP;
  NEEDS[PAETH_PRED] = NEEDS[FILTER_PRED] = NEEDS_LEFT | NEEDS_TOP | NEEDS_TOPLEFT;
  var preparedAngle = 0;
  function prepareEdges(x, haveLeft, y, haveTop, w, h, edgeFlags, pic, dst, stride, mode, angle, tw, th, filterEdge, bitdepth) {
    const e = edgeBuffer;
    if (mode >= VERT_PRED && mode <= VERT_LEFT_PRED) {
      angle = MODE_TO_ANGLE[mode - VERT_PRED] + 3 * angle;
      if (angle <= 90)
        mode = angle < 90 && haveTop ? Z1_PRED : VERT_PRED;
      else if (angle < 180)
        mode = Z2_PRED;
      else
        mode = angle > 180 && haveLeft ? Z3_PRED : HOR_PRED;
    } else if (mode === DC_PRED) {
      mode = haveLeft ? haveTop ? DC_PRED : LEFT_DC_PRED : haveTop ? TOP_DC_PRED : DC_128_PRED;
    } else if (mode === PAETH_PRED) {
      mode = haveLeft ? haveTop ? PAETH_PRED : HOR_PRED : haveTop ? VERT_PRED : DC_128_PRED;
    }
    preparedAngle = angle;
    const needs = NEEDS[mode];
    const top = dst - stride;
    if (needs & NEEDS_LEFT) {
      const sz = th << 2, left = EDGE - sz;
      if (haveLeft) {
        const have = Math.min(sz, h - y << 2);
        for (let i = 0;i < have; i++)
          e[left + sz - 1 - i] = pic[dst + stride * i - 1];
        if (have < sz)
          e.fill(e[left + sz - have], left, left + sz - have);
      } else
        e.fill(haveTop ? pic[top] : (1 << bitdepth >> 1) + 1, left, left + sz);
      if (needs & NEEDS_BOTTOMLEFT) {
        const haveBottomLeft = haveLeft && y + th < h && edgeFlags & EDGE_I444_LEFT_HAS_BOTTOM;
        if (haveBottomLeft) {
          const have = Math.min(sz, h - y - th << 2);
          for (let i = 0;i < have; i++)
            e[left - 1 - i] = pic[dst + (sz + i) * stride - 1];
          if (have < sz)
            e.fill(e[left - have], left - sz, left - have);
        } else
          e.fill(e[left], left - sz, left);
      }
    }
    if (needs & NEEDS_TOP) {
      const sz = tw << 2, t = EDGE + 1;
      if (haveTop) {
        const have = Math.min(sz, w - x << 2);
        for (let i = 0;i < have; i++)
          e[t + i] = pic[top + i];
        if (have < sz)
          e.fill(e[t + have - 1], t + have, t + sz);
      } else
        e.fill(haveLeft ? pic[dst - 1] : (1 << bitdepth >> 1) - 1, t, t + sz);
      if (needs & NEEDS_TOPRIGHT) {
        const haveTopRight = haveTop && x + tw < w && edgeFlags & EDGE_I444_TOP_HAS_RIGHT;
        if (haveTopRight) {
          const have = Math.min(sz, w - x - tw << 2);
          for (let i = 0;i < have; i++)
            e[t + sz + i] = pic[top + sz + i];
          if (have < sz)
            e.fill(e[t + sz + have - 1], t + sz + have, t + 2 * sz);
        } else
          e.fill(e[t + sz - 1], t + sz, t + 2 * sz);
      }
    }
    if (needs & NEEDS_TOPLEFT) {
      if (haveLeft)
        e[EDGE] = haveTop ? pic[top - 1] : pic[dst - 1];
      else
        e[EDGE] = haveTop ? pic[top] : 1 << bitdepth >> 1;
      if (mode === Z2_PRED && tw + th >= 6 && filterEdge)
        e[EDGE] = (e[EDGE - 1] + e[EDGE + 1]) * 5 + e[EDGE] * 6 + 8 >> 4;
    }
    return mode;
  }
  function splat(dst, d, stride, width, height, v) {
    for (let y = 0;y < height; y++, d += stride)
      dst.fill(v, d, d + width);
  }
  var ctz = (v) => 31 - Math.clz32(v & -v);
  function dcTop(e, width) {
    let dc = width >> 1;
    for (let i = 0;i < width; i++)
      dc += e[EDGE + 1 + i];
    return dc >> ctz(width);
  }
  function dcLeft(e, height) {
    let dc = height >> 1;
    for (let i = 0;i < height; i++)
      dc += e[EDGE - 1 - i];
    return dc >> ctz(height);
  }
  function dcBoth(e, width, height, hbd) {
    let dc = width + height >> 1;
    for (let i = 0;i < width; i++)
      dc += e[EDGE + 1 + i];
    for (let i = 0;i < height; i++)
      dc += e[EDGE - 1 - i];
    dc >>= ctz(width + height);
    if (width !== height) {
      const quarter = width > height * 2 || height > width * 2;
      dc = hbd ? Math.floor(dc * (quarter ? 26215 : 43691) / 131072) : dc * (quarter ? 13108 : 21846) >>> 16;
    }
    return dc;
  }
  function dcValue(mode, width, height, bitdepthMax) {
    const e = edgeBuffer;
    switch (mode) {
      case DC_PRED:
        return dcBoth(e, width, height, bitdepthMax > 255);
      case LEFT_DC_PRED:
        return dcLeft(e, height);
      case TOP_DC_PRED:
        return dcTop(e, width);
      default:
        return bitdepthMax + 1 >> 1;
    }
  }
  function filterStrength(wh, angle, smooth) {
    if (smooth) {
      if (wh <= 8) {
        if (angle >= 64)
          return 2;
        if (angle >= 40)
          return 1;
      } else if (wh <= 16) {
        if (angle >= 48)
          return 2;
        if (angle >= 20)
          return 1;
      } else if (wh <= 24) {
        if (angle >= 4)
          return 3;
      } else
        return 3;
    } else {
      if (wh <= 8) {
        if (angle >= 56)
          return 1;
      } else if (wh <= 16) {
        if (angle >= 40)
          return 1;
      } else if (wh <= 24) {
        if (angle >= 32)
          return 3;
        if (angle >= 16)
          return 2;
        if (angle >= 8)
          return 1;
      } else if (wh <= 32) {
        if (angle >= 32)
          return 3;
        if (angle >= 4)
          return 2;
        return 1;
      } else
        return 3;
    }
    return 0;
  }
  var KERNELS = [[0, 4, 8, 4, 0], [0, 5, 6, 5, 0], [2, 4, 4, 4, 2]];
  var clampIndex = (i, from, to) => i < from ? from : i > to - 1 ? to - 1 : i;
  function filterEdge(out, o, sz, limFrom, limTo, inp, i0, from, to, strength) {
    const k = KERNELS[strength - 1];
    let i = 0;
    for (;i < Math.min(sz, limFrom); i++)
      out[o + i] = inp[i0 + clampIndex(i, from, to)];
    for (;i < Math.min(limTo, sz); i++) {
      let s = 0;
      for (let j = 0;j < 5; j++)
        s += inp[i0 + clampIndex(i - 2 + j, from, to)] * k[j];
      out[o + i] = s + 8 >> 4;
    }
    for (;i < sz; i++)
      out[o + i] = inp[i0 + clampIndex(i, from, to)];
  }
  var upsampled = (wh, angle, smooth) => angle < 40 && wh <= 16 >> (smooth ? 1 : 0);
  function upsampleEdge(out, o, hsz, inp, i0, from, to, bitdepthMax) {
    let i;
    for (i = 0;i < hsz - 1; i++) {
      out[o + i * 2] = inp[i0 + clampIndex(i, from, to)];
      const s = -inp[i0 + clampIndex(i - 1, from, to)] + 9 * inp[i0 + clampIndex(i, from, to)] + 9 * inp[i0 + clampIndex(i + 1, from, to)] - inp[i0 + clampIndex(i + 2, from, to)];
      const v = s + 8 >> 4;
      out[o + i * 2 + 1] = v < 0 ? 0 : v > bitdepthMax ? bitdepthMax : v;
    }
    out[o + i * 2] = inp[i0 + clampIndex(i, from, to)];
  }
  var scratch = new Uint16Array(64 + 64 + 1);
  function z1(dst, d, stride, width, height, angle, bitdepthMax) {
    const e = edgeBuffer;
    const smooth = !!(angle >> 9 & 1), edgeFilter = !!(angle >> 10);
    angle &= 511;
    let dx = DR_INTRA_DERIVATIVE2[angle >> 1];
    let top, t0, maxBase;
    const up = edgeFilter && upsampled(width + height, 90 - angle, smooth);
    if (up) {
      upsampleEdge(scratch, 0, width + height, e, EDGE + 1, -1, width + Math.min(width, height), bitdepthMax);
      top = scratch;
      t0 = 0;
      maxBase = 2 * (width + height) - 2;
      dx <<= 1;
    } else {
      const strength = edgeFilter ? filterStrength(width + height, 90 - angle, smooth) : 0;
      if (strength) {
        filterEdge(scratch, 0, width + height, 0, width + height, e, EDGE + 1, -1, width + Math.min(width, height), strength);
        top = scratch;
        t0 = 0;
        maxBase = width + height - 1;
      } else {
        top = e;
        t0 = EDGE + 1;
        maxBase = width + Math.min(width, height) - 1;
      }
    }
    const inc = up ? 2 : 1;
    for (let y = 0, xpos = dx;y < height; y++, d += stride, xpos += dx) {
      const frac = xpos & 62;
      for (let x = 0, base = xpos >> 6;x < width; x++, base += inc) {
        if (base < maxBase)
          dst[d + x] = top[t0 + base] * (64 - frac) + top[t0 + base + 1] * frac + 32 >> 6;
        else {
          dst.fill(top[t0 + maxBase], d + x, d + width);
          break;
        }
      }
    }
  }
  function z2(dst, d, stride, width, height, angle, maxWidth, maxHeight, bitdepthMax) {
    const e = edgeBuffer;
    const smooth = !!(angle >> 9 & 1), edgeFilter = !!(angle >> 10);
    angle &= 511;
    let dy = DR_INTRA_DERIVATIVE2[angle - 90 >> 1];
    let dx = DR_INTRA_DERIVATIVE2[180 - angle >> 1];
    const upLeft = edgeFilter && upsampled(width + height, 180 - angle, smooth);
    const upAbove = edgeFilter && upsampled(width + height, angle - 90, smooth);
    const s = scratch, tl = 64;
    if (upAbove) {
      upsampleEdge(s, tl, width + 1, e, EDGE, 0, width + 1, bitdepthMax);
      dx <<= 1;
    } else {
      const strength = edgeFilter ? filterStrength(width + height, angle - 90, smooth) : 0;
      if (strength)
        filterEdge(s, tl + 1, width, 0, maxWidth, e, EDGE + 1, -1, width, strength);
      else
        s.set(e.subarray(EDGE + 1, EDGE + 1 + width), tl + 1);
    }
    if (upLeft) {
      upsampleEdge(s, tl - height * 2, height + 1, e, EDGE - height, 0, height + 1, bitdepthMax);
      dy <<= 1;
    } else {
      const strength = edgeFilter ? filterStrength(width + height, 180 - angle, smooth) : 0;
      if (strength)
        filterEdge(s, tl - height, height, height - maxHeight, height, e, EDGE - height, 0, height + 1, strength);
      else
        s.set(e.subarray(EDGE - height, EDGE), tl - height);
    }
    s[tl] = e[EDGE];
    const incX = upAbove ? 2 : 1;
    const left = tl - (upLeft ? 2 : 1);
    for (let y = 0, xpos = ((upAbove ? 2 : 1) << 6) - dx;y < height; y++, xpos -= dx, d += stride) {
      let baseX = xpos >> 6;
      const fracX = xpos & 62;
      for (let x = 0, ypos = (y << 6 + (upLeft ? 1 : 0)) - dy;x < width; x++, baseX += incX, ypos -= dy) {
        let v;
        if (baseX >= 0)
          v = s[tl + baseX] * (64 - fracX) + s[tl + baseX + 1] * fracX;
        else {
          const baseY = ypos >> 6, fracY = ypos & 62;
          v = s[left - baseY] * (64 - fracY) + s[left - baseY - 1] * fracY;
        }
        dst[d + x] = v + 32 >> 6;
      }
    }
  }
  function z3(dst, d, stride, width, height, angle, bitdepthMax) {
    const e = edgeBuffer;
    const smooth = !!(angle >> 9 & 1), edgeFilter = !!(angle >> 10);
    angle &= 511;
    let dy = DR_INTRA_DERIVATIVE2[270 - angle >> 1];
    let left, l0, maxBase;
    const up = edgeFilter && upsampled(width + height, angle - 180, smooth);
    if (up) {
      upsampleEdge(scratch, 0, width + height, e, EDGE - (width + height), Math.max(width - height, 0), width + height + 1, bitdepthMax);
      left = scratch;
      l0 = 2 * (width + height) - 2;
      maxBase = 2 * (width + height) - 2;
      dy <<= 1;
    } else {
      const strength = edgeFilter ? filterStrength(width + height, angle - 180, smooth) : 0;
      if (strength) {
        filterEdge(scratch, 0, width + height, 0, width + height, e, EDGE - (width + height), Math.max(width - height, 0), width + height + 1, strength);
        left = scratch;
        l0 = width + height - 1;
        maxBase = width + height - 1;
      } else {
        left = e;
        l0 = EDGE - 1;
        maxBase = height + Math.min(width, height) - 1;
      }
    }
    const inc = up ? 2 : 1;
    for (let x = 0, ypos = dy;x < width; x++, ypos += dy) {
      const frac = ypos & 62;
      for (let y = 0, base = ypos >> 6;y < height; y++, base += inc) {
        if (base < maxBase)
          dst[d + y * stride + x] = left[l0 - base] * (64 - frac) + left[l0 - base - 1] * frac + 32 >> 6;
        else {
          for (;y < height; y++)
            dst[d + y * stride + x] = left[l0 - maxBase];
          break;
        }
      }
    }
  }
  function filterIntra(dst, d, stride, width, height, filter, bitdepthMax) {
    const e = edgeBuffer;
    const taps = filter * 56;
    let topArr = e, top = EDGE + 1;
    for (let y = 0;y < height; y += 2) {
      let tlArr = e, tl = EDGE - y;
      let leftArr = e, left = tl - 1, leftStride = -1;
      for (let x = 0;x < width; x += 4) {
        const p0 = tlArr[tl];
        const p1 = topArr[top], p2 = topArr[top + 1], p3 = topArr[top + 2], p4 = topArr[top + 3];
        const p5 = leftArr[left], p6 = leftArr[left + leftStride];
        let ptr = d + x;
        for (let yy = 0, k = 0;yy < 2; yy++, ptr += stride) {
          for (let xx = 0;xx < 4; xx++, k++) {
            const t = taps + k * 7;
            const acc = FILTER_INTRA_TAPS2[t] * p0 + FILTER_INTRA_TAPS2[t + 1] * p1 + FILTER_INTRA_TAPS2[t + 2] * p2 + FILTER_INTRA_TAPS2[t + 3] * p3 + FILTER_INTRA_TAPS2[t + 4] * p4 + FILTER_INTRA_TAPS2[t + 5] * p5 + FILTER_INTRA_TAPS2[t + 6] * p6;
            const v = acc + 8 >> 4;
            dst[ptr + xx] = v < 0 ? 0 : v > bitdepthMax ? bitdepthMax : v;
          }
        }
        leftArr = dst;
        left = d + x + 4 - 1;
        leftStride = stride;
        top += 4;
        tlArr = topArr;
        tl = top - 1;
      }
      topArr = dst;
      top = d + stride;
      d += stride * 2;
    }
  }
  function predict(mode, dst, d, stride, width, height, angle, maxWidth, maxHeight, bitdepthMax) {
    const e = edgeBuffer;
    switch (mode) {
      case DC_PRED:
      case LEFT_DC_PRED:
      case TOP_DC_PRED:
      case DC_128_PRED:
        return splat(dst, d, stride, width, height, dcValue(mode, width, height, bitdepthMax));
      case VERT_PRED:
        for (let y = 0;y < height; y++, d += stride)
          dst.set(e.subarray(EDGE + 1, EDGE + 1 + width), d);
        return;
      case HOR_PRED:
        for (let y = 0;y < height; y++, d += stride)
          dst.fill(e[EDGE - 1 - y], d, d + width);
        return;
      case PAETH_PRED: {
        const topleft = e[EDGE];
        for (let y = 0;y < height; y++, d += stride) {
          const left = e[EDGE - 1 - y];
          for (let x = 0;x < width; x++) {
            const top = e[EDGE + 1 + x];
            const base = left + top - topleft;
            const ldiff = Math.abs(left - base), tdiff = Math.abs(top - base), tldiff = Math.abs(topleft - base);
            dst[d + x] = ldiff <= tdiff && ldiff <= tldiff ? left : tdiff <= tldiff ? top : topleft;
          }
        }
        return;
      }
      case SMOOTH_PRED: {
        const right = e[EDGE + width], bottom = e[EDGE - height];
        for (let y = 0;y < height; y++, d += stride) {
          const wv = SM_WEIGHTS2[height + y], left = e[EDGE - 1 - y];
          for (let x = 0;x < width; x++) {
            const wh = SM_WEIGHTS2[width + x];
            dst[d + x] = wv * e[EDGE + 1 + x] + (256 - wv) * bottom + wh * left + (256 - wh) * right + 256 >> 9;
          }
        }
        return;
      }
      case SMOOTH_V_PRED: {
        const bottom = e[EDGE - height];
        for (let y = 0;y < height; y++, d += stride) {
          const wv = SM_WEIGHTS2[height + y];
          for (let x = 0;x < width; x++)
            dst[d + x] = wv * e[EDGE + 1 + x] + (256 - wv) * bottom + 128 >> 8;
        }
        return;
      }
      case SMOOTH_H_PRED: {
        const right = e[EDGE + width];
        for (let y = 0;y < height; y++, d += stride) {
          const left = e[EDGE - 1 - y];
          for (let x = 0;x < width; x++) {
            const wh = SM_WEIGHTS2[width + x];
            dst[d + x] = wh * left + (256 - wh) * right + 128 >> 8;
          }
        }
        return;
      }
      case Z1_PRED:
        return z1(dst, d, stride, width, height, angle, bitdepthMax);
      case Z2_PRED:
        return z2(dst, d, stride, width, height, angle, maxWidth, maxHeight, bitdepthMax);
      case Z3_PRED:
        return z3(dst, d, stride, width, height, angle, bitdepthMax);
      case FILTER_PRED:
        return filterIntra(dst, d, stride, width, height, angle & 511, bitdepthMax);
    }
  }
  function cflAc(ac, y, yo, stride, wPad, hPad, width, height, ssHor, ssVer) {
    let a = 0, row;
    for (row = 0;row < height - 4 * hPad; row++) {
      let x;
      for (x = 0;x < width - 4 * wPad; x++) {
        let sum2 = y[yo + (x << ssHor)];
        if (ssHor)
          sum2 += y[yo + x * 2 + 1];
        if (ssVer) {
          sum2 += y[yo + (x << ssHor) + stride];
          if (ssHor)
            sum2 += y[yo + x * 2 + 1 + stride];
        }
        ac[a + x] = sum2 << 1 + (ssVer ? 0 : 1) + (ssHor ? 0 : 1);
      }
      for (;x < width; x++)
        ac[a + x] = ac[a + x - 1];
      a += width;
      yo += stride << ssVer;
    }
    for (;row < height; row++, a += width)
      ac.copyWithin(a, a - width, a);
    const log2 = ctz(width) + ctz(height);
    let sum = 1 << log2 >> 1;
    for (let i = 0;i < width * height; i++)
      sum += ac[i];
    sum >>= log2;
    for (let i = 0;i < width * height; i++)
      ac[i] -= sum;
  }
  function cflPredict(mode, dst, d, stride, width, height, ac, alpha, bitdepthMax) {
    const dc = dcValue(mode, width, height, bitdepthMax);
    for (let y = 0, a = 0;y < height; y++, d += stride) {
      for (let x = 0;x < width; x++, a++) {
        const diff = alpha * ac[a];
        const v = dc + (diff < 0 ? -(-diff + 32 >> 6) : diff + 32 >> 6);
        dst[d + x] = v < 0 ? 0 : v > bitdepthMax ? bitdepthMax : v;
      }
    }
  }

  // src/codecs/av1/itx.ts
  /*!
   * AV1 inverse transforms: DCT (4-64), ADST and flipped ADST (4-16), identity (4-32) and the Walsh-Hadamard transform
   * of lossless blocks, ported from dav1d (src/itx_1d.c, src/itx_tmpl.c). Copyright (c) 2018-2019, VideoLAN and dav1d
   * authors, Copyright (c) 2018-2019, Two Orioles, LLC, BSD-2-Clause License (see THIRD_PARTY_NOTICES.md)
   */
  var lo = 0;
  var hi = 0;
  var clip = (v) => v < lo ? lo : v > hi ? hi : v;
  function inv_dct4_1d_internal_c(c, o, stride, tx64) {
    const in0 = c[o + 0 * stride], in1 = c[o + 1 * stride];
    let t0, t1, t2, t3;
    if (tx64) {
      t0 = t1 = in0 * 181 + 128 >> 8;
      t2 = in1 * 1567 + 2048 >> 12;
      t3 = in1 * 3784 + 2048 >> 12;
    } else {
      const in2 = c[o + 2 * stride], in3 = c[o + 3 * stride];
      t0 = (in0 + in2) * 181 + 128 >> 8;
      t1 = (in0 - in2) * 181 + 128 >> 8;
      t2 = (in1 * 1567 - in3 * (3784 - 4096) + 2048 >> 12) - in3;
      t3 = (in1 * (3784 - 4096) + in3 * 1567 + 2048 >> 12) + in1;
    }
    c[o + 0 * stride] = clip(t0 + t3);
    c[o + 1 * stride] = clip(t1 + t2);
    c[o + 2 * stride] = clip(t1 - t2);
    c[o + 3 * stride] = clip(t0 - t3);
  }
  function inv_dct4_1d_c(c, o, stride) {
    inv_dct4_1d_internal_c(c, o, stride, 0);
  }
  function inv_dct8_1d_internal_c(c, o, stride, tx64) {
    inv_dct4_1d_internal_c(c, o, stride << 1, tx64);
    const in1 = c[o + 1 * stride], in3 = c[o + 3 * stride];
    let t4a, t5a, t6a, t7a;
    if (tx64) {
      t4a = in1 * 799 + 2048 >> 12;
      t5a = in3 * -2276 + 2048 >> 12;
      t6a = in3 * 3406 + 2048 >> 12;
      t7a = in1 * 4017 + 2048 >> 12;
    } else {
      const in5 = c[o + 5 * stride], in7 = c[o + 7 * stride];
      t4a = (in1 * 799 - in7 * (4017 - 4096) + 2048 >> 12) - in7;
      t5a = in5 * 1703 - in3 * 1138 + 1024 >> 11;
      t6a = in5 * 1138 + in3 * 1703 + 1024 >> 11;
      t7a = (in1 * (4017 - 4096) + in7 * 799 + 2048 >> 12) + in1;
    }
    const t4 = clip(t4a + t5a);
    t5a = clip(t4a - t5a);
    const t7 = clip(t7a + t6a);
    t6a = clip(t7a - t6a);
    const t5 = (t6a - t5a) * 181 + 128 >> 8;
    const t6 = (t6a + t5a) * 181 + 128 >> 8;
    const t0 = c[o + 0 * stride];
    const t1 = c[o + 2 * stride];
    const t2 = c[o + 4 * stride];
    const t3 = c[o + 6 * stride];
    c[o + 0 * stride] = clip(t0 + t7);
    c[o + 1 * stride] = clip(t1 + t6);
    c[o + 2 * stride] = clip(t2 + t5);
    c[o + 3 * stride] = clip(t3 + t4);
    c[o + 4 * stride] = clip(t3 - t4);
    c[o + 5 * stride] = clip(t2 - t5);
    c[o + 6 * stride] = clip(t1 - t6);
    c[o + 7 * stride] = clip(t0 - t7);
  }
  function inv_dct8_1d_c(c, o, stride) {
    inv_dct8_1d_internal_c(c, o, stride, 0);
  }
  function inv_dct16_1d_internal_c(c, o, stride, tx64) {
    inv_dct8_1d_internal_c(c, o, stride << 1, tx64);
    const in1 = c[o + 1 * stride], in3 = c[o + 3 * stride];
    const in5 = c[o + 5 * stride], in7 = c[o + 7 * stride];
    let t8a, t9a, t10a, t11a, t12a, t13a, t14a, t15a;
    if (tx64) {
      t8a = in1 * 401 + 2048 >> 12;
      t9a = in7 * -2598 + 2048 >> 12;
      t10a = in5 * 1931 + 2048 >> 12;
      t11a = in3 * -1189 + 2048 >> 12;
      t12a = in3 * 3920 + 2048 >> 12;
      t13a = in5 * 3612 + 2048 >> 12;
      t14a = in7 * 3166 + 2048 >> 12;
      t15a = in1 * 4076 + 2048 >> 12;
    } else {
      const in9 = c[o + 9 * stride], in11 = c[o + 11 * stride];
      const in13 = c[o + 13 * stride], in15 = c[o + 15 * stride];
      t8a = (in1 * 401 - in15 * (4076 - 4096) + 2048 >> 12) - in15;
      t9a = in9 * 1583 - in7 * 1299 + 1024 >> 11;
      t10a = (in5 * 1931 - in11 * (3612 - 4096) + 2048 >> 12) - in11;
      t11a = (in13 * (3920 - 4096) - in3 * 1189 + 2048 >> 12) + in13;
      t12a = (in13 * 1189 + in3 * (3920 - 4096) + 2048 >> 12) + in3;
      t13a = (in5 * (3612 - 4096) + in11 * 1931 + 2048 >> 12) + in5;
      t14a = in9 * 1299 + in7 * 1583 + 1024 >> 11;
      t15a = (in1 * (4076 - 4096) + in15 * 401 + 2048 >> 12) + in1;
    }
    let t8 = clip(t8a + t9a);
    let t9 = clip(t8a - t9a);
    let t10 = clip(t11a - t10a);
    let t11 = clip(t11a + t10a);
    let t12 = clip(t12a + t13a);
    let t13 = clip(t12a - t13a);
    let t14 = clip(t15a - t14a);
    let t15 = clip(t15a + t14a);
    t9a = (t14 * 1567 - t9 * (3784 - 4096) + 2048 >> 12) - t9;
    t14a = (t14 * (3784 - 4096) + t9 * 1567 + 2048 >> 12) + t14;
    t10a = (-(t13 * (3784 - 4096) + t10 * 1567) + 2048 >> 12) - t13;
    t13a = (t13 * 1567 - t10 * (3784 - 4096) + 2048 >> 12) - t10;
    t8a = clip(t8 + t11);
    t9 = clip(t9a + t10a);
    t10 = clip(t9a - t10a);
    t11a = clip(t8 - t11);
    t12a = clip(t15 - t12);
    t13 = clip(t14a - t13a);
    t14 = clip(t14a + t13a);
    t15a = clip(t15 + t12);
    t10a = (t13 - t10) * 181 + 128 >> 8;
    t13a = (t13 + t10) * 181 + 128 >> 8;
    t11 = (t12a - t11a) * 181 + 128 >> 8;
    t12 = (t12a + t11a) * 181 + 128 >> 8;
    const t0 = c[o + 0 * stride];
    const t1 = c[o + 2 * stride];
    const t2 = c[o + 4 * stride];
    const t3 = c[o + 6 * stride];
    const t4 = c[o + 8 * stride];
    const t5 = c[o + 10 * stride];
    const t6 = c[o + 12 * stride];
    const t7 = c[o + 14 * stride];
    c[o + 0 * stride] = clip(t0 + t15a);
    c[o + 1 * stride] = clip(t1 + t14);
    c[o + 2 * stride] = clip(t2 + t13a);
    c[o + 3 * stride] = clip(t3 + t12);
    c[o + 4 * stride] = clip(t4 + t11);
    c[o + 5 * stride] = clip(t5 + t10a);
    c[o + 6 * stride] = clip(t6 + t9);
    c[o + 7 * stride] = clip(t7 + t8a);
    c[o + 8 * stride] = clip(t7 - t8a);
    c[o + 9 * stride] = clip(t6 - t9);
    c[o + 10 * stride] = clip(t5 - t10a);
    c[o + 11 * stride] = clip(t4 - t11);
    c[o + 12 * stride] = clip(t3 - t12);
    c[o + 13 * stride] = clip(t2 - t13a);
    c[o + 14 * stride] = clip(t1 - t14);
    c[o + 15 * stride] = clip(t0 - t15a);
  }
  function inv_dct16_1d_c(c, o, stride) {
    inv_dct16_1d_internal_c(c, o, stride, 0);
  }
  function inv_dct32_1d_internal_c(c, o, stride, tx64) {
    inv_dct16_1d_internal_c(c, o, stride << 1, tx64);
    const in1 = c[o + 1 * stride], in3 = c[o + 3 * stride];
    const in5 = c[o + 5 * stride], in7 = c[o + 7 * stride];
    const in9 = c[o + 9 * stride], in11 = c[o + 11 * stride];
    const in13 = c[o + 13 * stride], in15 = c[o + 15 * stride];
    let t16a, t17a, t18a, t19a, t20a, t21a, t22a, t23a;
    let t24a, t25a, t26a, t27a, t28a, t29a, t30a, t31a;
    if (tx64) {
      t16a = in1 * 201 + 2048 >> 12;
      t17a = in15 * -2751 + 2048 >> 12;
      t18a = in9 * 1751 + 2048 >> 12;
      t19a = in7 * -1380 + 2048 >> 12;
      t20a = in5 * 995 + 2048 >> 12;
      t21a = in11 * -2106 + 2048 >> 12;
      t22a = in13 * 2440 + 2048 >> 12;
      t23a = in3 * -601 + 2048 >> 12;
      t24a = in3 * 4052 + 2048 >> 12;
      t25a = in13 * 3290 + 2048 >> 12;
      t26a = in11 * 3513 + 2048 >> 12;
      t27a = in5 * 3973 + 2048 >> 12;
      t28a = in7 * 3857 + 2048 >> 12;
      t29a = in9 * 3703 + 2048 >> 12;
      t30a = in15 * 3035 + 2048 >> 12;
      t31a = in1 * 4091 + 2048 >> 12;
    } else {
      const in17 = c[o + 17 * stride], in19 = c[o + 19 * stride];
      const in21 = c[o + 21 * stride], in23 = c[o + 23 * stride];
      const in25 = c[o + 25 * stride], in27 = c[o + 27 * stride];
      const in29 = c[o + 29 * stride], in31 = c[o + 31 * stride];
      t16a = (in1 * 201 - in31 * (4091 - 4096) + 2048 >> 12) - in31;
      t17a = (in17 * (3035 - 4096) - in15 * 2751 + 2048 >> 12) + in17;
      t18a = (in9 * 1751 - in23 * (3703 - 4096) + 2048 >> 12) - in23;
      t19a = (in25 * (3857 - 4096) - in7 * 1380 + 2048 >> 12) + in25;
      t20a = (in5 * 995 - in27 * (3973 - 4096) + 2048 >> 12) - in27;
      t21a = (in21 * (3513 - 4096) - in11 * 2106 + 2048 >> 12) + in21;
      t22a = in13 * 1220 - in19 * 1645 + 1024 >> 11;
      t23a = (in29 * (4052 - 4096) - in3 * 601 + 2048 >> 12) + in29;
      t24a = (in29 * 601 + in3 * (4052 - 4096) + 2048 >> 12) + in3;
      t25a = in13 * 1645 + in19 * 1220 + 1024 >> 11;
      t26a = (in21 * 2106 + in11 * (3513 - 4096) + 2048 >> 12) + in11;
      t27a = (in5 * (3973 - 4096) + in27 * 995 + 2048 >> 12) + in5;
      t28a = (in25 * 1380 + in7 * (3857 - 4096) + 2048 >> 12) + in7;
      t29a = (in9 * (3703 - 4096) + in23 * 1751 + 2048 >> 12) + in9;
      t30a = (in17 * 2751 + in15 * (3035 - 4096) + 2048 >> 12) + in15;
      t31a = (in1 * (4091 - 4096) + in31 * 201 + 2048 >> 12) + in1;
    }
    let t16 = clip(t16a + t17a);
    let t17 = clip(t16a - t17a);
    let t18 = clip(t19a - t18a);
    let t19 = clip(t19a + t18a);
    let t20 = clip(t20a + t21a);
    let t21 = clip(t20a - t21a);
    let t22 = clip(t23a - t22a);
    let t23 = clip(t23a + t22a);
    let t24 = clip(t24a + t25a);
    let t25 = clip(t24a - t25a);
    let t26 = clip(t27a - t26a);
    let t27 = clip(t27a + t26a);
    let t28 = clip(t28a + t29a);
    let t29 = clip(t28a - t29a);
    let t30 = clip(t31a - t30a);
    let t31 = clip(t31a + t30a);
    t17a = (t30 * 799 - t17 * (4017 - 4096) + 2048 >> 12) - t17;
    t30a = (t30 * (4017 - 4096) + t17 * 799 + 2048 >> 12) + t30;
    t18a = (-(t29 * (4017 - 4096) + t18 * 799) + 2048 >> 12) - t29;
    t29a = (t29 * 799 - t18 * (4017 - 4096) + 2048 >> 12) - t18;
    t21a = t26 * 1703 - t21 * 1138 + 1024 >> 11;
    t26a = t26 * 1138 + t21 * 1703 + 1024 >> 11;
    t22a = -(t25 * 1138 + t22 * 1703) + 1024 >> 11;
    t25a = t25 * 1703 - t22 * 1138 + 1024 >> 11;
    t16a = clip(t16 + t19);
    t17 = clip(t17a + t18a);
    t18 = clip(t17a - t18a);
    t19a = clip(t16 - t19);
    t20a = clip(t23 - t20);
    t21 = clip(t22a - t21a);
    t22 = clip(t22a + t21a);
    t23a = clip(t23 + t20);
    t24a = clip(t24 + t27);
    t25 = clip(t25a + t26a);
    t26 = clip(t25a - t26a);
    t27a = clip(t24 - t27);
    t28a = clip(t31 - t28);
    t29 = clip(t30a - t29a);
    t30 = clip(t30a + t29a);
    t31a = clip(t31 + t28);
    t18a = (t29 * 1567 - t18 * (3784 - 4096) + 2048 >> 12) - t18;
    t29a = (t29 * (3784 - 4096) + t18 * 1567 + 2048 >> 12) + t29;
    t19 = (t28a * 1567 - t19a * (3784 - 4096) + 2048 >> 12) - t19a;
    t28 = (t28a * (3784 - 4096) + t19a * 1567 + 2048 >> 12) + t28a;
    t20 = (-(t27a * (3784 - 4096) + t20a * 1567) + 2048 >> 12) - t27a;
    t27 = (t27a * 1567 - t20a * (3784 - 4096) + 2048 >> 12) - t20a;
    t21a = (-(t26 * (3784 - 4096) + t21 * 1567) + 2048 >> 12) - t26;
    t26a = (t26 * 1567 - t21 * (3784 - 4096) + 2048 >> 12) - t21;
    t16 = clip(t16a + t23a);
    t17a = clip(t17 + t22);
    t18 = clip(t18a + t21a);
    t19a = clip(t19 + t20);
    t20a = clip(t19 - t20);
    t21 = clip(t18a - t21a);
    t22a = clip(t17 - t22);
    t23 = clip(t16a - t23a);
    t24 = clip(t31a - t24a);
    t25a = clip(t30 - t25);
    t26 = clip(t29a - t26a);
    t27a = clip(t28 - t27);
    t28a = clip(t28 + t27);
    t29 = clip(t29a + t26a);
    t30a = clip(t30 + t25);
    t31 = clip(t31a + t24a);
    t20 = (t27a - t20a) * 181 + 128 >> 8;
    t27 = (t27a + t20a) * 181 + 128 >> 8;
    t21a = (t26 - t21) * 181 + 128 >> 8;
    t26a = (t26 + t21) * 181 + 128 >> 8;
    t22 = (t25a - t22a) * 181 + 128 >> 8;
    t25 = (t25a + t22a) * 181 + 128 >> 8;
    t23a = (t24 - t23) * 181 + 128 >> 8;
    t24a = (t24 + t23) * 181 + 128 >> 8;
    const t0 = c[o + 0 * stride];
    const t1 = c[o + 2 * stride];
    const t2 = c[o + 4 * stride];
    const t3 = c[o + 6 * stride];
    const t4 = c[o + 8 * stride];
    const t5 = c[o + 10 * stride];
    const t6 = c[o + 12 * stride];
    const t7 = c[o + 14 * stride];
    const t8 = c[o + 16 * stride];
    const t9 = c[o + 18 * stride];
    const t10 = c[o + 20 * stride];
    const t11 = c[o + 22 * stride];
    const t12 = c[o + 24 * stride];
    const t13 = c[o + 26 * stride];
    const t14 = c[o + 28 * stride];
    const t15 = c[o + 30 * stride];
    c[o + 0 * stride] = clip(t0 + t31);
    c[o + 1 * stride] = clip(t1 + t30a);
    c[o + 2 * stride] = clip(t2 + t29);
    c[o + 3 * stride] = clip(t3 + t28a);
    c[o + 4 * stride] = clip(t4 + t27);
    c[o + 5 * stride] = clip(t5 + t26a);
    c[o + 6 * stride] = clip(t6 + t25);
    c[o + 7 * stride] = clip(t7 + t24a);
    c[o + 8 * stride] = clip(t8 + t23a);
    c[o + 9 * stride] = clip(t9 + t22);
    c[o + 10 * stride] = clip(t10 + t21a);
    c[o + 11 * stride] = clip(t11 + t20);
    c[o + 12 * stride] = clip(t12 + t19a);
    c[o + 13 * stride] = clip(t13 + t18);
    c[o + 14 * stride] = clip(t14 + t17a);
    c[o + 15 * stride] = clip(t15 + t16);
    c[o + 16 * stride] = clip(t15 - t16);
    c[o + 17 * stride] = clip(t14 - t17a);
    c[o + 18 * stride] = clip(t13 - t18);
    c[o + 19 * stride] = clip(t12 - t19a);
    c[o + 20 * stride] = clip(t11 - t20);
    c[o + 21 * stride] = clip(t10 - t21a);
    c[o + 22 * stride] = clip(t9 - t22);
    c[o + 23 * stride] = clip(t8 - t23a);
    c[o + 24 * stride] = clip(t7 - t24a);
    c[o + 25 * stride] = clip(t6 - t25);
    c[o + 26 * stride] = clip(t5 - t26a);
    c[o + 27 * stride] = clip(t4 - t27);
    c[o + 28 * stride] = clip(t3 - t28a);
    c[o + 29 * stride] = clip(t2 - t29);
    c[o + 30 * stride] = clip(t1 - t30a);
    c[o + 31 * stride] = clip(t0 - t31);
  }
  function inv_dct32_1d_c(c, o, stride) {
    inv_dct32_1d_internal_c(c, o, stride, 0);
  }
  function inv_dct64_1d_c(c, o, stride) {
    inv_dct32_1d_internal_c(c, o, stride << 1, 1);
    const in1 = c[o + 1 * stride], in3 = c[o + 3 * stride];
    const in5 = c[o + 5 * stride], in7 = c[o + 7 * stride];
    const in9 = c[o + 9 * stride], in11 = c[o + 11 * stride];
    const in13 = c[o + 13 * stride], in15 = c[o + 15 * stride];
    const in17 = c[o + 17 * stride], in19 = c[o + 19 * stride];
    const in21 = c[o + 21 * stride], in23 = c[o + 23 * stride];
    const in25 = c[o + 25 * stride], in27 = c[o + 27 * stride];
    const in29 = c[o + 29 * stride], in31 = c[o + 31 * stride];
    let t32a = in1 * 101 + 2048 >> 12;
    let t33a = in31 * -2824 + 2048 >> 12;
    let t34a = in17 * 1660 + 2048 >> 12;
    let t35a = in15 * -1474 + 2048 >> 12;
    let t36a = in9 * 897 + 2048 >> 12;
    let t37a = in23 * -2191 + 2048 >> 12;
    let t38a = in25 * 2359 + 2048 >> 12;
    let t39a = in7 * -700 + 2048 >> 12;
    let t40a = in5 * 501 + 2048 >> 12;
    let t41a = in27 * -2520 + 2048 >> 12;
    let t42a = in21 * 2019 + 2048 >> 12;
    let t43a = in11 * -1092 + 2048 >> 12;
    let t44a = in13 * 1285 + 2048 >> 12;
    let t45a = in19 * -1842 + 2048 >> 12;
    let t46a = in29 * 2675 + 2048 >> 12;
    let t47a = in3 * -301 + 2048 >> 12;
    let t48a = in3 * 4085 + 2048 >> 12;
    let t49a = in29 * 3102 + 2048 >> 12;
    let t50a = in19 * 3659 + 2048 >> 12;
    let t51a = in13 * 3889 + 2048 >> 12;
    let t52a = in11 * 3948 + 2048 >> 12;
    let t53a = in21 * 3564 + 2048 >> 12;
    let t54a = in27 * 3229 + 2048 >> 12;
    let t55a = in5 * 4065 + 2048 >> 12;
    let t56a = in7 * 4036 + 2048 >> 12;
    let t57a = in25 * 3349 + 2048 >> 12;
    let t58a = in23 * 3461 + 2048 >> 12;
    let t59a = in9 * 3996 + 2048 >> 12;
    let t60a = in15 * 3822 + 2048 >> 12;
    let t61a = in17 * 3745 + 2048 >> 12;
    let t62a = in31 * 2967 + 2048 >> 12;
    let t63a = in1 * 4095 + 2048 >> 12;
    let t32 = clip(t32a + t33a);
    let t33 = clip(t32a - t33a);
    let t34 = clip(t35a - t34a);
    let t35 = clip(t35a + t34a);
    let t36 = clip(t36a + t37a);
    let t37 = clip(t36a - t37a);
    let t38 = clip(t39a - t38a);
    let t39 = clip(t39a + t38a);
    let t40 = clip(t40a + t41a);
    let t41 = clip(t40a - t41a);
    let t42 = clip(t43a - t42a);
    let t43 = clip(t43a + t42a);
    let t44 = clip(t44a + t45a);
    let t45 = clip(t44a - t45a);
    let t46 = clip(t47a - t46a);
    let t47 = clip(t47a + t46a);
    let t48 = clip(t48a + t49a);
    let t49 = clip(t48a - t49a);
    let t50 = clip(t51a - t50a);
    let t51 = clip(t51a + t50a);
    let t52 = clip(t52a + t53a);
    let t53 = clip(t52a - t53a);
    let t54 = clip(t55a - t54a);
    let t55 = clip(t55a + t54a);
    let t56 = clip(t56a + t57a);
    let t57 = clip(t56a - t57a);
    let t58 = clip(t59a - t58a);
    let t59 = clip(t59a + t58a);
    let t60 = clip(t60a + t61a);
    let t61 = clip(t60a - t61a);
    let t62 = clip(t63a - t62a);
    let t63 = clip(t63a + t62a);
    t33a = (t33 * (4096 - 4076) + t62 * 401 + 2048 >> 12) - t33;
    t34a = (t34 * -401 + t61 * (4096 - 4076) + 2048 >> 12) - t61;
    t37a = t37 * -1299 + t58 * 1583 + 1024 >> 11;
    t38a = t38 * -1583 + t57 * -1299 + 1024 >> 11;
    t41a = (t41 * (4096 - 3612) + t54 * 1931 + 2048 >> 12) - t41;
    t42a = (t42 * -1931 + t53 * (4096 - 3612) + 2048 >> 12) - t53;
    t45a = (t45 * -1189 + t50 * (3920 - 4096) + 2048 >> 12) + t50;
    t46a = (t46 * (4096 - 3920) + t49 * -1189 + 2048 >> 12) - t46;
    t49a = (t46 * -1189 + t49 * (3920 - 4096) + 2048 >> 12) + t49;
    t50a = (t45 * (3920 - 4096) + t50 * 1189 + 2048 >> 12) + t45;
    t53a = (t42 * (4096 - 3612) + t53 * 1931 + 2048 >> 12) - t42;
    t54a = (t41 * 1931 + t54 * (3612 - 4096) + 2048 >> 12) + t54;
    t57a = t38 * -1299 + t57 * 1583 + 1024 >> 11;
    t58a = t37 * 1583 + t58 * 1299 + 1024 >> 11;
    t61a = (t34 * (4096 - 4076) + t61 * 401 + 2048 >> 12) - t34;
    t62a = (t33 * 401 + t62 * (4076 - 4096) + 2048 >> 12) + t62;
    t32a = clip(t32 + t35);
    t33 = clip(t33a + t34a);
    t34 = clip(t33a - t34a);
    t35a = clip(t32 - t35);
    t36a = clip(t39 - t36);
    t37 = clip(t38a - t37a);
    t38 = clip(t38a + t37a);
    t39a = clip(t39 + t36);
    t40a = clip(t40 + t43);
    t41 = clip(t41a + t42a);
    t42 = clip(t41a - t42a);
    t43a = clip(t40 - t43);
    t44a = clip(t47 - t44);
    t45 = clip(t46a - t45a);
    t46 = clip(t46a + t45a);
    t47a = clip(t47 + t44);
    t48a = clip(t48 + t51);
    t49 = clip(t49a + t50a);
    t50 = clip(t49a - t50a);
    t51a = clip(t48 - t51);
    t52a = clip(t55 - t52);
    t53 = clip(t54a - t53a);
    t54 = clip(t54a + t53a);
    t55a = clip(t55 + t52);
    t56a = clip(t56 + t59);
    t57 = clip(t57a + t58a);
    t58 = clip(t57a - t58a);
    t59a = clip(t56 - t59);
    t60a = clip(t63 - t60);
    t61 = clip(t62a - t61a);
    t62 = clip(t62a + t61a);
    t63a = clip(t63 + t60);
    t34a = (t34 * (4096 - 4017) + t61 * 799 + 2048 >> 12) - t34;
    t35 = (t35a * (4096 - 4017) + t60a * 799 + 2048 >> 12) - t35a;
    t36 = (t36a * -799 + t59a * (4096 - 4017) + 2048 >> 12) - t59a;
    t37a = (t37 * -799 + t58 * (4096 - 4017) + 2048 >> 12) - t58;
    t42a = t42 * -1138 + t53 * 1703 + 1024 >> 11;
    t43 = t43a * -1138 + t52a * 1703 + 1024 >> 11;
    t44 = t44a * -1703 + t51a * -1138 + 1024 >> 11;
    t45a = t45 * -1703 + t50 * -1138 + 1024 >> 11;
    t50a = t45 * -1138 + t50 * 1703 + 1024 >> 11;
    t51 = t44a * -1138 + t51a * 1703 + 1024 >> 11;
    t52 = t43a * 1703 + t52a * 1138 + 1024 >> 11;
    t53a = t42 * 1703 + t53 * 1138 + 1024 >> 11;
    t58a = (t37 * (4096 - 4017) + t58 * 799 + 2048 >> 12) - t37;
    t59 = (t36a * (4096 - 4017) + t59a * 799 + 2048 >> 12) - t36a;
    t60 = (t35a * 799 + t60a * (4017 - 4096) + 2048 >> 12) + t60a;
    t61a = (t34 * 799 + t61 * (4017 - 4096) + 2048 >> 12) + t61;
    t32 = clip(t32a + t39a);
    t33a = clip(t33 + t38);
    t34 = clip(t34a + t37a);
    t35a = clip(t35 + t36);
    t36a = clip(t35 - t36);
    t37 = clip(t34a - t37a);
    t38a = clip(t33 - t38);
    t39 = clip(t32a - t39a);
    t40 = clip(t47a - t40a);
    t41a = clip(t46 - t41);
    t42 = clip(t45a - t42a);
    t43a = clip(t44 - t43);
    t44a = clip(t44 + t43);
    t45 = clip(t45a + t42a);
    t46a = clip(t46 + t41);
    t47 = clip(t47a + t40a);
    t48 = clip(t48a + t55a);
    t49a = clip(t49 + t54);
    t50 = clip(t50a + t53a);
    t51a = clip(t51 + t52);
    t52a = clip(t51 - t52);
    t53 = clip(t50a - t53a);
    t54a = clip(t49 - t54);
    t55 = clip(t48a - t55a);
    t56 = clip(t63a - t56a);
    t57a = clip(t62 - t57);
    t58 = clip(t61a - t58a);
    t59a = clip(t60 - t59);
    t60a = clip(t60 + t59);
    t61 = clip(t61a + t58a);
    t62a = clip(t62 + t57);
    t63 = clip(t63a + t56a);
    t36 = (t36a * (4096 - 3784) + t59a * 1567 + 2048 >> 12) - t36a;
    t37a = (t37 * (4096 - 3784) + t58 * 1567 + 2048 >> 12) - t37;
    t38 = (t38a * (4096 - 3784) + t57a * 1567 + 2048 >> 12) - t38a;
    t39a = (t39 * (4096 - 3784) + t56 * 1567 + 2048 >> 12) - t39;
    t40a = (t40 * -1567 + t55 * (4096 - 3784) + 2048 >> 12) - t55;
    t41 = (t41a * -1567 + t54a * (4096 - 3784) + 2048 >> 12) - t54a;
    t42a = (t42 * -1567 + t53 * (4096 - 3784) + 2048 >> 12) - t53;
    t43 = (t43a * -1567 + t52a * (4096 - 3784) + 2048 >> 12) - t52a;
    t52 = (t43a * (4096 - 3784) + t52a * 1567 + 2048 >> 12) - t43a;
    t53a = (t42 * (4096 - 3784) + t53 * 1567 + 2048 >> 12) - t42;
    t54 = (t41a * (4096 - 3784) + t54a * 1567 + 2048 >> 12) - t41a;
    t55a = (t40 * (4096 - 3784) + t55 * 1567 + 2048 >> 12) - t40;
    t56a = (t39 * 1567 + t56 * (3784 - 4096) + 2048 >> 12) + t56;
    t57 = (t38a * 1567 + t57a * (3784 - 4096) + 2048 >> 12) + t57a;
    t58a = (t37 * 1567 + t58 * (3784 - 4096) + 2048 >> 12) + t58;
    t59 = (t36a * 1567 + t59a * (3784 - 4096) + 2048 >> 12) + t59a;
    t32a = clip(t32 + t47);
    t33 = clip(t33a + t46a);
    t34a = clip(t34 + t45);
    t35 = clip(t35a + t44a);
    t36a = clip(t36 + t43);
    t37 = clip(t37a + t42a);
    t38a = clip(t38 + t41);
    t39 = clip(t39a + t40a);
    t40 = clip(t39a - t40a);
    t41a = clip(t38 - t41);
    t42 = clip(t37a - t42a);
    t43a = clip(t36 - t43);
    t44 = clip(t35a - t44a);
    t45a = clip(t34 - t45);
    t46 = clip(t33a - t46a);
    t47a = clip(t32 - t47);
    t48a = clip(t63 - t48);
    t49 = clip(t62a - t49a);
    t50a = clip(t61 - t50);
    t51 = clip(t60a - t51a);
    t52a = clip(t59 - t52);
    t53 = clip(t58a - t53a);
    t54a = clip(t57 - t54);
    t55 = clip(t56a - t55a);
    t56 = clip(t56a + t55a);
    t57a = clip(t57 + t54);
    t58 = clip(t58a + t53a);
    t59a = clip(t59 + t52);
    t60 = clip(t60a + t51a);
    t61a = clip(t61 + t50);
    t62 = clip(t62a + t49a);
    t63a = clip(t63 + t48);
    t40a = (t55 - t40) * 181 + 128 >> 8;
    t41 = (t54a - t41a) * 181 + 128 >> 8;
    t42a = (t53 - t42) * 181 + 128 >> 8;
    t43 = (t52a - t43a) * 181 + 128 >> 8;
    t44a = (t51 - t44) * 181 + 128 >> 8;
    t45 = (t50a - t45a) * 181 + 128 >> 8;
    t46a = (t49 - t46) * 181 + 128 >> 8;
    t47 = (t48a - t47a) * 181 + 128 >> 8;
    t48 = (t47a + t48a) * 181 + 128 >> 8;
    t49a = (t46 + t49) * 181 + 128 >> 8;
    t50 = (t45a + t50a) * 181 + 128 >> 8;
    t51a = (t44 + t51) * 181 + 128 >> 8;
    t52 = (t43a + t52a) * 181 + 128 >> 8;
    t53a = (t42 + t53) * 181 + 128 >> 8;
    t54 = (t41a + t54a) * 181 + 128 >> 8;
    t55a = (t40 + t55) * 181 + 128 >> 8;
    const t0 = c[o + 0 * stride];
    const t1 = c[o + 2 * stride];
    const t2 = c[o + 4 * stride];
    const t3 = c[o + 6 * stride];
    const t4 = c[o + 8 * stride];
    const t5 = c[o + 10 * stride];
    const t6 = c[o + 12 * stride];
    const t7 = c[o + 14 * stride];
    const t8 = c[o + 16 * stride];
    const t9 = c[o + 18 * stride];
    const t10 = c[o + 20 * stride];
    const t11 = c[o + 22 * stride];
    const t12 = c[o + 24 * stride];
    const t13 = c[o + 26 * stride];
    const t14 = c[o + 28 * stride];
    const t15 = c[o + 30 * stride];
    const t16 = c[o + 32 * stride];
    const t17 = c[o + 34 * stride];
    const t18 = c[o + 36 * stride];
    const t19 = c[o + 38 * stride];
    const t20 = c[o + 40 * stride];
    const t21 = c[o + 42 * stride];
    const t22 = c[o + 44 * stride];
    const t23 = c[o + 46 * stride];
    const t24 = c[o + 48 * stride];
    const t25 = c[o + 50 * stride];
    const t26 = c[o + 52 * stride];
    const t27 = c[o + 54 * stride];
    const t28 = c[o + 56 * stride];
    const t29 = c[o + 58 * stride];
    const t30 = c[o + 60 * stride];
    const t31 = c[o + 62 * stride];
    c[o + 0 * stride] = clip(t0 + t63a);
    c[o + 1 * stride] = clip(t1 + t62);
    c[o + 2 * stride] = clip(t2 + t61a);
    c[o + 3 * stride] = clip(t3 + t60);
    c[o + 4 * stride] = clip(t4 + t59a);
    c[o + 5 * stride] = clip(t5 + t58);
    c[o + 6 * stride] = clip(t6 + t57a);
    c[o + 7 * stride] = clip(t7 + t56);
    c[o + 8 * stride] = clip(t8 + t55a);
    c[o + 9 * stride] = clip(t9 + t54);
    c[o + 10 * stride] = clip(t10 + t53a);
    c[o + 11 * stride] = clip(t11 + t52);
    c[o + 12 * stride] = clip(t12 + t51a);
    c[o + 13 * stride] = clip(t13 + t50);
    c[o + 14 * stride] = clip(t14 + t49a);
    c[o + 15 * stride] = clip(t15 + t48);
    c[o + 16 * stride] = clip(t16 + t47);
    c[o + 17 * stride] = clip(t17 + t46a);
    c[o + 18 * stride] = clip(t18 + t45);
    c[o + 19 * stride] = clip(t19 + t44a);
    c[o + 20 * stride] = clip(t20 + t43);
    c[o + 21 * stride] = clip(t21 + t42a);
    c[o + 22 * stride] = clip(t22 + t41);
    c[o + 23 * stride] = clip(t23 + t40a);
    c[o + 24 * stride] = clip(t24 + t39);
    c[o + 25 * stride] = clip(t25 + t38a);
    c[o + 26 * stride] = clip(t26 + t37);
    c[o + 27 * stride] = clip(t27 + t36a);
    c[o + 28 * stride] = clip(t28 + t35);
    c[o + 29 * stride] = clip(t29 + t34a);
    c[o + 30 * stride] = clip(t30 + t33);
    c[o + 31 * stride] = clip(t31 + t32a);
    c[o + 32 * stride] = clip(t31 - t32a);
    c[o + 33 * stride] = clip(t30 - t33);
    c[o + 34 * stride] = clip(t29 - t34a);
    c[o + 35 * stride] = clip(t28 - t35);
    c[o + 36 * stride] = clip(t27 - t36a);
    c[o + 37 * stride] = clip(t26 - t37);
    c[o + 38 * stride] = clip(t25 - t38a);
    c[o + 39 * stride] = clip(t24 - t39);
    c[o + 40 * stride] = clip(t23 - t40a);
    c[o + 41 * stride] = clip(t22 - t41);
    c[o + 42 * stride] = clip(t21 - t42a);
    c[o + 43 * stride] = clip(t20 - t43);
    c[o + 44 * stride] = clip(t19 - t44a);
    c[o + 45 * stride] = clip(t18 - t45);
    c[o + 46 * stride] = clip(t17 - t46a);
    c[o + 47 * stride] = clip(t16 - t47);
    c[o + 48 * stride] = clip(t15 - t48);
    c[o + 49 * stride] = clip(t14 - t49a);
    c[o + 50 * stride] = clip(t13 - t50);
    c[o + 51 * stride] = clip(t12 - t51a);
    c[o + 52 * stride] = clip(t11 - t52);
    c[o + 53 * stride] = clip(t10 - t53a);
    c[o + 54 * stride] = clip(t9 - t54);
    c[o + 55 * stride] = clip(t8 - t55a);
    c[o + 56 * stride] = clip(t7 - t56);
    c[o + 57 * stride] = clip(t6 - t57a);
    c[o + 58 * stride] = clip(t5 - t58);
    c[o + 59 * stride] = clip(t4 - t59a);
    c[o + 60 * stride] = clip(t3 - t60);
    c[o + 61 * stride] = clip(t2 - t61a);
    c[o + 62 * stride] = clip(t1 - t62);
    c[o + 63 * stride] = clip(t0 - t63a);
  }
  function inv_adst4_1d_internal_c(inp, io, in_s, out, oo, out_s) {
    const in0 = inp[io + 0 * in_s], in1 = inp[io + 1 * in_s];
    const in2 = inp[io + 2 * in_s], in3 = inp[io + 3 * in_s];
    out[oo + 0 * out_s] = (1321 * in0 + (3803 - 4096) * in2 + (2482 - 4096) * in3 + (3344 - 4096) * in1 + 2048 >> 12) + in2 + in3 + in1;
    out[oo + 1 * out_s] = ((2482 - 4096) * in0 - 1321 * in2 - (3803 - 4096) * in3 + (3344 - 4096) * in1 + 2048 >> 12) + in0 - in3 + in1;
    out[oo + 2 * out_s] = 209 * (in0 - in2 + in3) + 128 >> 8;
    out[oo + 3 * out_s] = ((3803 - 4096) * in0 + (2482 - 4096) * in2 - 1321 * in3 - (3344 - 4096) * in1 + 2048 >> 12) + in0 + in2 - in1;
  }
  function inv_adst8_1d_internal_c(inp, io, in_s, out, oo, out_s) {
    const in0 = inp[io + 0 * in_s], in1 = inp[io + 1 * in_s];
    const in2 = inp[io + 2 * in_s], in3 = inp[io + 3 * in_s];
    const in4 = inp[io + 4 * in_s], in5 = inp[io + 5 * in_s];
    const in6 = inp[io + 6 * in_s], in7 = inp[io + 7 * in_s];
    const t0a = ((4076 - 4096) * in7 + 401 * in0 + 2048 >> 12) + in7;
    const t1a = (401 * in7 - (4076 - 4096) * in0 + 2048 >> 12) - in0;
    const t2a = ((3612 - 4096) * in5 + 1931 * in2 + 2048 >> 12) + in5;
    const t3a = (1931 * in5 - (3612 - 4096) * in2 + 2048 >> 12) - in2;
    let t4a = 1299 * in3 + 1583 * in4 + 1024 >> 11;
    let t5a = 1583 * in3 - 1299 * in4 + 1024 >> 11;
    let t6a = (1189 * in1 + (3920 - 4096) * in6 + 2048 >> 12) + in6;
    let t7a = ((3920 - 4096) * in1 - 1189 * in6 + 2048 >> 12) + in1;
    const t0 = clip(t0a + t4a);
    const t1 = clip(t1a + t5a);
    let t2 = clip(t2a + t6a);
    let t3 = clip(t3a + t7a);
    const t4 = clip(t0a - t4a);
    const t5 = clip(t1a - t5a);
    let t6 = clip(t2a - t6a);
    let t7 = clip(t3a - t7a);
    t4a = ((3784 - 4096) * t4 + 1567 * t5 + 2048 >> 12) + t4;
    t5a = (1567 * t4 - (3784 - 4096) * t5 + 2048 >> 12) - t5;
    t6a = ((3784 - 4096) * t7 - 1567 * t6 + 2048 >> 12) + t7;
    t7a = (1567 * t7 + (3784 - 4096) * t6 + 2048 >> 12) + t6;
    out[oo + 0 * out_s] = clip(t0 + t2);
    out[oo + 7 * out_s] = -clip(t1 + t3);
    t2 = clip(t0 - t2);
    t3 = clip(t1 - t3);
    out[oo + 1 * out_s] = -clip(t4a + t6a);
    out[oo + 6 * out_s] = clip(t5a + t7a);
    t6 = clip(t4a - t6a);
    t7 = clip(t5a - t7a);
    out[oo + 3 * out_s] = -((t2 + t3) * 181 + 128 >> 8);
    out[oo + 4 * out_s] = (t2 - t3) * 181 + 128 >> 8;
    out[oo + 2 * out_s] = (t6 + t7) * 181 + 128 >> 8;
    out[oo + 5 * out_s] = -((t6 - t7) * 181 + 128 >> 8);
  }
  function inv_adst16_1d_internal_c(inp, io, in_s, out, oo, out_s) {
    const in0 = inp[io + 0 * in_s], in1 = inp[io + 1 * in_s];
    const in2 = inp[io + 2 * in_s], in3 = inp[io + 3 * in_s];
    const in4 = inp[io + 4 * in_s], in5 = inp[io + 5 * in_s];
    const in6 = inp[io + 6 * in_s], in7 = inp[io + 7 * in_s];
    const in8 = inp[io + 8 * in_s], in9 = inp[io + 9 * in_s];
    const in10 = inp[io + 10 * in_s], in11 = inp[io + 11 * in_s];
    const in12 = inp[io + 12 * in_s], in13 = inp[io + 13 * in_s];
    const in14 = inp[io + 14 * in_s], in15 = inp[io + 15 * in_s];
    let t0 = (in15 * (4091 - 4096) + in0 * 201 + 2048 >> 12) + in15;
    let t1 = (in15 * 201 - in0 * (4091 - 4096) + 2048 >> 12) - in0;
    let t2 = (in13 * (3973 - 4096) + in2 * 995 + 2048 >> 12) + in13;
    let t3 = (in13 * 995 - in2 * (3973 - 4096) + 2048 >> 12) - in2;
    let t4 = (in11 * (3703 - 4096) + in4 * 1751 + 2048 >> 12) + in11;
    let t5 = (in11 * 1751 - in4 * (3703 - 4096) + 2048 >> 12) - in4;
    let t6 = in9 * 1645 + in6 * 1220 + 1024 >> 11;
    let t7 = in9 * 1220 - in6 * 1645 + 1024 >> 11;
    let t8 = (in7 * 2751 + in8 * (3035 - 4096) + 2048 >> 12) + in8;
    let t9 = (in7 * (3035 - 4096) - in8 * 2751 + 2048 >> 12) + in7;
    let t10 = (in5 * 2106 + in10 * (3513 - 4096) + 2048 >> 12) + in10;
    let t11 = (in5 * (3513 - 4096) - in10 * 2106 + 2048 >> 12) + in5;
    let t12 = (in3 * 1380 + in12 * (3857 - 4096) + 2048 >> 12) + in12;
    let t13 = (in3 * (3857 - 4096) - in12 * 1380 + 2048 >> 12) + in3;
    let t14 = (in1 * 601 + in14 * (4052 - 4096) + 2048 >> 12) + in14;
    let t15 = (in1 * (4052 - 4096) - in14 * 601 + 2048 >> 12) + in1;
    let t0a = clip(t0 + t8);
    let t1a = clip(t1 + t9);
    let t2a = clip(t2 + t10);
    let t3a = clip(t3 + t11);
    let t4a = clip(t4 + t12);
    let t5a = clip(t5 + t13);
    let t6a = clip(t6 + t14);
    let t7a = clip(t7 + t15);
    let t8a = clip(t0 - t8);
    let t9a = clip(t1 - t9);
    let t10a = clip(t2 - t10);
    let t11a = clip(t3 - t11);
    let t12a = clip(t4 - t12);
    let t13a = clip(t5 - t13);
    let t14a = clip(t6 - t14);
    let t15a = clip(t7 - t15);
    t8 = (t8a * (4017 - 4096) + t9a * 799 + 2048 >> 12) + t8a;
    t9 = (t8a * 799 - t9a * (4017 - 4096) + 2048 >> 12) - t9a;
    t10 = (t10a * 2276 + t11a * (3406 - 4096) + 2048 >> 12) + t11a;
    t11 = (t10a * (3406 - 4096) - t11a * 2276 + 2048 >> 12) + t10a;
    t12 = (t13a * (4017 - 4096) - t12a * 799 + 2048 >> 12) + t13a;
    t13 = (t13a * 799 + t12a * (4017 - 4096) + 2048 >> 12) + t12a;
    t14 = (t15a * 2276 - t14a * (3406 - 4096) + 2048 >> 12) - t14a;
    t15 = (t15a * (3406 - 4096) + t14a * 2276 + 2048 >> 12) + t15a;
    t0 = clip(t0a + t4a);
    t1 = clip(t1a + t5a);
    t2 = clip(t2a + t6a);
    t3 = clip(t3a + t7a);
    t4 = clip(t0a - t4a);
    t5 = clip(t1a - t5a);
    t6 = clip(t2a - t6a);
    t7 = clip(t3a - t7a);
    t8a = clip(t8 + t12);
    t9a = clip(t9 + t13);
    t10a = clip(t10 + t14);
    t11a = clip(t11 + t15);
    t12a = clip(t8 - t12);
    t13a = clip(t9 - t13);
    t14a = clip(t10 - t14);
    t15a = clip(t11 - t15);
    t4a = (t4 * (3784 - 4096) + t5 * 1567 + 2048 >> 12) + t4;
    t5a = (t4 * 1567 - t5 * (3784 - 4096) + 2048 >> 12) - t5;
    t6a = (t7 * (3784 - 4096) - t6 * 1567 + 2048 >> 12) + t7;
    t7a = (t7 * 1567 + t6 * (3784 - 4096) + 2048 >> 12) + t6;
    t12 = (t12a * (3784 - 4096) + t13a * 1567 + 2048 >> 12) + t12a;
    t13 = (t12a * 1567 - t13a * (3784 - 4096) + 2048 >> 12) - t13a;
    t14 = (t15a * (3784 - 4096) - t14a * 1567 + 2048 >> 12) + t15a;
    t15 = (t15a * 1567 + t14a * (3784 - 4096) + 2048 >> 12) + t14a;
    out[oo + 0 * out_s] = clip(t0 + t2);
    out[oo + 15 * out_s] = -clip(t1 + t3);
    t2a = clip(t0 - t2);
    t3a = clip(t1 - t3);
    out[oo + 3 * out_s] = -clip(t4a + t6a);
    out[oo + 12 * out_s] = clip(t5a + t7a);
    t6 = clip(t4a - t6a);
    t7 = clip(t5a - t7a);
    out[oo + 1 * out_s] = -clip(t8a + t10a);
    out[oo + 14 * out_s] = clip(t9a + t11a);
    t10 = clip(t8a - t10a);
    t11 = clip(t9a - t11a);
    out[oo + 2 * out_s] = clip(t12 + t14);
    out[oo + 13 * out_s] = -clip(t13 + t15);
    t14a = clip(t12 - t14);
    t15a = clip(t13 - t15);
    out[oo + 7 * out_s] = -((t2a + t3a) * 181 + 128 >> 8);
    out[oo + 8 * out_s] = (t2a - t3a) * 181 + 128 >> 8;
    out[oo + 4 * out_s] = (t6 + t7) * 181 + 128 >> 8;
    out[oo + 11 * out_s] = -((t6 - t7) * 181 + 128 >> 8);
    out[oo + 6 * out_s] = (t10 + t11) * 181 + 128 >> 8;
    out[oo + 9 * out_s] = -((t10 - t11) * 181 + 128 >> 8);
    out[oo + 5 * out_s] = -((t14a + t15a) * 181 + 128 >> 8);
    out[oo + 10 * out_s] = (t14a - t15a) * 181 + 128 >> 8;
  }
  function inv_adst4_1d_c(c, o, stride) {
    inv_adst4_1d_internal_c(c, o, stride, c, o, stride);
  }
  function inv_flipadst4_1d_c(c, o, stride) {
    inv_adst4_1d_internal_c(c, o, stride, c, o + 3 * stride, -stride);
  }
  function inv_adst8_1d_c(c, o, stride) {
    inv_adst8_1d_internal_c(c, o, stride, c, o, stride);
  }
  function inv_flipadst8_1d_c(c, o, stride) {
    inv_adst8_1d_internal_c(c, o, stride, c, o + 7 * stride, -stride);
  }
  function inv_adst16_1d_c(c, o, stride) {
    inv_adst16_1d_internal_c(c, o, stride, c, o, stride);
  }
  function inv_flipadst16_1d_c(c, o, stride) {
    inv_adst16_1d_internal_c(c, o, stride, c, o + 15 * stride, -stride);
  }
  function inv_identity4_1d_c(c, o, stride) {
    for (let i = 0;i < 4; i++) {
      const v = c[o + stride * i];
      c[o + stride * i] = v + (v * 1697 + 2048 >> 12);
    }
  }
  function inv_identity8_1d_c(c, o, stride) {
    for (let i = 0;i < 8; i++)
      c[o + stride * i] *= 2;
  }
  function inv_identity16_1d_c(c, o, stride) {
    for (let i = 0;i < 16; i++) {
      const v = c[o + stride * i];
      c[o + stride * i] = 2 * v + (v * 1697 + 1024 >> 11);
    }
  }
  function inv_identity32_1d_c(c, o, stride) {
    for (let i = 0;i < 32; i++)
      c[o + stride * i] *= 4;
  }
  function inv_wht4_1d_c(c, o, stride) {
    const in0 = c[o + 0 * stride], in1 = c[o + 1 * stride];
    const in2 = c[o + 2 * stride], in3 = c[o + 3 * stride];
    const t0 = in0 + in1;
    const t2 = in2 - in3;
    const t4 = t0 - t2 >> 1;
    const t3 = t4 - in3;
    const t1 = t4 - in1;
    c[o + 0 * stride] = t0 - t3;
    c[o + 1 * stride] = t3;
    c[o + 2 * stride] = t1;
    c[o + 3 * stride] = t2 + t1;
  }
  var DCT = 0;
  var ADST = 1;
  var FLIPADST = 2;
  var IDENTITY = 3;
  var TX1D = [
    [inv_dct4_1d_c, inv_adst4_1d_c, inv_flipadst4_1d_c, inv_identity4_1d_c],
    [inv_dct8_1d_c, inv_adst8_1d_c, inv_flipadst8_1d_c, inv_identity8_1d_c],
    [inv_dct16_1d_c, inv_adst16_1d_c, inv_flipadst16_1d_c, inv_identity16_1d_c],
    [inv_dct32_1d_c, null, null, inv_identity32_1d_c],
    [inv_dct64_1d_c, null, null, null]
  ];
  var MIRROR = [0, 2, 1, 3, 5, 4, 6, 8, 7, 9, 11, 10, 13, 12, 15, 14];
  var TX1D_TYPES = [
    [DCT, DCT],
    [ADST, DCT],
    [DCT, ADST],
    [ADST, ADST],
    [FLIPADST, DCT],
    [DCT, FLIPADST],
    [FLIPADST, FLIPADST],
    [ADST, FLIPADST],
    [FLIPADST, ADST],
    [IDENTITY, IDENTITY],
    [DCT, IDENTITY],
    [IDENTITY, DCT],
    [ADST, IDENTITY],
    [IDENTITY, ADST],
    [FLIPADST, IDENTITY],
    [IDENTITY, FLIPADST]
  ];
  var SHIFT = [0, 1, 2, 2, 2, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2];
  var tmp = new Int32Array(64 * 64);
  function inverseTransformAdd(dst, d, stride, coeff, eob, tx, txtp, bitdepthMax) {
    if (txtp === 16)
      return whtAdd(dst, d, stride, coeff, bitdepthMax);
    const w = 4 * TXFM_DIMENSIONS2[tx * 8], h = 4 * TXFM_DIMENSIONS2[tx * 8 + 1];
    const lw = TXFM_DIMENSIONS2[tx * 8 + 2], lh = TXFM_DIMENSIONS2[tx * 8 + 3];
    const shift = SHIFT[tx];
    const isRect2 = w * 2 === h || h * 2 === w;
    const rnd = 1 << shift >> 1;
    if (eob < (txtp === DCT_DCT ? 1 : 0)) {
      let dc = coeff[0];
      coeff[0] = 0;
      if (isRect2)
        dc = dc * 181 + 128 >> 8;
      dc = dc * 181 + 128 >> 8;
      dc = dc + rnd >> shift;
      dc = dc * 181 + 128 + 2048 >> 12;
      for (let y = 0;y < h; y++, d += stride) {
        for (let x = 0;x < w; x++) {
          const v = dst[d + x] + dc;
          dst[d + x] = v < 0 ? 0 : v > bitdepthMax ? bitdepthMax : v;
        }
      }
      return;
    }
    const [t0, t1] = TX1D_TYPES[MIRROR[txtp]];
    const first = TX1D[lw][t0], second = TX1D[lh][t1];
    const sh = Math.min(h, 32), sw = Math.min(w, 32);
    const rowMin = bitdepthMax === 255 ? -32768 : ~bitdepthMax << 7, colMin = bitdepthMax === 255 ? -32768 : ~bitdepthMax << 5;
    lo = rowMin;
    hi = ~rowMin;
    tmp.fill(0, 0, w * sh);
    for (let y = 0;y < sh; y++) {
      let nonzero = false;
      for (let x = 0;x < sw; x++)
        if (coeff[y + x * sh]) {
          nonzero = true;
          break;
        }
      if (!nonzero)
        continue;
      const c = y * w;
      if (isRect2)
        for (let x = 0;x < sw; x++)
          tmp[c + x] = coeff[y + x * sh] * 181 + 128 >> 8;
      else
        for (let x = 0;x < sw; x++)
          tmp[c + x] = coeff[y + x * sh];
      first(tmp, c, 1);
    }
    coeff.fill(0, 0, sw * sh);
    for (let i = 0;i < w * sh; i++) {
      const v = tmp[i] + rnd >> shift;
      tmp[i] = v < colMin ? colMin : v > ~colMin ? ~colMin : v;
    }
    lo = colMin;
    hi = ~colMin;
    for (let x = 0;x < w; x++)
      second(tmp, x, w);
    for (let y = 0, c = 0;y < h; y++, d += stride) {
      for (let x = 0;x < w; x++, c++) {
        const v = dst[d + x] + (tmp[c] + 8 >> 4);
        dst[d + x] = v < 0 ? 0 : v > bitdepthMax ? bitdepthMax : v;
      }
    }
  }
  function whtAdd(dst, d, stride, coeff, bitdepthMax) {
    for (let y = 0;y < 4; y++) {
      for (let x = 0;x < 4; x++)
        tmp[y * 4 + x] = coeff[y + x * 4] >> 2;
      inv_wht4_1d_c(tmp, y * 4, 1);
    }
    coeff.fill(0, 0, 16);
    for (let x = 0;x < 4; x++)
      inv_wht4_1d_c(tmp, x, 4);
    for (let y = 0, c = 0;y < 4; y++, d += stride) {
      for (let x = 0;x < 4; x++, c++) {
        const v = dst[d + x] + tmp[c];
        dst[d + x] = v < 0 ? 0 : v > bitdepthMax ? bitdepthMax : v;
      }
    }
  }

  // src/codecs/av1/decode.ts
  /*!
   * Decodes the tiles of AV1 intra frames: partitions, modes, palettes, transform sizes, coefficients and the intra
   * reconstruction, ported from dav1d (src/decode.c, src/recon_tmpl.c, src/lf_mask.c). Copyright (c) 2018-2021,
   * VideoLAN and dav1d authors, Copyright (c) 2018, Two Orioles, LLC, BSD-2-Clause License (see THIRD_PARTY_NOTICES.md)
   */
  var bdim = (bs, i) => BLOCK_DIMENSIONS2[bs * 4 + i];
  var tdim = (tx, i) => TXFM_DIMENSIONS2[tx * 8 + i];
  var W = 0;
  var H = 1;
  var LW = 2;
  var LH = 3;
  var MIN = 4;
  var MAX = 5;
  var SUB = 6;
  var CTX = 7;

  class Frame {
    seq;
    hdr;
    width;
    height;
    bitdepth;
    bitdepthMax;
    layout;
    ssx;
    ssy;
    planes = [];
    strides = [];
    bw;
    bh;
    b4Stride;
    lfLevels;
    txW;
    txH;
    uvTxW;
    uvTxH;
    skip;
    cdefIdx;
    segMap;
    lr = [[], [], []];
    lrUnitsW = [0, 0, 0];
    lrUnitsH = [0, 0, 0];
    incomplete = false;
    constructor(seq, hdr) {
      this.seq = seq;
      this.hdr = hdr;
      this.width = hdr.width;
      this.height = hdr.height;
      this.bitdepth = seq.bitDepth;
      this.bitdepthMax = (1 << seq.bitDepth) - 1;
      this.layout = seq.monochrome ? 0 : seq.ssx ? seq.ssy ? 1 : 2 : 3;
      this.ssx = seq.ssx;
      this.ssy = seq.ssy;
      this.bw = hdr.width + 7 >> 3 << 1;
      this.bh = hdr.height + 7 >> 3 << 1;
      this.b4Stride = this.bw + 31 & ~31;
      const b4Rows = this.bh + 31 & ~31;
      const lumaStride = this.b4Stride * 4, lumaRows = b4Rows * 4;
      for (let p = 0;p < (seq.monochrome ? 1 : 3); p++) {
        const sx = p ? this.ssx : 0, sy = p ? this.ssy : 0;
        this.strides.push(lumaStride >> sx);
        this.planes.push(new Uint16Array((lumaStride >> sx) * (lumaRows >> sy)));
      }
      const n = this.b4Stride * b4Rows;
      this.lfLevels = new Uint8Array(n * 4);
      this.txW = new Uint8Array(n);
      this.txH = new Uint8Array(n);
      this.uvTxW = new Uint8Array(n);
      this.uvTxH = new Uint8Array(n);
      this.skip = new Uint8Array(n);
      this.segMap = new Uint8Array(n);
      this.cdefIdx = new Int8Array((this.b4Stride >> 4) * (b4Rows >> 4)).fill(-1);
    }
  }
  function calcLfLevels(hdr, delta) {
    const lf = hdr.loopFilter;
    const out = [];
    const value = (base, lfDelta, segDelta) => {
      const b = Math.min(63, Math.max(0, Math.min(63, Math.max(0, base + lfDelta)) + segDelta));
      if (!lf.modeRefDeltaEnabled)
        return b;
      return Math.min(63, Math.max(0, b + lf.refDeltas[0] * (1 << (b >= 32 ? 1 : 0))));
    };
    for (let s = 0;s < (hdr.segmentation.enabled ? 8 : 1); s++) {
      if (!lf.levelY[0] && !lf.levelY[1]) {
        out.push([0, 0, 0, 0]);
        continue;
      }
      const seg = hdr.segmentation.enabled ? hdr.segmentation.data[s].deltaLf : [0, 0, 0, 0];
      const multi = hdr.deltaLf.multi;
      out.push([
        value(lf.levelY[0], delta[0], seg[0]),
        value(lf.levelY[1], delta[multi ? 1 : 0], seg[1]),
        lf.levelU ? value(lf.levelU, delta[multi ? 2 : 0], seg[2]) : 0,
        lf.levelV ? value(lf.levelV, delta[multi ? 3 : 0], seg[3]) : 0
      ]);
    }
    return out;
  }
  function quantTables(seq, hdr, qidx) {
    const q = hdr.quant, hbd = seq.bitDepth === 8 ? 0 : seq.bitDepth === 10 ? 1 : 2;
    const clip2 = (v) => Math.min(255, Math.max(0, v));
    const out = [];
    for (let i = 0;i < (hdr.segmentation.enabled ? 8 : 1); i++) {
      const yac = hdr.segmentation.enabled ? clip2(qidx + hdr.segmentation.data[i].deltaQ) : qidx;
      out.push([
        [dequant(hbd, clip2(yac + q.ydcDelta), 0), dequant(hbd, yac, 1)],
        [dequant(hbd, clip2(yac + q.udcDelta), 0), dequant(hbd, clip2(yac + q.uacDelta), 1)],
        [dequant(hbd, clip2(yac + q.vdcDelta), 0), dequant(hbd, clip2(yac + q.vacDelta), 1)]
      ]);
    }
    return out;
  }
  var neg_deinterleave = (diff, ref, max2) => {
    if (!ref)
      return diff;
    if (ref >= max2 - 1)
      return max2 - diff - 1;
    if (2 * ref < max2) {
      if (diff <= 2 * ref)
        return diff & 1 ? ref + (diff + 1 >> 1) : ref - (diff >> 1);
      return diff;
    }
    if (diff <= 2 * (max2 - ref - 1))
      return diff & 1 ? ref + (diff + 1 >> 1) : ref - (diff >> 1);
    return max2 - (diff + 1);
  };
  function decodeTileGroup(decoder, data, start, end, first, last) {
    const hdr = decoder.frame.hdr;
    let o = start;
    for (let j = first;j <= last; j++) {
      let size;
      if (j === last)
        size = end - o;
      else {
        size = 0;
        for (let k = 0;k < hdr.tiles.sizeBytes; k++)
          size += data[o++] * 2 ** (k * 8);
        size++;
        if (o + size > end)
          throw new Error("AV1: invalid tile size");
      }
      decoder.decodeTile(data, o, o + size, Math.floor(j / hdr.tiles.cols), j % hdr.tiles.cols);
      o += size;
    }
  }

  class TileDecoder {
    frame;
    seq;
    hdr;
    msac;
    cdf;
    bx = 0;
    by = 0;
    colStart = 0;
    colEnd = 0;
    rowStart = 0;
    rowEnd = 0;
    lastQidx = 0;
    lastDeltaLf = [0, 0, 0, 0];
    dq;
    frameDq;
    lfLvl;
    frameLfLvl;
    lrRef = [];
    cdefSb = 0;
    aMode;
    lMode = new Uint8Array(32);
    aLcoef;
    lLcoef = new Uint8Array(32);
    aCcoef;
    lCcoef = [new Uint8Array(32), new Uint8Array(32)];
    aSegPred;
    lSegPred = new Uint8Array(32);
    aSkip;
    lSkip = new Uint8Array(32);
    aIntra;
    lIntra = new Uint8Array(32);
    aTxIntra;
    lTxIntra = new Int8Array(32);
    aTx;
    lTx = new Int8Array(32);
    aUvmode;
    lUvmode = new Uint8Array(32);
    aPalSz;
    lPalSz = new Uint8Array(32);
    aPalSzUv;
    lPalSzUv = new Uint8Array(32);
    aPartition;
    lPartition = new Uint8Array(16);
    aPal;
    lPal = new Uint16Array(32 * 24);
    pal = new Uint16Array(24);
    palIdxY = new Uint8Array(64 * 64);
    palIdxUv = new Uint8Array(64 * 64);
    palTmp = new Uint8Array(64 * 64);
    cf = new Int32Array(32 * 32);
    levels = new Uint8Array(36 * 36);
    ac = new Int16Array(32 * 32);
    qm = [];
    constructor(frame) {
      this.frame = frame;
      this.seq = frame.seq;
      this.hdr = frame.hdr;
      const n = frame.b4Stride + 32;
      this.aMode = new Uint8Array(n);
      this.aLcoef = new Uint8Array(n);
      this.aCcoef = [new Uint8Array(n), new Uint8Array(n)];
      this.aSegPred = new Uint8Array(n);
      this.aSkip = new Uint8Array(n);
      this.aIntra = new Uint8Array(n);
      this.aTxIntra = new Int8Array(n);
      this.aTx = new Int8Array(n);
      this.aUvmode = new Uint8Array(n);
      this.aPalSz = new Uint8Array(n);
      this.aPalSzUv = new Uint8Array(n);
      this.aPartition = new Uint8Array(n >> 1);
      this.aPal = new Uint16Array(n * 24);
      this.frameDq = this.dq = quantTables(this.seq, this.hdr, this.hdr.quant.yac);
      this.frameLfLvl = this.lfLvl = calcLfLevels(this.hdr, [0, 0, 0, 0]);
      for (let tx = 0;tx < 19; tx++) {
        const q = this.hdr.quant;
        this.qm.push(q.qm ? [q.qmY, q.qmU, q.qmV].map((level, p) => level < 15 ? quantizerMatrix(level, p ? 1 : 0, tx) : null) : [null, null, null]);
      }
      this.resetAbove(0, n);
      if (this.hdr.allowIntrabc) {
        const size = frame.b4Stride * ((frame.bh + 31 & ~31) + 32);
        this.mvY = new Int16Array(size);
        this.mvX = new Int16Array(size);
        this.mvValid = new Uint8Array(size);
        this.mvBs = new Uint8Array(size);
      }
      for (let p = 0;p < frame.planes.length; p++) {
        const type = this.hdr.restoration.types[p];
        if (type === RESTORATION_NONE)
          continue;
        const sx = p ? frame.ssx : 0, sy = p ? frame.ssy : 0;
        const size = 1 << this.hdr.restoration.unitSizeLog2[p ? 1 : 0];
        const w = this.hdr.upscaledWidth + sx >> sx, h = frame.height + sy >> sy;
        const cols = Math.max(1, Math.floor((w + (size >> 1)) / size)), rows = Math.max(1, Math.floor((h + (size >> 1)) / size));
        frame.lrUnitsW[p] = cols;
        frame.lrUnitsH[p] = rows;
        for (let i = 0;i < cols * rows; i++)
          frame.lr[p].push({ type: RESTORATION_NONE, filterV: [3, -7, 15], filterH: [3, -7, 15], sgrWeights: [-32, 31] });
      }
    }
    resetAbove(from, to) {
      this.aIntra.fill(1, from, to);
      this.aUvmode.fill(DC_PRED, from, to);
      this.aMode.fill(DC_PRED, from, to);
      this.aPartition.fill(0, from >> 1, to + 1 >> 1);
      this.aSkip.fill(0, from, to);
      this.aTxIntra.fill(-1, from, to);
      this.aTx.fill(TX_64X64, from, to);
      this.aLcoef.fill(64, from, to);
      this.aCcoef[0].fill(64, from, to);
      this.aCcoef[1].fill(64, from, to);
      this.aSegPred.fill(0, from, to);
      this.aPalSz.fill(0, from, to);
      this.aPalSzUv.fill(0, from, to);
    }
    resetLeft() {
      this.lIntra.fill(1);
      this.lUvmode.fill(DC_PRED);
      this.lMode.fill(DC_PRED);
      this.lPartition.fill(0);
      this.lSkip.fill(0);
      this.lTxIntra.fill(-1);
      this.lTx.fill(TX_64X64);
      this.lLcoef.fill(64);
      this.lCcoef[0].fill(64);
      this.lCcoef[1].fill(64);
      this.lSegPred.fill(0);
      this.lPalSz.fill(0);
      this.lPalSzUv.fill(0);
    }
    tileRow = -1;
    decodeTile(data, start, end, tileRow, tileCol) {
      const f = this.frame, hdr = this.hdr, seq = this.seq;
      if (tileRow !== this.tileRow) {
        this.tileRow = tileRow;
        this.resetAbove(0, this.aMode.length);
      }
      const sbShift = seq.sb128 ? 5 : 4, sbStep = 1 << sbShift;
      this.colStart = hdr.tiles.colStarts[tileCol] << sbShift;
      this.colEnd = Math.min(hdr.tiles.colStarts[tileCol + 1] << sbShift, f.bw);
      this.rowStart = hdr.tiles.rowStarts[tileRow] << sbShift;
      this.rowEnd = Math.min(hdr.tiles.rowStarts[tileRow + 1] << sbShift, f.bh);
      this.cdf = defaultCdfs(hdr.quant.yac);
      this.msac = new SymbolDecoder(data, start, end, !hdr.disableCdfUpdate);
      this.lastQidx = hdr.quant.yac;
      this.lastDeltaLf = [0, 0, 0, 0];
      this.dq = this.frameDq;
      this.lfLvl = this.frameLfLvl;
      for (let p = 0;p < 3; p++)
        this.lrRef[p] = { type: RESTORATION_NONE, filterV: [3, -7, 15], filterH: [3, -7, 15], sgrWeights: [-32, 31] };
      const root = edgeTree(seq.sb128);
      for (this.by = this.rowStart;this.by < this.rowEnd; this.by += sbStep) {
        this.resetLeft();
        for (this.bx = this.colStart;this.bx < this.colEnd; this.bx += sbStep) {
          this.cdefSb = (this.by >> 4) * (f.b4Stride >> 4) + (this.bx >> 4);
          this.readRestorationUnits();
          this.decodeSb(seq.sb128 ? BL_128X128 : 1, root);
        }
      }
      if (this.msac.overread)
        throw new Error("AV1: truncated tile data");
    }
    readRestorationUnits() {
      const f = this.frame, hdr = this.hdr;
      if (hdr.superresDenominator !== 8 && hdr.restoration.types.some((t) => t)) {
        this.readRestorationUnitsSuperres();
        return;
      }
      for (let p = 0;p < f.planes.length; p++) {
        const type = hdr.restoration.types[p];
        if (type === RESTORATION_NONE)
          continue;
        const sx = p ? f.ssx : 0, sy = p ? f.ssy : 0;
        const sizeLog2 = hdr.restoration.unitSizeLog2[p ? 1 : 0], size = 1 << sizeLog2, mask = size - 1;
        const y = this.by * 4 >> sy, h = f.height + sy >> sy;
        if (y & mask)
          continue;
        if (y && y + (size >> 1) > h)
          continue;
        const x = this.bx * 4 >> sx, w = f.width + sx >> sx;
        if (x & mask)
          continue;
        if (x && x + (size >> 1) > w)
          continue;
        const unit = f.lr[p][(y >> sizeLog2) * f.lrUnitsW[p] + (x >> sizeLog2)];
        this.readRestorationInfo(unit, p, type);
      }
    }
    readRestorationUnitsSuperres() {
      const f = this.frame, hdr = this.hdr;
      const sbStep = this.seq.sb128 ? 32 : 16;
      for (let p = 0;p < f.planes.length; p++) {
        const type = hdr.restoration.types[p];
        if (type === RESTORATION_NONE)
          continue;
        const sx = p ? f.ssx : 0, sy = p ? f.ssy : 0;
        const sizeLog2 = hdr.restoration.unitSizeLog2[p ? 1 : 0], size = 1 << sizeLog2;
        const y = this.by * 4 >> sy, h = f.height + sy >> sy;
        if (y & size - 1)
          continue;
        if (y && y + (size >> 1) > h)
          continue;
        const d = hdr.superresDenominator;
        const rnd = size * 8 - 1, shift = sizeLog2 + 3;
        const x0 = (4 * this.bx * d >> sx) + rnd >> shift;
        const x1 = (4 * (this.bx + sbStep) * d >> sx) + rnd >> shift;
        for (let x = x0;x < Math.min(x1, f.lrUnitsW[p]); x++) {
          const unit = f.lr[p][(y >> sizeLog2) * f.lrUnitsW[p] + x];
          this.readRestorationInfo(unit, p, type);
        }
      }
    }
    readRestorationInfo(lr, p, frameType) {
      const m = this.msac, cdf = this.cdf;
      if (frameType === RESTORATION_SWITCHABLE) {
        const filter = m.symbol(cdf, CDF2.restoreSwitchable, 2);
        lr.type = filter ? filter + 1 : RESTORATION_NONE;
      } else {
        const type = m.boolAdapt(cdf, frameType === RESTORATION_WIENER ? CDF2.restoreWiener : CDF2.restoreSgrproj);
        lr.type = type ? frameType : RESTORATION_NONE;
      }
      const ref = this.lrRef[p];
      if (lr.type === RESTORATION_WIENER) {
        lr.filterV = [
          p ? 0 : m.subexp(ref.filterV[0] + 5, 16, 1) - 5,
          m.subexp(ref.filterV[1] + 23, 32, 2) - 23,
          m.subexp(ref.filterV[2] + 17, 64, 3) - 17
        ];
        lr.filterH = [
          p ? 0 : m.subexp(ref.filterH[0] + 5, 16, 1) - 5,
          m.subexp(ref.filterH[1] + 23, 32, 2) - 23,
          m.subexp(ref.filterH[2] + 17, 64, 3) - 17
        ];
        lr.sgrWeights = ref.sgrWeights.slice();
        this.lrRef[p] = lr;
      } else if (lr.type === RESTORATION_SGRPROJ) {
        const idx = m.bools(4);
        lr.type += idx;
        lr.sgrWeights = [
          SGR_PARAMS2[idx * 2] ? m.subexp(ref.sgrWeights[0] + 96, 128, 4) - 96 : 0,
          SGR_PARAMS2[idx * 2 + 1] ? m.subexp(ref.sgrWeights[1] + 32, 128, 4) - 32 : 95
        ];
        lr.filterV = ref.filterV.slice();
        lr.filterH = ref.filterH.slice();
        this.lrRef[p] = lr;
      }
    }
    decodeSb(bl, node) {
      const f = this.frame;
      const hsz = 16 >> bl;
      const haveH = f.bw > this.bx + hsz, haveV = f.bh > this.by + hsz;
      if (!haveH && !haveV)
        return this.decodeSb(bl + 1, node.split[0]);
      const bx8 = this.bx >> 1, by8 = (this.by & 31) >> 1;
      const ctx = (this.aPartition[bx8] >> 4 - bl & 1) + ((this.lPartition[by8] >> 4 - bl & 1) << 1);
      const pc = CDF2.partition + (bl * 4 + ctx) * 16;
      const cdf = this.cdf;
      let bp;
      if (haveH && haveV) {
        bp = this.msac.symbol(cdf, pc, PARTITION_TYPE_COUNT2[bl]);
        if (f.layout === 2 && (bp === PARTITION_V || bp === PARTITION_V4 || bp === PARTITION_T_LEFT_SPLIT || bp === PARTITION_T_RIGHT_SPLIT))
          throw new Error("AV1: invalid partition");
        const b = (i) => BLOCK_SIZES2[(bl * 10 + bp) * 2 + i];
        switch (bp) {
          case PARTITION_NONE:
            this.decodeB(b(0), node.o);
            break;
          case PARTITION_H:
            this.decodeB(b(0), node.h[0]);
            this.by += hsz;
            this.decodeB(b(0), node.h[1]);
            this.by -= hsz;
            break;
          case PARTITION_V:
            this.decodeB(b(0), node.v[0]);
            this.bx += hsz;
            this.decodeB(b(0), node.v[1]);
            this.bx -= hsz;
            break;
          case PARTITION_SPLIT:
            if (bl === BL_8X8) {
              this.decodeB(BS_4x4, EDGE_ALL_TR_AND_BL);
              this.bx++;
              this.decodeB(BS_4x4, node.tip[0]);
              this.bx--;
              this.by++;
              this.decodeB(BS_4x4, node.tip[1]);
              this.bx++;
              this.decodeB(BS_4x4, node.tip[2]);
              this.bx--;
              this.by--;
            } else {
              this.decodeSb(bl + 1, node.split[0]);
              this.bx += hsz;
              this.decodeSb(bl + 1, node.split[1]);
              this.bx -= hsz;
              this.by += hsz;
              this.decodeSb(bl + 1, node.split[2]);
              this.bx += hsz;
              this.decodeSb(bl + 1, node.split[3]);
              this.bx -= hsz;
              this.by -= hsz;
            }
            break;
          case PARTITION_T_TOP_SPLIT:
            this.decodeB(b(0), EDGE_ALL_TR_AND_BL);
            this.bx += hsz;
            this.decodeB(b(0), node.v[1]);
            this.bx -= hsz;
            this.by += hsz;
            this.decodeB(b(1), node.h[1]);
            this.by -= hsz;
            break;
          case PARTITION_T_BOTTOM_SPLIT:
            this.decodeB(b(0), node.h[0]);
            this.by += hsz;
            this.decodeB(b(1), node.v[0]);
            this.bx += hsz;
            this.decodeB(b(1), 0);
            this.bx -= hsz;
            this.by -= hsz;
            break;
          case PARTITION_T_LEFT_SPLIT:
            this.decodeB(b(0), EDGE_ALL_TR_AND_BL);
            this.by += hsz;
            this.decodeB(b(0), node.h[1]);
            this.by -= hsz;
            this.bx += hsz;
            this.decodeB(b(1), node.v[1]);
            this.bx -= hsz;
            break;
          case PARTITION_T_RIGHT_SPLIT:
            this.decodeB(b(0), node.v[0]);
            this.bx += hsz;
            this.decodeB(b(1), node.h[0]);
            this.by += hsz;
            this.decodeB(b(1), 0);
            this.by -= hsz;
            this.bx -= hsz;
            break;
          case PARTITION_H4:
            this.decodeB(b(0), node.h[0]);
            this.by += hsz >> 1;
            this.decodeB(b(0), node.h4);
            this.by += hsz >> 1;
            this.decodeB(b(0), EDGE_ALL_LEFT_HAS_BOTTOM);
            this.by += hsz >> 1;
            if (this.by < f.bh)
              this.decodeB(b(0), node.h[1]);
            this.by -= hsz * 3 >> 1;
            break;
          case PARTITION_V4:
            this.decodeB(b(0), node.v[0]);
            this.bx += hsz >> 1;
            this.decodeB(b(0), node.v4);
            this.bx += hsz >> 1;
            this.decodeB(b(0), EDGE_ALL_TOP_HAS_RIGHT);
            this.bx += hsz >> 1;
            if (this.bx < f.bw)
              this.decodeB(b(0), node.v[1]);
            this.bx -= hsz * 3 >> 1;
            break;
        }
      } else if (haveH) {
        let prob = cdf[pc + PARTITION_V - 1] - cdf[pc + PARTITION_T_TOP_SPLIT];
        prob += cdf[pc + PARTITION_T_LEFT_SPLIT - 1];
        if (bl !== BL_128X128)
          prob += cdf[pc + PARTITION_V4 - 1] - cdf[pc + PARTITION_T_RIGHT_SPLIT];
        const split = this.msac.boolProb(prob);
        if (split) {
          bp = PARTITION_SPLIT;
          this.decodeSb(bl + 1, node.split[0]);
          this.bx += hsz;
          this.decodeSb(bl + 1, node.split[1]);
          this.bx -= hsz;
        } else {
          bp = PARTITION_H;
          this.decodeB(BLOCK_SIZES2[(bl * 10 + PARTITION_H) * 2], node.h[0]);
        }
      } else {
        let prob = cdf[pc + PARTITION_H - 1] - cdf[pc + PARTITION_H];
        prob += cdf[pc + PARTITION_SPLIT - 1] - cdf[pc + PARTITION_T_LEFT_SPLIT];
        if (bl !== BL_128X128)
          prob += cdf[pc + PARTITION_H4 - 1] - cdf[pc + PARTITION_H4];
        const split = this.msac.boolProb(prob);
        if (f.layout === 2 && !split)
          throw new Error("AV1: invalid partition");
        if (split) {
          bp = PARTITION_SPLIT;
          this.decodeSb(bl + 1, node.split[0]);
          this.by += hsz;
          this.decodeSb(bl + 1, node.split[2]);
          this.by -= hsz;
        } else {
          bp = PARTITION_V;
          this.decodeB(BLOCK_SIZES2[(bl * 10 + PARTITION_V) * 2], node.v[0]);
        }
      }
      if (bp !== PARTITION_SPLIT || bl === BL_8X8) {
        this.aPartition.fill(AL_PART_CTX2[bl * 10 + bp], bx8, bx8 + hsz);
        this.lPartition.fill(AL_PART_CTX2[50 + bl * 10 + bp], by8, by8 + hsz);
      }
    }
    decodeB(bs, edgeFlags) {
      const f = this.frame, hdr = this.hdr, seq = this.seq, m = this.msac, cdf = this.cdf;
      const bx = this.bx, by = this.by, bx4 = bx, by4 = by & 31;
      const { ssx, ssy } = f;
      const cbx4 = bx4 >> ssx, cby4 = by4 >> ssy;
      const bw4 = bdim(bs, 0), bh4 = bdim(bs, 1), lw4 = bdim(bs, 2), lh4 = bdim(bs, 3);
      const w4 = Math.min(bw4, f.bw - bx), h4 = Math.min(bh4, f.bh - by);
      const cbw4 = bw4 + ssx >> ssx, cbh4 = bh4 + ssy >> ssy;
      const haveLeft = bx > this.colStart, haveTop = by > this.rowStart;
      const hasChroma = f.layout !== 0 && (bw4 > ssx || !!(bx & 1)) && (bh4 > ssy || !!(by & 1));
      const b = { segId: 0, skip: 0, yMode: 0, yAngle: 0, uvMode: 0, uvAngle: 0, cflAlpha: [0, 0], palSz: [0, 0], tx: 0, uvtx: 0 };
      const segmentation = hdr.segmentation;
      let seg = null;
      const readSegId = () => {
        const { segMap: map, b4Stride: s } = f, o = by * s + bx;
        let segCtx, pred;
        if (haveLeft && haveTop) {
          const l = map[o - 1], a = map[o - s], al = map[o - s - 1];
          segCtx = l === a && al === l ? 2 : l === a || al === l || a === al ? 1 : 0;
          pred = a === al ? a : l;
        } else {
          segCtx = 0;
          pred = haveLeft ? map[o - 1] : haveTop ? map[o - s] : 0;
        }
        if (b.skip && !segmentation.preskip)
          b.segId = pred;
        else {
          const diff = m.symbol(cdf, CDF2.segId + segCtx * 8, 7);
          b.segId = neg_deinterleave(diff, pred, segmentation.lastActiveSegId + 1);
          if (b.segId > segmentation.lastActiveSegId)
            b.segId = 0;
        }
        if (b.segId >= 8)
          b.segId = 0;
      };
      if (segmentation.enabled && segmentation.preskip) {
        readSegId();
        seg = segmentation.data[b.segId];
      }
      if (seg?.skip)
        b.skip = 1;
      else {
        b.skip = m.boolAdapt(cdf, CDF2.skip + (this.aSkip[bx4] + this.lSkip[by4]) * 2);
      }
      if (segmentation.enabled && !segmentation.preskip)
        readSegId();
      if (!b.skip) {
        const idx = seq.sb128 ? this.cdefSb + (bx >> 4 & 1) + (by >> 4 & 1) * (f.b4Stride >> 4) : this.cdefSb;
        if (f.cdefIdx[idx] === -1) {
          const v = m.bools(hdr.cdef.bits);
          f.cdefIdx[idx] = v;
          const stride = f.b4Stride >> 4;
          if (bw4 > 16)
            f.cdefIdx[idx + 1] = v;
          if (bh4 > 16)
            f.cdefIdx[idx + stride] = v;
          if (bw4 === 32 && bh4 === 32)
            f.cdefIdx[idx + stride + 1] = v;
        }
      }
      const sbMask = seq.sb128 ? 31 : 15;
      if (!(bx & sbMask) && !(by & sbMask)) {
        const prevQidx = this.lastQidx;
        const prevDeltaLf = this.lastDeltaLf.join();
        if (hdr.deltaQ.present && (bs !== (seq.sb128 ? BS_128x128 : BS_64x64) || !b.skip)) {
          const readDelta = (o) => {
            let d = m.symbol(cdf, o, 3);
            if (d === 3) {
              const n = 1 + m.bools(3);
              d = m.bools(n) + 1 + (1 << n);
            }
            return d;
          };
          let deltaQ = readDelta(CDF2.deltaQ);
          if (deltaQ) {
            if (m.bool())
              deltaQ = -deltaQ;
            deltaQ *= 1 << hdr.deltaQ.resLog2;
          }
          this.lastQidx = Math.min(255, Math.max(1, this.lastQidx + deltaQ));
          if (hdr.deltaLf.present) {
            const n = hdr.deltaLf.multi ? f.layout ? 4 : 2 : 1;
            for (let i = 0;i < n; i++) {
              let d = readDelta(CDF2.deltaLf + (i + (hdr.deltaLf.multi ? 1 : 0)) * 4);
              if (d) {
                if (m.bool())
                  d = -d;
                d *= 1 << hdr.deltaLf.resLog2;
              }
              this.lastDeltaLf[i] = Math.min(63, Math.max(-63, this.lastDeltaLf[i] + d));
            }
          }
        }
        if (this.lastQidx === hdr.quant.yac)
          this.dq = this.frameDq;
        else if (this.lastQidx !== prevQidx)
          this.dq = quantTables(seq, hdr, this.lastQidx);
        if (this.lastDeltaLf.every((v) => !v))
          this.lfLvl = this.frameLfLvl;
        else if (this.lastDeltaLf.join() !== prevDeltaLf)
          this.lfLvl = calcLfLevels(hdr, this.lastDeltaLf);
      }
      if (hdr.allowIntrabc && m.boolAdapt(cdf, CDF2.intrabc)) {
        this.intrabcBlock(bs, edgeFlags, b, hasChroma);
        this.storeBlock(bs, b, hasChroma);
        return;
      }
      b.yMode = m.symbol(cdf, CDF2.kfYMode + (INTRA_MODE_CONTEXT2[this.aMode[bx4]] * 5 + INTRA_MODE_CONTEXT2[this.lMode[by4]]) * 16, 12);
      if (lw4 + lh4 >= 2 && b.yMode >= VERT_PRED && b.yMode <= VERT_LEFT_PRED)
        b.yAngle = m.symbol(cdf, CDF2.angleDelta + (b.yMode - VERT_PRED) * 8, 6) - 3;
      const lossless = hdr.segmentation.lossless[b.segId];
      if (hasChroma) {
        const cflAllowed = lossless ? cbw4 === 1 && cbh4 === 1 : !!(CFL_ALLOWED_MASK & 1 << bs);
        b.uvMode = m.symbol(cdf, CDF2.uvMode + ((cflAllowed ? 1 : 0) * 13 + b.yMode) * 16, cflAllowed ? 13 : 12);
        if (b.uvMode === CFL_PRED) {
          const sign = m.symbol(cdf, CDF2.cflSign, 7) + 1;
          const signU = sign * 86 >> 8, signV = sign - signU * 3;
          if (signU) {
            const ctx = (signU === 2 ? 3 : 0) + signV;
            b.cflAlpha[0] = m.symbol(cdf, CDF2.cflAlpha + ctx * 16, 15) + 1;
            if (signU === 1)
              b.cflAlpha[0] = -b.cflAlpha[0];
          }
          if (signV) {
            const ctx = (signV === 2 ? 3 : 0) + signU;
            b.cflAlpha[1] = m.symbol(cdf, CDF2.cflAlpha + ctx * 16, 15) + 1;
            if (signV === 1)
              b.cflAlpha[1] = -b.cflAlpha[1];
          }
        } else if (lw4 + lh4 >= 2 && b.uvMode >= VERT_PRED && b.uvMode <= VERT_LEFT_PRED) {
          b.uvAngle = m.symbol(cdf, CDF2.angleDelta + (b.uvMode - VERT_PRED) * 8, 6) - 3;
        }
      }
      if (hdr.allowScreenContentTools && Math.max(bw4, bh4) <= 16 && bw4 + bh4 >= 4) {
        const szCtx = lw4 + lh4 - 2;
        if (b.yMode === DC_PRED) {
          const palCtx = (this.aPalSz[bx4] > 0 ? 1 : 0) + (this.lPalSz[by4] > 0 ? 1 : 0);
          if (m.boolAdapt(cdf, CDF2.palY + (szCtx * 3 + palCtx) * 2))
            this.readPalPlane(b, 0, szCtx, bx4, by4);
        }
        if (hasChroma && b.uvMode === DC_PRED) {
          if (m.boolAdapt(cdf, CDF2.palUv + (b.palSz[0] > 0 ? 2 : 0)))
            this.readPalUv(b, szCtx, bx4, by4);
        }
      }
      if (b.yMode === DC_PRED && !b.palSz[0] && Math.max(lw4, lh4) <= 3 && seq.filterIntra) {
        if (m.boolAdapt(cdf, CDF2.useFilterIntra + bs * 2)) {
          b.yMode = FILTER_PRED;
          b.yAngle = m.symbol(cdf, CDF2.filterIntra, 4);
        }
      }
      if (b.palSz[0])
        this.readPalIndices(this.palIdxY, b.palSz[0], 0, w4, h4, bw4, bh4);
      if (hasChroma && b.palSz[1]) {
        const cw4 = w4 + ssx >> ssx, ch4 = h4 + ssy >> ssy;
        this.readPalIndices(this.palIdxUv, b.palSz[1], 1, cw4, ch4, cbw4, cbh4);
      }
      let tx;
      if (lossless) {
        tx = b.uvtx = TX_4X4;
      } else {
        tx = MAX_TXFM_SIZE_FOR_BS2[bs * 4];
        b.uvtx = MAX_TXFM_SIZE_FOR_BS2[bs * 4 + f.layout];
        if (hdr.txMode === 2 && tdim(tx, MAX) > TX_4X4) {
          const tctx = (this.lTxIntra[by4] >= tdim(tx, LH) ? 1 : 0) + (this.aTxIntra[bx4] >= tdim(tx, LW) ? 1 : 0);
          let depth = m.symbol(cdf, CDF2.txSize + ((tdim(tx, MAX) - 1) * 3 + tctx) * 4, Math.min(tdim(tx, MAX), 2));
          while (depth--)
            tx = tdim(tx, SUB);
        }
      }
      b.tx = tx;
      this.reconIntra(bs, edgeFlags, b, hasChroma);
      this.storeBlock(bs, b, hasChroma);
      const yModeNofilt = b.yMode === FILTER_PRED ? DC_PRED : b.yMode;
      const aw = 1 << lw4, lh = 1 << lh4;
      this.aTxIntra.fill(tdim(tx, LW), bx4, bx4 + aw);
      this.lTxIntra.fill(tdim(tx, LH), by4, by4 + lh);
      this.aTx.fill(tdim(tx, LW), bx4, bx4 + aw);
      this.lTx.fill(tdim(tx, LH), by4, by4 + lh);
      this.aMode.fill(yModeNofilt, bx4, bx4 + aw);
      this.lMode.fill(yModeNofilt, by4, by4 + lh);
      this.aPalSz.fill(b.palSz[0], bx4, bx4 + aw);
      this.lPalSz.fill(b.palSz[0], by4, by4 + lh);
      this.aSegPred.fill(0, bx4, bx4 + aw);
      this.lSegPred.fill(0, by4, by4 + lh);
      this.aIntra.fill(1, bx4, bx4 + aw);
      this.lIntra.fill(1, by4, by4 + lh);
      this.aSkip.fill(b.skip, bx4, bx4 + aw);
      this.lSkip.fill(b.skip, by4, by4 + lh);
      this.aPalSzUv.fill(hasChroma ? b.palSz[1] : 0, bx4, bx4 + aw);
      this.lPalSzUv.fill(hasChroma ? b.palSz[1] : 0, by4, by4 + lh);
      if (b.palSz[0]) {
        for (let x = 0;x < bw4; x++)
          this.aPal.set(this.pal.subarray(0, 8), (bx4 + x) * 24);
        for (let y = 0;y < bh4; y++)
          this.lPal.set(this.pal.subarray(0, 8), (by4 + y) * 24);
      }
      if (hasChroma) {
        this.aUvmode.fill(b.uvMode, cbx4, cbx4 + cbw4);
        this.lUvmode.fill(b.uvMode, cby4, cby4 + cbh4);
        if (b.palSz[1]) {
          for (let pl = 1;pl <= 2; pl++) {
            for (let x = 0;x < bw4; x++)
              this.aPal.set(this.pal.subarray(pl * 8, pl * 8 + 8), (bx4 + x) * 24 + pl * 8);
            for (let y = 0;y < bh4; y++)
              this.lPal.set(this.pal.subarray(pl * 8, pl * 8 + 8), (by4 + y) * 24 + pl * 8);
          }
        }
      }
      if (hdr.allowIntrabc)
        this.splatMv(bs, -1, 0, 0);
    }
    storeBlock(bs, b, hasChroma) {
      const f = this.frame, bx = this.bx, by = this.by, ssx = f.ssx, ssy = f.ssy;
      const bw4 = bdim(bs, 0), bh4 = bdim(bs, 1);
      const w4 = Math.min(bw4, f.bw - bx), h4 = Math.min(bh4, f.bh - by);
      const tx = b.tx;
      const lvl = this.lfLvl[b.segId];
      const s4 = f.b4Stride;
      for (let y = 0;y < h4; y++) {
        for (let x = 0;x < w4; x++) {
          const o = (by + y) * s4 + bx + x;
          f.lfLevels.set(lvl, o * 4);
          f.txW[o] = tdim(tx, LW);
          f.txH[o] = tdim(tx, LH);
          f.skip[o] = b.skip;
        }
      }
      if (hasChroma) {
        const cx = bx >> ssx, cy = by >> ssy, cw4 = w4 + ssx >> ssx, ch4 = h4 + ssy >> ssy;
        for (let y = 0;y < ch4; y++) {
          for (let x = 0;x < cw4; x++) {
            const o = (cy + y) * s4 + cx + x;
            f.uvTxW[o] = tdim(b.uvtx, LW);
            f.uvTxH[o] = tdim(b.uvtx, LH);
          }
        }
      }
      if (this.hdr.segmentation.enabled) {
        for (let y = 0;y < bh4 && by + y < f.bh; y++)
          f.segMap.fill(b.segId, (by + y) * s4 + bx, (by + y) * s4 + bx + bw4);
      }
    }
    mvY = null;
    mvX = null;
    mvValid = null;
    mvBs = null;
    txSplit = [0, 0];
    maxYtx = 0;
    txtpMap = new Uint8Array(32 * 32);
    splatMv(bs, valid, y, x) {
      const f = this.frame, s4 = f.b4Stride;
      const bw4 = bdim(bs, 0), bh4 = bdim(bs, 1);
      for (let r = 0;r < bh4; r++) {
        const o = (this.by + r) * s4 + this.bx;
        this.mvY.fill(y, o, o + bw4);
        this.mvX.fill(x, o, o + bw4);
        this.mvValid.fill(valid > 0 ? 1 : 0, o, o + bw4);
        this.mvBs.fill(bs, o, o + bw4);
      }
    }
    findMvs(bs, edgeFlags) {
      const f = this.frame, s4 = f.b4Stride;
      const by4 = this.by, bx4 = this.bx;
      const iw4 = f.width + 3 >> 2, ih4 = f.height + 3 >> 2;
      const colStart = this.colStart, colEnd = Math.min(this.colEnd, iw4), rowStart = this.rowStart, rowEnd = Math.min(this.rowEnd, ih4);
      const bw4 = bdim(bs, 0), w4 = Math.min(Math.min(bw4, 16), colEnd - bx4);
      const bh4 = bdim(bs, 1), h4 = Math.min(Math.min(bh4, 16), rowEnd - by4);
      const valid = this.mvValid, mvY = this.mvY, mvX = this.mvX, mvBs = this.mvBs;
      const stack = [];
      const add = (o, weight) => {
        if (!valid[o])
          return;
        const y = mvY[o], x = mvX[o];
        for (const c of stack) {
          if (c.y === y && c.x === x) {
            c.weight += weight;
            return;
          }
        }
        if (stack.length < 8)
          stack.push({ y, x, weight });
      };
      const scanRow = (row, col, maxRows2, step) => {
        const o = row * s4 + col;
        const firstBw4 = bdim(mvBs[o], 0);
        let len = Math.max(step, Math.min(bw4, firstBw4));
        if (bw4 <= firstBw4) {
          const weight = bw4 === 1 ? 2 : Math.max(2, Math.min(2 * maxRows2, bdim(mvBs[o], 1)));
          add(o, len * weight);
          return weight >> 1;
        }
        for (let x = 0;; ) {
          add(o + x, len * 2);
          x += len;
          if (x >= w4)
            return 1;
          len = Math.max(step, bdim(mvBs[o + x], 0));
        }
      };
      const scanCol = (row, col, maxCols2, step) => {
        const o = row * s4 + col;
        const firstBh4 = bdim(mvBs[o], 1);
        let len = Math.max(step, Math.min(bh4, firstBh4));
        if (bh4 <= firstBh4) {
          const weight = bh4 === 1 ? 2 : Math.max(2, Math.min(2 * maxCols2, bdim(mvBs[o], 0)));
          add(o, len * weight);
          return weight >> 1;
        }
        for (let y = 0;; ) {
          add(o + y * s4, len * 2);
          y += len;
          if (y >= h4)
            return 1;
          len = Math.max(step, bdim(mvBs[o + y * s4], 1));
        }
      };
      const NONE = 4294967295;
      let maxRows = 0, nRows = NONE;
      if (by4 > rowStart) {
        maxRows = Math.min(by4 - rowStart + 1 >> 1, 2 + (bh4 > 1 ? 1 : 0));
        nRows = scanRow(by4 - 1, bx4, maxRows, bw4 >= 16 ? 4 : 1);
      }
      let maxCols = 0, nCols = NONE;
      if (bx4 > colStart) {
        maxCols = Math.min(bx4 - colStart + 1 >> 1, 2 + (bw4 > 1 ? 1 : 0));
        nCols = scanCol(by4, bx4 - 1, maxCols, bh4 >= 16 ? 4 : 1);
      }
      if (nRows !== NONE && edgeFlags & EDGE_I444_TOP_HAS_RIGHT && Math.max(bw4, bh4) <= 16 && bw4 + bx4 < colEnd)
        add((by4 - 1) * s4 + bx4 + bw4, 4);
      const nearest = stack.length;
      for (const c of stack)
        c.weight += 640;
      if (nRows !== NONE && nCols !== NONE)
        add((by4 - 1) * s4 + bx4 - 1, 4);
      for (let n = 2;n <= 3; n++) {
        if (nRows !== NONE && n > nRows && n <= maxRows) {
          nRows += scanRow(by4 - 2 * n + 1 | 1, bx4 | 1, 1 + maxRows - n, bw4 >= 16 ? 4 : 2);
        }
        if (nCols !== NONE && n > nCols && n <= maxCols) {
          nCols += scanCol(by4 | 1, bx4 - n * 2 + 1 | 1, 1 + maxCols - n, bh4 >= 16 ? 4 : 2);
        }
      }
      const sort = (from, to) => {
        let len = to;
        while (len > from) {
          let last = from;
          for (let n = from + 1;n < len; n++) {
            if (stack[n - 1].weight < stack[n].weight) {
              [stack[n - 1], stack[n]] = [stack[n], stack[n - 1]];
              last = n;
            }
          }
          len = last;
        }
      };
      sort(0, nearest);
      sort(nearest, stack.length);
      const left = -(bx4 + bw4 + 4) * 32, right = (iw4 - bx4 + 4) * 32;
      const top = -(by4 + bh4 + 4) * 32, bottom = (ih4 - by4 + 4) * 32;
      const out = stack.map((c) => [Math.min(bottom, Math.max(top, c.y)), Math.min(right, Math.max(left, c.x))]);
      while (out.length < 2)
        out.push([0, 0]);
      return out;
    }
    readMvComponent(comp) {
      const m = this.msac, cdf = this.cdf;
      const sign = m.boolAdapt(cdf, comp ? CDF2.mvSign1 : CDF2.mvSign0);
      const cl = m.symbol(cdf, comp ? CDF2.mvClasses1 : CDF2.mvClasses0, 10);
      let up;
      if (!cl)
        up = m.boolAdapt(cdf, comp ? CDF2.mvClass01 : CDF2.mvClass00);
      else {
        up = 1 << cl;
        for (let n = 0;n < cl; n++)
          up |= m.boolAdapt(cdf, (comp ? CDF2.mvClassN1 : CDF2.mvClassN0) + n * 2) << n;
      }
      const diff = (up << 3 | 7) + 1;
      return sign ? -diff : diff;
    }
    intrabcBlock(bs, edgeFlags, b, hasChroma) {
      const f = this.frame, seq = this.seq, m = this.msac, cdf = this.cdf;
      const bx = this.bx, by = this.by, bx4 = bx, by4 = by & 31;
      const { ssx, ssy } = f;
      const bw4 = bdim(bs, 0), bh4 = bdim(bs, 1);
      const sb128 = seq.sb128 ? 1 : 0;
      const stack = this.findMvs(bs, edgeFlags);
      let [mvy, mvx] = stack[0][0] || stack[0][1] ? stack[0] : stack[1][0] || stack[1][1] ? stack[1] : [0, 0];
      if (!mvy && !mvx) {
        if (by - (16 << sb128) < this.rowStart) {
          mvy = 0;
          mvx = -(512 << sb128) - 2048;
        } else {
          mvy = -(512 << sb128);
          mvx = 0;
        }
      }
      const joint = m.symbol(cdf, CDF2.mvJoint, 3);
      if (joint & 2)
        mvy += this.readMvComponent(0);
      if (joint & 1)
        mvx += this.readMvComponent(1);
      let borderLeft = this.colStart * 4, borderTop = this.rowStart * 4;
      if (hasChroma) {
        if (bw4 < 2 && ssx)
          borderLeft += 4;
        if (bh4 < 2 && ssy)
          borderTop += 4;
      }
      let srcLeft = bx * 4 + (mvx >> 3), srcTop = by * 4 + (mvy >> 3);
      let srcRight = srcLeft + bw4 * 4, srcBottom = srcTop + bh4 * 4;
      const borderRight = (this.colEnd + (bw4 - 1) & ~(bw4 - 1)) * 4;
      if (srcLeft < borderLeft) {
        srcRight += borderLeft - srcLeft;
        srcLeft = borderLeft;
      } else if (srcRight > borderRight) {
        srcLeft -= srcRight - borderRight;
        srcRight = borderRight;
      }
      if (srcTop < borderTop) {
        srcBottom += borderTop - srcTop;
        srcTop = borderTop;
      }
      const sbx = bx >> 4 + sb128 << 6 + sb128, sby = by >> 4 + sb128 << 6 + sb128, sbSize = 1 << 6 + sb128;
      if (srcBottom > sby && srcRight > sbx) {
        if (srcTop - borderTop >= srcBottom - sby) {
          srcTop -= srcBottom - sby;
          srcBottom = sby;
        } else if (srcLeft - borderLeft >= srcRight - sbx) {
          srcLeft -= srcRight - sbx;
          srcRight = sbx;
        }
      }
      if (srcBottom > sby + sbSize) {
        srcTop -= srcBottom - (sby + sbSize);
        srcBottom = sby + sbSize;
      }
      if (srcBottom > sby && srcRight > sbx)
        throw new Error("AV1: invalid intra block copy vector");
      mvx = (srcLeft - bx * 4) * 8;
      mvy = (srcTop - by * 4) * 8;
      this.readVartxTree(b, bs);
      b.tx = this.maxYtx;
      this.reconInter(bs, b, hasChroma, mvy, mvx);
      this.splatMv(bs, 1, mvy, mvx);
      const aw = 1 << bdim(bs, 2), lh = 1 << bdim(bs, 3);
      this.aTxIntra.fill(bdim(bs, 2), bx4, bx4 + aw);
      this.lTxIntra.fill(bdim(bs, 3), by4, by4 + lh);
      this.aMode.fill(DC_PRED, bx4, bx4 + aw);
      this.lMode.fill(DC_PRED, by4, by4 + lh);
      this.aPalSz.fill(0, bx4, bx4 + aw);
      this.lPalSz.fill(0, by4, by4 + lh);
      this.aPalSzUv.fill(0, bx4, bx4 + aw);
      this.lPalSzUv.fill(0, by4, by4 + lh);
      this.aSegPred.fill(0, bx4, bx4 + aw);
      this.lSegPred.fill(0, by4, by4 + lh);
      this.aIntra.fill(0, bx4, bx4 + aw);
      this.lIntra.fill(0, by4, by4 + lh);
      this.aSkip.fill(b.skip, bx4, bx4 + aw);
      this.lSkip.fill(b.skip, by4, by4 + lh);
      if (hasChroma) {
        const cbx4 = bx4 >> ssx, cby4 = by4 >> ssy, cbw4 = bw4 + ssx >> ssx, cbh4 = bh4 + ssy >> ssy;
        this.aUvmode.fill(DC_PRED, cbx4, cbx4 + cbw4);
        this.lUvmode.fill(DC_PRED, cby4, cby4 + cbh4);
      }
    }
    readVartxTree(b, bs) {
      const f = this.frame, hdr = this.hdr;
      const bw4 = bdim(bs, 0), bh4 = bdim(bs, 1), lw = bdim(bs, 2), lh = bdim(bs, 3);
      const bx4 = this.bx, by4 = this.by & 31;
      this.txSplit = [0, 0];
      this.maxYtx = MAX_TXFM_SIZE_FOR_BS2[bs * 4];
      if (!b.skip && (hdr.segmentation.lossless[b.segId] || this.maxYtx === TX_4X4)) {
        this.maxYtx = b.uvtx = TX_4X4;
        if (hdr.txMode === 2) {
          this.aTx.fill(TX_4X4, bx4, bx4 + (1 << lw));
          this.lTx.fill(TX_4X4, by4, by4 + (1 << lh));
        }
      } else if (hdr.txMode !== 2 || b.skip) {
        if (hdr.txMode === 2) {
          this.aTx.fill(lw, bx4, bx4 + (1 << lw));
          this.lTx.fill(lh, by4, by4 + (1 << lh));
        }
        b.uvtx = MAX_TXFM_SIZE_FOR_BS2[bs * 4 + f.layout];
      } else {
        const ytx = this.maxYtx, tw = tdim(ytx, W), th = tdim(ytx, H);
        for (let y = 0, yOff = 0;y < bh4; y += th, yOff++) {
          for (let x = 0, xOff = 0;x < bw4; x += tw, xOff++) {
            this.readTxTree(ytx, 0, xOff, yOff);
            this.bx += tw;
          }
          this.bx -= bw4 + tw - 1 & ~(tw - 1);
          this.by += th;
        }
        this.by -= bh4 + th - 1 & ~(th - 1);
        b.uvtx = MAX_TXFM_SIZE_FOR_BS2[bs * 4 + f.layout];
      }
    }
    readTxTree(from, depth, xOff, yOff) {
      const f = this.frame, m = this.msac;
      const bx4 = this.bx, by4 = this.by & 31;
      const txw = tdim(from, LW), txh = tdim(from, LH);
      let split = 0;
      if (depth < 2 && from > TX_4X4) {
        const cat = 2 * (TX_64X64 - tdim(from, MAX)) - depth;
        const a = this.aTx[bx4] < txw ? 1 : 0, l = this.lTx[by4] < txh ? 1 : 0;
        split = m.boolAdapt(this.cdf, CDF2.txPart + (cat * 3 + a + l) * 2);
        if (split)
          this.txSplit[depth] |= 1 << yOff * 4 + xOff;
      }
      if (split && tdim(from, MAX) > 1) {
        const sub = tdim(from, SUB), sw = tdim(sub, W), sh = tdim(sub, H);
        this.readTxTree(sub, depth + 1, xOff * 2, yOff * 2);
        this.bx += sw;
        if (tdim(from, W) >= tdim(from, H) && this.bx < f.bw)
          this.readTxTree(sub, depth + 1, xOff * 2 + 1, yOff * 2);
        this.bx -= sw;
        this.by += sh;
        if (tdim(from, H) >= tdim(from, W) && this.by < f.bh) {
          this.readTxTree(sub, depth + 1, xOff * 2, yOff * 2 + 1);
          this.bx += sw;
          if (tdim(from, W) >= tdim(from, H) && this.bx < f.bw)
            this.readTxTree(sub, depth + 1, xOff * 2 + 1, yOff * 2 + 1);
          this.bx -= sw;
        }
        this.by -= sh;
      } else {
        this.aTx.fill(split ? TX_4X4 : txw, bx4, bx4 + (1 << tdim(from, LW)));
        this.lTx.fill(split ? TX_4X4 : txh, by4, by4 + (1 << tdim(from, LH)));
      }
    }
    mc(plane, w4, h4, bx, by, mvy, mvx) {
      const f = this.frame, ssx = plane ? f.ssx : 0, ssy = plane ? f.ssy : 0;
      const hMul = 4 >> ssx, vMul = 4 >> ssy;
      const mx = mvx & 15 >> (ssx ? 0 : 1), my = mvy & 15 >> (ssy ? 0 : 1);
      const dx = bx * hMul + (mvx >> 3 + ssx), dy = by * vMul + (mvy >> 3 + ssy);
      const w = f.bw * 4 >> ssx, h = f.bh * 4 >> ssy;
      const pic = f.planes[plane], stride = f.strides[plane];
      const bw = w4 * hMul, bh = h4 * vMul;
      const fx = mx << (ssx ? 0 : 1), fy = my << (ssy ? 0 : 1);
      const at = (x, y) => pic[Math.min(h - 1, Math.max(0, y)) * stride + Math.min(w - 1, Math.max(0, x))];
      const ib = f.bitdepth === 12 ? 2 : 4, rnd = 1 << ib >> 1, max2 = f.bitdepthMax;
      const clip2 = (v) => v < 0 ? 0 : v > max2 ? max2 : v;
      const out = new Uint16Array(bw * bh);
      for (let y = 0;y < bh; y++) {
        for (let x = 0;x < bw; x++) {
          const sx = dx + x, sy = dy + y;
          let v;
          if (fx && fy) {
            const h0 = 16 * at(sx, sy) + fx * (at(sx + 1, sy) - at(sx, sy)) + (1 << 4 - ib >> 1) >> 4 - ib;
            const h1 = 16 * at(sx, sy + 1) + fx * (at(sx + 1, sy + 1) - at(sx, sy + 1)) + (1 << 4 - ib >> 1) >> 4 - ib;
            v = clip2(16 * h0 + fy * (h1 - h0) + (1 << 4 + ib >> 1) >> 4 + ib);
          } else if (fx) {
            const p = 16 * at(sx, sy) + fx * (at(sx + 1, sy) - at(sx, sy)) + (1 << 4 - ib >> 1) >> 4 - ib;
            v = clip2(p + rnd >> ib);
          } else if (fy) {
            v = clip2(16 * at(sx, sy) + fy * (at(sx, sy + 1) - at(sx, sy)) + 8 >> 4);
          } else
            v = at(sx, sy);
          out[y * bw + x] = v;
        }
      }
      for (let y = 0;y < bh; y++)
        pic.set(out.subarray(y * bw, (y + 1) * bw), (by * vMul + y) * stride + bx * hMul);
    }
    reconInter(bs, b, hasChroma, mvy, mvx) {
      const f = this.frame, ssx = f.ssx, ssy = f.ssy;
      const bx = this.bx, by = this.by, bx4 = bx, by4 = by & 31;
      const cbx4 = bx4 >> ssx, cby4 = by4 >> ssy;
      const bw4 = bdim(bs, 0), bh4 = bdim(bs, 1);
      const w4 = Math.min(bw4, f.bw - bx), h4 = Math.min(bh4, f.bh - by);
      const cbw4 = bw4 + ssx >> ssx, cbh4 = bh4 + ssy >> ssy;
      this.mc(0, bw4, bh4, bx, by, mvy, mvx);
      if (hasChroma) {
        for (let pl = 1;pl < 3; pl++) {
          this.mc(pl, bw4 << (bw4 === ssx ? 1 : 0), bh4 << (bh4 === ssy ? 1 : 0), bx & ~ssx, by & ~ssy, mvy, mvx);
        }
      }
      if (b.skip) {
        this.aLcoef.fill(64, bx4, bx4 + (1 << bdim(bs, 2)));
        this.lLcoef.fill(64, by4, by4 + (1 << bdim(bs, 3)));
        if (hasChroma) {
          const cw = 1 << 31 - Math.clz32(cbw4), ch = 1 << 31 - Math.clz32(cbh4);
          for (let pl = 0;pl < 2; pl++) {
            this.aCcoef[pl].fill(64, cbx4, cbx4 + cw);
            this.lCcoef[pl].fill(64, cby4, cby4 + ch);
          }
        }
        return;
      }
      const ytx = this.maxYtx, ytw = tdim(ytx, W), yth = tdim(ytx, H);
      const uvtx = b.uvtx, uvtw = tdim(uvtx, W), uvth = tdim(uvtx, H);
      const cw4 = w4 + ssx >> ssx, ch4 = h4 + ssy >> ssy;
      const stride = f.strides[0], cstride = f.strides[1];
      for (let initY = 0;initY < bh4; initY += 16) {
        for (let initX = 0;initX < bw4; initX += 16) {
          let yOff = initY ? 1 : 0;
          for (let y = initY;y < Math.min(h4, initY + 16); y += yth, yOff++) {
            let xOff = initX ? 1 : 0;
            for (let x = initX;x < Math.min(w4, initX + 16); x += ytw, xOff++) {
              this.bx = bx + x;
              this.by = by + y;
              this.readCoefTree(bs, b, ytx, 0, xOff, yOff, 4 * ((by + y) * stride + bx + x));
            }
          }
          this.bx = bx;
          this.by = by;
          if (!hasChroma)
            continue;
          for (let pl = 0;pl < 2; pl++) {
            const plane = f.planes[1 + pl];
            for (let y = initY >> ssy;y < Math.min(ch4, initY + 16 >> ssy); y += uvth) {
              for (let x = initX >> ssx;x < Math.min(cw4, initX + 16 >> ssx); x += uvtw) {
                const tbx = bx + (x << ssx), tby = by + (y << ssy);
                this.txtp = this.txtpMap[(by4 + (y << ssy) & 31) * 32 + (bx4 + (x << ssx) & 31)];
                const eob = this.decodeCoefs(this.aCcoef[pl], cbx4 + x, this.lCcoef[pl], cby4 + y, uvtx, bs, b, 1 + pl, false);
                const ctw = Math.min(uvtw, f.bw - tbx + ssx >> ssx), cth = Math.min(uvth, f.bh - tby + ssy >> ssy);
                this.aCcoef[pl].fill(this.resCtx, cbx4 + x, cbx4 + x + ctw);
                this.lCcoef[pl].fill(this.resCtx, cby4 + y, cby4 + y + cth);
                if (eob >= 0)
                  inverseTransformAdd(plane, 4 * (((by >> ssy) + y) * cstride + (bx >> ssx) + x), cstride, this.cf, eob, uvtx, this.txtp, f.bitdepthMax);
              }
            }
          }
        }
      }
    }
    readCoefTree(bs, b, ytx, depth, xOff, yOff, dst) {
      const f = this.frame;
      const tw = tdim(ytx, W), th = tdim(ytx, H);
      if (depth < 2 && this.txSplit[depth] && this.txSplit[depth] & 1 << yOff * 4 + xOff) {
        const sub = tdim(ytx, SUB), sw = tdim(sub, W), sh = tdim(sub, H);
        const stride = f.strides[0];
        this.readCoefTree(bs, b, sub, depth + 1, xOff * 2, yOff * 2, dst);
        this.bx += sw;
        if (tw >= th && this.bx < f.bw)
          this.readCoefTree(bs, b, sub, depth + 1, xOff * 2 + 1, yOff * 2, dst + 4 * sw);
        this.bx -= sw;
        this.by += sh;
        if (th >= tw && this.by < f.bh) {
          const d2 = dst + 4 * sh * stride;
          this.readCoefTree(bs, b, sub, depth + 1, xOff * 2, yOff * 2 + 1, d2);
          this.bx += sw;
          if (tw >= th && this.bx < f.bw)
            this.readCoefTree(bs, b, sub, depth + 1, xOff * 2 + 1, yOff * 2 + 1, d2 + 4 * sw);
          this.bx -= sw;
        }
        this.by -= sh;
        return;
      }
      const bx4 = this.bx, by4 = this.by & 31;
      const eob = this.decodeCoefs(this.aLcoef, bx4, this.lLcoef, by4, ytx, bs, b, 0, false);
      this.aLcoef.fill(this.resCtx, bx4, bx4 + Math.min(tw, f.bw - this.bx));
      this.lLcoef.fill(this.resCtx, by4, by4 + Math.min(th, f.bh - this.by));
      for (let y = 0;y < th; y++)
        this.txtpMap.fill(this.txtp, (by4 + y & 31) * 32 + (bx4 & 31), (by4 + y & 31) * 32 + (bx4 & 31) + Math.min(1 << tdim(ytx, LW), 16));
      if (eob >= 0)
        inverseTransformAdd(f.planes[0], dst, f.strides[0], this.cf, eob, ytx, this.txtp, f.bitdepthMax);
    }
    readPalPlane(b, pl, szCtx, bx4, by4) {
      const m = this.msac, f = this.frame;
      const palSz = b.palSz[pl] = m.symbol(this.cdf, CDF2.palSize + (pl * 7 + szCtx) * 8, 6) + 2;
      const cache = [], used = [];
      let lCache = pl ? this.lPalSzUv[by4] : this.lPalSz[by4];
      let aCache = by4 & 15 ? pl ? this.aPalSzUv[bx4] : this.aPalSz[bx4] : 0;
      let l = by4 * 24 + pl * 8, a = bx4 * 24 + pl * 8;
      const L = this.lPal, A = this.aPal;
      const push = (v) => {
        if (!cache.length || cache[cache.length - 1] !== v)
          cache.push(v);
      };
      while (lCache && aCache) {
        if (L[l] < A[a]) {
          push(L[l++]);
          lCache--;
        } else {
          if (A[a] === L[l]) {
            l++;
            lCache--;
          }
          push(A[a++]);
          aCache--;
        }
      }
      while (lCache-- > 0)
        push(L[l++]);
      while (aCache-- > 0)
        push(A[a++]);
      for (let n = 0;n < cache.length && used.length < palSz; n++)
        if (m.bool())
          used.push(cache[n]);
      const pal = this.pal, o = pl * 8;
      let i = used.length;
      if (i < palSz) {
        const bpc = f.bitdepth;
        let prev = pal[o + i++] = m.bools(bpc);
        if (i < palSz) {
          let bits2 = bpc - 3 + m.bools(2);
          const max2 = (1 << bpc) - 1, minus = pl ? 0 : 1;
          do {
            const delta = m.bools(bits2);
            prev = pal[o + i++] = Math.min(prev + delta + minus, max2);
            if (prev + minus >= max2) {
              for (;i < palSz; i++)
                pal[o + i] = max2;
              break;
            }
            bits2 = Math.min(bits2, 1 + (31 - Math.clz32(max2 - prev - minus)));
          } while (i < palSz);
        }
        const merged = [];
        let n = 0, k = used.length;
        for (i = 0;i < palSz; i++) {
          if (n < used.length && (k >= palSz || used[n] <= pal[o + k]))
            merged.push(used[n++]);
          else
            merged.push(pal[o + k++]);
        }
        pal.set(merged, o);
      } else
        pal.set(used, o);
    }
    readPalUv(b, szCtx, bx4, by4) {
      this.readPalPlane(b, 1, szCtx, bx4, by4);
      const m = this.msac, pal = this.pal, bpc = this.frame.bitdepth;
      if (m.bool()) {
        const bits2 = bpc - 4 + m.bools(2);
        let prev = pal[16] = m.bools(bpc);
        const max2 = (1 << bpc) - 1;
        for (let i = 1;i < b.palSz[1]; i++) {
          let delta = m.bools(bits2);
          if (delta && m.bool())
            delta = -delta;
          prev = pal[16 + i] = prev + delta & max2;
        }
      } else {
        for (let i = 0;i < b.palSz[1]; i++)
          pal[16 + i] = m.bools(bpc);
      }
    }
    readPalIndices(out, palSz, pl, w4, h4, bw4, bh4) {
      const m = this.msac, cdf = this.cdf, stride = bw4 * 4, t = this.palTmp;
      t[0] = m.uniform(palSz);
      const order = [0, 0, 0, 0, 0, 0, 0, 0];
      for (let i = 1;i < 4 * (w4 + h4) - 1; i++) {
        const first = Math.min(i, w4 * 4 - 1), last = Math.max(0, i - h4 * 4 + 1);
        for (let j = first;j >= last; j--) {
          const p = (i - j) * stride + j;
          const haveTop = i - j > 0, haveLeft = j > 0;
          let ctx, n = 0, mask = 0;
          const add = (v) => {
            order[n++] = v;
            mask |= 1 << v;
          };
          if (!haveLeft) {
            ctx = 0;
            add(t[p - stride]);
          } else if (!haveTop) {
            ctx = 0;
            add(t[p - 1]);
          } else {
            const l = t[p - 1], tp = t[p - stride], tl = t[p - stride - 1];
            const sameTL = tp === l, sameTTl = tp === tl, sameLTl = l === tl;
            if (sameTL && sameTTl && sameLTl) {
              ctx = 4;
              add(tp);
            } else if (sameTL) {
              ctx = 3;
              add(tp);
              add(tl);
            } else if (sameTTl || sameLTl) {
              ctx = 2;
              add(tl);
              add(sameTTl ? l : tp);
            } else {
              ctx = 1;
              add(Math.min(tp, l));
              add(Math.max(tp, l));
              add(tl);
            }
          }
          for (let bit = 0;bit < 8; bit++)
            if (!(mask & 1 << bit))
              order[n++] = bit;
          const idx = m.symbol(cdf, CDF2.colorMap + ((pl * 7 + palSz - 2) * 5 + ctx) * 8, palSz - 1);
          t[p] = order[idx];
        }
      }
      const w = w4 * 4, h = h4 * 4, bw = bw4 * 4, bh = bh4 * 4;
      for (let y = 0;y < h; y++) {
        for (let x = 0;x < w; x++)
          out[y * bw + x] = t[y * stride + x];
        out.fill(t[y * stride + w - 1], y * bw + w, y * bw + bw);
      }
      for (let y = h;y < bh; y++)
        out.copyWithin(y * bw, (h - 1) * bw, h * bw);
    }
    txtp = 0;
    resCtx = 0;
    decodeCoefs(aArr, a, lArr, l, tx, bs, b, plane, intra = true) {
      const m = this.msac, cdf = this.cdf, f = this.frame, hdr = this.hdr;
      const chroma = plane ? 1 : 0;
      const lossless = hdr.segmentation.lossless[b.segId];
      const tlw = tdim(tx, LW), tlh = tdim(tx, LH), tctx = tdim(tx, CTX), tmin = tdim(tx, MIN), tmax = tdim(tx, MAX);
      let sctx;
      const aw = 1 << tlw, lh = 1 << tlh;
      if (chroma) {
        const bl2 = bdim(bs, 2), bl3 = bdim(bs, 3);
        const notOneBlk = bl2 - (bl2 && f.ssx ? 1 : 0) > tlw || bl3 - (bl3 && f.ssy ? 1 : 0) > tlh;
        let ca = 0, cl = 0;
        for (let i = 0;i < aw; i++)
          if (aArr[a + i] !== 64) {
            ca = 1;
            break;
          }
        for (let i = 0;i < lh; i++)
          if (lArr[l + i] !== 64) {
            cl = 1;
            break;
          }
        sctx = 7 + (notOneBlk ? 3 : 0) + ca + cl;
      } else if (bdim(bs, 2) === tlw && bdim(bs, 3) === tlh) {
        sctx = 0;
      } else {
        let la = 0, ll = 0;
        for (let i = 0;i < aw; i++)
          la |= aArr[a + i];
        for (let i = 0;i < lh; i++)
          ll |= lArr[l + i];
        sctx = SKIP_CTX2[Math.min(la & 63, 4) * 5 + Math.min(ll & 63, 4)];
      }
      if (m.boolAdapt(cdf, CDF2.coefSkip + (tctx * 13 + sctx) * 2)) {
        this.resCtx = 64;
        this.txtp = lossless ? WHT_WHT : DCT_DCT;
        return -1;
      }
      let txtp;
      if (lossless)
        txtp = WHT_WHT;
      else if (tmax + (intra ? 1 : 0) >= TX_64X64)
        txtp = DCT_DCT;
      else if (chroma) {
        if (intra)
          txtp = TXTP_FROM_UVMODE2[b.uvMode];
        else {
          const y = this.txtp;
          if (tmax === TX_32X32)
            txtp = y === IDTX ? IDTX : DCT_DCT;
          else if (tmin === TX_16X16 && 1 << y & (1 << 15 | 1 << 14 | 1 << 13 | 1 << 12))
            txtp = DCT_DCT;
          else
            txtp = y;
        }
      } else if (!hdr.segmentation.qidx[b.segId])
        txtp = DCT_DCT;
      else if (!intra) {
        if (hdr.reducedTxSet || tmax === TX_32X32)
          txtp = m.boolAdapt(cdf, CDF2.txtpInter3 + tmin * 2) ? DCT_DCT : IDTX;
        else if (tmin === TX_16X16)
          txtp = TX_TYPES_PER_SET2[m.symbol(cdf, CDF2.txtpInter2, 11) + 12];
        else
          txtp = TX_TYPES_PER_SET2[m.symbol(cdf, CDF2.txtpInter1 + tmin * 16, 15) + 24];
      } else {
        const yModeNofilt = b.yMode === FILTER_PRED ? FILTER_MODE_TO_Y_MODE2[b.yAngle] : b.yMode;
        if (hdr.reducedTxSet || tmin === TX_16X16)
          txtp = TX_TYPES_PER_SET2[m.symbol(cdf, CDF2.txtpIntra2 + (tmin * 13 + yModeNofilt) * 8, 4)];
        else
          txtp = TX_TYPES_PER_SET2[m.symbol(cdf, CDF2.txtpIntra1 + (tmin * 13 + yModeNofilt) * 8, 6) + 5];
      }
      this.txtp = txtp;
      const slw = Math.min(tlw, 3), slh = Math.min(tlh, 3);
      const tx2d = slw + slh;
      const txClass = TX_TYPE_CLASS2[txtp];
      const is1d = txClass !== TX_CLASS_2D ? 1 : 0;
      let eobBin;
      switch (tx2d) {
        case 0:
          eobBin = m.symbol(cdf, CDF2.eobBin16 + (chroma * 2 + is1d) * 8, 4);
          break;
        case 1:
          eobBin = m.symbol(cdf, CDF2.eobBin32 + (chroma * 2 + is1d) * 8, 5);
          break;
        case 2:
          eobBin = m.symbol(cdf, CDF2.eobBin64 + (chroma * 2 + is1d) * 8, 6);
          break;
        case 3:
          eobBin = m.symbol(cdf, CDF2.eobBin128 + (chroma * 2 + is1d) * 8, 7);
          break;
        case 4:
          eobBin = m.symbol(cdf, CDF2.eobBin256 + (chroma * 2 + is1d) * 16, 8);
          break;
        case 5:
          eobBin = m.symbol(cdf, CDF2.eobBin512 + chroma * 16, 9);
          break;
        default:
          eobBin = m.symbol(cdf, CDF2.eobBin1024 + chroma * 16, 10);
          break;
      }
      let eob;
      if (eobBin > 1) {
        const hi2 = m.boolAdapt(cdf, CDF2.eobHiBit + ((tctx * 2 + chroma) * 11 + eobBin) * 2);
        eob = (hi2 | 2) << eobBin - 2 | m.bools(eobBin - 2);
      } else
        eob = eobBin;
      const cf = this.cf, levels = this.levels;
      const eobCdf = CDF2.eobBaseTok + (tctx * 2 + chroma) * 16;
      const hiCdf = CDF2.brTok + (Math.min(tctx, 3) * 2 + chroma) * 84;
      let rc, dcTok;
      if (eob) {
        const loCdf = CDF2.baseTok + (tctx * 2 + chroma) * 164;
        let ctx = 1 + (eob > 2 << tx2d ? 1 : 0) + (eob > 4 << tx2d ? 1 : 0);
        const eobTok = m.symbol(cdf, eobCdf + ctx * 4, 2);
        let tok = eobTok + 1;
        let levelTok = tok * 65;
        let mag;
        let scanTable = null, stride, shift, shift2, mask, offsets = 0;
        if (txClass === TX_CLASS_2D) {
          const nonsquare = tx >= RTX_4X8 ? 1 : 0;
          offsets = (nonsquare + (tx & nonsquare)) * 25;
          scanTable = scan(tx);
          stride = 4 << slh;
          shift = slh + 2;
          shift2 = 0;
          mask = (4 << slh) - 1;
          levels.fill(0, 0, stride * ((4 << slw) + 2));
        } else if (txClass === TX_CLASS_H) {
          stride = 16;
          shift = slh + 2;
          shift2 = 0;
          mask = (4 << slh) - 1;
          levels.fill(0, 0, stride * ((4 << slh) + 2));
        } else {
          stride = 16;
          shift = slw + 2;
          shift2 = slh + 2;
          mask = (4 << slw) - 1;
          levels.fill(0, 0, stride * ((4 << slw) + 2));
        }
        let hiMag = 0;
        const loCtx = (lv, x2, y2) => {
          let mg = levels[lv + 1] + levels[lv + stride];
          let off;
          if (txClass === TX_CLASS_2D) {
            mg += levels[lv + stride + 1];
            hiMag = mg;
            mg += levels[lv + 2] + levels[lv + 2 * stride];
            off = LO_CTX_OFFSETS2[offsets + Math.min(y2, 4) * 5 + Math.min(x2, 4)];
          } else {
            mg += levels[lv + 2];
            hiMag = mg;
            mg += levels[lv + 3] + levels[lv + 4];
            off = 26 + (y2 > 1 ? 10 : y2 * 5);
          }
          return off + (mg > 512 ? 4 : mg + 64 >> 7);
        };
        const position = (i) => {
          if (txClass === TX_CLASS_2D) {
            const r2 = scanTable[i];
            return [r2, r2 >> shift, r2 & mask];
          }
          const x2 = i & mask, y2 = i >> shift;
          return [txClass === TX_CLASS_H ? i : x2 << shift2 | y2, x2, y2];
        };
        const [r, x, y] = position(eob);
        rc = r;
        if (eobTok === 2) {
          ctx = (txClass === TX_CLASS_2D ? (x | y) > 1 : y !== 0) ? 14 : 7;
          tok = m.hiTok(cdf, hiCdf + ctx * 4);
          levelTok = tok + (3 << 6);
        }
        cf[rc] = tok << 11;
        levels[x * stride + y] = levelTok;
        for (let i = eob - 1;i > 0; i--) {
          const [rcI, xi, yi0] = position(i);
          const lv = xi * stride + yi0;
          ctx = loCtx(lv, xi, yi0);
          const yi = txClass === TX_CLASS_2D ? yi0 | xi : yi0;
          tok = m.symbol(cdf, loCdf + ctx * 4, 3);
          if (tok === 3) {
            mag = hiMag & 63;
            ctx = (yi > (txClass === TX_CLASS_2D ? 1 : 0) ? 14 : 7) + (mag > 12 ? 6 : mag + 1 >> 1);
            tok = m.hiTok(cdf, hiCdf + ctx * 4);
            levels[lv] = tok + (3 << 6);
            cf[rcI] = tok << 11 | rc;
            rc = rcI;
          } else {
            levels[lv] = tok * 65;
            if (tok) {
              cf[rcI] = tok << 11 | rc;
              rc = rcI;
            } else
              cf[rcI] = 0;
          }
        }
        ctx = txClass === TX_CLASS_2D ? 0 : loCtx(0, 0, 0);
        dcTok = m.symbol(cdf, loCdf + ctx * 4, 3);
        if (dcTok === 3) {
          if (txClass === TX_CLASS_2D)
            hiMag = levels[1] + levels[stride] + levels[stride + 1];
          mag = hiMag & 63;
          ctx = mag > 12 ? 6 : mag + 1 >> 1;
          dcTok = m.hiTok(cdf, hiCdf + ctx * 4);
        }
      } else {
        const tokBr = m.symbol(cdf, eobCdf, 2);
        dcTok = 1 + tokBr;
        if (tokBr === 2)
          dcTok = m.hiTok(cdf, hiCdf);
        rc = 0;
      }
      const dq = this.dq[b.segId][plane];
      const qm = txtp < IDTX ? this.qm[tx][plane] : null;
      const dqShift = Math.max(0, tctx - 2);
      const cfMax = (128 << (f.bitdepth === 8 ? 8 : f.bitdepth)) - 1;
      let culLevel, dcSignLevel;
      if (!dcTok) {
        culLevel = 0;
        dcSignLevel = 1 << 6;
      } else {
        let sctx2 = 0;
        for (let i = 0;i < aw; i++)
          sctx2 += aArr[a + i] >> 6;
        for (let i = 0;i < lh; i++)
          sctx2 += lArr[l + i] >> 6;
        sctx2 -= aw + lh;
        const dcSignCtx = (sctx2 !== 0 ? 1 : 0) + (sctx2 > 0 ? 1 : 0);
        const dcSign = m.boolAdapt(cdf, CDF2.dcSign + (chroma * 3 + dcSignCtx) * 2);
        let dcDq = dq[0];
        dcSignLevel = dcSign - 1 & 2 << 6;
        if (qm)
          dcDq = dcDq * qm[0] + 16 >> 5;
        if (dcTok === 15) {
          dcTok = m.golomb() + 15 & 1048575;
          dcDq = (dcDq * dcTok & 16777215) >> dqShift;
          dcDq = Math.min(dcDq, cfMax + dcSign);
        } else {
          dcDq = dcDq * dcTok >> dqShift;
          if (qm)
            dcDq = Math.min(dcDq, cfMax + dcSign);
        }
        culLevel = dcTok;
        cf[0] = dcSign ? -dcDq : dcDq;
      }
      if (rc) {
        const acDq = dq[1];
        do {
          const sign = m.bool();
          const rcTok = cf[rc];
          let tok, d = qm ? acDq * qm[rc] + 16 >> 5 : acDq;
          if (rcTok >= 15 << 11) {
            tok = m.golomb() + 15 & 1048575;
            d = (d * tok & 16777215) >> dqShift;
            d = Math.min(d, cfMax + sign);
          } else {
            tok = rcTok >> 11;
            d = d * tok >> dqShift;
            if (qm)
              d = Math.min(d, cfMax + sign);
          }
          culLevel += tok;
          cf[rc] = sign ? -d : d;
          rc = rcTok & 1023;
        } while (rc);
      }
      this.resCtx = Math.min(culLevel, 63) | dcSignLevel;
      return eob;
    }
    reconIntra(bs, edgeFlags, b, hasChroma) {
      const f = this.frame, seq = this.seq;
      const bx = this.bx, by = this.by, bx4 = bx, by4 = by & 31;
      const { ssx, ssy } = f;
      const cbx4 = bx4 >> ssx, cby4 = by4 >> ssy;
      const bw4 = bdim(bs, 0), bh4 = bdim(bs, 1);
      const w4 = Math.min(bw4, f.bw - bx), h4 = Math.min(bh4, f.bh - by);
      const cw4 = w4 + ssx >> ssx, ch4 = h4 + ssy >> ssy;
      const cbw4 = bw4 + ssx >> ssx, cbh4 = bh4 + ssy >> ssy;
      const { tx, uvtx } = b;
      const tw = tdim(tx, W), th = tdim(tx, H), uvtw = tdim(uvtx, W), uvth = tdim(uvtx, H);
      const filterFlag = seq.intraEdgeFilter ? ANGLE_USE_EDGE_FILTER : 0;
      const bdMax = f.bitdepthMax;
      const pic = f.planes[0], stride = f.strides[0];
      const smFlag = (mode) => mode === SMOOTH_PRED || mode === SMOOTH_H_PRED || mode === SMOOTH_V_PRED ? ANGLE_SMOOTH_EDGE : 0;
      for (let initY = 0;initY < h4; initY += 16) {
        const subH4 = Math.min(h4, 16 + initY);
        const subCh4 = Math.min(ch4, initY + 16 >> ssy);
        for (let initX = 0;initX < w4; initX += 16) {
          if (b.palSz[0]) {
            const d = 4 * (by * stride + bx), bw = bw4 * 4;
            for (let y = 0;y < bh4 * 4; y++)
              for (let x = 0;x < bw; x++)
                pic[d + y * stride + x] = this.pal[this.palIdxY[y * bw + x]];
          }
          const intraFlags = (this.aIntra[bx4] ? smFlag(this.aMode[bx4]) : 0) | (this.lIntra[by4] ? smFlag(this.lMode[by4]) : 0) | filterFlag;
          const sbHasTr = initX + 16 < w4 ? 1 : initY ? 0 : edgeFlags & EDGE_I444_TOP_HAS_RIGHT;
          const sbHasBl = initX ? 0 : initY + 16 < h4 ? 1 : edgeFlags & EDGE_I444_LEFT_HAS_BOTTOM;
          const subW4 = Math.min(w4, initX + 16);
          for (let y = initY;y < subH4; y += th) {
            const ty = by + y;
            let d = 4 * (ty * stride + bx + initX);
            for (let x = initX;x < subW4; x += tw, d += 4 * tw) {
              const tx4 = bx + x;
              if (!b.palSz[0]) {
                const flags = ((y > initY || !sbHasTr) && x + tw >= subW4 ? 0 : EDGE_I444_TOP_HAS_RIGHT) | (x > initX || !sbHasBl && y + th >= subH4 ? 0 : EDGE_I444_LEFT_HAS_BOTTOM);
                const mode = prepareEdges(tx4, tx4 > this.colStart, ty, ty > this.rowStart, this.colEnd, this.rowEnd, flags, pic, d, stride, b.yMode, b.yAngle, tw, th, seq.intraEdgeFilter, f.bitdepth);
                predict(mode, pic, d, stride, tw * 4, th * 4, preparedAngle | intraFlags, 4 * f.bw - 4 * tx4, 4 * f.bh - 4 * ty, bdMax);
              }
              if (!b.skip) {
                const eob = this.decodeCoefs(this.aLcoef, bx4 + x, this.lLcoef, by4 + y, tx, bs, b, 0);
                this.aLcoef.fill(this.resCtx, bx4 + x, bx4 + x + Math.min(tw, f.bw - tx4));
                this.lLcoef.fill(this.resCtx, by4 + y, by4 + y + Math.min(th, f.bh - ty));
                if (eob >= 0)
                  inverseTransformAdd(pic, d, stride, this.cf, eob, tx, this.txtp, bdMax);
              } else {
                this.aLcoef.fill(64, bx4 + x, bx4 + x + tw);
                this.lLcoef.fill(64, by4 + y, by4 + y + th);
              }
            }
          }
          if (!hasChroma)
            continue;
          const cstride = f.strides[1];
          if (b.uvMode === CFL_PRED) {
            const yo = 4 * (bx & ~ssx) + 4 * (by & ~ssy) * stride;
            const furthestR = (cw4 << ssx) + tw - 1 & ~(tw - 1);
            const furthestB = (ch4 << ssy) + th - 1 & ~(th - 1);
            cflAc(this.ac, pic, yo, stride, cbw4 - (furthestR >> ssx), cbh4 - (furthestB >> ssy), cbw4 * 4, cbh4 * 4, ssx, ssy);
            const uvOff = 4 * ((bx >> ssx) + (by >> ssy) * cstride);
            for (let pl = 0;pl < 2; pl++) {
              if (!b.cflAlpha[pl])
                continue;
              const xpos = bx >> ssx, ypos = by >> ssy;
              const mode = prepareEdges(xpos, xpos > this.colStart >> ssx, ypos, ypos > this.rowStart >> ssy, this.colEnd >> ssx, this.rowEnd >> ssy, 0, f.planes[1 + pl], uvOff, cstride, DC_PRED, 0, uvtw, uvth, false, f.bitdepth);
              cflPredict(mode, f.planes[1 + pl], uvOff, cstride, uvtw * 4, uvth * 4, this.ac, b.cflAlpha[pl], bdMax);
            }
          } else if (b.palSz[1]) {
            const uvOff = 4 * ((bx >> ssx) + (by >> ssy) * cstride), bw = cbw4 * 4;
            for (let pl = 1;pl <= 2; pl++) {
              const plane = f.planes[pl];
              for (let y = 0;y < cbh4 * 4; y++)
                for (let x = 0;x < bw; x++)
                  plane[uvOff + y * cstride + x] = this.pal[pl * 8 + this.palIdxUv[y * bw + x]];
            }
          }
          const smUv = smFlag(this.aUvmode[cbx4]) | smFlag(this.lUvmode[cby4]);
          const edge = f.layout === 1 ? [EDGE_I420_TOP_HAS_RIGHT, EDGE_I420_LEFT_HAS_BOTTOM] : f.layout === 2 ? [2, 16] : [1, 8];
          const uvSbHasTr = initX + 16 >> ssx < cw4 ? 1 : initY ? 0 : edgeFlags & edge[0];
          const uvSbHasBl = initX ? 0 : initY + 16 >> ssy < ch4 ? 1 : edgeFlags & edge[1];
          const subCw4 = Math.min(cw4, initX + 16 >> ssx);
          for (let pl = 0;pl < 2; pl++) {
            const plane = f.planes[1 + pl];
            const aC = this.aCcoef[pl], lC = this.lCcoef[pl];
            for (let y = initY >> ssy, tyl = by + initY;y < subCh4; y += uvth, tyl += uvth << ssy) {
              let d = 4 * ((tyl >> ssy) * cstride + (bx + initX >> ssx));
              for (let x = initX >> ssx, txl = bx + initX;x < subCw4; x += uvtw, txl += uvtw << ssx, d += uvtw * 4) {
                if (!(b.uvMode === CFL_PRED && b.cflAlpha[pl]) && !b.palSz[1]) {
                  const flags = ((y > initY >> ssy || !uvSbHasTr) && x + uvtw >= subCw4 ? 0 : EDGE_I444_TOP_HAS_RIGHT) | (x > initX >> ssx || !uvSbHasBl && y + uvth >= subCh4 ? 0 : EDGE_I444_LEFT_HAS_BOTTOM);
                  const uvMode = b.uvMode === CFL_PRED ? DC_PRED : b.uvMode;
                  const xpos = txl >> ssx, ypos = tyl >> ssy;
                  const mode = prepareEdges(xpos, xpos > this.colStart >> ssx, ypos, ypos > this.rowStart >> ssy, this.colEnd >> ssx, this.rowEnd >> ssy, flags, plane, d, cstride, uvMode, b.uvAngle, uvtw, uvth, seq.intraEdgeFilter, f.bitdepth);
                  predict(mode, plane, d, cstride, uvtw * 4, uvth * 4, preparedAngle | filterFlag | smUv, 4 * f.bw + ssx - 4 * (txl & ~ssx) >> ssx, 4 * f.bh + ssy - 4 * (tyl & ~ssy) >> ssy, bdMax);
                }
                if (!b.skip) {
                  const eob = this.decodeCoefs(aC, cbx4 + x, lC, cby4 + y, uvtx, bs, b, 1 + pl);
                  const ctw = Math.min(uvtw, f.bw - txl + ssx >> ssx);
                  const cth = Math.min(uvth, f.bh - tyl + ssy >> ssy);
                  aC.fill(this.resCtx, cbx4 + x, cbx4 + x + ctw);
                  lC.fill(this.resCtx, cby4 + y, cby4 + y + cth);
                  if (eob >= 0)
                    inverseTransformAdd(plane, d, cstride, this.cf, eob, uvtx, this.txtp, bdMax);
                } else {
                  aC.fill(64, cbx4 + x, cbx4 + x + uvtw);
                  lC.fill(64, cby4 + y, cby4 + y + uvth);
                }
              }
            }
          }
        }
      }
    }
  }

  // src/codecs/av1/loopfilter.ts
  /*!
   * The AV1 deblocking filter: every transform block edge of intra frames, filtered with the filters of dav1d
   * (src/loopfilter_tmpl.c, src/lf_mask.c). Copyright (c) 2018-2021, VideoLAN and dav1d authors, Copyright (c) 2018,
   * Two Orioles, LLC, BSD-2-Clause License (see THIRD_PARTY_NOTICES.md)
   */
  function deblock(f) {
    const lf = f.hdr.loopFilter;
    if (!lf.levelY[0] && !lf.levelY[1])
      return;
    const sharp = lf.sharpness;
    const I = new Uint8Array(64), E = new Uint8Array(64);
    for (let level = 0;level < 64; level++) {
      let limit = level;
      if (sharp > 0)
        limit = Math.min(limit >> (sharp + 3 >> 2), 9 - sharp);
      I[level] = Math.max(limit, 1);
      E[level] = 2 * (level + 2) + I[level];
    }
    const s4 = f.b4Stride;
    for (let plane = 0;plane < f.planes.length; plane++) {
      if (plane && !(plane === 1 ? lf.levelU : lf.levelV))
        continue;
      const subX = plane ? f.ssx : 0, subY = plane ? f.ssy : 0;
      const txW = plane ? f.uvTxW : f.txW, txH = plane ? f.uvTxH : f.txH;
      const pic = f.planes[plane], stride = f.strides[plane];
      for (let pass = 0;pass < 2; pass++) {
        const dx = pass ? 0 : 1, dy = pass;
        const tx = pass ? txH : txW;
        const level = plane ? plane + 1 : pass;
        for (let row = 0;row < f.bh; row += 1 << subY) {
          const y = row * 4;
          if (y >= f.height || pass && !y)
            continue;
          for (let col = 0;col < f.bw; col += 1 << subX) {
            const x = col * 4;
            if (x >= f.width || !pass && !x)
              continue;
            const r = row | subY, c = col | subX;
            const xP = x >> subX, yP = y >> subY;
            const cur = (r >> subY) * s4 + (c >> subX);
            const prevR = r - (dy << subY), prevC = c - (dx << subX);
            const prev = (prevR >> subY) * s4 + (prevC >> subX);
            const size = 4 << tx[cur];
            if ((pass ? yP : xP) % size)
              continue;
            const filterSize = Math.min(plane ? 8 : 16, size, 4 << tx[prev]);
            let lvl = f.lfLevels[(r * s4 + c) * 4 + level];
            if (!lvl)
              lvl = f.lfLevels[(prevR * s4 + prevC) * 4 + level];
            if (!lvl)
              continue;
            const wd = plane && filterSize === 8 ? 6 : filterSize;
            filter(pic, yP * stride + xP, E[lvl], I[lvl], lvl >> 4, pass ? 1 : stride, pass ? stride : 1, wd, f.bitdepth);
          }
        }
      }
    }
  }
  function filter(dst, d, E, I, H2, stridea, strideb, wd, bitdepth) {
    const shift = bitdepth - 8, F = 1 << shift;
    E <<= shift;
    I <<= shift;
    H2 <<= shift;
    const max2 = (1 << bitdepth) - 1;
    const pix = (v) => v < 0 ? 0 : v > max2 ? max2 : v;
    const diffMin = -128 * (1 << shift), diffMax = 128 * (1 << shift) - 1;
    const clipDiff = (v) => v < diffMin ? diffMin : v > diffMax ? diffMax : v;
    const abs = Math.abs;
    for (let i = 0;i < 4; i++, d += stridea) {
      let p6 = 0, p5 = 0, p4 = 0, p3 = 0, p2 = 0, q2 = 0, q3 = 0, q4 = 0, q5 = 0, q6 = 0;
      const p1 = dst[d - 2 * strideb], p0 = dst[d - strideb], q0 = dst[d], q1 = dst[d + strideb];
      let fm = abs(p1 - p0) <= I && abs(q1 - q0) <= I && abs(p0 - q0) * 2 + (abs(p1 - q1) >> 1) <= E;
      if (wd > 4) {
        p2 = dst[d - 3 * strideb];
        q2 = dst[d + 2 * strideb];
        fm &&= abs(p2 - p1) <= I && abs(q2 - q1) <= I;
        if (wd > 6) {
          p3 = dst[d - 4 * strideb];
          q3 = dst[d + 3 * strideb];
          fm &&= abs(p3 - p2) <= I && abs(q3 - q2) <= I;
        }
      }
      if (!fm)
        continue;
      let flat8out = false, flat8in = false;
      if (wd >= 16) {
        p6 = dst[d - 7 * strideb];
        p5 = dst[d - 6 * strideb];
        p4 = dst[d - 5 * strideb];
        q4 = dst[d + 4 * strideb];
        q5 = dst[d + 5 * strideb];
        q6 = dst[d + 6 * strideb];
        flat8out = abs(p6 - p0) <= F && abs(p5 - p0) <= F && abs(p4 - p0) <= F && abs(q4 - q0) <= F && abs(q5 - q0) <= F && abs(q6 - q0) <= F;
      }
      if (wd >= 6)
        flat8in = abs(p2 - p0) <= F && abs(p1 - p0) <= F && abs(q1 - q0) <= F && abs(q2 - q0) <= F;
      if (wd >= 8)
        flat8in &&= abs(p3 - p0) <= F && abs(q3 - q0) <= F;
      if (wd >= 16 && flat8out && flat8in) {
        dst[d - 6 * strideb] = p6 * 7 + p5 * 2 + p4 * 2 + p3 + p2 + p1 + p0 + q0 + 8 >> 4;
        dst[d - 5 * strideb] = p6 * 5 + p5 * 2 + p4 * 2 + p3 * 2 + p2 + p1 + p0 + q0 + q1 + 8 >> 4;
        dst[d - 4 * strideb] = p6 * 4 + p5 + p4 * 2 + p3 * 2 + p2 * 2 + p1 + p0 + q0 + q1 + q2 + 8 >> 4;
        dst[d - 3 * strideb] = p6 * 3 + p5 + p4 + p3 * 2 + p2 * 2 + p1 * 2 + p0 + q0 + q1 + q2 + q3 + 8 >> 4;
        dst[d - 2 * strideb] = p6 * 2 + p5 + p4 + p3 + p2 * 2 + p1 * 2 + p0 * 2 + q0 + q1 + q2 + q3 + q4 + 8 >> 4;
        dst[d - strideb] = p6 + p5 + p4 + p3 + p2 + p1 * 2 + p0 * 2 + q0 * 2 + q1 + q2 + q3 + q4 + q5 + 8 >> 4;
        dst[d] = p5 + p4 + p3 + p2 + p1 + p0 * 2 + q0 * 2 + q1 * 2 + q2 + q3 + q4 + q5 + q6 + 8 >> 4;
        dst[d + strideb] = p4 + p3 + p2 + p1 + p0 + q0 * 2 + q1 * 2 + q2 * 2 + q3 + q4 + q5 + q6 * 2 + 8 >> 4;
        dst[d + 2 * strideb] = p3 + p2 + p1 + p0 + q0 + q1 * 2 + q2 * 2 + q3 * 2 + q4 + q5 + q6 * 3 + 8 >> 4;
        dst[d + 3 * strideb] = p2 + p1 + p0 + q0 + q1 + q2 * 2 + q3 * 2 + q4 * 2 + q5 + q6 * 4 + 8 >> 4;
        dst[d + 4 * strideb] = p1 + p0 + q0 + q1 + q2 + q3 * 2 + q4 * 2 + q5 * 2 + q6 * 5 + 8 >> 4;
        dst[d + 5 * strideb] = p0 + q0 + q1 + q2 + q3 + q4 * 2 + q5 * 2 + q6 * 7 + 8 >> 4;
      } else if (wd >= 8 && flat8in) {
        dst[d - 3 * strideb] = p3 * 3 + 2 * p2 + p1 + p0 + q0 + 4 >> 3;
        dst[d - 2 * strideb] = p3 * 2 + p2 + 2 * p1 + p0 + q0 + q1 + 4 >> 3;
        dst[d - strideb] = p3 + p2 + p1 + 2 * p0 + q0 + q1 + q2 + 4 >> 3;
        dst[d] = p2 + p1 + p0 + 2 * q0 + q1 + q2 + q3 + 4 >> 3;
        dst[d + strideb] = p1 + p0 + q0 + 2 * q1 + q2 + q3 * 2 + 4 >> 3;
        dst[d + 2 * strideb] = p0 + q0 + q1 + 2 * q2 + q3 * 3 + 4 >> 3;
      } else if (wd === 6 && flat8in) {
        dst[d - 2 * strideb] = p2 * 3 + 2 * p1 + 2 * p0 + q0 + 4 >> 3;
        dst[d - strideb] = p2 + 2 * p1 + 2 * p0 + 2 * q0 + q1 + 4 >> 3;
        dst[d] = p1 + 2 * p0 + 2 * q0 + 2 * q1 + q2 + 4 >> 3;
        dst[d + strideb] = p0 + 2 * q0 + 2 * q1 + q2 * 3 + 4 >> 3;
      } else {
        const hev = abs(p1 - p0) > H2 || abs(q1 - q0) > H2;
        const top = (128 << shift) - 1;
        if (hev) {
          let f = clipDiff(p1 - q1);
          f = clipDiff(3 * (q0 - p0) + f);
          const f1 = Math.min(f + 4, top) >> 3, f2 = Math.min(f + 3, top) >> 3;
          dst[d - strideb] = pix(p0 + f2);
          dst[d] = pix(q0 - f1);
        } else {
          const f = clipDiff(3 * (q0 - p0));
          const f1 = Math.min(f + 4, top) >> 3, f2 = Math.min(f + 3, top) >> 3;
          dst[d - strideb] = pix(p0 + f2);
          dst[d] = pix(q0 - f1);
          const g = f1 + 1 >> 1;
          dst[d - 2 * strideb] = pix(p1 + g);
          dst[d + strideb] = pix(q1 - g);
        }
      }
    }
  }

  // src/codecs/av1/cdef.ts
  /*!
   * The AV1 constrained directional enhancement filter, as the AV1 specification describes it (section 7.15) and dav1d
   * implements it (src/cdef_tmpl.c). Copyright (c) 2018-2021, VideoLAN and dav1d authors, Copyright (c) 2018, Two
   * Orioles, LLC, BSD-2-Clause License (see THIRD_PARTY_NOTICES.md)
   */
  var DIV_TABLE = [0, 840, 420, 280, 210, 168, 140, 120, 105];
  var UV_DIR = [[[0, 1, 2, 3, 4, 5, 6, 7], [1, 2, 2, 2, 3, 4, 6, 0]], [[7, 0, 2, 4, 5, 6, 6, 6], [0, 1, 2, 3, 4, 5, 6, 7]]];
  var PRI_TAPS = [[4, 2], [3, 3]];
  var SEC_TAPS = [2, 1];
  var floorLog2 = (v) => 31 - Math.clz32(v);
  function cdefActive(f) {
    const c = f.hdr.cdef;
    return f.seq.cdef && (c.yStrengths.some((s) => s) || c.uvStrengths.some((s) => s));
  }
  function cdef(f, src, dirs) {
    const c = f.hdr.cdef;
    const coeffShift = f.bitdepth - 8;
    const s4 = f.b4Stride;
    for (let r = 0;r < f.bh; r += 2) {
      for (let col = 0;col < f.bw; col += 2) {
        const idx = f.cdefIdx[(r >> 4) * (s4 >> 4) + (col >> 4)];
        if (idx === -1)
          continue;
        const o = r * s4 + col;
        if (f.skip[o] && f.skip[o + s4] && f.skip[o + 1] && f.skip[o + s4 + 1])
          continue;
        const usesDirection = c.yStrengths[idx] >> 2 || f.planes.length > 1 && c.uvStrengths[idx] >> 2;
        let yDir = 0, variance = 0;
        if (usesDirection) {
          const k = (r >> 1) * (s4 >> 1) + (col >> 1);
          if (dirs && dirs[2 * k] >= 0) {
            yDir = dirs[2 * k];
            variance = dirs[2 * k + 1];
          } else {
            yDir = direction(src[0], r * 4 * f.strides[0] + col * 4, f.strides[0], coeffShift);
            variance = directionVariance;
            if (dirs) {
              dirs[2 * k] = yDir;
              dirs[2 * k + 1] = variance;
            }
          }
        }
        const ys = c.yStrengths[idx];
        let priStr = ys >> 2 << coeffShift;
        const secY = ys & 3;
        const secStr = (secY === 3 ? 4 : secY) << coeffShift;
        const dir = priStr ? yDir : 0;
        const varStr = variance >> 6 ? Math.min(floorLog2(variance >> 6), 12) : 0;
        priStr = variance ? priStr * (4 + varStr) + 8 >> 4 : 0;
        filterBlock(f, src, 0, r, col, priStr, secStr, c.damping + coeffShift, dir);
        if (f.planes.length === 1)
          continue;
        const uvs = c.uvStrengths[idx];
        const uvPri = uvs >> 2 << coeffShift, secUv = uvs & 3;
        const uvSec = (secUv === 3 ? 4 : secUv) << coeffShift;
        const uvDir = uvPri ? UV_DIR[f.ssx][f.ssy][yDir] : 0;
        for (let p = 1;p < 3; p++)
          filterBlock(f, src, p, r, col, uvPri, uvSec, c.damping + coeffShift - 1, uvDir);
      }
    }
  }
  var partial = new Int32Array(8 * 15);
  var cost = new Float64Array(8);
  var directionVariance = 0;
  function direction(luma, o, ls, coeffShift) {
    partial.fill(0);
    for (let i = 0;i < 8; i++) {
      const row = o + i * ls, ih = i >> 1;
      for (let j = 0;j < 8; j++) {
        const x = (luma[row + j] >> coeffShift) - 128, jh = j >> 1;
        partial[i + j] += x;
        partial[15 + i + jh] += x;
        partial[30 + i] += x;
        partial[45 + 3 + i - jh] += x;
        partial[60 + 7 + i - j] += x;
        partial[75 + 3 - ih + j] += x;
        partial[90 + j] += x;
        partial[105 + ih + j] += x;
      }
    }
    cost.fill(0);
    for (let i = 0;i < 8; i++) {
      cost[2] += partial[30 + i] * partial[30 + i];
      cost[6] += partial[90 + i] * partial[90 + i];
    }
    cost[2] *= DIV_TABLE[8];
    cost[6] *= DIV_TABLE[8];
    for (let i = 0;i < 7; i++) {
      cost[0] += (partial[i] * partial[i] + partial[14 - i] * partial[14 - i]) * DIV_TABLE[i + 1];
      cost[4] += (partial[60 + i] * partial[60 + i] + partial[60 + 14 - i] * partial[60 + 14 - i]) * DIV_TABLE[i + 1];
    }
    cost[0] += partial[7] * partial[7] * DIV_TABLE[8];
    cost[4] += partial[67] * partial[67] * DIV_TABLE[8];
    for (let i = 1;i < 8; i += 2) {
      const p = i * 15;
      for (let j = 0;j < 5; j++)
        cost[i] += partial[p + 3 + j] * partial[p + 3 + j];
      cost[i] *= DIV_TABLE[8];
      for (let j = 0;j < 3; j++)
        cost[i] += (partial[p + j] * partial[p + j] + partial[p + 10 - j] * partial[p + 10 - j]) * DIV_TABLE[2 * j + 2];
    }
    let bestCost = 0, yDir = 0;
    for (let i = 0;i < 8; i++) {
      if (cost[i] > bestCost) {
        bestCost = cost[i];
        yDir = i;
      }
    }
    directionVariance = Math.floor((bestCost - cost[yDir + 4 & 7]) / 1024);
    return yDir;
  }
  function filterBlock(f, src, plane, r, c, priStr, secStr, damping, dir) {
    if (!priStr && !secStr)
      return;
    const subX = plane ? f.ssx : 0, subY = plane ? f.ssy : 0;
    const s = src[plane], dst = f.planes[plane], stride = f.strides[plane];
    const x0 = c * 4 >> subX, y0 = r * 4 >> subY, w = 8 >> subX, h = 8 >> subY;
    const maxX = f.bw * 4 >> subX, maxY = f.bh * 4 >> subY;
    const priTaps = PRI_TAPS[priStr >> f.bitdepth - 8 & 1];
    const priShift = priStr ? Math.max(0, damping - floorLog2(priStr)) : 0, secShift = secStr ? Math.max(0, damping - floorLog2(secStr)) : 0;
    for (let n = 0;n < 6; n++) {
      const t = n >> 1, k = n & 1;
      const d = (t === 0 ? dir : t === 1 ? dir + 6 : dir + 2) & 7;
      const dy = DIRECTIONS[d * 4 + k * 2], dx = DIRECTIONS[d * 4 + k * 2 + 1];
      offsets[n] = dy * stride + dx;
      dys[n] = dy;
      dxs[n] = dx;
      taps[n] = t ? SEC_TAPS[k] : priTaps[k];
      strengths[n] = t ? secStr : priStr;
      shifts[n] = t ? secShift : priShift;
    }
    if (x0 >= 2 && y0 >= 2 && x0 + w + 2 <= maxX && y0 + h + 2 <= maxY) {
      const p0 = offsets[0], p1 = offsets[1], s0 = offsets[2], s1 = offsets[3], s2 = offsets[4], s3 = offsets[5];
      const t0 = priTaps[0], t1 = priTaps[1];
      const off = (1 << f.bitdepth) - 1;
      const P = constrainTable(priStr, priShift, f.bitdepth), S = constrainTable(secStr, secShift, f.bitdepth);
      for (let i = 0;i < h; i++) {
        for (let j = 0, o = (y0 + i) * stride + x0;j < w; j++, o++) {
          const x = s[o];
          const a0 = s[o + p0], b0 = s[o - p0], a1 = s[o + p1], b1 = s[o - p1];
          const c0 = s[o + s0], d0 = s[o - s0], c1 = s[o + s1], d1 = s[o - s1];
          const e0 = s[o + s2], f0 = s[o - s2], e1 = s[o + s3], f1 = s[o - s3];
          const ox = off - x;
          const sum = t0 * (P[a0 + ox] + P[b0 + ox]) + t1 * (P[a1 + ox] + P[b1 + ox]) + 2 * (S[c0 + ox] + S[d0 + ox] + S[e0 + ox] + S[f0 + ox]) + S[c1 + ox] + S[d1 + ox] + S[e1 + ox] + S[f1 + ox];
          let v = x + (8 + sum - (sum < 0 ? 1 : 0) >> 4);
          if (v > x) {
            if (v > a0 && v > b0 && v > a1 && v > b1 && v > c0 && v > d0 && v > c1 && v > d1 && v > e0 && v > f0 && v > e1 && v > f1)
              v = Math.max(x, a0, b0, a1, b1, c0, d0, c1, d1, e0, f0, e1, f1);
          } else if (v < x) {
            if (v < a0 && v < b0 && v < a1 && v < b1 && v < c0 && v < d0 && v < c1 && v < d1 && v < e0 && v < f0 && v < e1 && v < f1)
              v = Math.min(x, a0, b0, a1, b1, c0, d0, c1, d1, e0, f0, e1, f1);
          }
          dst[o] = v;
        }
      }
      return;
    }
    for (let i = 0;i < h; i++) {
      const y = y0 + i;
      for (let j = 0;j < w; j++) {
        const xx = x0 + j, o = y * stride + xx;
        const x = s[o];
        let sum = 0, max2 = x, min = x;
        for (let t = 0;t < 6; t++) {
          for (let sign = -1;sign <= 1; sign += 2) {
            const py = y + sign * dys[t], px = xx + sign * dxs[t];
            if (py < 0 || px < 0 || py >= maxY || px >= maxX)
              continue;
            const p = s[o + sign * offsets[t]];
            sum += taps[t] * constrain(p - x, strengths[t], shifts[t]);
            if (p > max2)
              max2 = p;
            if (p < min)
              min = p;
          }
        }
        const v = x + (8 + sum - (sum < 0 ? 1 : 0) >> 4);
        dst[o] = v < min ? min : v > max2 ? max2 : v;
      }
    }
  }
  var tables2 = new Map;
  function constrainTable(strength, shift, bitdepth) {
    const key = (strength * 32 + shift) * 16 + bitdepth;
    let t = tables2.get(key);
    if (!t) {
      const off = (1 << bitdepth) - 1;
      t = new Int16Array(2 * off + 1);
      for (let d = -off;d <= off; d++)
        t[d + off] = constrain(d, strength, shift);
      tables2.set(key, t);
    }
    return t;
  }
  function constrain(diff, strength, shift) {
    if (!strength)
      return 0;
    const a = diff < 0 ? -diff : diff;
    let v = strength - (a >> shift);
    if (v > a)
      v = a;
    if (v <= 0)
      return 0;
    return diff < 0 ? -v : v;
  }
  var DIRECTIONS = new Int8Array([
    -1,
    1,
    -2,
    2,
    0,
    1,
    -1,
    2,
    0,
    1,
    0,
    2,
    0,
    1,
    1,
    2,
    1,
    1,
    2,
    2,
    1,
    0,
    2,
    1,
    1,
    0,
    2,
    0,
    1,
    0,
    2,
    -1
  ]);
  var offsets = new Int32Array(6);
  var dys = new Int32Array(6);
  var dxs = new Int32Array(6);
  var taps = new Int32Array(6);
  var strengths = new Int32Array(6);
  var shifts = new Int32Array(6);

  // src/codecs/av1/restoration.ts
  /*!
   * AV1 superres upscaling and loop restoration (Wiener and self guided filters), as the AV1 specification describes them
   * (sections 7.16, 7.17) and dav1d implements them (src/looprestoration_tmpl.c, src/mc_tmpl.c), with dav1d's tables.
   * Copyright (c) 2018-2021, VideoLAN and dav1d authors, Copyright (c) 2018, Two Orioles, LLC, BSD-2-Clause License (see
   * THIRD_PARTY_NOTICES.md)
   */
  function superres(f, planes) {
    const out = [], strides = [];
    const max2 = f.bitdepthMax;
    for (let p = 0;p < planes.length; p++) {
      const subX = p ? f.ssx : 0, subY = p ? f.ssy : 0;
      const downW = f.width + subX >> subX, upW = f.hdr.upscaledWidth + subX >> subX, h = f.height + subY >> subY;
      const stepX = Math.floor(((downW << 14) + (upW >> 1)) / upW);
      const err = upW * stepX - (downW << 14);
      let initialSubpelX = Math.trunc((-(upW - downW << 13) + (upW >> 1)) / upW) + (1 << 7) - Math.trunc(err / 2);
      initialSubpelX &= (1 << 14) - 1;
      const maxX = (f.bw >> subX) * 4 - 1;
      const src = planes[p], srcStride = f.strides[p];
      const stride = upW + 31 & ~31;
      const dst = new Uint16Array(stride * (h + 8));
      for (let y = 0;y < h; y++) {
        for (let x = 0;x < upW; x++) {
          const srcX = -(1 << 14) + initialSubpelX + x * stepX;
          const px = srcX >> 14, subpel = (srcX & (1 << 14) - 1) >> 8;
          let sum = 0;
          for (let k = 0;k < 8; k++) {
            const sx = Math.min(maxX, Math.max(0, px + k - 3));
            sum -= src[y * srcStride + sx] * RESIZE_FILTER2[subpel * 8 + k];
          }
          const v = sum + 64 >> 7;
          dst[y * stride + x] = v < 0 ? 0 : v > max2 ? max2 : v;
        }
      }
      out.push(dst);
      strides.push(stride);
    }
    return { planes: out, strides };
  }
  var SGR = [
    [2, 12, 1, 4],
    [2, 15, 1, 6],
    [2, 18, 1, 8],
    [2, 21, 1, 9],
    [2, 24, 1, 10],
    [2, 29, 1, 11],
    [2, 36, 1, 12],
    [2, 45, 1, 13],
    [2, 56, 1, 14],
    [2, 68, 1, 15],
    [0, 0, 1, 5],
    [0, 0, 1, 8],
    [0, 0, 1, 11],
    [0, 0, 1, 14],
    [2, 30, 0, 0],
    [2, 75, 0, 0]
  ];
  function loopRestoration(f, pre, cdef2, out, strides) {
    const { hdr, bitdepth, bitdepthMax: max2 } = f;
    for (let p = 0;p < out.length; p++) {
      if (hdr.restoration.types[p] === RESTORATION_NONE)
        continue;
      const subX = p ? f.ssx : 0, subY = p ? f.ssy : 0;
      const planeW = hdr.upscaledWidth + subX >> subX, planeH = f.height + subY >> subY;
      const unitSize = 1 << hdr.restoration.unitSizeLog2[p ? 1 : 0];
      const unitCols = f.lrUnitsW[p], unitRows = f.lrUnitsH[p];
      const stride = strides[p], cur = pre[p], cd = cdef2[p], dst = out[p];
      for (let stripe = 0;-8 + stripe * 64 >> subY < planeH; stripe++) {
        const stripeStart = -8 + stripe * 64 >> subY, stripeEnd = stripeStart + (64 >> subY) - 1;
        const y0 = Math.max(0, stripeStart), y1 = Math.min(planeH, stripeEnd + 1);
        if (y0 >= y1)
          continue;
        const lumaRow = Math.max(0, stripe * 64 - 8) >> 2;
        const unitRow = Math.min(unitRows - 1, Math.floor((lumaRow * 4 + 8 >> subY) / unitSize));
        const sample = (x, y) => {
          x = Math.max(0, Math.min(planeW - 1, x));
          y = Math.max(0, Math.min(planeH - 1, y));
          if (y < stripeStart)
            return cur[Math.max(stripeStart - 2, y) * stride + x];
          if (y > stripeEnd)
            return cur[Math.min(stripeEnd + 2, y) * stride + x];
          return cd[y * stride + x];
        };
        for (let unitCol = 0;unitCol < unitCols; unitCol++) {
          const x0 = unitCol * unitSize, x1 = unitCol === unitCols - 1 ? planeW : Math.min(planeW, x0 + unitSize);
          const unit = f.lr[p][unitRow * unitCols + unitCol];
          const w = x1 - x0, h = y1 - y0;
          const ww = w + 6, win = new Int32Array(ww * (h + 6));
          for (let y = 0;y < h + 6; y++)
            for (let x = 0;x < ww; x++)
              win[y * ww + x] = sample(x0 + x - 3, y0 + y - 3);
          if (unit.type === RESTORATION_WIENER)
            wiener(win, ww, w, h, unit.filterV, unit.filterH, bitdepth, dst, y0 * stride + x0, stride);
          else if (unit.type !== RESTORATION_NONE)
            selfGuided(win, ww, w, h, unit.type - 3, unit.sgrWeights, bitdepth, cd, dst, y0 * stride + x0, stride, max2);
        }
      }
    }
  }
  function wienerFilter(coeff) {
    const filter2 = [coeff[0], coeff[1], coeff[2], 128, coeff[2], coeff[1], coeff[0]];
    filter2[3] -= 2 * (coeff[0] + coeff[1] + coeff[2]);
    return filter2;
  }
  function wiener(win, ww, w, h, v, hf, bitdepth, dst, d, stride) {
    const round0 = bitdepth === 12 ? 5 : 3, round1 = bitdepth === 12 ? 9 : 11;
    const vfilter = wienerFilter(v), hfilter = wienerFilter(hf);
    const offset = 1 << bitdepth + 7 - round0 - 1, limit = (1 << bitdepth + 1 + 7 - round0) - 1;
    const max2 = (1 << bitdepth) - 1;
    const inter = new Int32Array(w * (h + 6));
    for (let r = 0;r < h + 6; r++) {
      for (let c = 0;c < w; c++) {
        let s = 0;
        for (let t = 0;t < 7; t++)
          s += hfilter[t] * win[r * ww + c + t];
        const x = s + (1 << round0 - 1) >> round0;
        inter[r * w + c] = x < -offset ? -offset : x > limit - offset ? limit - offset : x;
      }
    }
    for (let r = 0;r < h; r++) {
      for (let c = 0;c < w; c++) {
        let s = 0;
        for (let t = 0;t < 7; t++)
          s += vfilter[t] * inter[(r + t) * w + c];
        const x = s + (1 << round1 - 1) >> round1;
        dst[d + r * stride + c] = x < 0 ? 0 : x > max2 ? max2 : x;
      }
    }
  }
  function boxFilter(win, ww, w, h, r, eps, pass, bitdepth, cd, d, stride) {
    const n = (2 * r + 1) * (2 * r + 1), n2e = n * n * eps;
    const s = Math.floor(((1 << 20) + Math.floor(n2e / 2)) / n2e);
    const oneOverN = Math.floor(((1 << 12) + (n >> 1)) / n);
    const shiftA = 2 * (bitdepth - 8), shiftB = bitdepth - 8;
    const aw = w + 2, A = new Int32Array(aw * (h + 2)), B = new Int32Array(aw * (h + 2));
    const rowSum = new Int32Array(ww), rowSq = new Float64Array(ww);
    for (let i = -1;i < h + 1; i++) {
      if (pass === 0 && !(i & 1))
        continue;
      rowSum.fill(0);
      rowSq.fill(0);
      for (let dy = -r;dy <= r; dy++) {
        const o = (i + dy + 3) * ww;
        for (let x = 0;x < ww; x++) {
          const c = win[o + x];
          rowSum[x] += c;
          rowSq[x] += c * c;
        }
      }
      for (let j = -1;j < w + 1; j++) {
        let a = 0, b = 0;
        for (let dx = -r;dx <= r; dx++) {
          a += rowSq[j + dx + 3];
          b += rowSum[j + dx + 3];
        }
        a = shiftA ? a + (1 << shiftA - 1) >> shiftA : a;
        const dd = shiftB ? b + (1 << shiftB - 1) >> shiftB : b;
        const p = Math.max(0, a * n - dd * dd);
        const z = Math.floor((p * s + (1 << 19)) / (1 << 20));
        const a2 = z >= 255 ? 256 : z === 0 ? 1 : Math.floor(((z << 8) + (z >> 1)) / (z + 1));
        A[(i + 1) * aw + j + 1] = a2;
        B[(i + 1) * aw + j + 1] = Math.floor(((256 - a2) * b * oneOverN + 2048) / 4096);
      }
    }
    const F = new Int32Array(w * h);
    for (let i = 0;i < h; i++) {
      const shift = (pass === 0 && i & 1 ? 4 : 5) + 4, rnd = 1 << shift - 1;
      const up = i * aw, mid = (i + 1) * aw, down = (i + 2) * aw;
      for (let j = 0;j < w; j++) {
        let a, b;
        if (pass === 0) {
          if (i & 1) {
            a = 6 * A[mid + j + 1] + 5 * (A[mid + j] + A[mid + j + 2]);
            b = 6 * B[mid + j + 1] + 5 * (B[mid + j] + B[mid + j + 2]);
          } else {
            a = 6 * (A[up + j + 1] + A[down + j + 1]) + 5 * (A[up + j] + A[up + j + 2] + A[down + j] + A[down + j + 2]);
            b = 6 * (B[up + j + 1] + B[down + j + 1]) + 5 * (B[up + j] + B[up + j + 2] + B[down + j] + B[down + j + 2]);
          }
        } else {
          a = 4 * (A[up + j + 1] + A[mid + j] + A[mid + j + 1] + A[mid + j + 2] + A[down + j + 1]) + 3 * (A[up + j] + A[up + j + 2] + A[down + j] + A[down + j + 2]);
          b = 4 * (B[up + j + 1] + B[mid + j] + B[mid + j + 1] + B[mid + j + 2] + B[down + j + 1]) + 3 * (B[up + j] + B[up + j + 2] + B[down + j] + B[down + j + 2]);
        }
        F[i * w + j] = a * cd[d + i * stride + j] + b + rnd >> shift;
      }
    }
    return F;
  }
  function selfGuided(win, ww, w, h, set, weights, bitdepth, cd, dst, d, stride, max2) {
    const [r0, e0, r1, e1] = SGR[set];
    const flt0 = r0 ? boxFilter(win, ww, w, h, r0, e0, 0, bitdepth, cd, d, stride) : null;
    const flt1 = r1 ? boxFilter(win, ww, w, h, r1, e1, 1, bitdepth, cd, d, stride) : null;
    const w0 = weights[0], w1 = weights[1], w2 = 128 - w0 - w1;
    for (let i = 0;i < h; i++) {
      for (let j = 0;j < w; j++) {
        const u = cd[d + i * stride + j] << 4;
        let v = w1 * u;
        v += flt0 ? w0 * flt0[i * w + j] : w0 * u;
        v += flt1 ? w2 * flt1[i * w + j] : w2 * u;
        const s = v + 1024 >> 11;
        dst[d + i * stride + j] = s < 0 ? 0 : s > max2 ? max2 : s;
      }
    }
  }

  // src/codecs/av1/postfilter.ts
  /*!
   * The post filters of AV1 frames: deblocking, CDEF, superres upscaling and loop restoration, in the order
   * of the AV1 specification. Copyright (c) 2018-2021, VideoLAN and dav1d authors, BSD-2-Clause License (see
   * THIRD_PARTY_NOTICES.md)
   */
  function postFilter(f) {
    deblock(f);
    const usesLr = f.hdr.restoration.types.some((t) => t !== RESTORATION_NONE);
    const doCdef = cdefActive(f);
    let pre = doCdef || usesLr ? f.planes.map((p) => p.slice()) : f.planes;
    if (doCdef)
      cdef(f, pre);
    if (f.hdr.upscaledWidth !== f.width) {
      const up = superres(f, f.planes);
      pre = usesLr ? superres(f, pre).planes : up.planes;
      f.planes = up.planes;
      f.strides = up.strides;
    }
    if (usesLr) {
      const out = f.planes.map((p) => p.slice());
      loopRestoration(f, pre, f.planes, out, f.strides);
      f.planes = out;
    }
  }

  // src/codecs/av1/filmgrain.ts
  /*!
   * AV1 film grain synthesis, ported from dav1d (src/filmgrain_tmpl.c, src/fg_apply_tmpl.c). Copyright (c) 2018-2021,
   * VideoLAN and dav1d authors, Copyright (c) 2018, Two Orioles, LLC, BSD-2-Clause License (see THIRD_PARTY_NOTICES.md)
   */
  var GRAIN_WIDTH = 82;
  var GRAIN_HEIGHT = 73;
  var SUB_GRAIN_WIDTH = 44;
  var SUB_GRAIN_HEIGHT = 38;
  var BLOCK = 32;

  class Random {
    state;
    constructor(state) {
      this.state = state;
    }
    next(bits2) {
      const r = this.state;
      const bit = (r ^ r >> 1 ^ r >> 3 ^ r >> 12) & 1;
      this.state = r >> 1 | bit << 15;
      return this.state >> 16 - bits2 & (1 << bits2) - 1;
    }
  }
  var round2 = (x, shift) => x + (1 << shift >> 1) >> shift;
  function generateGrainY(g, bitdepth) {
    const gauss = gaussianSequence();
    const buf = new Int16Array(GRAIN_HEIGHT * GRAIN_WIDTH);
    const rnd = new Random(g.seed);
    const shift = 4 - (bitdepth - 8) + g.grainScaleShift;
    const ctr = 128 << bitdepth - 8, min = -ctr, max2 = ctr - 1;
    for (let i = 0;i < buf.length; i++)
      buf[i] = round2(gauss[rnd.next(11)], shift);
    const lag = g.arCoeffLag;
    for (let y = 3;y < GRAIN_HEIGHT; y++) {
      for (let x = 3;x < GRAIN_WIDTH - 3; x++) {
        let sum = 0, c = 0;
        outer:
          for (let dy = -lag;dy <= 0; dy++) {
            for (let dx = -lag;dx <= lag; dx++) {
              if (!dx && !dy)
                break outer;
              sum += g.arCoeffsY[c++] * buf[(y + dy) * GRAIN_WIDTH + x + dx];
            }
          }
        const v = buf[y * GRAIN_WIDTH + x] + round2(sum, g.arCoeffShift);
        buf[y * GRAIN_WIDTH + x] = v < min ? min : v > max2 ? max2 : v;
      }
    }
    return buf;
  }
  function generateGrainUv(g, lumaBuf, uv, subx, suby, bitdepth) {
    const gauss = gaussianSequence();
    const buf = new Int16Array(GRAIN_HEIGHT * GRAIN_WIDTH);
    const rnd = new Random(g.seed ^ (uv ? 18904 : 46372));
    const shift = 4 - (bitdepth - 8) + g.grainScaleShift;
    const ctr = 128 << bitdepth - 8, min = -ctr, max2 = ctr - 1;
    const w = subx ? SUB_GRAIN_WIDTH : GRAIN_WIDTH, h = suby ? SUB_GRAIN_HEIGHT : GRAIN_HEIGHT;
    for (let y = 0;y < h; y++)
      for (let x = 0;x < w; x++)
        buf[y * GRAIN_WIDTH + x] = round2(gauss[rnd.next(11)], shift);
    const lag = g.arCoeffLag, coeffs = g.arCoeffsUv[uv];
    for (let y = 3;y < h; y++) {
      for (let x = 3;x < w - 3; x++) {
        let sum = 0, c = 0;
        outer:
          for (let dy = -lag;dy <= 0; dy++) {
            for (let dx = -lag;dx <= lag; dx++) {
              if (!dx && !dy) {
                if (!g.yPoints.length)
                  break outer;
                let luma = 0;
                const lx = (x - 3 << subx) + 3, ly = (y - 3 << suby) + 3;
                for (let i = 0;i <= suby; i++)
                  for (let j = 0;j <= subx; j++)
                    luma += lumaBuf[(ly + i) * GRAIN_WIDTH + lx + j];
                sum += round2(luma, subx + suby) * coeffs[c];
                break outer;
              }
              sum += coeffs[c++] * buf[(y + dy) * GRAIN_WIDTH + x + dx];
            }
          }
        const v = buf[y * GRAIN_WIDTH + x] + round2(sum, g.arCoeffShift);
        buf[y * GRAIN_WIDTH + x] = v < min ? min : v > max2 ? max2 : v;
      }
    }
    return buf;
  }
  function generateScaling(bitdepth, points) {
    const shiftX = bitdepth - 8, size = 1 << bitdepth;
    const scaling = new Uint8Array(size);
    const num = points.length;
    if (!num)
      return scaling;
    scaling.fill(points[0][1], 0, points[0][0] << shiftX);
    for (let i = 0;i < num - 1; i++) {
      const [bx, by] = points[i], [ex, ey] = points[i + 1];
      const dx = ex - bx, dy = ey - by;
      const delta = dy * Math.floor((65536 + (dx >> 1)) / dx);
      for (let x = 0, d = 32768;x < dx; x++) {
        scaling[bx + x << shiftX] = by + (d >> 16);
        d += delta;
      }
    }
    const n = points[num - 1][0] << shiftX;
    scaling.fill(points[num - 1][1], n, size);
    if (bitdepth > 8) {
      const pad = 1 << shiftX, rnd = pad >> 1;
      for (let i = 0;i < num - 1; i++) {
        const bx = points[i][0] << shiftX, ex = points[i + 1][0] << shiftX;
        for (let x = 0;x < ex - bx; x += pad) {
          const range = scaling[bx + x + pad] - scaling[bx + x];
          for (let k = 1, r = rnd;k < pad; k++) {
            r += range;
            scaling[bx + x + k] = scaling[bx + x] + (r >> shiftX);
          }
        }
      }
    }
    return scaling;
  }
  var W2 = [[[27, 17], [17, 27]], [[23, 22], [0, 0]]];
  function applyStripe(g, dst, src, stride, pw, bh, rowNum, scaling, lut, bitdepth, plane, sx, sy, isId, luma, lumaStride) {
    const rows = 1 + (g.overlap && rowNum > 0 ? 1 : 0);
    const shift8 = bitdepth - 8, ctr = 128 << shift8, gmin = -ctr, gmax = ctr - 1, bdMax = (1 << bitdepth) - 1;
    const minV = g.clipToRestrictedRange ? 16 << shift8 : 0;
    const maxV = g.clipToRestrictedRange ? (plane && !isId ? 240 : 235) << shift8 : bdMax;
    const clip2 = (v, lo2, hi2) => v < lo2 ? lo2 : v > hi2 ? hi2 : v;
    const seeds = [];
    for (let i = 0;i < rows; i++) {
      let s = g.seed;
      s ^= ((rowNum - i) * 37 + 178 & 255) << 8;
      s ^= (rowNum - i) * 173 + 105 & 255;
      seeds.push(new Random(s));
    }
    const offsets2 = [[0, 0], [0, 0]];
    const sample = (bx, by, x, y) => {
      const randval = offsets2[bx][by];
      const offx = 3 + (2 >> sx) * (3 + (randval >> 4)), offy = 3 + (2 >> sy) * (3 + (randval & 15));
      return lut[(offy + y + (BLOCK >> sy) * by) * GRAIN_WIDTH + offx + x + (BLOCK >> sx) * bx];
    };
    const y0 = rowNum * BLOCK >> sy;
    const uv = plane - 1;
    const add = (bx, x, y, grain) => {
      const o = (y0 + y) * stride + bx + x;
      let val;
      if (!plane)
        val = src[o];
      else {
        const lx = bx + x << sx, ly = y0 + y << sy;
        let avg = luma[ly * lumaStride + lx];
        if (sx)
          avg = avg + luma[ly * lumaStride + lx + 1] + 1 >> 1;
        val = avg;
        if (!g.chromaScalingFromLuma) {
          const combined = avg * g.uvLumaMult[uv] + src[o] * g.uvMult[uv];
          val = clip2((combined >> 6) + g.uvOffset[uv] * (1 << shift8), 0, bdMax);
        }
      }
      const noise = round2(scaling[val] * grain, g.scalingShift);
      dst[o] = clip2(src[o] + noise, minV, maxV);
    };
    const blockW = BLOCK >> sx;
    for (let bx = 0;bx < pw; bx += blockW) {
      const bw = Math.min(blockW, pw - bx);
      if (g.overlap && bx)
        for (let i = 0;i < rows; i++)
          offsets2[1][i] = offsets2[0][i];
      for (let i = 0;i < rows; i++)
        offsets2[0][i] = seeds[i].next(8);
      const ystart = g.overlap && rowNum ? Math.min(2 >> sy, bh) : 0;
      const xstart = g.overlap && bx ? Math.min(2 >> sx, bw) : 0;
      const wx = W2[sx], wy = W2[sy];
      for (let y = ystart;y < bh; y++) {
        for (let x = xstart;x < bw; x++)
          add(bx, x, y, sample(0, 0, x, y));
        for (let x = 0;x < xstart; x++) {
          const grain = clip2(round2(sample(1, 0, x, y) * wx[x][0] + sample(0, 0, x, y) * wx[x][1], 5), gmin, gmax);
          add(bx, x, y, grain);
        }
      }
      for (let y = 0;y < ystart; y++) {
        for (let x = xstart;x < bw; x++) {
          const grain = clip2(round2(sample(0, 1, x, y) * wy[y][0] + sample(0, 0, x, y) * wy[y][1], 5), gmin, gmax);
          add(bx, x, y, grain);
        }
        for (let x = 0;x < xstart; x++) {
          const top = clip2(round2(sample(1, 1, x, y) * wx[x][0] + sample(0, 1, x, y) * wx[x][1], 5), gmin, gmax);
          let grain = clip2(round2(sample(1, 0, x, y) * wx[x][0] + sample(0, 0, x, y) * wx[x][1], 5), gmin, gmax);
          grain = clip2(round2(top * wy[y][0] + grain * wy[y][1], 5), gmin, gmax);
          add(bx, x, y, grain);
        }
      }
    }
  }
  function applyFilmGrain(f, g) {
    const bitdepth = f.bitdepth, w = f.hdr.upscaledWidth, h = f.height;
    const { ssx: sx, ssy: sy } = f;
    const lumaLut = generateGrainY(g, bitdepth);
    const out = f.planes.map((p) => p.slice());
    const scalingY = g.yPoints.length || g.chromaScalingFromLuma ? generateScaling(bitdepth, g.yPoints) : new Uint8Array(1 << bitdepth);
    const isId = f.seq.matrixCoefficients === 0;
    const rows = Math.ceil(h / BLOCK);
    if (g.yPoints.length) {
      for (let row = 0;row < rows; row++) {
        applyStripe(g, out[0], f.planes[0], f.strides[0], w, Math.min(h - row * BLOCK, BLOCK), row, scalingY, lumaLut, bitdepth, 0, 0, 0, isId, f.planes[0], f.strides[0]);
      }
    }
    if (f.planes.length === 1 || !g.uvPoints[0].length && !g.uvPoints[1].length && !g.chromaScalingFromLuma)
      return out;
    const luma = f.planes[0], ls = f.strides[0];
    if (w & sx)
      for (let y = 0;y < h; y++)
        luma[y * ls + w] = luma[y * ls + w - 1];
    const cpw = w + sx >> sx;
    for (let pl = 0;pl < 2; pl++) {
      if (!g.chromaScalingFromLuma && !g.uvPoints[pl].length)
        continue;
      const lut = generateGrainUv(g, lumaLut, pl, sx, sy, bitdepth);
      const scaling = g.chromaScalingFromLuma ? scalingY : generateScaling(bitdepth, g.uvPoints[pl]);
      for (let row = 0;row < rows; row++) {
        const bh = Math.min(h - row * BLOCK, BLOCK) + sy >> sy;
        applyStripe(g, out[1 + pl], f.planes[1 + pl], f.strides[1], cpw, bh, row, scaling, lut, bitdepth, 1 + pl, sx, sy, isId, luma, ls);
      }
    }
    return out;
  }

  // src/codecs/av1/frame.ts
  /*!
   * Decodes the first shown frame of an AV1 bitstream (intra frames only), following dav1d's handling of the OBUs
   * (src/obu.c). Copyright (c) 2018-2021, VideoLAN and dav1d authors, BSD-2-Clause License (see THIRD_PARTY_NOTICES.md)
   */
  function decodeAV1(data, start = 0, end = data.length, { maxPixels = MAX_PIXELS, filmGrain = true, operatingPoint = 0, layer = -1 } = {}) {
    let seq = null;
    let hdr = null;
    let frame = null;
    let decoder = null;
    let tilesDone = 0;
    let opIdc = 0, target = 0;
    let best = null;
    const refs = new Array(8).fill(null);
    for (const obu of obus(data, start, end)) {
      if (obu.type !== OBU_SEQUENCE_HEADER && obu.type !== OBU_TEMPORAL_DELIMITER && opIdc && (!(opIdc >> obu.temporalId & 1) || !(opIdc >> obu.spatialId + 8 & 1)))
        continue;
      if (obu.type === OBU_REDUNDANT_FRAME_HEADER && hdr)
        continue;
      const r = new BitReader(data, obu.start, obu.end);
      switch (obu.type === OBU_REDUNDANT_FRAME_HEADER ? OBU_FRAME_HEADER : obu.type) {
        case OBU_SEQUENCE_HEADER:
          seq = parseSequenceHeader(r);
          opIdc = seq.operatingPoints[Math.min(operatingPoint, seq.operatingPoints.length - 1)].idc;
          target = opIdc >> 8 ? 31 - Math.clz32(opIdc >> 8) : 0;
          if (layer >= 0 && layer < target)
            target = layer;
          break;
        case OBU_FRAME_HEADER:
        case OBU_FRAME: {
          if (!seq)
            throw new Error("AV1: frame before the sequence header");
          try {
            hdr = parseFrameHeader(r, seq, obu.temporalId, obu.spatialId);
          } catch (err) {
            const lower2 = best;
            if (!(err instanceof InterFrameError) || !lower2)
              throw err;
            lower2.incomplete = true;
            return lower2;
          }
          if (hdr.showExistingFrame) {
            const shown2 = refs[hdr.existingFrameIdx];
            if (!shown2)
              throw new Error("AV1: shows a frame that doesn't exist");
            return output(shown2);
          }
          checkPixels(hdr.upscaledWidth, hdr.height, maxPixels);
          frame = new Frame(seq, hdr);
          decoder = new TileDecoder(frame);
          tilesDone = 0;
          if (obu.type !== OBU_FRAME)
            break;
          r.align();
          const shown = tileGroup(r, obu.end, obu.spatialId);
          if (shown)
            return shown;
          break;
        }
        case OBU_TILE_GROUP: {
          if (!hdr || !frame)
            throw new Error("AV1: tile group without a frame header");
          const shown = tileGroup(r, obu.end, obu.spatialId);
          if (shown)
            return shown;
          break;
        }
      }
    }
    const lower = best;
    if (lower)
      return lower;
    throw new Error("AV1: no frame");
    function tileGroup(r, end2, spatialId) {
      const h = hdr, f = frame;
      const count = h.tiles.cols * h.tiles.rows;
      let first = 0, last = count - 1;
      if (count > 1 && r.bit()) {
        const bits2 = h.tiles.log2Cols + h.tiles.log2Rows;
        first = r.bits(bits2);
        last = r.bits(bits2);
      }
      r.align();
      if (first !== tilesDone || last < first || last >= count)
        throw new Error("AV1: invalid tile group");
      decodeTileGroup(decoder, data, r.byte, end2, first, last);
      tilesDone = last + 1;
      if (tilesDone < count)
        return null;
      postFilter(f);
      for (let i = 0;i < 8; i++)
        if (h.refreshFrameFlags >> i & 1)
          refs[i] = f;
      if (!h.showFrame)
        return null;
      if (opIdc && spatialId < target) {
        best = output(f);
        return null;
      }
      return output(f);
    }
    function output(f) {
      if (filmGrain && f.hdr.filmGrain)
        f.planes = applyFilmGrain(f, f.hdr.filmGrain);
      return f;
    }
  }

  // src/codecs/hdr.ts
  function linearToSRGB(v) {
    if (!(v > 0))
      return 0;
    if (v >= 1)
      return 255;
    return Math.round(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055));
  }
  function toSRGB(rgb, toneMapping) {
    const count = rgb.length / 3;
    const luminance = (i) => 0.2126 * rgb[i] + 0.7152 * rgb[i + 1] + 0.0722 * rgb[i + 2];
    let white = 1;
    if (toneMapping === "reinhard")
      for (let i = 0;i < rgb.length; i += 3)
        white = Math.max(white, luminance(i));
    const white2 = white * white;
    const pixels = new Uint8Array(count * 4);
    for (let i = 0, p = 0;i < rgb.length; i += 3, p += 4) {
      let scale = 1;
      if (white > 1) {
        const l = Math.max(0, luminance(i));
        scale = (1 + l / white2) / (1 + l);
      }
      pixels[p] = linearToSRGB(rgb[i] * scale);
      pixels[p + 1] = linearToSRGB(rgb[i + 1] * scale);
      pixels[p + 2] = linearToSRGB(rgb[i + 2] * scale);
      pixels[p + 3] = 255;
    }
    return pixels;
  }
  var PRIMARIES_BT2020 = 9;
  var PRIMARIES_P3 = 12;
  var REFERENCE_WHITE = 203;
  function hdrToLinear(rgb, transfer, primaries) {
    const m1 = 2610 / 16384, m2 = 2523 / 4096 * 128, c1 = 3424 / 4096, c2 = 2413 / 4096 * 32, c3 = 2392 / 4096 * 32;
    const pq = (v) => {
      const e = (v <= 0 ? 0 : v >= 1 ? 1 : v) ** (1 / m2);
      return 1e4 / REFERENCE_WHITE * (Math.max(e - c1, 0) / (c2 - c3 * e)) ** (1 / m1);
    };
    const a = 0.17883277, b = 1 - 4 * a, c = 0.5 - a * Math.log(4 * a);
    const hlg = (v) => {
      const e = v <= 0 ? 0 : v >= 1 ? 1 : v;
      return e <= 0.5 ? e * e / 3 : (Math.exp((e - c) / a) + b) / 12;
    };
    const matrix = primaries === PRIMARIES_BT2020 ? [1.660491, -0.587641, -0.07285, -0.12455, 1.1329, -0.008349, -0.018151, -0.100579, 1.11873] : primaries === PRIMARIES_P3 ? [1.22494, -0.22494, 0, -0.042057, 1.042057, 0, -0.019638, -0.078636, 1.098274] : null;
    for (let i = 0;i < rgb.length; i += 3) {
      let r, g, bl;
      if (transfer === 16) {
        r = pq(rgb[i]);
        g = pq(rgb[i + 1]);
        bl = pq(rgb[i + 2]);
      } else {
        r = hlg(rgb[i]);
        g = hlg(rgb[i + 1]);
        bl = hlg(rgb[i + 2]);
        const ys = 0.2627 * r + 0.678 * g + 0.0593 * bl;
        const gain = ys > 0 ? 1000 / REFERENCE_WHITE * ys ** 0.2 : 0;
        r *= gain;
        g *= gain;
        bl *= gain;
      }
      if (matrix) {
        rgb[i] = matrix[0] * r + matrix[1] * g + matrix[2] * bl;
        rgb[i + 1] = matrix[3] * r + matrix[4] * g + matrix[5] * bl;
        rgb[i + 2] = matrix[6] * r + matrix[7] * g + matrix[8] * bl;
      } else {
        rgb[i] = r;
        rgb[i + 1] = g;
        rgb[i + 2] = bl;
      }
    }
    return rgb;
  }
  var XYZ_TO_RGB = (() => {
    const inverse = ([a, b2, c, d, e, f, g2, h, i]) => {
      const det = a * (e * i - f * h) - b2 * (d * i - f * g2) + c * (d * h - e * g2);
      return [e * i - f * h, c * h - b2 * i, b2 * f - c * e, f * g2 - d * i, a * i - c * g2, c * d - a * f, d * h - e * g2, b2 * g2 - a * h, a * e - b2 * d].map((v) => v / det);
    };
    const [r, g, b] = [[0.64, 0.33], [0.29, 0.6], [0.15, 0.06]].map(([x, y]) => [x / y, 1, (1 - x - y) / y]);
    const primaries = [r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]];
    const inv = inverse(primaries);
    const scale = [0, 1, 2].map((row) => inv[row * 3] + inv[row * 3 + 1] + inv[row * 3 + 2]);
    return inverse(primaries.map((v, i) => v * scale[i % 3]));
  })();

  // src/util/threads.ts
  var globals = globalThis;
  function builtin(id) {
    try {
      return globals.process?.getBuiltinModule?.(id) ?? null;
    } catch {
      return null;
    }
  }
  function thread(post, listen, terminate) {
    let current = null;
    listen((m) => {
      if (!current)
        return;
      if ("message" in m)
        current.onMessage?.(m.message);
      else {
        const c = current;
        current = null;
        if (m.error !== undefined)
          c.reject(new Error(m.error));
        else
          c.resolve(m.result);
      }
    }, (e) => {
      const c = current;
      current = null;
      c?.reject(e);
    });
    return {
      run: (task, onMessage) => new Promise((resolve, reject) => {
        current = { resolve, reject, onMessage };
        post(task);
      }),
      terminate
    };
  }
  function availableThreads() {
    if (typeof SharedArrayBuffer === "undefined" || typeof Atomics === "undefined" || globals.crossOriginIsolated === false)
      return 0;
    if (!globals.Worker && !builtin("node:worker_threads"))
      return 0;
    const os = builtin("node:os");
    const n = os ? os.availableParallelism ? os.availableParallelism() : os.cpus().length : globals.navigator?.hardwareConcurrency ?? 1;
    return Math.max(1, n | 0);
  }
  function startThreads(n) {
    if (n < 1 || !availableThreads())
      return null;
    const threads = [];
    try {
      for (let i = 0;i < n; i++) {
        if (globals.Worker) {
          const w = new Worker(new URL("./worker.ts", ""), { type: "module" });
          threads.push(thread((m) => w.postMessage(m), (message, error) => {
            w.onmessage = (e) => message(e.data);
            w.onerror = (e) => {
              e.preventDefault?.();
              error(new Error(e.message ?? "worker failed"));
            };
          }, () => w.terminate()));
        } else {
          const { Worker: Worker2 } = builtin("node:worker_threads");
          const url = "";
          const w = new Worker2(new URL(url.endsWith(".ts") ? "./worker.ts" : "./worker.js", url));
          w.unref();
          threads.push(thread((m) => w.postMessage(m), (message, error) => {
            w.on("message", (m) => message(m));
            w.on("error", (e) => error(e));
          }, () => void w.terminate()));
        }
      }
      return threads;
    } catch {
      for (const t of threads)
        t.terminate();
      return null;
    }
  }
  async function runChunks(threads, task, count, local) {
    const results = new Array(count);
    if (!threads || count < 2) {
      for (let i = 0;i < count; i++)
        results[i] = local(i);
      return results;
    }
    const counter = new Int32Array(new SharedArrayBuffer(4));
    await Promise.all(threads.slice(0, count).map((t) => t.run({ ...task, counter, chunks: count }, (m) => {
      const { chunk, result } = m;
      results[chunk] = result;
    })));
    return results;
  }
  var sharedOf = (array) => array.buffer instanceof SharedArrayBuffer ? array : shared(array);
  function shared(array) {
    const Type = array.constructor;
    const copy = new Type(new SharedArrayBuffer(array.byteLength));
    copy.set(array);
    return copy;
  }

  // src/codecs/gainmap.ts
  function valid(p) {
    const ok = (v) => Number.isFinite(v);
    for (let c = 0;c < 3; c++)
      if (!ok(p.min[c]) || !ok(p.max[c]) || !ok(p.gamma[c]) || !ok(p.offsetSDR[c]) || !ok(p.offsetHDR[c]) || p.gamma[c] <= 0 || p.max[c] < p.min[c])
        return false;
    return ok(p.capacityMin) && ok(p.capacityMax) && p.capacityMax > p.capacityMin && p.capacityMin >= 0;
  }
  function readISO(data) {
    if (data.length < 5)
      return null;
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    if (view.getUint16(0) !== 0)
      return null;
    const flags = data[4];
    if (flags & 4)
      return null;
    const channels = flags & 128 ? 3 : 1, common = (flags & 8) !== 0;
    let p = 5;
    const need = (n) => p + n <= data.length;
    let denominator = 1;
    if (common) {
      if (!need(4))
        return null;
      denominator = view.getUint32(p);
      p += 4;
      if (!denominator)
        return null;
    }
    const fraction = (signed) => {
      if (!need(common ? 4 : 8))
        return NaN;
      const n = signed ? view.getInt32(p) : view.getUint32(p);
      const d = common ? denominator : view.getUint32(p + 4);
      p += common ? 4 : 8;
      return d ? n / d : NaN;
    };
    const capacityMin = fraction(false), capacityMax = fraction(false);
    const min = [], max2 = [], gamma = [], offsetSDR = [], offsetHDR = [];
    for (let c = 0;c < channels; c++) {
      min.push(fraction(true));
      max2.push(fraction(true));
      gamma.push(fraction(false));
      offsetSDR.push(fraction(true));
      offsetHDR.push(fraction(true));
    }
    const params = { min: fill3(min), max: fill3(max2), gamma: fill3(gamma), offsetSDR: fill3(offsetSDR), offsetHDR: fill3(offsetHDR), capacityMin, capacityMax, useBaseColorSpace: (flags & 64) !== 0 };
    return valid(params) ? params : null;
  }
  var fill3 = (values) => values.length === 1 ? [values[0], values[0], values[0]] : values.slice(0, 3);
  var MPF_LENGTH = 4 + 50 + 32;

  // src/codecs/avif.ts
  /*!
   * AVIF (AV1 images in HEIF containers, https://aomediacodec.github.io/av1-avif/): the primary item (an AV1 image or a
   * grid of them), its alpha, crop, rotation and mirroring, or the first frame of an image sequence; converted to RGB like
   * libavif converts (its reference path, src/reformat.c, with bilinear chroma upsampling; src/read.c, src/alpha.c), HDR
   * (PQ, HLG) tone mapped. Copyright 2019 Joe Drago, BSD-2-Clause License (see THIRD_PARTY_NOTICES.md)
   */
  var fourcc = (d, o) => String.fromCharCode(d[o], d[o + 1], d[o + 2], d[o + 3]);
  function* boxes(d, start, end) {
    const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
    let o = start;
    while (o + 8 <= end) {
      let size = view.getUint32(o);
      const type = fourcc(d, o + 4);
      let header = 8;
      if (size === 1) {
        if (o + 16 > end)
          throw new Error("AVIF: truncated box");
        size = view.getUint32(o + 8) * 2 ** 32 + view.getUint32(o + 12);
        header = 16;
      } else if (size === 0)
        size = end - o;
      if (size < header || o + size > end)
        throw new Error(`AVIF: invalid ${type} box`);
      yield { type, start: o + header, end: o + size };
      o += size;
    }
  }
  var child = (d, box, type, offset = 0) => {
    for (const b of boxes(d, box.start + offset, box.end))
      if (b.type === type)
        return b;
    return;
  };
  function isAVIF(d) {
    if (d.length < 16 || fourcc(d, 4) !== "ftyp")
      return false;
    const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
    let size = view.getUint32(0), start = 8;
    if (size === 1) {
      size = view.getUint32(8) * 2 ** 32 + view.getUint32(12);
      start = 16;
    }
    if (size < start + 8 || size > d.length || size % 4 !== 0)
      return false;
    for (let o = start;o + 4 <= size; o += o === start ? 8 : 4) {
      const brand = fourcc(d, o);
      if (brand === "avif" || brand === "avis")
        return true;
    }
    return false;
  }
  function parseMeta(d, meta) {
    const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
    const items = new Map;
    const item = (id) => {
      let it = items.get(id);
      if (!it)
        items.set(id, it = { id, type: "", extents: [], method: 0, props: [], refs: new Map });
      return it;
    };
    let primary = -1;
    const uint = (o, size) => size === 8 ? view.getUint32(o) * 2 ** 32 + view.getUint32(o + 4) : size === 4 ? view.getUint32(o) : size === 2 ? view.getUint16(o) : size === 1 ? d[o] : 0;
    const idat = child(d, meta, "idat", 4);
    for (const box of boxes(d, meta.start + 4, meta.end)) {
      const version = d[box.start];
      let o = box.start + 4;
      if (box.type === "pitm")
        primary = version ? view.getUint32(o) : view.getUint16(o);
      else if (box.type === "iinf") {
        o += version ? 4 : 2;
        for (const infe of boxes(d, o, box.end)) {
          if (infe.type !== "infe")
            continue;
          const v = d[infe.start];
          if (v < 2)
            continue;
          let p = infe.start + 4;
          const id = v === 2 ? view.getUint16(p) : view.getUint32(p);
          p += v === 2 ? 2 : 4;
          p += 2;
          item(id).type = fourcc(d, p);
        }
      } else if (box.type === "iloc") {
        const offsetSize = d[o] >> 4, lengthSize = d[o] & 15, baseSize = d[o + 1] >> 4, indexSize = version ? d[o + 1] & 15 : 0;
        o += 2;
        const count = version < 2 ? view.getUint16(o) : view.getUint32(o);
        o += version < 2 ? 2 : 4;
        for (let i = 0;i < count; i++) {
          const id = version < 2 ? view.getUint16(o) : view.getUint32(o);
          o += version < 2 ? 2 : 4;
          const it = item(id);
          if (version) {
            it.method = view.getUint16(o) & 15;
            o += 2;
          }
          o += 2;
          const base = uint(o, baseSize);
          o += baseSize;
          const extents = view.getUint16(o);
          o += 2;
          for (let e = 0;e < extents; e++) {
            o += indexSize;
            const offset = uint(o, offsetSize);
            o += offsetSize;
            const length = uint(o, lengthSize);
            o += lengthSize;
            it.extents.push({ offset: base + offset, length });
          }
        }
      } else if (box.type === "iref") {
        for (const ref of boxes(d, o, box.end)) {
          let p = ref.start;
          const from = version ? view.getUint32(p) : view.getUint16(p);
          p += version ? 4 : 2;
          const count = view.getUint16(p);
          p += 2;
          const to = [];
          for (let i = 0;i < count; i++, p += version ? 4 : 2)
            to.push(version ? view.getUint32(p) : view.getUint16(p));
          item(from).refs.set(ref.type, (item(from).refs.get(ref.type) ?? []).concat(to));
        }
      } else if (box.type === "iprp") {
        const ipco = child(d, box, "ipco");
        const properties = ipco ? [...boxes(d, ipco.start, ipco.end)] : [];
        for (const ipma of boxes(d, box.start, box.end)) {
          if (ipma.type !== "ipma")
            continue;
          const v = d[ipma.start], flags = d[ipma.start + 3];
          let p = ipma.start + 4;
          const count = view.getUint32(p);
          p += 4;
          for (let i = 0;i < count; i++) {
            const id = v < 1 ? view.getUint16(p) : view.getUint32(p);
            p += v < 1 ? 2 : 4;
            const n = d[p++];
            for (let k = 0;k < n; k++) {
              let index, essential;
              if (flags & 1) {
                essential = !!(d[p] & 128);
                index = view.getUint16(p) & 32767;
                p += 2;
              } else {
                essential = !!(d[p] & 128);
                index = d[p++] & 127;
              }
              if (index && properties[index - 1])
                item(id).props.push({ box: properties[index - 1], essential });
            }
          }
        }
      }
    }
    return { items, primary, idat };
  }
  function itemData(d, it, idat) {
    const parts = it.extents.map(({ offset, length }) => {
      const base = it.method === 1 ? idat ? idat.start : 0 : 0, end = it.method === 1 ? idat?.end ?? 0 : d.length;
      if (it.method > 1)
        throw new Error("AVIF: unsupported item construction method");
      const start = base + offset, stop = length ? start + length : end;
      if (start > end || stop > end)
        throw new Error("AVIF: item data outside the file");
      return d.subarray(start, stop);
    });
    if (parts.length === 1)
      return parts[0];
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let o = 0;
    for (const p of parts) {
      out.set(p, o);
      o += p.length;
    }
    return out;
  }
  var property = (it, type) => it.props.find((p) => p.box.type === type)?.box;
  function fromFrame(f) {
    return {
      width: f.hdr.upscaledWidth,
      height: f.height,
      bitdepth: f.bitdepth,
      layout: f.layout,
      planes: f.planes,
      strides: f.strides,
      fullRange: f.seq.fullRange,
      matrix: f.seq.matrixCoefficients,
      transfer: f.seq.transferCharacteristics,
      primaries: f.seq.colorPrimaries
    };
  }
  function av1Input(d, it, idat) {
    let data = itemData(d, it, idat);
    const av1C = property(it, "av1C");
    if (av1C && av1C.end - av1C.start > 4 && (data[0] >> 3 & 15) !== 1) {
      const config = d.subarray(av1C.start + 4, av1C.end);
      const joined = new Uint8Array(config.length + data.length);
      joined.set(config);
      joined.set(data, config.length);
      data = joined;
    }
    const a1op = property(it, "a1op"), lsel = property(it, "lsel"), ispe = property(it, "ispe");
    const layer = lsel ? d[lsel.start] << 8 | d[lsel.start + 1] : 65535;
    const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
    return {
      data,
      operatingPoint: a1op ? d[a1op.start] : 0,
      layer: layer === 65535 ? -1 : layer,
      size: ispe ? [view.getUint32(ispe.start + 4), view.getUint32(ispe.start + 8)] : null
    };
  }
  function decodeAV1Input({ data, operatingPoint, layer, size }, maxPixels) {
    const frame = decodeAV1(data, 0, data.length, { maxPixels, operatingPoint, layer });
    if (frame.incomplete && (!size || size[0] !== frame.hdr.upscaledWidth || size[1] !== frame.height))
      throw new Error("AVIF: layered images with inter predicted layers are not supported");
    return fromFrame(frame);
  }
  var decodeAV1Item = (d, it, idat, maxPixels) => decodeAV1Input(av1Input(d, it, idat), maxPixels);
  function tileChunks({ inputs, maxPixels }) {
    return (i) => decodeAV1Input(inputs[i], maxPixels);
  }
  async function decodeGrid(d, it, items, idat, maxPixels, threads, tiles = it.refs.get("dimg") ?? []) {
    const g = itemData(d, it, idat);
    const view = new DataView(g.buffer, g.byteOffset, g.byteLength);
    const wide = g[1] & 1;
    const rows = g[2] + 1, cols = g[3] + 1;
    const width = wide ? view.getUint32(4) : view.getUint16(4), height = wide ? view.getUint32(8) : view.getUint16(6);
    checkPixels(width, height, maxPixels);
    if (tiles.length !== rows * cols)
      throw new Error("AVIF: the grid has the wrong number of tiles");
    if (new Set(tiles).size !== tiles.length)
      throw new Error("AVIF: the grid repeats tiles");
    const inputs = tiles.map((id) => {
      const tileItem = items.get(id);
      if (!tileItem || tileItem.type !== "av01")
        throw new Error("AVIF: invalid grid tile");
      return av1Input(d, tileItem, idat);
    });
    const place = (grid, k, tile) => {
      const r = Math.floor(k / cols), c = k % cols;
      let out2 = grid;
      if (!out2) {
        if (tile.width * cols < width || tile.height * rows < height)
          throw new Error("AVIF: the grid's tiles are too small");
        out2 = { ...tile, width, height, planes: [], strides: [] };
        for (let p = 0;p < tile.planes.length; p++) {
          const sx = p && tile.layout < 3 ? 1 : 0, sy = p && tile.layout === 1 ? 1 : 0;
          const stride = width + sx >> sx;
          out2.strides.push(stride);
          out2.planes.push(new Uint16Array(stride * (height + sy >> sy)));
        }
      } else if (tile.layout !== out2.layout || tile.bitdepth !== out2.bitdepth)
        throw new Error("AVIF: the grid's tiles differ");
      for (let p = 0;p < out2.planes.length; p++) {
        const sx = p && out2.layout < 3 ? 1 : 0, sy = p && out2.layout === 1 ? 1 : 0;
        const tw = tile.width + sx >> sx, th = tile.height + sy >> sy;
        const x0 = c * tw, y0 = r * th;
        const pw = width + sx >> sx, ph = height + sy >> sy;
        for (let y = 0;y < th && y0 + y < ph; y++) {
          const n2 = Math.min(tw, pw - x0);
          if (n2 <= 0)
            break;
          out2.planes[p].set(tile.planes[p].subarray(y * tile.strides[p], y * tile.strides[p] + n2), (y0 + y) * out2.strides[p] + x0);
        }
      }
      return out2;
    };
    let decoded = null;
    const n = threads ? Math.min(threads.length, Math.ceil(inputs.length / TILES_PER_THREAD)) : 0;
    if (threads && n > 1) {
      const data = new Uint8Array(new SharedArrayBuffer(inputs.reduce((n2, i) => n2 + i.data.length, 0)));
      let o = 0;
      for (const input of inputs) {
        data.set(input.data, o);
        input.data = data.subarray(o, o += input.data.length);
      }
      const task = { task: "avif-tiles", inputs, maxPixels };
      decoded = await runChunks(threads.slice(0, n), task, inputs.length, tileChunks(task)).catch(() => null);
    }
    let out = null;
    for (let k = 0;k < inputs.length; k++)
      out = place(out, k, decoded ? decoded[k] : decodeAV1Input(inputs[k], maxPixels));
    return out;
  }
  async function decodeItem(d, it, items, idat, maxPixels, threads) {
    if (it.type === "av01")
      return decodeAV1Item(d, it, idat, maxPixels);
    if (it.type === "grid")
      return decodeGrid(d, it, items, idat, maxPixels, threads);
    throw new Error(`AVIF: unsupported item type ${it.type}`);
  }
  function coefficients(matrix) {
    switch (matrix) {
      case 1:
        return [0.2126, 0.0722];
      case 4:
        return [0.3, 0.11];
      case 7:
        return [0.212, 0.087];
      case 9:
      case 10:
        return [0.2627, 0.0593];
      default:
        return [0.299, 0.114];
    }
  }
  var TRANSFER_PQ = 16;
  var TRANSFER_HLG = 18;
  var f32 = Math.fround;
  var toByte = (v) => v <= 0 ? 0 : v >= 1 ? 255 : Math.trunc(f32(0.5 + f32(v * 255)));
  function convertRow444(c, j) {
    const { Y, U, V, tableY, out, n } = c, red = c.red, blue = c.blue, gTerm = c.gTerm;
    const yRow = j * c.ys, uvRow = j * c.cs;
    for (let i = 0, p = j * c.width * 4;i < c.width; i++, p += 4) {
      const y = Y[yRow + i], u = U[uvRow + i], v = V[uvRow + i];
      out[p] = red[y * n + v];
      out[p + 1] = toByte(f32(tableY[y] - gTerm[u * n + v]));
      out[p + 2] = blue[y * n + u];
      out[p + 3] = 255;
    }
  }
  function convertRowSubsampled(c, j) {
    const { width, height, layout, Y, U, V, cs, sy, tableY, out, cr2, cb2, crg, cbg, kgInverse } = c, [w9, w3, w1] = c.weighted;
    const uvRow = (j >> sy) * cs, yRow = j * c.ys;
    const adjRow = layout === 1 && !(j === 0 || j === height - 1 && j % 2) ? j % 2 ? cs : -cs : 0;
    for (let i = 0, p = j * width * 4;i < width; i++, p += 4) {
      const lum = tableY[Y[yRow + i]];
      const o = uvRow + (i >> 1), adjCol = i === 0 || i === width - 1 ? 0 : i % 2 ? 1 : -1;
      const cb = f32(f32(f32(w9[U[o]] + w3[U[o + adjCol]]) + w3[U[o + adjRow]]) + w1[U[o + adjCol + adjRow]]);
      const cr = f32(f32(f32(w9[V[o]] + w3[V[o + adjCol]]) + w3[V[o + adjRow]]) + w1[V[o + adjCol + adjRow]]);
      out[p] = toByte(f32(lum + f32(cr2 * cr)));
      out[p + 1] = toByte(f32(lum - f32(f32(2 * f32(f32(crg * cr) + f32(cbg * cb))) * kgInverse)));
      out[p + 2] = toByte(f32(lum + f32(cb2 * cb)));
      out[p + 3] = 255;
    }
  }
  function convertRow(c, j) {
    const { width, height, layout, color, identity, ycgco, Y, U, V, cs, sx, sy, tableY, tableUV, out, rgb, unmultiply, cr2, cb2, crg, cbg, kgInverse } = c;
    const uvRow = (j >> sy) * cs, yRow = j * c.ys;
    let adjRow = 0;
    if (color && layout === 1 && !(j === 0 || j === height - 1 && j % 2))
      adjRow = j % 2 ? cs : -cs;
    for (let i = 0, p = j * width * 4;i < width; i++, p += 4) {
      const lum = tableY[Y[yRow + i]];
      out[p + 3] = 255;
      if (!color) {
        if (rgb)
          rgb[p / 4 * 3] = rgb[p / 4 * 3 + 1] = rgb[p / 4 * 3 + 2] = lum;
        else
          out[p] = out[p + 1] = out[p + 2] = toByte(lum);
        continue;
      }
      const o = uvRow + (i >> sx);
      let cb, cr;
      if (layout === 3) {
        cb = tableUV[U[o]];
        cr = tableUV[V[o]];
      } else {
        const adjCol = i === 0 || i === width - 1 ? 0 : i % 2 ? 1 : -1;
        cb = f32(f32(f32(f32(tableUV[U[o]] * 0.5625) + f32(tableUV[U[o + adjCol]] * 0.1875)) + f32(tableUV[U[o + adjRow]] * 0.1875)) + f32(tableUV[U[o + adjCol + adjRow]] * 0.0625));
        cr = f32(f32(f32(f32(tableUV[V[o]] * 0.5625) + f32(tableUV[V[o + adjCol]] * 0.1875)) + f32(tableUV[V[o + adjRow]] * 0.1875)) + f32(tableUV[V[o + adjCol + adjRow]] * 0.0625));
      }
      let r, g, b;
      if (identity) {
        g = lum;
        b = cb;
        r = cr;
      } else if (ycgco) {
        const t = lum - cb;
        g = lum + cb;
        b = t - cr;
        r = t + cr;
      } else {
        r = f32(lum + f32(cr2 * cr));
        b = f32(lum + f32(cb2 * cb));
        g = f32(lum - f32(f32(2 * f32(f32(crg * cr) + f32(cbg * cb))) * kgInverse));
      }
      if (rgb) {
        const q = p / 4 * 3;
        rgb[q] = r;
        rgb[q + 1] = g;
        rgb[q + 2] = b;
        continue;
      }
      if (unmultiply) {
        const a = unmultiply[p >> 2];
        if (a === 0)
          r = g = b = 0;
        else if (a < 1) {
          r = Math.min(f32((r <= 0 ? 0 : r >= 1 ? 1 : r) / a), 1);
          g = Math.min(f32((g <= 0 ? 0 : g >= 1 ? 1 : g) / a), 1);
          b = Math.min(f32((b <= 0 ? 0 : b >= 1 ? 1 : b) / a), 1);
        }
      }
      out[p] = toByte(r);
      out[p + 1] = toByte(g);
      out[p + 2] = toByte(b);
    }
  }
  function conversionChunks(c) {
    const row = c.red ? convertRow444 : c.weighted ? convertRowSubsampled : convertRow;
    return (band) => {
      for (let j = band * 64;j < Math.min(c.height, band * 64 + 64); j++)
        row(c, j);
    };
  }
  async function toRgba(y, alpha, toneMapping, premultiplied = false, threads = null) {
    const { width, height, bitdepth, layout } = y;
    const max2 = (1 << bitdepth) - 1;
    const [kr, kb] = coefficients(y.matrix).map(f32), kg = f32(f32(1 - kr) - kb);
    const identity = y.matrix === 0, ycgco = y.matrix === 8;
    const biasY = y.fullRange ? 0 : 16 << bitdepth - 8, rangeY = y.fullRange ? max2 : 219 << bitdepth - 8;
    const biasUV = 1 << bitdepth - 1, rangeUV = y.fullRange ? max2 : 224 << bitdepth - 8;
    const tableY = new Float32Array(max2 + 1), tableUV = new Float32Array(max2 + 1);
    for (let i = 0;i <= max2; i++) {
      tableY[i] = (i - biasY) / rangeY;
      tableUV[i] = identity ? tableY[i] : (i - biasUV) / rangeUV;
    }
    const array = (Type, bytes, length) => new Type(threads ? new SharedArrayBuffer(bytes * length) : new ArrayBuffer(bytes * length));
    let out = array(Uint8Array, 1, width * height * 4);
    const hdr = y.transfer === TRANSFER_PQ || y.transfer === TRANSFER_HLG;
    const rgb = hdr ? array(Float32Array, 4, width * height * 3) : null;
    const planes = threads ? y.planes.map(sharedOf) : y.planes;
    const Y = planes[0], ys = y.strides[0];
    const color = layout !== 0 && planes.length === 3;
    const U = planes[1], V = planes[2], cs = y.strides[1];
    const sx = layout < 3 ? 1 : 0, sy = layout === 1 ? 1 : 0;
    const alphas = alpha ? array(Float32Array, 4, width * height).fill(1) : null;
    if (alpha && alphas) {
      const A = alpha.planes[0], as = alpha.strides[0], amax = (1 << alpha.bitdepth) - 1;
      const lo2 = 16 << alpha.bitdepth - 8, span = 219 << alpha.bitdepth - 8;
      for (let j = 0;j < Math.min(height, alpha.height); j++) {
        for (let i = 0;i < Math.min(width, alpha.width); i++) {
          let v = Math.min(A[j * as + i], amax);
          if (!alpha.fullRange)
            v = Math.min(amax, Math.max(0, Math.trunc(((v - lo2) * amax + (span >> 1)) / span)));
          alphas[j * width + i] = v / amax;
        }
      }
    }
    const unmultiply = premultiplied && !hdr ? alphas : null;
    const c = {
      width,
      height,
      layout,
      color,
      identity,
      ycgco,
      Y,
      U,
      V,
      ys,
      cs,
      sx,
      sy,
      tableY,
      tableUV,
      out,
      rgb,
      unmultiply,
      cr2: f32(2 * f32(1 - kr)),
      cb2: f32(2 * f32(1 - kb)),
      crg: f32(kr * f32(1 - kr)),
      cbg: f32(kb * f32(1 - kb)),
      kgInverse: 1 / kg,
      n: max2 + 1,
      red: null,
      blue: null,
      gTerm: null,
      weighted: null
    };
    const n = max2 + 1;
    if (layout === 3 && color && !identity && !ycgco && !rgb && !unmultiply && n * n * 2 <= width * height) {
      const red = c.red = array(Uint8Array, 1, n * n), blue = c.blue = array(Uint8Array, 1, n * n), gTerm = c.gTerm = array(Float32Array, 4, n * n);
      for (let v = 0;v < n; v++) {
        const rTerm = f32(c.cr2 * tableUV[v]), bTerm = f32(c.cb2 * tableUV[v]);
        for (let y2 = 0;y2 < n; y2++) {
          red[y2 * n + v] = toByte(f32(tableY[y2] + rTerm));
          blue[y2 * n + v] = toByte(f32(tableY[y2] + bTerm));
        }
      }
      for (let u = 0;u < n; u++) {
        const cbTerm = f32(c.cbg * tableUV[u]);
        for (let v = 0;v < n; v++)
          gTerm[u * n + v] = f32(f32(2 * f32(f32(c.crg * tableUV[v]) + cbTerm)) * c.kgInverse);
      }
    } else if (layout < 3 && color && !identity && !ycgco && !rgb && !unmultiply)
      c.weighted = [0.5625, 0.1875, 0.0625].map((w) => tableUV.map((v) => f32(v * w)));
    const task = { ...c, task: "avif-convert" };
    try {
      await runChunks(threads, task, Math.ceil(height / 64), conversionChunks(task));
    } catch {
      await runChunks(null, task, Math.ceil(height / 64), conversionChunks(task));
    }
    if (threads && !rgb)
      out = new Uint8Array(out);
    if (rgb)
      out = toSRGB(hdrToLinear(rgb, y.transfer, y.primaries), toneMapping);
    if (alphas)
      for (let i = 0;i < alphas.length; i++)
        out[i * 4 + 3] = Math.round(alphas[i] * 255);
    return out;
  }
  var MIN_THREADED_PIXELS = 4 << 20;
  var PIXELS_PER_THREAD = 1 << 20;
  var TILES_PER_THREAD = 4;
  async function decode(d, maxPixels = MAX_PIXELS, toneMapping = "reinhard", threads = 1, gainMap = false) {
    if (!isAVIF(d))
      throw new Error("AVIF: invalid header");
    let meta, moov;
    for (const box of boxes(d, 0, d.length)) {
      if (box.type === "meta")
        meta = box;
      else if (box.type === "moov")
        moov = box;
    }
    if (meta) {
      const { items, primary, idat } = parseMeta(d, meta);
      const it = items.get(primary);
      if (it) {
        const alphaOf = (id) => {
          for (const candidate of items.values()) {
            if (!(candidate.refs.get("auxl") ?? []).includes(id))
              continue;
            const auxC = property(candidate, "auxC");
            const type = auxC ? String.fromCharCode(...d.subarray(auxC.start + 4, auxC.end)).replace(/\0.*$/s, "") : "";
            if (type === "urn:mpeg:mpegB:cicp:systems:auxiliary:alpha" || type === "urn:mpeg:hevc:2015:auxid:1")
              return candidate;
          }
          return;
        };
        const alphaItem = alphaOf(primary);
        const ispe = property(it, "ispe"), view = new DataView(d.buffer, d.byteOffset, d.byteLength);
        const pixels = ispe && ispe.end - ispe.start >= 12 ? view.getUint32(ispe.start + 4) * view.getUint32(ispe.start + 8) : 0;
        const n = Math.min(threads, Math.floor(pixels / PIXELS_PER_THREAD));
        const pool = n > 1 && pixels >= MIN_THREADED_PIXELS && pixels <= maxPixels ? startThreads(n) : null;
        try {
          const image = await decodeImage(d, it, items, idat, alphaItem, alphaOf, maxPixels, toneMapping, pool);
          if (gainMap)
            image.gainMap = await decodeGainMap(d, primary, items, idat, maxPixels).catch(() => {
              return;
            });
          return image;
        } finally {
          if (pool)
            for (const t of pool)
              t.terminate();
        }
      }
    }
    if (moov)
      return decodeSequence(d, moov, maxPixels, toneMapping);
    throw new Error("AVIF: no image");
  }
  async function decodeImage(d, it, items, idat, alphaItem, alphaOf, maxPixels, toneMapping, threads) {
    const color = await decodeItem(d, it, items, idat, maxPixels, threads);
    applyColr(d, it, color);
    const icc = iccOf(d, it);
    if (icc && parseProfile(icc)) {
      color.primaries = 1;
      color.transfer = 13;
    }
    let alpha = alphaItem ? await decodeItem(d, alphaItem, items, idat, maxPixels, threads) : null;
    if (!alphaItem && it.type === "grid") {
      const tiles = (it.refs.get("dimg") ?? []).map(alphaOf);
      if (tiles.length && tiles.every((t) => t))
        alpha = await decodeGrid(d, it, items, idat, maxPixels, threads, tiles.map((t) => t.id));
    }
    let pixels = await toRgba(color, alpha, toneMapping, alphaItem && (it.refs.get("prem") ?? []).includes(alphaItem.id), threads);
    const transformed = transform(d, it, color.width, color.height, pixels);
    const { width, height } = transformed;
    pixels = transformed.pixels;
    return { width, height, pixels, icc, cicp: icc ? undefined : [color.primaries, color.transfer] };
  }
  function transform(d, it, width, height, pixels) {
    for (const { box } of it.props) {
      if (box.type === "clap")
        ({ width, height, pixels } = clap(d, box, width, height, pixels));
      else if (box.type === "irot")
        ({ width, height, pixels } = rotate(pixels, width, height, d[box.start] & 3));
      else if (box.type === "imir")
        pixels = mirror(pixels, width, height, d[box.start] & 1);
    }
    return { width, height, pixels };
  }
  async function decodeGainMap(d, primary, items, idat, maxPixels) {
    for (const tmap of items.values()) {
      const inputs = tmap.refs.get("dimg") ?? [];
      if (tmap.type !== "tmap" || inputs.length !== 2 || inputs[0] !== primary)
        continue;
      const data = itemData(d, tmap, idat);
      if (data[0] !== 0)
        return;
      const params = readISO(data.subarray(1));
      const mapItem = items.get(inputs[1]);
      if (!params || !mapItem)
        return;
      const colors = { primaries: 0, transfer: 0, matrix: 0 };
      if (tmap.props.some(({ box }) => box.type === "colr" && box.end - box.start >= 11 && fourcc(d, box.start) === "nclx")) {
        applyColr(d, tmap, colors);
        params.alternate = [colors.primaries, colors.transfer, colors.matrix];
      }
      const yuv = await decodeItem(d, mapItem, items, idat, maxPixels, null);
      applyColr(d, mapItem, yuv);
      yuv.transfer = 13;
      const { width, height, pixels } = transform(d, mapItem, yuv.width, yuv.height, await toRgba(yuv, null, "clamp"));
      return { width, height, pixels, params };
    }
    return;
  }
  function iccOf(d, it) {
    for (const { box } of it.props) {
      const type = box.type === "colr" && box.end - box.start > 4 ? fourcc(d, box.start) : "";
      if (type === "prof" || type === "rICC")
        return d.subarray(box.start + 4, box.end);
    }
    return;
  }
  function applyColr(d, it, yuv) {
    for (const { box } of it.props) {
      if (box.type !== "colr" || fourcc(d, box.start) !== "nclx")
        continue;
      const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
      yuv.primaries = view.getUint16(box.start + 4);
      yuv.transfer = view.getUint16(box.start + 6);
      yuv.matrix = view.getUint16(box.start + 8);
      yuv.fullRange = !!(d[box.start + 10] & 128);
    }
  }
  function clap(d, box, width, height, pixels) {
    const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
    const v = [0, 1, 2, 3, 4, 5, 6, 7].map((i) => view.getInt32(box.start + i * 4));
    const [wN, wD, hN, hD, xN, xD, yN, yD] = v;
    if (wD <= 0 || hD <= 0 || xD <= 0 || yD <= 0)
      throw new Error("AVIF: invalid clap");
    const cw = wN / wD, ch = hN / hD;
    const left = xN / xD + (width - 1) / 2 - (cw - 1) / 2, top = yN / yD + (height - 1) / 2 - (ch - 1) / 2;
    if (!Number.isInteger(cw) || !Number.isInteger(ch) || !Number.isInteger(left) || !Number.isInteger(top) || left < 0 || top < 0 || cw < 1 || ch < 1 || left + cw > width || top + ch > height)
      throw new Error("AVIF: invalid clap");
    const out = new Uint8Array(cw * ch * 4);
    for (let y = 0;y < ch; y++)
      out.set(pixels.subarray(((top + y) * width + left) * 4, ((top + y) * width + left + cw) * 4), y * cw * 4);
    return { width: cw, height: ch, pixels: out };
  }
  function rotate(pixels, width, height, steps) {
    if (!steps)
      return { width, height, pixels };
    const src = new Uint32Array(pixels.buffer, pixels.byteOffset, width * height);
    const w = steps === 2 ? width : height, h = steps === 2 ? height : width;
    const out = new Uint8Array(w * h * 4), dst = new Uint32Array(out.buffer);
    for (let y = 0;y < h; y++) {
      for (let x = 0;x < w; x++) {
        let sx, sy;
        if (steps === 1) {
          sx = width - 1 - y;
          sy = x;
        } else if (steps === 2) {
          sx = width - 1 - x;
          sy = height - 1 - y;
        } else {
          sx = y;
          sy = height - 1 - x;
        }
        dst[y * w + x] = src[sy * width + sx];
      }
    }
    return { width: w, height: h, pixels: out };
  }
  function mirror(pixels, width, height, axis) {
    const src = new Uint32Array(pixels.buffer, pixels.byteOffset, width * height);
    const out = new Uint8Array(width * height * 4), dst = new Uint32Array(out.buffer);
    for (let y = 0;y < height; y++) {
      for (let x = 0;x < width; x++)
        dst[y * width + x] = axis ? src[y * width + width - 1 - x] : src[(height - 1 - y) * width + x];
    }
    return out;
  }
  async function decodeSequence(d, moov, maxPixels, toneMapping) {
    const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
    const tracks = [];
    for (const trak of boxes(d, moov.start, moov.end)) {
      if (trak.type !== "trak")
        continue;
      const tkhd = child(d, trak, "tkhd");
      const id = tkhd ? view.getUint32(tkhd.start + (d[tkhd.start] ? 20 : 12)) : 0;
      const tref = child(d, trak, "tref");
      const auxlBox = tref && child(d, tref, "auxl");
      const auxl = [];
      if (auxlBox)
        for (let o = auxlBox.start;o + 4 <= auxlBox.end; o += 4)
          auxl.push(view.getUint32(o));
      const mdia = child(d, trak, "mdia");
      const hdlr = mdia && child(d, mdia, "hdlr");
      const minf = mdia && child(d, mdia, "minf");
      const stbl = minf && child(d, minf, "stbl");
      if (!hdlr || !stbl)
        continue;
      const handler = fourcc(d, hdlr.start + 8);
      const stsd = child(d, stbl, "stsd"), stsz = child(d, stbl, "stsz");
      const stco = child(d, stbl, "stco") ?? child(d, stbl, "co64");
      if (!stsd || !stsz || !stco)
        continue;
      const entry = [...boxes(d, stsd.start + 8, stsd.end)][0];
      if (!entry || entry.type !== "av01")
        continue;
      const av1C = child(d, entry, "av1C", 78);
      const size = view.getUint32(stsz.start + 4) || view.getUint32(stsz.start + 12);
      const offset = stco.type === "stco" ? view.getUint32(stco.start + 8) : view.getUint32(stco.start + 8) * 2 ** 32 + view.getUint32(stco.start + 12);
      if (offset + size > d.length)
        throw new Error("AVIF: sample outside the file");
      tracks.push({ id, handler, auxl, sample: d.subarray(offset, offset + size), config: av1C && av1C.end - av1C.start > 4 ? d.subarray(av1C.start + 4, av1C.end) : null });
    }
    const colorTrack = tracks.find((t) => t.handler === "pict" || t.handler === "vide") ?? tracks[0];
    if (!colorTrack)
      throw new Error("AVIF: no image");
    const alphaTrack = tracks.find((t) => t !== colorTrack && (t.auxl.includes(colorTrack.id) || t.handler === "auxv"));
    const frame = (t) => {
      let data = t.sample;
      if (t.config && (data[0] >> 3 & 15) !== 1) {
        const joined = new Uint8Array(t.config.length + data.length);
        joined.set(t.config);
        joined.set(data, t.config.length);
        data = joined;
      }
      return fromFrame(decodeAV1(data, 0, data.length, { maxPixels }));
    };
    const color = frame(colorTrack);
    return { width: color.width, height: color.height, pixels: await toRgba(color, alphaTrack ? frame(alphaTrack) : null, toneMapping), cicp: [color.primaries, color.transfer] };
  }

  // entry.js
  globalThis.atob ??= function(encoded) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let decoded = "";
    let bits2 = 0;
    let word = 0;
    for (const character of encoded) {
      if (character === "=")
        break;
      word = word << 6 | alphabet.indexOf(character);
      bits2 += 6;
      if (bits2 >= 8) {
        bits2 -= 8;
        decoded += String.fromCharCode(word >>> bits2 & 255);
      }
    }
    return decoded;
  };
  globalThis.decodeAvifPage = async function(bytes, maxPixels) {
    if (!Number.isSafeInteger(maxPixels) || maxPixels <= 0) {
      throw new RangeError("Invalid AVIF pixel limit");
    }
    const { width, height, pixels } = await decode(new Uint8Array(bytes), maxPixels);
    const buffer = pixels.byteOffset === 0 && pixels.byteLength === pixels.buffer.byteLength ? pixels.buffer : pixels.slice().buffer;
    return { width, height, pixels: buffer };
  };
})();
