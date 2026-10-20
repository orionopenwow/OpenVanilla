// WASI stubs for the browser build. There is no filesystem, no env, no clock through WASI:
// libc's start-up asks "which directories are preopened?" (answer: none — EBADF ends the scan),
// and everything else reports ENOSYS. `bind(memory)` lets the size queries write their zeros.
const EBADF = 8, ENOSYS = 52;
let mem = null;
export function bind(memory) { mem = memory; }
function zero(ptr) { if (mem) new DataView(mem.buffer).setUint32(ptr, 0, true); }
export function fd_prestat_get() { return EBADF; }
export function fd_prestat_dir_name() { return EBADF; }
export function environ_sizes_get(countPtr, sizePtr) { zero(countPtr); zero(sizePtr); return 0; }
export function environ_get() { return 0; }
export function args_sizes_get(countPtr, sizePtr) { zero(countPtr); zero(sizePtr); return 0; }
export function args_get() { return 0; }
export function clock_time_get() { return ENOSYS; }
export function fd_close() { return EBADF; }
export function fd_fdstat_get() { return EBADF; }
export function fd_fdstat_set_flags() { return EBADF; }
export function fd_read() { return EBADF; }
export function fd_renumber() { return EBADF; }
export function fd_seek() { return EBADF; }
export function fd_write() { return EBADF; }
export function path_open() { return ENOSYS; }
export function path_remove_directory() { return ENOSYS; }
export function path_rename() { return ENOSYS; }
export function path_unlink_file() { return ENOSYS; }
export function proc_exit(code) { throw new Error('proc_exit ' + code); }
