//! Plane geometry in WoW world coordinates: x is north, y is west, z is up, and an orientation is
//! the angle from +x toward +y in radians, in `[0, 2*pi)` (the same convention as
//! `MovementInfo.orientation` and `Position::o` in CMaNGOS).

use std::f32::consts::{PI, TAU};

pub type Vec3 = [f32; 3];

/// Distance on the ground plane (x, y). Server-side range checks are mostly 3D, but without a
/// height map our own z is an estimate, so the bot decides with 2D distance plus a margin.
pub fn dist2(a: Vec3, b: Vec3) -> f32 {
    ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2)).sqrt()
}

pub fn dist3(a: Vec3, b: Vec3) -> f32 {
    ((a[0] - b[0]).powi(2) + (a[1] - b[1]).powi(2) + (a[2] - b[2]).powi(2)).sqrt()
}

/// Wrap an angle into `[0, 2*pi)`.
pub fn norm_angle(a: f32) -> f32 {
    let r = a.rem_euclid(TAU);
    if r >= TAU {
        0.0
    } else {
        r
    }
}

/// The orientation that faces `to` from `from`. Equal points face 0.
pub fn facing(from: Vec3, to: Vec3) -> f32 {
    let (dx, dy) = (to[0] - from[0], to[1] - from[1]);
    if dx.abs() < 1e-6 && dy.abs() < 1e-6 {
        return 0.0;
    }
    norm_angle(dy.atan2(dx))
}

/// Smallest signed difference `b - a`, in `(-pi, pi]`.
pub fn angle_diff(a: f32, b: f32) -> f32 {
    let mut d = (b - a).rem_euclid(TAU);
    if d > PI {
        d -= TAU;
    }
    d
}

/// Whether `target` lies within `arc` radians centred on the orientation `o` seen from `from`
/// (CMaNGOS `HasInArc`: melee and Auto Shot need the target in the front 180 degrees).
pub fn in_arc(from: Vec3, o: f32, target: Vec3, arc: f32) -> bool {
    angle_diff(o, facing(from, target)).abs() <= arc / 2.0 + 1e-4
}

/// The point `d` yards from `p` along orientation `o` (z kept).
pub fn step(p: Vec3, o: f32, d: f32) -> Vec3 {
    [p[0] + d * o.cos(), p[1] + d * o.sin(), p[2]]
}

/// Linear interpolation between two points.
pub fn lerp(a: Vec3, b: Vec3, t: f32) -> Vec3 {
    [
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
    ]
}

/// Where a walker is after covering `d` yards along the polyline `pts` (clamped to its end).
pub fn along(pts: &[Vec3], mut d: f32) -> Option<Vec3> {
    let first = *pts.first()?;
    if d <= 0.0 {
        return Some(first);
    }
    for w in pts.windows(2) {
        let seg = dist3(w[0], w[1]);
        if d <= seg && seg > 0.0 {
            return Some(lerp(w[0], w[1], d / seg));
        }
        d -= seg;
    }
    pts.last().copied()
}

pub fn path_len(pts: &[Vec3]) -> f32 {
    pts.windows(2).map(|w| dist3(w[0], w[1])).sum()
}

/// Weapon-range bands for a class that has both ranged and melee attacks (CMaNGOS: melee reach
/// is `ATTACK_DISTANCE` 5 yd; hunter shots have an 8 yd minimum and a 35 yd maximum).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RangeBands {
    pub melee: f32,
    pub min_ranged: f32,
    pub max_ranged: f32,
}

impl Default for RangeBands {
    fn default() -> Self {
        RangeBands {
            melee: 5.0,
            min_ranged: 8.0,
            max_ranged: 35.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Band {
    /// Within melee reach.
    Melee,
    /// Too far for melee, too close to shoot (hunters: 5-8 yd).
    DeadZone,
    /// Shots possible.
    Ranged,
    /// Beyond the maximum range.
    OutOfRange,
}

impl RangeBands {
    pub fn band(&self, d: f32) -> Band {
        if d <= self.melee {
            Band::Melee
        } else if d < self.min_ranged {
            Band::DeadZone
        } else if d <= self.max_ranged {
            Band::Ranged
        } else {
            Band::OutOfRange
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-4
    }

    #[test]
    fn facing_follows_the_wow_convention() {
        let o = [0.0, 0.0, 0.0];
        assert!(close(facing(o, [10.0, 0.0, 0.0]), 0.0), "north (+x) is 0");
        assert!(
            close(facing(o, [0.0, 10.0, 0.0]), PI / 2.0),
            "west (+y) is pi/2"
        );
        assert!(close(facing(o, [-10.0, 0.0, 0.0]), PI));
        assert!(
            close(facing(o, [0.0, -10.0, 0.0]), 1.5 * PI),
            "never negative"
        );
        assert!(close(facing(o, o), 0.0));
    }

    #[test]
    fn angle_diff_takes_the_short_way_round() {
        assert!(close(angle_diff(0.1, TAU - 0.1), -0.2));
        assert!(close(angle_diff(TAU - 0.1, 0.1), 0.2));
        assert!(close(norm_angle(-0.5), TAU - 0.5));
        assert!(close(norm_angle(TAU + 1.0), 1.0));
    }

    #[test]
    fn arc_checks_the_front_half() {
        let p = [0.0, 0.0, 0.0];
        assert!(in_arc(p, 0.0, [5.0, 4.0, 0.0], PI));
        assert!(!in_arc(p, 0.0, [-5.0, 1.0, 0.0], PI));
        assert!(in_arc(p, PI, [-5.0, 1.0, 0.0], PI));
    }

    #[test]
    fn step_and_along() {
        let p = step([1.0, 1.0, 5.0], PI / 2.0, 3.0);
        assert!(close(p[0], 1.0) && close(p[1], 4.0) && close(p[2], 5.0));
        let pts = [[0.0, 0.0, 0.0], [10.0, 0.0, 0.0], [10.0, 10.0, 0.0]];
        assert_eq!(along(&pts, 15.0), Some([10.0, 5.0, 0.0]));
        assert_eq!(along(&pts, 99.0), Some([10.0, 10.0, 0.0]));
        assert!(close(path_len(&pts), 20.0));
    }

    #[test]
    fn hunter_range_bands() {
        let b = RangeBands::default();
        assert_eq!(b.band(3.0), Band::Melee);
        assert_eq!(b.band(5.0), Band::Melee);
        assert_eq!(b.band(6.5), Band::DeadZone);
        assert_eq!(b.band(8.0), Band::Ranged);
        assert_eq!(b.band(35.0), Band::Ranged);
        assert_eq!(b.band(35.1), Band::OutOfRange);
    }
}
