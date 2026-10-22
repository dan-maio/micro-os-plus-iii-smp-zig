//! The shapes of the interfaces example (~/Documents/work_zig/interfaces),
//! on the RTOS: a generic intrusive singly linked list, a hand written vtable
//! interface (`Shape`) and four concrete shapes. The list never allocates and
//! has no locking; the test guards it with an RTOS mutex.
//!
//! Differences from the example: the list operations are plain Zig here (the
//! example compiles them into a static library and calls them over the C
//! ABI); each shape records the area its constructor arguments predict, so a
//! caller can check the vtable dispatch; `kindOf()` / `free()` recover the
//! concrete type from the vtable pointer, so a corrupted node is detected
//! instead of freed with the wrong size.

const std = @import("std");

pub fn IntrusiveList(comptime T: type) type {
    comptime {
        if (@typeInfo(T) != .@"struct")
            @compileError("IntrusiveList requires a struct type, got " ++ @typeName(T));
        if (!@hasField(T, "next"))
            @compileError("IntrusiveList requires " ++ @typeName(T) ++ " to have a `next` field");
        if (@FieldType(T, "next") != ?*T)
            @compileError("IntrusiveList requires `next` to be `?*" ++ @typeName(T) ++ "`");
    }

    return struct {
        head: ?*T = null,

        const Self = @This();

        pub fn push(self: *Self, node: *T) void {
            self.push_front(node);
        }

        pub fn push_front(self: *Self, node: *T) void {
            node.next = self.head;
            self.head = node;
        }

        pub fn unlink(self: *Self, node: *T) bool {
            var link = &self.head;
            while (link.*) |current| {
                if (current == node) {
                    link.* = current.next;
                    current.next = null;
                    return true;
                }
                link = &current.next;
            }
            return false;
        }
    };
}

pub const Shape = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    next: ?*Shape = null,

    pub const VTable = struct {
        area: *const fn (ptr: *anyopaque) callconv(.c) f64,
        name: *const fn (ptr: *anyopaque) callconv(.c) [*:0]const u8,
        scale: *const fn (ptr: *anyopaque, factor: f64) callconv(.c) void,
    };

    pub fn area(self: Shape) f64 {
        return self.vtable.area(self.ptr);
    }

    pub fn name(self: Shape) []const u8 {
        return std.mem.span(self.vtable.name(self.ptr));
    }

    pub fn scale(self: Shape, factor: f64) void {
        self.vtable.scale(self.ptr, factor);
    }
};

pub const ShapeList = struct {
    nodes: IntrusiveList(Shape) = .{},

    pub fn push(self: *ShapeList, shape: *Shape) void {
        self.nodes.push(shape);
    }

    pub fn search(self: ShapeList, name: []const u8) ?*Shape {
        var it = self.nodes.head;
        while (it) |shape| : (it = shape.next) {
            if (std.mem.eql(u8, shape.name(), name)) return shape;
        }
        return null;
    }

    pub fn modify(self: ShapeList, name: []const u8, factor: f64) bool {
        const shape = self.search(name) orelse return false;
        shape.scale(factor);
        return true;
    }

    pub fn delete(self: *ShapeList, shape: *Shape) bool {
        return self.nodes.unlink(shape);
    }

    pub fn totalArea(self: ShapeList) f64 {
        var sum: f64 = 0;
        var it = self.nodes.head;
        while (it) |shape| : (it = shape.next) sum += shape.area();
        return sum;
    }

    pub fn count(self: ShapeList) usize {
        var n: usize = 0;
        var it = self.nodes.head;
        while (it) |shape| : (it = shape.next) n += 1;
        return n;
    }
};

pub const Kind = enum(u8) { circle, triangle, ellipse, rect };
pub const kinds = [_]Kind{ .circle, .triangle, .ellipse, .rect };

