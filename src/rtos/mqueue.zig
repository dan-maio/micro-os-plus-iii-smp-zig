pub const MessageQueue = struct {};
pub fn MessageQueueTyped(comptime T: type) type { _ = T; return struct {}; }
