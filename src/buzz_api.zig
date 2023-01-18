const std = @import("std");
const builtin = @import("builtin");
const _vm = @import("./vm.zig");
const VM = _vm.VM;
const TryCtx = _vm.TryCtx;
const _obj = @import("./obj.zig");
const _value = @import("./value.zig");
const memory = @import("./memory.zig");
const _parser = @import("./parser.zig");
const _codegen = @import("./codegen.zig");
const BuildOptions = @import("build_options");
const jmp = @import("jmp.zig").jmp;

const Value = _value.Value;
const valueToStringAlloc = _value.valueToStringAlloc;
const ObjString = _obj.ObjString;
const ObjPattern = _obj.ObjPattern;
const ObjMap = _obj.ObjMap;
const ObjUpValue = _obj.ObjUpValue;
const ObjEnum = _obj.ObjEnum;
const ObjEnumInstance = _obj.ObjEnumInstance;
const ObjObject = _obj.ObjObject;
const ObjObjectInstance = _obj.ObjObjectInstance;
const ObjTypeDef = _obj.ObjTypeDef;
const ObjFunction = _obj.ObjFunction;
const ObjList = _obj.ObjList;
const ObjUserData = _obj.ObjUserData;
const ObjClosure = _obj.ObjClosure;
const ObjNative = _obj.ObjNative;
const NativeFn = _obj.NativeFn;
const NativeCtx = _obj.NativeCtx;
const UserData = _obj.UserData;
const TypeRegistry = memory.TypeRegistry;
const Parser = _parser.Parser;
const CodeGen = _codegen.CodeGen;
const GarbageCollector = memory.GarbageCollector;

var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
}){};

var allocator: std.mem.Allocator = if (builtin.mode == .Debug)
    gpa.allocator()
else if (BuildOptions.use_mimalloc)
    @import("./mimalloc.zig").mim_allocator
else
    std.heap.c_allocator;

// Stack manipulation

/// Push a Value to the stack
export fn bz_push(self: *VM, value: Value) void {
    self.push(value);
}

/// Pop a Value from the stack and returns it
export fn bz_pop(self: *VM) Value {
    self.current_fiber.stack_top -= 1;
    return @ptrCast(*Value, self.current_fiber.stack_top).*;
}

/// Peeks at the stack at [distance] from the stack top
export fn bz_peek(self: *VM, distance: u32) Value {
    return @ptrCast(*Value, self.current_fiber.stack_top - 1 - distance).*;
}

// Value manipulations

/// Push a boolean value on the stack
export fn bz_pushBool(self: *VM, value: bool) void {
    self.push(Value.fromBoolean(value));
}

/// Push a float value on the stack
export fn bz_pushFloat(self: *VM, value: f64) void {
    self.push(Value.fromFloat(value));
}

/// Push a integer value on the stack
export fn bz_pushInteger(self: *VM, value: i32) void {
    self.push(Value.fromInteger(value));
}

/// Push null on the stack
export fn bz_pushNull(self: *VM) void {
    self.push(Value.Null);
}

/// Push void on the stack
export fn bz_pushVoid(self: *VM) void {
    self.push(Value.Void);
}

/// Push string on the stack
export fn bz_pushString(self: *VM, value: *ObjString) void {
    self.push(value.toValue());
}

/// Push list on the stack
export fn bz_pushList(self: *VM, value: *ObjList) void {
    self.push(value.toValue());
}

/// Push a uesrdata value on the stack
export fn bz_pushUserData(self: *VM, value: *ObjUserData) void {
    self.push(value.toValue());
}

/// Converts a value to a string
export fn bz_valueToString(value: Value, len: *usize) ?[*]const u8 {
    if (!value.isObj() or value.obj().obj_type != .String) {
        return null;
    }

    const string = ObjString.cast(value.obj()).?.string;

    len.* = string.len;

    return if (string.len > 0) @ptrCast([*]const u8, string) else null;
}