pub const Circle = struct {
    node: Shape,
    radius: f64,
    expected: f64,

    pub const vtable = Shape.VTable{ .area = area, .name = name, .scale = scale };

    pub fn init(self: *Circle, radius: f64) void {
        self.radius = radius;
        self.expected = std.math.pi * radius * radius;
        self.node = .{ .ptr = self, .vtable = &vtable };
    }

    pub fn create(gpa: std.mem.Allocator, radius: f64) !*Circle {
        const self = try gpa.create(Circle);
        self.init(radius);
        return self;
    }

    fn area(ptr: *anyopaque) callconv(.c) f64 {
        const self: *Circle = @ptrCast(@alignCast(ptr));
        return std.math.pi * self.radius * self.radius;
    }

    fn name(_: *anyopaque) callconv(.c) [*:0]const u8 {
        return "circle";
    }

    fn scale(ptr: *anyopaque, factor: f64) callconv(.c) void {
        const self: *Circle = @ptrCast(@alignCast(ptr));
        self.radius *= factor;
        self.expected *= factor * factor;
    }

    pub fn shape(self: *Circle) *Shape {
        return &self.node;
    }
};

pub const Rect = struct {
    node: Shape,
    w: f64,
    h: f64,
    expected: f64,

    pub const vtable = Shape.VTable{ .area = area, .name = name, .scale = scale };

    pub fn init(self: *Rect, w: f64, h: f64) void {
        self.w = w;
        self.h = h;
        self.expected = w * h;
        self.node = .{ .ptr = self, .vtable = &vtable };
    }

    pub fn create(gpa: std.mem.Allocator, w: f64, h: f64) !*Rect {
        const self = try gpa.create(Rect);
        self.init(w, h);
        return self;
    }

    fn area(ptr: *anyopaque) callconv(.c) f64 {
        const self: *Rect = @ptrCast(@alignCast(ptr));
        return self.w * self.h;
    }

    fn name(_: *anyopaque) callconv(.c) [*:0]const u8 {
        return "rect";
    }

    fn scale(ptr: *anyopaque, factor: f64) callconv(.c) void {
        const self: *Rect = @ptrCast(@alignCast(ptr));
        self.w *= factor;
        self.h *= factor;
        self.expected *= factor * factor;
    }

    pub fn shape(self: *Rect) *Shape {
        return &self.node;
    }
};

pub const Triangle = struct {
    node: Shape,
    base: f64,
    height: f64,
    expected: f64,

    pub const vtable = Shape.VTable{ .area = area, .name = name, .scale = scale };

    pub fn init(self: *Triangle, base: f64, height: f64) void {
        self.base = base;
        self.height = height;
        self.expected = 0.5 * base * height;
        self.node = .{ .ptr = self, .vtable = &vtable };
    }

    pub fn create(gpa: std.mem.Allocator, base: f64, height: f64) !*Triangle {
        const self = try gpa.create(Triangle);
        self.init(base, height);
        return self;
    }

    fn area(ptr: *anyopaque) callconv(.c) f64 {
        const self: *Triangle = @ptrCast(@alignCast(ptr));
        return 0.5 * self.base * self.height;
    }

    fn name(_: *anyopaque) callconv(.c) [*:0]const u8 {
        return "triangle";
    }

    fn scale(ptr: *anyopaque, factor: f64) callconv(.c) void {
        const self: *Triangle = @ptrCast(@alignCast(ptr));
        self.base *= factor;
        self.height *= factor;
        self.expected *= factor * factor;
    }

    pub fn shape(self: *Triangle) *Shape {
        return &self.node;
    }
};

