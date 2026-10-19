//! Herald Lite: a headless WoW 1.12.1 test client built on wenilla's protocol crates.
//!
//! - [`client`]: logon, world session, keep-alive and the observed world model
//! - [`bridge`]: the loopback pipe that carries the protocol over TCP or the realm's WebSocket relay
//! - [`web`]: the realm service's web login, `/api/play` credential and relay URL
//! - [`scenario`]: the line DSL; [`runner`]: execution and the JSON report
//! - [`wnl`]: Open Vanilla's `WNL\t<TAG> ...` server channel
//! - [`autopilot`]: Herald Autopilot, the questing/combat test bot (`heraldlite autopilot`)

pub mod autopilot;
pub mod bridge;
pub mod client;
pub mod runner;
pub mod scenario;
pub mod web;
pub mod wnl;