/// Dump value
export fn bz_valueDump(value_ptr: *const Value, vm: *VM) void {
    const value = value_ptr.*;

    if (!value.isObj()) {
        const string = valueToStringAlloc(vm.gc.allocator, value) catch "";
        defer vm.gc.allocator.free(string);

        std.debug.print("{s}", .{string});
    } else {
        switch (value.obj().obj_type) {
            .Type,
            .Closure,
            .Function,
            .Bound,
            .Native,
            .UserData,
            .Fiber,
            .EnumInstance,
            => {
                const string = valueToStringAlloc(vm.gc.allocator, value) catch "";
                defer vm.gc.allocator.free(string);

                std.debug.print("{s}", .{string});
            },

            .UpValue => {
                const upvalue = ObjUpValue.cast(value.obj()).?;

                bz_valueDump(if (upvalue.closed != null) &upvalue.closed.? else upvalue.location, vm);
            },

            .String => {
                const string = ObjString.cast(value.obj()).?;

                std.debug.print("\"{s}\"", .{string.string});
            },

            .Pattern => {
                const pattern = ObjPattern.cast(value.obj()).?;

                std.debug.print("_{s}_", .{pattern.source});
            },

            .List => {
                const list = ObjList.cast(value.obj()).?;

                std.debug.print("[ ", .{});
                for (list.items.items) |item| {
                    bz_valueDump(&item, vm);
                    std.debug.print(", ", .{});
                }
                std.debug.print("]", .{});
            },

            .Map => {
                const map = ObjMap.cast(value.obj()).?;

                std.debug.print("{{ ", .{});
                var it = map.map.iterator();
                while (it.next()) |kv| {
                    const key = kv.key_ptr.*;

                    bz_valueDump(&key, vm);
                    std.debug.print(": ", .{});
                    bz_valueDump(kv.value_ptr, vm);
                    std.debug.print(", ", .{});
                }
                std.debug.print("}}", .{});
            },

            .Enum => {
                const enumeration = ObjEnum.cast(value.obj()).?;
                const enum_type_def = enumeration.type_def.resolved_type.?.Enum;

                std.debug.print("enum({s}) {s} {{ ", .{ enum_type_def.name.string, enumeration.name.string });
                for (enum_type_def.cases.items) |case, i| {
                    std.debug.print("{s} -> ", .{case});
                    bz_valueDump(&enumeration.cases.items[i], vm);
                    std.debug.print(", ", .{});
                }
                std.debug.print("}}", .{});
            },

            .Object => {
                const object = ObjObject.cast(value.obj()).?;
                const object_def = object.type_def.resolved_type.?.Object;

                std.debug.print("object", .{});
                if (object_def.conforms_to.count() > 0) {
                    std.debug.print("(", .{});
                    var it = object_def.conforms_to.iterator();
                    while (it.next()) |kv| {
                        std.debug.print("{s}, ", .{kv.key_ptr.*.resolved_type.?.Protocol.name.string});
                    }
                    std.debug.print(")", .{});
                }

                std.debug.print("{s} {{ ", .{object_def.name.string});

                var it = object_def.static_fields.iterator();
                while (it.next()) |kv| {
                    const static_field_type_str = kv.value_ptr.*.toStringAlloc(vm.gc.allocator) catch "";
                    defer vm.gc.allocator.free(static_field_type_str);

                    std.debug.print("static {s} {s}", .{ static_field_type_str, kv.key_ptr.* });

                    var static_it = object.static_fields.iterator();
                    while (static_it.next()) |static_kv| {
                        if (std.mem.eql(u8, static_kv.key_ptr.*.string, kv.key_ptr.*)) {
                            std.debug.print(" = ", .{});
                            bz_valueDump(&static_kv.value_ptr.*, vm);
                            break;
                        }
                    }

                    std.debug.print(", ", .{});
                }

                it = object_def.fields.iterator();
                while (it.next()) |kv| {
                    const field_type_str = kv.value_ptr.*.toStringAlloc(vm.gc.allocator) catch "";
                    defer vm.gc.allocator.free(field_type_str);

                    std.debug.print("{s} {s}", .{ field_type_str, kv.key_ptr.* });

                    var field_it = object.fields.iterator();
                    while (field_it.next()) |field_kv| {
                        if (std.mem.eql(u8, field_kv.key_ptr.*.string, kv.key_ptr.*)) {
                            std.debug.print(" = ", .{});
                            bz_valueDump(&field_kv.value_ptr.*, vm);
                            break;
                        }
                    }

                    std.debug.print(", ", .{});
                }

                it = object_def.methods.iterator();
                while (it.next()) |kv| {
                    const method_type_str = kv.value_ptr.*.toStringAlloc(vm.gc.allocator) catch "";
                    defer vm.gc.allocator.free(method_type_str);

                    std.debug.print("{s}, ", .{method_type_str});
                }

                std.debug.print("}}", .{});
            },

            .ObjectInstance => {
                const object_instance = ObjObjectInstance.cast(value.obj()).?;

                std.debug.print("{s}{{ ", .{if (object_instance.object) |object| object.type_def.resolved_type.?.Object.name.string else "."});
                var it = object_instance.fields.iterator();
                while (it.next()) |kv| {
                    std.debug.print("{s} = ", .{kv.key_ptr.*.string});
                    bz_valueDump(kv.value_ptr, vm);
                    std.debug.print(", ", .{});
                }
                std.debug.print("}}", .{});
            },
        }
    }
}