pub const Ellipse = struct {
    node: Shape,
    semi_major: f64,
    semi_minor: f64,
    expected: f64,

    pub const vtable = Shape.VTable{ .area = area, .name = name, .scale = scale };

    pub fn init(self: *Ellipse, semi_major: f64, semi_minor: f64) void {
        self.semi_major = semi_major;
        self.semi_minor = semi_minor;
        self.expected = std.math.pi * semi_major * semi_minor;
        self.node = .{ .ptr = self, .vtable = &vtable };
    }

    pub fn create(gpa: std.mem.Allocator, semi_major: f64, semi_minor: f64) !*Ellipse {
        const self = try gpa.create(Ellipse);
        self.init(semi_major, semi_minor);
        return self;
    }

    fn area(ptr: *anyopaque) callconv(.c) f64 {
        const self: *Ellipse = @ptrCast(@alignCast(ptr));
        return std.math.pi * self.semi_major * self.semi_minor;
    }

    fn name(_: *anyopaque) callconv(.c) [*:0]const u8 {
        return "ellipse";
    }

    fn scale(ptr: *anyopaque, factor: f64) callconv(.c) void {
        const self: *Ellipse = @ptrCast(@alignCast(ptr));
        self.semi_major *= factor;
        self.semi_minor *= factor;
        self.expected *= factor * factor;
    }

    pub fn shape(self: *Ellipse) *Shape {
        return &self.node;
    }
};

/// The concrete kind behind a node, from its vtable; null for a node whose
/// vtable is none of the four (a corrupted node).
pub fn kindOf(s: *const Shape) ?Kind {
    if (s.vtable == &Circle.vtable) return .circle;
    if (s.vtable == &Triangle.vtable) return .triangle;
    if (s.vtable == &Ellipse.vtable) return .ellipse;
    if (s.vtable == &Rect.vtable) return .rect;
    return null;
}

/// The area the constructor arguments (and every scale since) predict.
pub fn expectedArea(s: *const Shape) f64 {
    const k = kindOf(s) orelse return -1;
    return switch (k) {
        .circle => @as(*const Circle, @ptrCast(@alignCast(s.ptr))).expected,
        .triangle => @as(*const Triangle, @ptrCast(@alignCast(s.ptr))).expected,
        .ellipse => @as(*const Ellipse, @ptrCast(@alignCast(s.ptr))).expected,
        .rect => @as(*const Rect, @ptrCast(@alignCast(s.ptr))).expected,
    };
}

/// True when `s` is the node embedded in the object its `ptr` points to.
pub fn selfConsistent(s: *const Shape) bool {
    const k = kindOf(s) orelse return false;
    return switch (k) {
        .circle => &@as(*Circle, @ptrCast(@alignCast(s.ptr))).node == s,
        .triangle => &@as(*Triangle, @ptrCast(@alignCast(s.ptr))).node == s,
        .ellipse => &@as(*Ellipse, @ptrCast(@alignCast(s.ptr))).node == s,
        .rect => &@as(*Rect, @ptrCast(@alignCast(s.ptr))).node == s,
    };
}

/// Release a heap shape with its own type's size. The node must already be
/// unlinked. False (and nothing freed) for an unknown vtable.
pub fn free(gpa: std.mem.Allocator, s: *Shape) bool {
    const k = kindOf(s) orelse return false;
    switch (k) {
        .circle => gpa.destroy(@as(*Circle, @ptrCast(@alignCast(s.ptr)))),
        .triangle => gpa.destroy(@as(*Triangle, @ptrCast(@alignCast(s.ptr)))),
        .ellipse => gpa.destroy(@as(*Ellipse, @ptrCast(@alignCast(s.ptr)))),
        .rect => gpa.destroy(@as(*Rect, @ptrCast(@alignCast(s.ptr)))),
    }
    return true;
}

/// Build one shape of `kind` on the heap from two parameters (the second is
/// unused by a circle).
pub fn make(gpa: std.mem.Allocator, kind: Kind, a: f64, b: f64) !*Shape {
    return switch (kind) {
        .circle => (try Circle.create(gpa, a)).shape(),
        .triangle => (try Triangle.create(gpa, a, b)).shape(),
        .ellipse => (try Ellipse.create(gpa, a, b)).shape(),
        .rect => (try Rect.create(gpa, a, b)).shape(),
    };
}

/// |got - want| within a relative tolerance.
pub fn close(got: f64, want: f64) bool {
    const tol = 1e-9 * @max(@abs(want), 1.0);
    return @abs(got - want) <= tol;
}
