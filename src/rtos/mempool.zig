pub const MemoryPool = struct {};
pub fn MemoryPoolTyped(comptime T: type) type { _ = T; return struct {}; }