export fn bz_valueToUserData(value: Value) *UserData {
    return ObjUserData.cast(value.obj()).?.userdata;
}

// Obj manipulations

/// Converts a c string to a *ObjString
export fn bz_string(vm: *VM, string: ?[*]const u8, len: usize) ?*ObjString {
    return (if (string) |ustring| vm.gc.copyString(ustring[0..len]) else vm.gc.copyString("")) catch null;
}

/// ObjString -> [*]const u8 + len
export fn bz_objStringToString(obj_string: *ObjString, len: *usize) ?[*]const u8 {
    len.* = obj_string.string.len;

    return if (obj_string.string.len > 0) @ptrCast([*]const u8, obj_string.string) else null;
}

/// ObjString -> Value
export fn bz_objStringToValue(obj_string: *ObjString) Value {
    return obj_string.toValue();
}

export fn bz_objStringConcat(vm: *VM, obj_string: Value, other: Value) Value {
    return (ObjString.cast(obj_string.obj()).?.concat(
        vm,
        ObjString.cast(other.obj()).?,
    ) catch @panic("Could not concat strings")).toValue();
}

export fn bz_toString(vm: *VM, value: Value) Value {
    const str = valueToStringAlloc(vm.gc.allocator, value) catch {
        @panic("Could not convert value to string");
    };
    defer vm.gc.allocator.free(str);

    return Value.fromObj(
        (vm.gc.copyString(str) catch {
            @panic("Could not convert value to string");
        }).toObj(),
    );
}

// Other stuff

// Type helpers

// TODO: should always return the same instance
/// Returns the [bool] type
export fn bz_boolType() ?*ObjTypeDef {
    var bool_type: ?*ObjTypeDef = allocator.create(ObjTypeDef) catch null;

    if (bool_type == null) {
        return null;
    }

    bool_type.?.* = ObjTypeDef{ .def_type = .Bool, .optional = false };

    return bool_type;
}

/// Returns the [str] type
export fn bz_stringType() Value {
    const bool_type = allocator.create(ObjTypeDef) catch @panic("Could not create type");

    bool_type.* = ObjTypeDef{ .def_type = .String, .optional = false };

    return bool_type.toValue();
}

/// Returns the [void] type
export fn bz_voidType() ?*ObjTypeDef {
    var void_type: ?*ObjTypeDef = allocator.create(ObjTypeDef) catch null;

    if (void_type == null) {
        return null;
    }

    void_type.?.* = ObjTypeDef{ .def_type = .Void, .optional = false };

    return void_type;
}

export fn bz_allocated(self: *VM) usize {
    return self.gc.bytes_allocated;
}

export fn bz_collect(self: *VM) bool {
    self.gc.collectGarbage() catch {
        return false;
    };

    return true;
}

