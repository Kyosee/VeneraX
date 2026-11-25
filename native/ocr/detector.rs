//! PP-OCR detector input. The caller owns both buffers for the duration of the call.

const MAX_SIDE: usize = 1280;

const fn normalization() -> [[f32; 256]; 3] {
    let mean = [0.485, 0.456, 0.406];
    let std = [0.229, 0.224, 0.225];
    let mut table = [[0.0; 256]; 3];
    let mut channel = 0;
    while channel < 3 {
        let mut value = 0;
        while value < 256 {
            table[channel][value] = ((value as f64 / 255.0 - mean[channel]) / std[channel]) as f32;
            value += 1;
        }
        channel += 1;
    }
    table
}

static NORMALIZED: [[f32; 256]; 3] = normalization();

#[derive(Clone, Copy, Default)]
struct Sample {
    lo: usize,
    hi: usize,
    weight: f64,
}

fn sample(position: f64, length: usize, stride: usize) -> Sample {
    let floor = position.floor();
    // Match Dart's left-edge sampling: clamp the index but keep the fractional part.
    let lo = (floor as usize).min(length - 1);
    Sample {
        lo: lo * stride,
        hi: (lo + 1).min(length - 1) * stride,
        weight: position - floor,
    }
}

fn resize(src: &[u8], w: usize, h: usize, out: &mut [f32], ow: usize, oh: usize, rotate: bool) {
    let plane = ow * oh;
    let (red, rest) = out.split_at_mut(plane);
    let (green, blue) = rest.split_at_mut(plane);
    if !rotate && w == ow && h == oh {
        for (i, px) in src.chunks_exact(4).enumerate() {
            red[i] = NORMALIZED[0][px[0] as usize];
            green[i] = NORMALIZED[1][px[1] as usize];
            blue[i] = NORMALIZED[2][px[2] as usize];
        }
        return;
    }

    let (inner_len, inner_stride) = if rotate { (h, w * 4) } else { (w, 4) };
    let mut columns = [Sample::default(); MAX_SIDE];
    for (x, col) in columns[..ow].iter_mut().enumerate() {
        *col = sample(
            (x as f64 + 0.5) * inner_len as f64 / ow as f64 - 0.5,
            inner_len,
            inner_stride,
        );
    }
    for y in 0..oh {
        let row = if rotate {
            sample(
                w as f64 - 0.5 - (y as f64 + 0.5) * w as f64 / oh as f64,
                w,
                4,
            )
        } else {
            sample((y as f64 + 0.5) * h as f64 / oh as f64 - 0.5, h, w * 4)
        };
        for (x, &col) in columns[..ow].iter().enumerate() {
            let (sx, sy) = if rotate { (row, col) } else { (col, row) };
            let value = |c: usize| {
                let a = src[sy.lo + sx.lo + c] as f64;
                let b = src[sy.lo + sx.hi + c] as f64;
                let d = src[sy.hi + sx.lo + c] as f64;
                let e = src[sy.hi + sx.hi + c] as f64;
                let top = a + (b - a) * sx.weight;
                let bottom = d + (e - d) * sx.weight;
                (top + (bottom - top) * sy.weight).round() as u8 as usize
            };
            let i = y * ow + x;
            red[i] = NORMALIZED[0][value(0)];
            green[i] = NORMALIZED[1][value(1)];
            blue[i] = NORMALIZED[2][value(2)];
        }
    }
}

/// Returns zero for null buffers, unaligned output, or invalid sizes.
///
/// # Safety
/// For accepted pointers and sizes the caller must supply live, disjoint
/// buffers of the declared lengths, with exclusively writable output.
/// No pointer is kept after returning.
#[no_mangle]
pub unsafe extern "C" fn venera_ocr_detector_rgb(
    src: *const u8,
    src_len: usize,
    w: u32,
    h: u32,
    out: *mut f32,
    out_len: usize,
    ow: u32,
    oh: u32,
    rotate: u8,
) -> u8 {
    let (w, h, ow, oh) = (w as usize, h as usize, ow as usize, oh as usize);
    if src.is_null()
        || out.is_null()
        || !out.is_aligned()
        || rotate > 1
        || w == 0
        || h == 0
        || !(1..=MAX_SIDE).contains(&ow)
        || !(1..=MAX_SIDE).contains(&oh)
        || w.checked_mul(h).and_then(|n| n.checked_mul(4)) != Some(src_len)
        || src_len > isize::MAX as usize
        || out_len != ow * oh * 3
    {
        return 0;
    }
    let src = unsafe { std::slice::from_raw_parts(src, src_len) };
    let out = unsafe { std::slice::from_raw_parts_mut(out, out_len) };
    resize(src, w, h, out, ow, oh, rotate == 1);
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_lengths_and_dimensions_leave_output_untouched() {
        let src = [0u8; 4];
        let mut out = [7.0; 3];
        for (src_len, w, h, out_len, ow, oh, rotate) in [
            (3, 1, 1, 3, 1, 1, 0),
            (4, 1, 1, 2, 1, 1, 0),
            (4, 0, 1, 3, 1, 1, 0),
            (4, u32::MAX, u32::MAX, 3, 1, 1, 0),
            (4, 1, 1, 3, 1281, 1, 0),
            (4, 1, 1, 3, 1, 0, 0),
            (4, 1, 1, 3, 1, 1, 2),
        ] {
            assert_eq!(
                unsafe {
                    venera_ocr_detector_rgb(
                        src.as_ptr(),
                        src_len,
                        w,
                        h,
                        out.as_mut_ptr(),
                        out_len,
                        ow,
                        oh,
                        rotate,
                    )
                },
                0
            );
        }
        assert_eq!(out, [7.0; 3]);
    }

    #[test]
    fn rejects_null_and_unaligned_buffers() {
        let src = [0u8; 4];
        let mut out = [7.0f32; 4];
        let output = out.as_mut_ptr();
        let unaligned = output.cast::<u8>().wrapping_add(1).cast::<f32>();
        for (source, target) in [
            (std::ptr::null(), output),
            (src.as_ptr(), std::ptr::null_mut()),
            (src.as_ptr(), unaligned),
        ] {
            assert_eq!(
                unsafe { venera_ocr_detector_rgb(source, 4, 1, 1, target, 3, 1, 1, 0) },
                0
            );
        }
        assert_eq!(out, [7.0; 4]);
    }
}
