//! Applies this fork's generate-time patch effects post-hoc onto
//! already-generated reflection-database artifacts.
//!
//! Why this exists: the Windows Roblox Studio 0.728.0.7280895 build's
//! `-FullAPI` dump is mirrored to the public `-API` dump — internal
//! serialization-only members (e.g. `Smoke.size_xml`, `Humanoid.Health_XML`)
//! are missing — so `rbx_reflector generate` cannot run against this build
//! on Windows: upstream's own patch files reference those members and fail
//! against the non-full dump. Upstream's shipped v728 artifacts were
//! generated from the SAME Roblox version with a working dump, so we adopt
//! those artifacts and re-apply the single patch this fork adds on top of
//! upstream's patch set (patches/parts.yml: `TriangleMeshPart.CollisionFidelity`
//! marked `Serializes`) directly to the artifacts.
//!
//! The transform is intentionally exactly equivalent to what
//! `rbx_reflector generate --patches patches` produces for that entry:
//! `PropertyChange { serialization: Serializes }` maps to
//! `PropertyKind::Canonical { serialization: PropertySerialization::Serializes }`
//! (see `rbx_reflector/src/patches.rs`), and the writers below mirror the
//! `generate` subcommand's default output branches byte-for-byte
//! (`rmp_serde::to_vec` for .msgpack, `serde_json::to_writer_pretty` for .json).
//!
//! Usage:
//!   cargo run -p rbx_reflector --example post_patch_starfruit_db -- \
//!       rbx_reflection_database/database.msgpack rbx_dom_lua/src/database.json

use std::{
    fs::{self, File},
    io::{BufWriter, Write},
};

use anyhow::{bail, Context};
use rbx_reflection::{PropertyKind, PropertySerialization, ReflectionDatabase};

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [msgpack_path, json_path] = args.as_slice() else {
        bail!("usage: post_patch_starfruit_db <database.msgpack> <database.json>");
    };

    let bytes = fs::read(msgpack_path).context("could not read msgpack database")?;
    let mut database: ReflectionDatabase =
        rmp_serde::from_slice(&bytes).context("could not deserialize msgpack database")?;

    // Guard: refuse to run on a database derived from a mirrored (non-full)
    // API dump — the entire premise is that the input artifacts carry the
    // full-dump internals.
    let smoke = database
        .classes
        .get("Smoke")
        .context("database has no Smoke class")?;
    if !smoke.properties.contains_key("size_xml") {
        bail!("input database lacks full-dump internals (Smoke.size_xml missing) — refusing to patch a mirrored-dump artifact");
    }

    let prop = database
        .classes
        .get_mut("TriangleMeshPart")
        .context("database has no TriangleMeshPart class")?
        .properties
        .get_mut("CollisionFidelity")
        .context("TriangleMeshPart has no CollisionFidelity property")?;

    let before = format!("{:?}", prop.kind);
    prop.kind = PropertyKind::Canonical {
        serialization: PropertySerialization::Serializes,
    };
    println!(
        "TriangleMeshPart.CollisionFidelity kind: {} -> {:?}",
        before, prop.kind
    );

    // Mirror `generate`'s default (non-human-readable) msgpack branch.
    let buf = rmp_serde::to_vec(&database).context("could not serialize msgpack database")?;
    let mut file = BufWriter::new(File::create(msgpack_path)?);
    file.write_all(&buf)?;
    file.flush()?;

    // Mirror `generate`'s default (pretty) JSON branch.
    let mut file = BufWriter::new(File::create(json_path)?);
    serde_json::to_writer_pretty(&mut file, &database)
        .context("could not serialize JSON database")?;
    file.flush()?;

    println!("patched artifacts written: {msgpack_path} + {json_path}");
    Ok(())
}