export fn bz_newList(vm: *VM, of_type: Value) Value {
    var list_def: ObjList.ListDef = ObjList.ListDef.init(
        vm.gc.allocator,
        ObjTypeDef.cast(of_type.obj()).?,
    );

    var list_def_union: ObjTypeDef.TypeUnion = .{
        .List = list_def,
    };

    var list_def_type: *ObjTypeDef = vm.gc.type_registry.getTypeDef(ObjTypeDef{
        .def_type = .List,
        .optional = false,
        .resolved_type = list_def_union,
    }) catch @panic("Could not create list");

    return (vm.gc.allocateObject(
        ObjList,
        ObjList.init(vm.gc.allocator, list_def_type),
    ) catch @panic("Could not create list")).toValue();
}

export fn bz_listAppend(vm: *VM, list: Value, value: Value) void {
    ObjList.cast(list.obj()).?.rawAppend(vm.gc, value) catch @panic("Could not add element to list");
}

export fn bz_valueToList(value: Value) *ObjList {
    return ObjList.cast(value.obj()).?;
}

export fn bz_listGet(self: Value, index: usize) Value {
    return ObjList.cast(self.obj()).?.items.items[index];
}

export fn bz_listSet(vm: *VM, self: Value, index: usize, value: Value) void {
    ObjList.cast(self.obj()).?.set(
        vm.gc,
        index,
        value,
    ) catch @panic("Could not set element in list");
}

export fn bz_listLen(self: *ObjList) usize {
    return self.items.items.len;
}

export fn bz_listMethod(vm: *VM, list: Value, member: [*]const u8, member_len: usize) Value {
    return (ObjList.cast(list.obj()).?.member(vm, bz_string(vm, member, member_len).?) catch @panic("Could not get list method")).?.toValue();
}

export fn bz_listConcat(vm: *VM, list: Value, other_list: Value) Value {
    const left: *ObjList = ObjList.cast(list.obj()).?;
    const right: *ObjList = ObjList.cast(other_list.obj()).?;

    var new_list = std.ArrayList(Value).init(vm.gc.allocator);
    new_list.appendSlice(left.items.items) catch @panic("Could not concatenate lists");
    new_list.appendSlice(right.items.items) catch @panic("Could not concatenate lists");

    return (vm.gc.allocateObject(
        ObjList,
        ObjList{
            .type_def = left.type_def,
            .methods = left.methods,
            .items = new_list,
        },
    ) catch @panic("Could not concatenate lists")).toValue();
}

export fn bz_mapConcat(vm: *VM, map: Value, other_map: Value) Value {
    const left: *ObjMap = ObjMap.cast(map.obj()).?;
    const right: *ObjMap = ObjMap.cast(other_map.obj()).?;

    var new_map = left.map.clone() catch @panic("Could not concatenate maps");
    var it = right.map.iterator();
    while (it.next()) |entry| {
        new_map.put(entry.key_ptr.*, entry.value_ptr.*) catch @panic("Could not concatenate maps");
    }

    return (vm.gc.allocateObject(ObjMap, ObjMap{
        .type_def = left.type_def,
        .methods = left.methods,
        .map = new_map,
    }) catch @panic("Could not concatenate maps")).toValue();
}

export fn bz_newUserData(vm: *VM, userdata: *UserData) ?*ObjUserData {
    return vm.gc.allocateObject(
        ObjUserData,
        ObjUserData{ .userdata = userdata },
    ) catch {
        return null;
    };
}

export fn bz_getUserData(userdata: *ObjUserData) *UserData {
    return userdata.userdata;
}

export fn bz_userDataToValue(userdata: *ObjUserData) Value {
    return userdata.toValue();
}

// Like bz_throw but assumes the error payload is already on the stack
export fn bz_rethrow(vm: *VM) void {
    // Are we in a JIT compiled function and within a try-catch?
    if (vm.currentFrame().?.in_native_call and vm.current_fiber.try_context != null) {
        const try_context = vm.current_fiber.try_context.?;

        jmp.longjmp(try_context.env, 1);

        unreachable;
    }
}

export fn bz_throw(vm: *VM, value: Value) void {
    vm.push(value);

    bz_rethrow(vm);
}

export fn bz_throwString(vm: *VM, message: ?[*]const u8, len: usize) void {
    bz_pushString(vm, bz_string(vm, message.?, len) orelse {
        _ = std.io.getStdErr().write((message.?)[0..len]) catch unreachable;
        std.os.exit(1);
    });
}

