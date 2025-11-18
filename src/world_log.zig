const std = @import("std");
const main = @import("main");
const utils = @import("utils.zig");
const NeverFailingAllocator = main.heap.NeverFailingAllocator;

const LogMsg = union(enum) {
	inventory: struct {base_op: BaseOperation, sync_ops: []const SyncOperation},
};

var worldLogDir: std.fs.Dir = undefined;
var inventoryLogFile: std.fs.File = undefined;
var running: bool = false;

pub fn init(worldName: []const u8) void {
	if(running) return;
	running = true;
	const systemTimeString = utils.getCurrentSystemTime(main.stackAllocator.allocator);
	defer main.stackAllocator.free(systemTimeString);
	const worldLogPath = std.fmt.allocPrint(main.stackAllocator.allocator, "saves/{s}/worldLogs/{s}/", .{worldName, systemTimeString}) catch unreachable;
	defer main.stackAllocator.free(worldLogPath);
	const wdir = main.files.cubyzDir().openDir(worldLogPath) catch
		std.debug.panic("Couldn't open worldLogDir at {s}", .{worldLogPath});

	worldLogDir = wdir.dir;

	inventoryLogFile = worldLogDir.createFile("inventory_log.txt", .{}) catch
		std.debug.panic("Couldn't open inventoryLogFile at {s}{s}", .{worldLogPath, "inventoryLog.txt"});
}

pub fn deinit() void {
	if(running) {
		worldLogDir.close();
		inventoryLogFile.close();
	}
	running = false;
}

// Inventory Logging
const BaseOperation = main.items.Inventory.Command.BaseOperation;
const SyncOperation = main.items.Inventory.Command.SyncOperation;
const InventoryAndSlot = main.items.Inventory.Command.InventoryAndSlot;

fn logInventoryAndSlot(jw: *std.json.WriteStream(std.fs.File.DeprecatedWriter, .{.checked_to_fixed_depth = 256}), inventoryslot: InventoryAndSlot) !void {
	const invsource = inventoryslot.inv.source;
	try jw.beginObject();
	{
		try jw.objectField("slot_type");
		try jw.write(@tagName(invsource));
		switch(invsource) {
			.playerInventory, .hand => |user| {
				try jw.objectField("slot_info");
				try jw.write(if(user.userptr) |u| u.name else null);
			},
			.blockInventory => |blockpos| {
				try jw.objectField("slot_info");
				try jw.write(blockpos);
			},
			else => {},
		}
		try jw.objectField("slot_item");
		try jw.write(if(inventoryslot.ref().item) |item| item.id() else null);
		try jw.objectField("slot_amount");
		try jw.write(inventoryslot.ref().amount);
	}
	try jw.endObject();
}

fn logSyncOperation(jw: *std.json.WriteStream(std.fs.File.DeprecatedWriter, .{.checked_to_fixed_depth = 256}), sync_operation: SyncOperation) !void {
	try jw.beginObject();
	{
		try jw.objectField("syncop_type");
		try jw.write(@tagName(sync_operation));
		switch(sync_operation) {
			.create => |syncop_create| {
				try jw.objectField("syncop_item");
				try jw.write(if(syncop_create.item) |item| item.id() else null);
				try jw.objectField("syncop_amount");
				try jw.write(syncop_create.amount);
				try jw.objectField("syncop_slot");
				try logInventoryAndSlot(jw, syncop_create.inv);
			},
			.delete => |syncop_delete| {
				try jw.objectField("syncop_amount");
				try jw.write(syncop_delete.amount);
				try jw.objectField("syncop_slot");
				try logInventoryAndSlot(jw, syncop_delete.inv);
			},
			else => {},
		}
	}
	try jw.endObject();
}

fn logBaseOperation(jw: *std.json.WriteStream(std.fs.File.DeprecatedWriter, .{.checked_to_fixed_depth = 256}), base_operation: BaseOperation) !void {
	try jw.beginObject();
	{
		try jw.objectField("baseop_type");
		try jw.write(@tagName(base_operation));
		switch(base_operation) {
			.move => |baseop_move| {
				try jw.objectField("baseop_item");
				try jw.write(if(baseop_move.source.ref().item) |item| item.id() else null);
				try jw.objectField("baseop_amount");
				try jw.write(baseop_move.amount);
				try jw.objectField("source_slot");
				try logInventoryAndSlot(jw, baseop_move.source);
				try jw.objectField("dest_slot");
				try logInventoryAndSlot(jw, baseop_move.dest);
			},
			else => {},
		}
	}
	try jw.endObject();
}

pub fn logInventoryOperation(base_operation: BaseOperation, sync_operations: []SyncOperation) !void {
	// var buffer: [std.Thread.max_name_len:0]u8 = @splat(0);
	// const err = try std.posix.prctl(.GET_NAME, .{@intFromPtr(&buffer[0])});
	// switch (@as(std.posix.E, @enumFromInt(err))) {
	//     .SUCCESS => {
	//         const name = std.mem.sliceTo(&buffer, 0);
	//         std.debug.print("thread name: {s}\n", .{name});
	//     },
	//     else => {},
	// }

	const writer = inventoryLogFile.deprecatedWriter();
	var jw = std.json.writeStream(writer, .{.whitespace = .minified});
	try jw.beginObject();
	{
		try jw.objectField("baseop");
		try logBaseOperation(&jw, base_operation);
		try jw.objectField("syncops");
		try jw.beginArray();
		{
			for(sync_operations) |syncop| {
				try logSyncOperation(&jw, syncop);
			}
		}
		try jw.endArray();
	}
	try jw.endObject();
	_ = writer.write("\n") catch unreachable;
}
