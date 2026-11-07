//! Applies this fork's patches post-hoc to reflection-database artifacts that
//! were generated elsewhere (upstream's), so the fork can adopt them without
//! running `rbx_reflector generate` against a local Studio.
//!
//! Each change below mirrors one of the fork's own patch files exactly, so the
//! result equals what `rbx_reflector generate --patches patches` would produce
//! for those entries:
//! - `patches/parts.yml`: `TriangleMeshPart.CollisionFidelity` Serializes;
//! - `patches/gui-object.yml`: `GuiObject.InputSink` saved as `Sink`, with
//!   `GuiObject.Sink` an alias of `InputSink`.
//!
//! The writers mirror the `generate` subcommand's default output
//! (`rmp_serde::to_vec` for .msgpack, `serde_json::to_writer_pretty` for .json).
//! Each change checks the property exists and is idempotent, and the example
//! refuses an input built from a mirrored (non-full) API dump.
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

    // Guard: refuse a database derived from a mirrored (non-full) API dump.
    // Such a dump lacks the serialization-only internals.
    for (class, property) in [("Smoke", "size_xml"), ("Humanoid", "Health_XML")] {
        let has = database
            .classes
            .get(class)
            .is_some_and(|c| c.properties.contains_key(property));
        if !has {
            bail!("input database lacks {class}.{property}: refusing to patch an artifact built from a mirrored API dump");
        }
    }

    set_kind(
        &mut database,
        "TriangleMeshPart",
        "CollisionFidelity",
        PropertyKind::Canonical {
            serialization: PropertySerialization::Serializes,
        },
    )?;
    set_kind(
        &mut database,
        "GuiObject",
        "InputSink",
        PropertyKind::Canonical {
            serialization: PropertySerialization::SerializesAs("Sink"),
        },
    )?;
    set_kind(
        &mut database,
        "GuiObject",
        "Sink",
        PropertyKind::Alias {
            alias_for: "InputSink",
        },
    )?;

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

fn set_kind<'a>(
    database: &mut ReflectionDatabase<'a>,
    class: &str,
    property: &str,
    kind: PropertyKind<'a>,
) -> anyhow::Result<()> {
    let prop = database
        .classes
        .get_mut(class)
        .with_context(|| format!("database has no {class} class"))?
        .properties
        .get_mut(property)
        .with_context(|| format!("{class} has no {property} property"))?;
    let before = format!("{:?}", prop.kind);
    prop.kind = kind;
    println!("{class}.{property} kind: {before} -> {:?}", prop.kind);
    Ok(())
}
