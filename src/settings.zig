//! Settings re-export shim.
//! Settings are now part of the unified config system in config.zig.
//! This module re-exports the Settings type for backward compatibility.

const config = @import("config.zig");

pub const Settings = config.Settings;
pub const Config = config.Config;
pub const CONFIG_FILE = config.CONFIG_FILE;
pub const toJson = config.toJson;
pub const parseJson = config.parseJson;
pub const load = config.load;
pub const save = config.save;
pub const applyArgs = config.applyArgs;
pub const applyEnvOverride = config.applyEnvOverride;