export fn bz_newVM(self: *VM) ?*VM {
    var vm = self.gc.allocator.create(VM) catch {
        return null;
    };
    var gc = self.gc.allocator.create(GarbageCollector) catch {
        return null;
    };
    // FIXME: should share strings between gc
    gc.* = GarbageCollector.init(self.gc.allocator);
    gc.type_registry = TypeRegistry{
        .gc = gc,
        .registry = std.StringHashMap(*ObjTypeDef).init(self.gc.allocator),
    };

    // FIXME: give reference to JIT?
    vm.* = VM.init(gc, self.import_registry, self.testing) catch {
        return null;
    };

    return vm;
}

export fn bz_deinitVM(_: *VM) void {
    // self.deinit();
}

export fn bz_getGC(vm: *VM) *memory.GarbageCollector {
    return vm.gc;
}

export fn bz_compile(self: *VM, source: ?[*]const u8, source_len: usize, file_name: ?[*]const u8, file_name_len: usize) ?*ObjFunction {
    if (source == null or file_name_len == 0 or source_len == 0 or file_name_len == 0) {
        return null;
    }

    var imports = std.StringHashMap(Parser.ScriptImport).init(self.gc.allocator);
    var strings = std.StringHashMap(*ObjString).init(self.gc.allocator);
    var parser = Parser.init(self.gc, &imports, false);
    var codegen = CodeGen.init(self.gc, &parser, false);
    defer {
        codegen.deinit();
        imports.deinit();
        parser.deinit();
        strings.deinit();
        // FIXME: fails
        // gc.deinit();
        // self.gc.allocator.destroy(self.gc);
    }

    if (parser.parse(source.?[0..source_len], file_name.?[0..file_name_len]) catch null) |function_node| {
        return function_node.toByteCode(function_node, &codegen, null) catch null;
    } else {
        return null;
    }
}

export fn bz_interpret(self: *VM, function: *ObjFunction) bool {
    self.interpret(function, null) catch {
        return false;
    };

    return true;
}

pub export fn bz_call(self: *VM, closure: *ObjClosure, arguments: [*]const *const Value, len: u8, catch_value: ?*Value) void {
    self.push(closure.toValue());
    var i: usize = 0;
    while (i < len) : (i += 1) {
        self.push(arguments[i].*);
    }

    // TODO: catch properly
    self.callValue(closure.toValue(), len, if (catch_value) |v| v.* else null) catch unreachable;

    self.run();
}

// Assumes the global exists
export fn bz_pushError(self: *VM, qualified_name: [*]const u8, len: usize) void {
    const object = bz_getQualified(self, qualified_name, len);

    self.push(
        // Dismiss error because if we fail to create the error payload there's not much to salvage anyway
        (self.gc.allocateObject(
            ObjObjectInstance,
            ObjObjectInstance.init(self.gc.allocator, ObjObject.cast(object.obj()).?, null),
        ) catch unreachable).toValue(),
    );
}

export fn bz_pushErrorEnum(self: *VM, qualified_name: [*]const u8, name_len: usize, case: [*]const u8, case_len: usize) void {
    const enum_set = ObjEnum.cast(bz_getQualified(self, qualified_name, name_len).obj()).?;

    self.push(
        bz_getEnumCase(enum_set, self, case, case_len).?.toValue(),
    );
}

export fn bz_getQualified(self: *VM, qualified_name: [*]const u8, len: usize) Value {
    for (self.globals.items) |global| {
        if (global.isObj()) {
            switch (global.obj().obj_type) {
                .Enum => {
                    const obj_enum = ObjEnum.cast(global.obj()).?;

                    if (std.mem.eql(u8, qualified_name[0..len], obj_enum.type_def.resolved_type.?.Enum.qualified_name.string)) {
                        return global;
                    }
                },
                .Object => {
                    const obj_enum = ObjObject.cast(global.obj()).?;

                    if (std.mem.eql(u8, qualified_name[0..len], obj_enum.type_def.resolved_type.?.Object.qualified_name.string)) {
                        return global;
                    }
                },
                else => {},
            }
        }
    }

    unreachable;
}

