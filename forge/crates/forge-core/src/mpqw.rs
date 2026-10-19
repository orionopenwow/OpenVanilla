//! A small MPQ version 1 writer: what the 1.12 client, StormLib and the browser client (wenilla)
//! all read. Ported from tools/modelport/mpq.py (which matches tools/build_mpq.py's StormLib
//! output): every file in 4 KB sectors with a sector offset table, each sector zlib-compressed
//! when that makes it smaller, an encrypted hash and block table, and a (listfile).
//! No single-unit files: wenilla can't read them (wow-mpq's writer makes them for small files).

use anyhow::Result;
use std::io::Write;
use wow_mpq::crypto::{encrypt_block, hash_string, hash_type};

const EXISTS: u32 = 0x8000_0000;
const COMPRESS: u32 = 0x0000_0200;
const SECTOR_SHIFT: u16 = 3; // 512 << 3 = 4096-byte sectors

fn zlib(part: &[u8]) -> Vec<u8> {
    let mut e = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
    e.write_all(part).unwrap();
    e.finish().unwrap()
}

/// Write `files` (archive name -> bytes) as a fresh archive; names are stored as given.
pub fn write(path: &std::path::Path, files: &[(String, Vec<u8>)]) -> Result<u64> {
    let sector = 512usize << SECTOR_SHIFT;
    let mut names: Vec<&(String, Vec<u8>)> = files.iter().collect();
    names.sort_by_key(|(n, _)| n.to_ascii_lowercase());
    let mut list = String::new();
    for (n, _) in &names {
        list.push_str(n);
        list.push_str("\r\n");
    }
    let listfile = ("(listfile)".to_string(), list.into_bytes());
    let mut entries: Vec<&(String, Vec<u8>)> = names;
    entries.push(&listfile);

    let mut body: Vec<u8> = Vec::new();
    let mut blocks: Vec<[u32; 4]> = Vec::new();
    for (_, data) in &entries {
        let pos = 32 + body.len() as u32;
        if data.is_empty() {
            blocks.push([pos, 0, 0, EXISTS]);
            continue;
        }
        let n = data.len().div_ceil(sector);
        let mut sectors: Vec<Vec<u8>> = Vec::with_capacity(n);
        for k in 0..n {
            let part = &data[k * sector..((k + 1) * sector).min(data.len())];
            let mut z = vec![0x02u8];
            z.extend(zlib(part));
            sectors.push(if z.len() < part.len() { z } else { part.to_vec() });
        }
        let mut table: Vec<u32> = vec![4 * (n as u32 + 1)];
        for s in &sectors {
            table.push(table.last().unwrap() + s.len() as u32);
        }
        let mut blob: Vec<u8> = table.iter().flat_map(|v| v.to_le_bytes()).collect();
        for s in sectors {
            blob.extend(s);
        }
        blocks.push([pos, blob.len() as u32, data.len() as u32, EXISTS | COMPRESS]);
        body.extend(blob);
    }
    let mut ht_n = 16usize;
    while ht_n < entries.len() * 2 {
        ht_n *= 2;
    }
    // hash entry: name1, name2, locale(u16) platform(u16), block index
    let mut ht: Vec<[u32; 4]> = vec![[0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF]; ht_n];
    for (bi, (name, _)) in entries.iter().enumerate() {
        let mut i = hash_string(name, hash_type::TABLE_OFFSET) as usize & (ht_n - 1);
        while ht[i][3] != 0xFFFF_FFFF {
            i = (i + 1) % ht_n;
        }
        ht[i] = [hash_string(name, hash_type::NAME_A), hash_string(name, hash_type::NAME_B), 0, bi as u32];
    }
    let mut htw: Vec<u32> = ht.iter().flatten().copied().collect();
    let mut btw: Vec<u32> = blocks.iter().flatten().copied().collect();
    encrypt_block(&mut htw, hash_string("(hash table)", hash_type::FILE_KEY));
    encrypt_block(&mut btw, hash_string("(block table)", hash_type::FILE_KEY));
    let ht_off = 32 + body.len() as u32;
    let bt_off = ht_off + (ht_n * 16) as u32;
    let total = bt_off + (blocks.len() * 16) as u32;
    let mut out: Vec<u8> = Vec::with_capacity(total as usize);
    out.extend(b"MPQ\x1a");
    out.extend(32u32.to_le_bytes());
    out.extend(total.to_le_bytes());
    out.extend(0u16.to_le_bytes());
    out.extend(SECTOR_SHIFT.to_le_bytes());
    out.extend(ht_off.to_le_bytes());
    out.extend(bt_off.to_le_bytes());
    out.extend((ht_n as u32).to_le_bytes());
    out.extend((blocks.len() as u32).to_le_bytes());
    out.extend(body);
    out.extend(htw.iter().flat_map(|v| v.to_le_bytes()));
    out.extend(btw.iter().flat_map(|v| v.to_le_bytes()));
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, &out)?;
    std::fs::rename(&tmp, path)?;
    Ok(out.len() as u64)
}

#[cfg(test)]
mod tests {
    #[test]
    fn small_and_large_files_read_back_with_wow_mpq() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("t.MPQ");
        let big: Vec<u8> = (0..20_000u32).map(|i| (i * 7 % 251) as u8).collect();
        let files = vec![
            ("Interface\\AddOns\\X\\X.toc".to_string(), b"## Interface: 11200\n".to_vec()),
            ("Interface\\Big.bin".to_string(), big.clone()),
            ("Interface\\Empty.txt".to_string(), vec![]),
        ];
        super::write(&p, &files).unwrap();
        let mut a = wow_mpq::Archive::open(&p).unwrap();
        assert_eq!(a.read_file("Interface\\Big.bin").unwrap(), big);
        assert_eq!(a.read_file("interface\\addons\\x\\x.toc").unwrap(), b"## Interface: 11200\n");
        let list = String::from_utf8(a.read_file("(listfile)").unwrap()).unwrap();
        assert!(list.contains("Interface\\Empty.txt"));
    }
}
