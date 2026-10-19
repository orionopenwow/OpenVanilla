//! Lights: how a place looks at every hour. A map has a global light, and spheres of light that
//! take over inside them (Light.dbc: where, how far; five LightParams: clear, clear under water,
//! storm, storm under water, death). Each LightParams has 18 colour bands (LightIntBand: sun,
//! ambient, the sky from top to horizon, fog, sun glow, clouds, water …) and 6 number bands
//! (LightFloatBand: fog distance …), each a few stops through the day (times in half-minutes,
//! 0–2880; colours 0xRRGGBB).
//!
//! Positions in Light.dbc are file coordinates × 36 (x, height, z); Forge speaks world
//! coordinates (x, y, z) as `.gps` prints them.

use crate::data::{self, Dbc};
use crate::ids::IdLock;
use crate::project::Project;
use crate::vfs::GameData;
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use serde_json::{json, Value};
use toml::Value as T;

/// What each of the 18 colour bands is (by index).
pub const INT_BANDS: [&str; 18] = [
    "Sun", "Ambient", "Sky top", "Sky middle", "Sky lower", "Above the horizon", "Horizon", "Fog", "Unused", "Sun colour", "Sun glow",
    "Clouds", "Unused 2", "Cloud edge", "River near", "River far", "Ocean near", "Ocean far",
];
/// The 6 number bands.
pub const FLOAT_BANDS: [&str; 6] = ["Fog distance", "Fog start", "Glow", "Cloud density", "Unused", "Unused 2"];
/// The five weathers of a light, in order.
pub const PARAMS: [&str; 5] = ["Clear", "Clear, under water", "Storm", "Storm, under water", "Death"];

const UNIT: f64 = 36.0;

fn merged(p: &Project, g: &GameData, t: &str) -> Result<Dbc> {
    let stock = data::read_stock(g, t)?;
    let d = data::load(p);
    match d.dbc.get(t) {
        Some(r) if !r.rows.is_empty() => data::merge(t, &stock, &r.rows),
        _ => Ok(stock),
    }
}

fn own_ids(p: &Project, t: &str) -> Vec<u32> {
    data::load(p).dbc.get(t).map(|r| r.rows.iter().filter_map(|x| x.get("ID").and_then(T::as_integer)).map(|x| x as u32).collect()).unwrap_or_default()
}

fn f(w: u32) -> f64 {
    f32::from_bits(w) as f64
}

fn light_json(d: &Dbc, r: &[u32], own: &[u32]) -> Value {
    // GameCoords: file x, height, file z (× 36)
    let (fx, h, fz) = (f(r[2]) / UNIT, f(r[3]) / UNIT, f(r[4]) / UNIT);
    let global = r[2] == 0 && r[3] == 0 && r[4] == 0;
    let _ = d;
    json!({
        "id": r[0], "map": r[1], "global": global,
        "x": crate::adt::HALF - fz, "y": crate::adt::HALF - fx, "z": h,
        "start": f(r[5]) / UNIT, "end": f(r[6]) / UNIT,
        "params": r[7..12].to_vec(), "own": own.contains(&r[0]),
    })
}

/// The lights of a map: its global light first, then the spheres (nearest to (x, y) first when
/// given).
pub fn lights(p: &Project, g: &GameData, map: u32, near: Option<(f64, f64)>) -> Result<Vec<Value>> {
    let d = merged(p, g, "Light")?;
    let own = own_ids(p, "Light");
    let mut out: Vec<Value> = d.records.iter().filter(|r| r[1] == map).map(|r| light_json(&d, r, &own)).collect();
    let dist = |v: &Value| match near {
        Some((x, y)) if v["global"] != true => ((v["x"].as_f64().unwrap_or(0.0) - x).powi(2) + (v["y"].as_f64().unwrap_or(0.0) - y).powi(2)).sqrt(),
        Some(_) => -1.0,
        None => if v["global"] == true { -1.0 } else { 0.0 },
    };
    out.sort_by(|a, b| dist(a).partial_cmp(&dist(b)).unwrap_or(std::cmp::Ordering::Equal));
    Ok(out)
}

