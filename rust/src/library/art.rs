//! The cover art cache. Each distinct image is stored once, named by a hash of its bytes:
//! `<key>-128.jpg` and `<key>-512.jpg` for lists and grids, `<key>-full.jpg` for Now Playing.

use std::path::Path;

use image::imageops::FilterType;
use image::{DynamicImage, ImageFormat};

pub const SIZES: &[u32] = &[128, 512];

/// Writes the image to the cache unless it's already there. Returns its key.
pub fn store(dir: &Path, bytes: &[u8]) -> Option<String> {
    let key = format!("{:016x}", fnv1a(bytes));
    if dir.join(format!("{key}-full.jpg")).exists() {
        return Some(key);
    }

    let image = image::load_from_memory(bytes).ok()?;
    let original_fits = image.width() == image.height()
        && image.width() <= 1600
        && image::guess_format(bytes).ok() == Some(ImageFormat::Jpeg);
    let square = crop_square(image);
    for &size in SIZES {
        let thumb = square.resize_exact(size, size, FilterType::Lanczos3).into_rgb8();
        thumb.save_with_format(dir.join(format!("{key}-{size}.jpg")), ImageFormat::Jpeg).ok()?;
    }
    // Written last: its presence means the whole set is there. A square JPEG that is small
    // enough is kept as is, to avoid re-encoding it.
    let full_path = dir.join(format!("{key}-full.jpg"));
    if original_fits {
        std::fs::write(&full_path, bytes).ok()?;
        return Some(key);
    }
    let full = if square.width() > 1600 {
        square.resize_exact(1600, 1600, FilterType::Lanczos3)
    } else {
        square
    };
    full.into_rgb8().save_with_format(full_path, ImageFormat::Jpeg).ok()?;
    Some(key)
}

fn crop_square(image: DynamicImage) -> DynamicImage {
    let (w, h) = (image.width(), image.height());
    if w == h {
        return image;
    }
    let side = w.min(h);
    image.crop_imm((w - side) / 2, (h - side) / 2, side, side)
}

/// FNV-1a: stable across Rust versions, unlike `DefaultHasher`, so cache names never change.
fn fnv1a(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325, |hash, &b| (hash ^ b as u64).wrapping_mul(0x100_0000_01b3))
}

/// Hue buckets for `art_colors`, 10° each.
const HUES: usize = 36;

/// The two most vivid colours in a cover, as 0xAARRGGBB, strongest first: what the
/// visualizer paints with. A colourless cover gives its average colour alone.
pub fn art_colors(thumbnail: &Path) -> Vec<u32> {
    let Ok(image) = image::open(thumbnail) else { return Vec::new() };
    let image = image.into_rgb8();

    // Per hue: total vividness, and the vividness-weighted sum of the colours.
    let mut weight = [0f32; HUES];
    let mut sums = [[0f32; 3]; HUES];
    let mut average = [0f32; 3];
    for pixel in image.pixels() {
        let [r, g, b] = pixel.0.map(|c| c as f32 / 255.0);
        for (sum, c) in average.iter_mut().zip([r, g, b]) {
            *sum += c;
        }
        let max = r.max(g).max(b);
        let min = r.min(g).min(b);
        let chroma = max - min;
        if max < 0.15 || chroma < 0.08 {
            continue;
        }
        let hue = if max == r {
            ((g - b) / chroma).rem_euclid(6.0)
        } else if max == g {
            (b - r) / chroma + 2.0
        } else {
            (r - g) / chroma + 4.0
        } * 60.0;
        let saturation = chroma / max;
        let w = saturation * saturation * max;
        let bucket = (hue / 360.0 * HUES as f32) as usize % HUES;
        weight[bucket] += w;
        for (sum, c) in sums[bucket].iter_mut().zip([r, g, b]) {
            *sum += c * w;
        }
    }

    let near = |i: usize, d: isize| (i as isize + d).rem_euclid(HUES as isize) as usize;
    let score: Vec<f32> =
        (0..HUES).map(|i| weight[near(i, -1)] * 0.5 + weight[i] + weight[near(i, 1)] * 0.5).collect();
    let colour = |i: usize| {
        let (mut rgb, mut w) = ([0f32; 3], 0f32);
        for j in [near(i, -1), i, near(i, 1)] {
            w += weight[j];
            for (c, s) in rgb.iter_mut().zip(sums[j]) {
                *c += s;
            }
        }
        argb(rgb.map(|c| c / w))
    };

    let pixels = (image.width() * image.height()) as f32;
    let best = (0..HUES).max_by(|&a, &b| score[a].total_cmp(&score[b])).unwrap_or(0);
    // Under 0.5% of the cover fully vivid: treat it as colourless.
    if score[best] < pixels * 0.005 {
        return vec![argb(average.map(|c| c / pixels))];
    }
    let distance = |a: usize, b: usize| {
        let d = a.abs_diff(b);
        d.min(HUES - d)
    };
    let second = (0..HUES)
        .filter(|&i| distance(i, best) >= 4 && score[i] >= score[best] * 0.15)
        .max_by(|&a, &b| score[a].total_cmp(&score[b]));
    [Some(best), second].into_iter().flatten().map(colour).collect()
}

fn argb([r, g, b]: [f32; 3]) -> u32 {
    let c = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u32;
    0xFF00_0000 | c(r) << 16 | c(g) << 8 | c(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_vivid_colours() {
        let dir = std::env::temp_dir().join(format!("halcyn-art-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("cover.png");
        // Mostly grey, a big red block and a smaller blue one.
        let image = image::RgbImage::from_fn(128, 128, |x, y| match (x, y) {
            (0..64, 0..64) => image::Rgb([220, 30, 30]),
            (64..96, 64..96) => image::Rgb([30, 60, 220]),
            _ => image::Rgb([120, 120, 120]),
        });
        image.save(&path).unwrap();
        let colors = art_colors(&path);
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(colors, vec![0xFFDC1E1E, 0xFF1E3CDC]);
    }
}