export fn bz_instance(self: *ObjObject, vm: *VM) ?*ObjObjectInstance {
    return vm.gc.allocateObject(
        ObjObjectInstance,
        ObjObjectInstance.init(vm.gc.allocator, self, null),
    ) catch null;
}

export fn bz_valueToObject(value: Value) *ObjObject {
    return ObjObject.cast(value.obj()).?;
}

export fn bz_pushObjectInstance(vm: *VM, payload: *ObjObjectInstance) void {
    vm.push(payload.toValue());
}

export fn bz_getEnumCase(self: *ObjEnum, vm: *VM, case: [*]const u8, len: usize) ?*ObjEnumInstance {
    var case_index: usize = 0;

    for (self.type_def.resolved_type.?.Enum.cases.items) |enum_case, index| {
        if (std.mem.eql(u8, case[0..len], enum_case)) {
            case_index = index;
            break;
        }
    }

    return vm.gc.allocateObject(
        ObjEnumInstance,
        ObjEnumInstance{
            .enum_ref = self,
            .case = @intCast(u8, case_index),
        },
    ) catch null;
}

export fn bz_pushEnumInstance(vm: *VM, payload: *ObjEnumInstance) void {
    vm.push(payload.toValue());
}

export fn bz_jitFunction(self: *VM, closure: *ObjClosure) void {
    if (closure.function.native == null) {
        const compiled = self.jit.jitFunction(closure) catch {
            @panic("Error while compiling function to machine code");
        };

        closure.function.native = compiled[0];
        closure.function.native_raw = compiled[1];
    }
}

export fn bz_valueIsBuzzFn(value: Value) bool {
    if (!value.isObj()) {
        return false;
    }

    if (ObjClosure.cast(value.obj())) |closure| {
        return closure.function.native == null;
    }

    return false;
}

export fn bz_valueToClosure(value: Value) *ObjClosure {
    return ObjClosure.cast(value.obj()).?;
}

export fn bz_toObjNative(value: Value) *ObjNative {
    return ObjNative.cast(value.obj()).?;
}

export fn bz_toObjNativeOpt(value: Value) ?*ObjNative {
    return ObjNative.cast(value.obj());
}

export fn bz_valueToRawNativeFn(value: u64) *anyopaque {
    return ObjNative.cast((Value{ .val = value }).obj()).?.native_raw;
}

export fn bz_valueEqual(self: Value, other: Value) Value {
    return Value.fromBoolean(_value.valueEql(self, other));
}

export fn bz_newMap(vm: *VM, map_type: Value) Value {
    var map: *ObjMap = vm.gc.allocateObject(ObjMap, ObjMap.init(
        vm.gc.allocator,
        ObjTypeDef.cast(map_type.obj()).?,
    )) catch @panic("Could not create map");

    return Value.fromObj(map.toObj());
}

export fn bz_mapSet(vm: *VM, map: Value, key: Value, value: Value) void {
    ObjMap.cast(map.obj()).?.set(
        vm.gc,
        key,
        value,
    ) catch @panic("Could not set map element");
}

export fn bz_mapGet(map: Value, key: Value) Value {
    return ObjMap.cast(map.obj()).?.map.get(_value.floatToInteger(key)) orelse Value.Null;
}

export fn bz_mapMethod(vm: *VM, map: Value, member: [*]const u8, member_len: usize) Value {
    return (ObjMap.cast(map.obj()).?.member(vm, bz_string(vm, member, member_len).?) catch @panic("Could not get map method")).?.toValue();
}

export fn bz_valueIs(self: Value, type_def: Value) Value {
    return Value.fromBoolean(_value.valueIs(type_def, self));
}

export fn bz_setTryCtx(self: *VM, env: *jmp.jmp_buf) c_int {
    var try_ctx = self.gc.allocator.create(TryCtx) catch @panic("Could not create try context");
    try_ctx.* = .{
        .previous = self.current_fiber.try_context,
        .env = env,
    };

    self.current_fiber.try_context = try_ctx;

    return jmp.setjmp(env);
}

export fn bz_popTryCtx(self: *VM) void {
    if (self.current_fiber.try_context) |try_ctx| {
        self.current_fiber.try_context = try_ctx.previous;
    }
}