fn band_id(params: u32, k: usize, n: usize) -> u32 {
    (params - 1) * n as u32 + k as u32 + 1
}

/// A light's five weathers, each with its colour and number bands.
pub fn light_detail(p: &Project, g: &GameData, id: u32) -> Result<Value> {
    let ld = merged(p, g, "Light")?;
    let r = ld.records.get(ld.find(id).with_context(|| format!("no light {id}"))?).context("no light")?.clone();
    let ib = merged(p, g, "LightIntBand")?;
    let fb = merged(p, g, "LightFloatBand")?;
    let pd = merged(p, g, "LightParams")?;
    let own = own_ids(p, "Light");
    let mut weathers = vec![];
    for (wi, &pid) in r[7..12].iter().enumerate() {
        if pid == 0 {
            weathers.push(json!({"name": PARAMS[wi], "params": 0}));
            continue;
        }
        let ints: Vec<Value> = (0..18)
            .map(|k| {
                let b = ib.find(band_id(pid, k, 18)).map(|i| ib.records[i].clone());
                let (n, times, data) = b.map(|b| (b[1] as usize, b[2..18].to_vec(), b[18..34].to_vec())).unwrap_or((0, vec![], vec![]));
                json!({"band": k, "name": INT_BANDS[k], "times": times[..n.min(16)].to_vec(), "colors": data[..n.min(16)].to_vec()})
            })
            .collect();
        let floats: Vec<Value> = (0..6)
            .map(|k| {
                let b = fb.find(band_id(pid, k, 6)).map(|i| fb.records[i].clone());
                let (n, times, data) = b.map(|b| (b[1] as usize, b[2..18].to_vec(), b[18..34].iter().map(|w| f(*w)).collect::<Vec<_>>())).unwrap_or((0, vec![], vec![]));
                json!({"band": k, "name": FLOAT_BANDS[k], "times": times[..n.min(16)].to_vec(), "values": data[..n.min(16)].to_vec()})
            })
            .collect();
        let prm = pd.find(pid).map(|i| pd.records[i].clone());
        weathers.push(json!({"name": PARAMS[wi], "params": pid, "ints": ints, "floats": floats,
            "skybox": prm.as_ref().map(|x| x[2]), "glow": prm.as_ref().map(|x| f(x[3]))}));
    }
    let mut v = light_json(&ld, &r, &own);
    v["weathers"] = json!(weathers);
    Ok(v)
}

fn rows(p: &Project, t: &str) -> Vec<toml::Table> {
    data::load(p).dbc.get(t).map(|r| r.rows.clone()).unwrap_or_default()
}

/// Put a row (by ID) in the pack's table: replaces the pack's own, or overrides a stock one.
pub(crate) fn upsert(p: &Project, g: &GameData, t: &str, id: u32, fields: Vec<(&str, T)>) -> Result<()> {
    let mut all = rows(p, t);
    let stock = data::read_stock(g, t).ok();
    let i = match all.iter().position(|r| r.get("ID").and_then(T::as_integer) == Some(id as i64)) {
        Some(i) => i,
        None => {
            let mut r = toml::Table::new();
            r.insert("ID".into(), T::Integer(id as i64));
            if stock.as_ref().is_some_and(|s| s.find(id).is_some()) {
                r.insert("override".into(), T::Boolean(true));
                r.insert("clone".into(), T::Integer(id as i64));
            }
            all.push(r);
            all.len() - 1
        }
    };
    for (k, v) in fields {
        all[i].insert(k.to_string(), v);
    }
    data::save_rows(p, "dbc", t, &all)?;
    Ok(())
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct LightEdit {
    #[serde(default)]
    pub x: Option<f64>,
    #[serde(default)]
    pub y: Option<f64>,
    #[serde(default)]
    pub z: Option<f64>,
    #[serde(default)]
    pub start: Option<f64>,
    #[serde(default)]
    pub end: Option<f64>,
}

/// Move a light or change how far it reaches (a stock light gets an override row).
pub fn light_set(p: &Project, g: &GameData, id: u32, e: &LightEdit) -> Result<()> {
    let ld = merged(p, g, "Light")?;
    let r = ld.records.get(ld.find(id).with_context(|| format!("no light {id}"))?).context("no light")?.clone();
    let cur = light_json(&ld, &r, &[]);
    if cur["global"] == true && (e.x.is_some() || e.y.is_some() || e.z.is_some()) {
        bail!("the map's global light is everywhere: it has no place to move to");
    }
    let x = e.x.unwrap_or(cur["x"].as_f64().unwrap_or(0.0));
    let y = e.y.unwrap_or(cur["y"].as_f64().unwrap_or(0.0));
    let z = e.z.unwrap_or(cur["z"].as_f64().unwrap_or(0.0));
    let (start, end) = (e.start.unwrap_or(cur["start"].as_f64().unwrap_or(0.0)), e.end.unwrap_or(cur["end"].as_f64().unwrap_or(0.0)));
    if end < start {
        bail!("a light fades out after it starts fading (end ≥ start)");
    }
    let (fx, fz) = (crate::adt::HALF - y, crate::adt::HALF - x);
    let coords = T::Array(vec![T::Float(fx * UNIT), T::Float(z * UNIT), T::Float(fz * UNIT)]);
    upsert(p, g, "Light", id, vec![("GameCoords", coords), ("GameFalloffStart", T::Float(start * UNIT)), ("GameFalloffEnd", T::Float(end * UNIT))])
}

/// Set one colour band of one weather (stops: times in half-minutes, colours 0xRRGGBB; 1–16).
pub fn band_set(p: &Project, g: &GameData, params: u32, band: usize, times: &[u32], colors: &[u32]) -> Result<()> {
    if band >= 18 || times.is_empty() || times.len() > 16 || times.len() != colors.len() {
        bail!("a band has 1 to 16 stops, each a time and a colour");
    }
    if times.windows(2).any(|w| w[0] >= w[1]) || times.iter().any(|t| *t > 2880) {
        bail!("stops go in order through the day (0 to 24:00)");
    }
    let mut ts: Vec<T> = times.iter().map(|t| T::Integer(*t as i64)).collect();
    let mut cs: Vec<T> = colors.iter().map(|c| T::Integer((*c & 0xFF_FFFF) as i64)).collect();
    ts.resize(16, T::Integer(0));
    cs.resize(16, T::Integer(0));
    upsert(p, g, "LightIntBand", band_id(params, band, 18), vec![("Num", T::Integer(times.len() as i64)), ("Time", T::Array(ts)), ("Data", T::Array(cs))])
}

/// A new light at (x, y, z), copying the look of `from` (a light ID): its own five weathers.
pub fn light_new(p: &Project, g: &GameData, map: u32, x: f64, y: f64, z: f64, start: f64, end: f64, from: u32) -> Result<u32> {
    let ld = merged(p, g, "Light")?;
    let src = ld.records.get(ld.find(from).with_context(|| format!("no light {from} to copy"))?).context("no light")?.clone();
    let ib = merged(p, g, "LightIntBand")?;
    let fb = merged(p, g, "LightFloatBand")?;
    let mut lock = IdLock::load(&p.root)?;
    let pack = p.manifest.pack.id.clone();
    let id = lock.allocate(&pack, "Light", "light")?;
    let mut new_params = vec![];
    for _ in 0..5 {
        new_params.push(lock.allocate(&pack, "LightParams", "light")?);
    }
    lock.save(&p.root)?;
    let mut lp = rows(p, "LightParams");
    let mut li = rows(p, "LightIntBand");
    let mut lf = rows(p, "LightFloatBand");
    let tbl = |pairs: Vec<(&str, T)>| -> toml::Table { pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect() };
    for (wi, &old) in src[7..12].iter().enumerate() {
        let np = new_params[wi];
        lp.push(tbl(vec![("ID", T::Integer(np as i64)), ("clone", T::Integer(old.max(1) as i64)), ("comment", T::String(format!("light {id}: {}", PARAMS[wi])))]));
        for k in 0..18 {
            if ib.find(band_id(old.max(1), k, 18)).is_some() {
                li.push(tbl(vec![("ID", T::Integer(band_id(np, k, 18) as i64)), ("clone", T::Integer(band_id(old.max(1), k, 18) as i64))]));
            }
        }
        for k in 0..6 {
            if fb.find(band_id(old.max(1), k, 6)).is_some() {
                lf.push(tbl(vec![("ID", T::Integer(band_id(np, k, 6) as i64)), ("clone", T::Integer(band_id(old.max(1), k, 6) as i64))]));
            }
        }
    }
    data::save_rows(p, "dbc", "LightParams", &lp)?;
    data::save_rows(p, "dbc", "LightIntBand", &li)?;
    data::save_rows(p, "dbc", "LightFloatBand", &lf)?;
    let mut ll = rows(p, "Light");
    let (fx, fz) = (crate::adt::HALF - y, crate::adt::HALF - x);
    ll.push(tbl(vec![
        ("ID", T::Integer(id as i64)),
        ("comment", T::String("a light Forge made".into())),
        ("ContinentID", T::Integer(map as i64)),
        ("GameCoords", T::Array(vec![T::Float(fx * UNIT), T::Float(z * UNIT), T::Float(fz * UNIT)])),
        ("GameFalloffStart", T::Float(start * UNIT)),
        ("GameFalloffEnd", T::Float(end.max(start) * UNIT)),
        ("LightParamsID", T::Array(new_params.iter().map(|x| T::Integer(*x as i64)).collect())),
    ]));
    data::save_rows(p, "dbc", "Light", &ll)?;
    Ok(id)
}

/// Remove one of the pack's own lights (its weathers and bands go with it).
pub fn light_remove(p: &Project, g: &GameData, id: u32) -> Result<()> {
    let ld = merged(p, g, "Light")?;
    let r = ld.records.get(ld.find(id).with_context(|| format!("no light {id}"))?).context("no light")?.clone();
    if !own_ids(p, "Light").contains(&id) || data::read_stock(g, "Light")?.find(id).is_some() {
        bail!("only the pack's own lights can be removed (a game light can be changed)");
    }
    let params: Vec<i64> = r[7..12].iter().map(|x| *x as i64).collect();
    let keep = |t: &str, ids: &dyn Fn(i64) -> bool| -> Result<()> {
        let mut all = rows(p, t);
        all.retain(|x| !x.get("ID").and_then(T::as_integer).is_some_and(ids));
        data::save_rows(p, "dbc", t, &all)?;
        Ok(())
    };
    keep("Light", &|x| x == id as i64)?;
    keep("LightParams", &|x| params.contains(&x))?;
    keep("LightIntBand", &|x| params.iter().any(|pid| *pid > 0 && x > (pid - 1) * 18 && x <= pid * 18))?;
    keep("LightFloatBand", &|x| params.iter().any(|pid| *pid > 0 && x > (pid - 1) * 6 && x <= pid * 6))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::project::{create, Template};

    /// A game with a global light and one sphere on map 0, and their bands.
    fn light_game(dir: &std::path::Path) -> GameData {
        let mk = |t: &str, recs: Vec<Vec<u32>>| -> Vec<u8> {
            let n = data::dbc_schema()[t].record_fields;
            Dbc { fields: n, records: recs.into_iter().map(|mut r| { r.resize(n, 0); r }).collect(), strings: vec![0] }.write()
        };
        let fl = |v: f32| v.to_bits();
        let light = mk("Light", vec![vec![1, 0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0], vec![2, 0, fl(17000.0 * 36.0), fl(50.0 * 36.0), fl(27000.0 * 36.0), fl(100.0 * 36.0), fl(300.0 * 36.0), 1, 2, 0, 0, 0]]);
        let params = mk("LightParams", vec![vec![1], vec![2]]);
        let mut ib = vec![];
        for pid in 1..=2u32 {
            for k in 0..18u32 {
                let mut r = vec![(pid - 1) * 18 + k + 1, 2, 0, 1440];
                r.resize(18, 0);
                r.extend([0x102030, 0x405060]);
                ib.push(r);
            }
        }
        let ib = mk("LightIntBand", ib);
        let fb = mk("LightFloatBand", (1..=12).map(|i| vec![i, 1, 0]).collect());
        let game = dir.join("wow/Data");
        std::fs::create_dir_all(&game).unwrap();
        crate::mpqw::write(&game.join("dbc.MPQ"), &[
            ("DBFilesClient\\Light.dbc".into(), light), ("DBFilesClient\\LightParams.dbc".into(), params),
            ("DBFilesClient\\LightIntBand.dbc".into(), ib), ("DBFilesClient\\LightFloatBand.dbc".into(), fb),
        ]).unwrap();
        GameData::open(dir.join("wow")).unwrap()
    }

    #[test]
    fn lights_read_change_and_copy() {
        crate::test_config();
        let dir = tempfile::tempdir().unwrap();
        let p = create(dir.path().join("p"), "Light Pack", "Orion", Template::Empty).unwrap();
        let g = light_game(dir.path());
        let ls = lights(&p, &g, 0, None).unwrap();
        assert_eq!(ls.len(), 2);
        assert_eq!(ls[0]["global"], true);
        let s = &ls[1];
        assert!((s["x"].as_f64().unwrap() - (crate::adt::HALF - 27000.0)).abs() < 0.01);
        assert!((s["y"].as_f64().unwrap() - (crate::adt::HALF - 17000.0)).abs() < 0.01);
        assert!((s["end"].as_f64().unwrap() - 300.0).abs() < 0.01);
        let d = light_detail(&p, &g, 2).unwrap();
        assert_eq!(d["weathers"][0]["ints"][2]["colors"], json!([0x102030, 0x405060]));
        assert_eq!(d["weathers"][0]["ints"][2]["times"], json!([0, 1440]));
        // a stock light moved: an override; its sky changed
        light_set(&p, &g, 2, &LightEdit { end: Some(400.0), ..Default::default() }).unwrap();
        band_set(&p, &g, 1, 2, &[0, 720, 2160], &[0x000000, 0x3aa2cf, 0x112233]).unwrap();
        let d = light_detail(&p, &g, 2).unwrap();
        assert!((d["end"].as_f64().unwrap() - 400.0).abs() < 0.01);
        assert_eq!(d["weathers"][0]["ints"][2]["colors"], json!([0, 0x3aa2cf, 0x112233]));
        assert!(band_set(&p, &g, 1, 2, &[720, 0], &[1, 2]).is_err(), "out of order");
        assert!(light_set(&p, &g, 1, &LightEdit { x: Some(1.0), ..Default::default() }).is_err(), "the global light doesn't move");
        // a new light copying the sphere: its own weathers, the same sky
        let id = light_new(&p, &g, 0, -100.0, 50.0, 20.0, 30.0, 80.0, 2).unwrap();
        let n = light_detail(&p, &g, id).unwrap();
        assert_eq!(n["own"], true);
        assert_ne!(n["params"][0], d["params"][0]);
        assert_eq!(n["weathers"][0]["ints"][2]["colors"], json!([0, 0x3aa2cf, 0x112233]));
        assert!((n["x"].as_f64().unwrap() + 100.0).abs() < 0.01 && (n["y"].as_f64().unwrap() - 50.0).abs() < 0.01);
        // the rows check clean, and the light builds into the client's DBC
        let found = crate::data::check(&p, Some(&g));
        assert!(found.iter().all(|f| f.level != crate::check::Level::Error), "{found:?}");
        light_remove(&p, &g, id).unwrap();
        assert!(light_detail(&p, &g, id).is_err());
        assert!(light_remove(&p, &g, 2).is_err(), "a game light stays");
    }
}
