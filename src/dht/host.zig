const std = @import("std");
const message = @import("message.zig");
const cbor = @import("cbor.zig");
const routing_table = @import("routing_table.zig");
const DhtRoutingTable = routing_table.DhtRoutingTable;
const DhtKey = message.DhtKey;
const DhtNodeId = message.DhtNodeId;
const DhtNodeEntry = message.DhtNodeEntry;
const DhtMessage = message.DhtMessage;
const DhtRequest = message.DhtRequest;
const DhtResponse = message.DhtResponse;
const CborCodec = cbor.CborCodec;

/// A Dht Host Observer
pub const DhtHostObserver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onPing: *const fn (ptr: *anyopaque, node: *DhtHost, sender: DhtNodeId) void,
        onGet: *const fn (ptr: *anyopaque, node: *DhtHost, sender: DhtNodeId, key: DhtKey) void,
        onPut: *const fn (ptr: *anyopaque, node: *DhtHost, sender: DhtNodeId, key: DhtKey, value: []const u8, signature: []u8, seq: i32) void,
        onFindNode: *const fn (ptr: *anyopaque, node: *DhtHost, sender: DhtNodeId, target: DhtNodeId) void,
        onPong: *const fn (ptr: *anyopaque, node: *DhtHost, from: DhtNodeId) void,
        onPutOk: *const fn (ptr: *anyopaque, node: *DhtHost, from: DhtNodeId) void,
        onNodesFound: *const fn (ptr: *anyopaque, node: *DhtHost, nodes: []const DhtNodeEntry) void,
        onValueFound: *const fn (ptr: *anyopaque, node: *DhtHost, value: []const u8) void,
        onBootstrap: *const fn (ptr: *anyopaque, node: *DhtHost) void,
        onError: *const fn (ptr: *anyopaque, node: *DhtHost, err: anyerror) void,
    };

    pub fn init(ptr: anytype) DhtHostObserver {
        const T = @TypeOf(ptr);
        const PtrInfo = @typeInfo(T);

        comptime if (PtrInfo != .Pointer) @compileError("Expected pointer");

        const Child = PtrInfo.Pointer.child;

        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .onPing = @ptrCast(&Child.onPing),
                .onPut = @ptrCast(&Child.onPut),
                .onFindNode = @ptrCast(&Child.onFindNode),
                .onGet = @ptrCast(&Child.onGet),
                .onPong = @ptrCast(&Child.onPong),
                .onPutOk = @ptrCast(&Child.onPutOk),
                .onNodesFound = @ptrCast(&Child.onNodesFound),
                .onValueFound = @ptrCast(&Child.onValueFound),
                .onBootstrap = @ptrCast(&Child.onBootstrap),
                .onError = @ptrCast(&Child.onError),
            },
        };
    }

    // onPing - called when a ping message arrives
    pub fn onPing(self: DhtHostObserver, node: *DhtHost, sender: DhtNodeId) void {
        self.vtable.onPing(self.ptr, node, sender);
    }

    // onGet - called when a get value message arrives
    pub fn onGet(self: DhtHostObserver, node: *DhtHost, sender: DhtNodeId, key: DhtKey) void {
        self.vtable.onGet(self.ptr, node, sender, key);
    }

    // onPut - called when a put message arrives
    pub fn onPut(self: DhtHostObserver, node: *DhtHost, sender: DhtNodeId, key: DhtKey, value: []const u8, signature: []u8, seq: i32) void {
        self.vtable.onPut(self.ptr, node, sender, key, value, signature, seq);
    }

    // onFindNode - called when a find node message arrives
    pub fn onFindNode(self: DhtHostObserver, node: *DhtHost, sender: DhtNodeId, target: DhtNodeId) void {
        self.vtable.onFindNode(self.ptr, node, sender, target);
    }

    // replies

    pub fn onPong(self: DhtHostObserver, node: *DhtHost, from: DhtNodeId) void {
        _ = self;
        _ = node;
        _ = from;
    }

    pub fn onPutOk(self: DhtHostObserver, node: *DhtHost, from: DhtNodeId) void {
        _ = self;
        _ = node;
        _ = from;
    }

    pub fn onNodesFound(self: DhtHostObserver, node: *DhtHost, nodes: []const DhtNodeEntry) void {
        _ = self;
        _ = node;
        _ = nodes;
    }

    pub fn onValueFound(self: DhtHostObserver, node: *DhtHost, value: []const u8) void {
        _ = self;
        _ = node;
        _ = value;
    }

    // TODO: which parameters to give back
    pub fn onBootstrap(self: DhtHostObserver, node: *DhtHost) void {
        _ = self;
        _ = node;
    }

    pub fn onError(self: DhtHostObserver, node: *DhtHost) void {
        _ = self;
        _ = node;
    }
};

/// A Dht Host - a local peer host/server
pub const DhtHost = struct {
    allocator: std.mem.Allocator,
    node: DhtNodeEntry, // we are a node too
    observers: std.ArrayList(*DhtHostObserver),
    codec: CborCodec,
    routingTable: DhtRoutingTable,

    pub fn init(allocator: std.mem.Allocator, id: DhtNodeId) DhtHost {
        return .{
            .allocator = allocator,
            .node = .{
                .id = id,
                // FIXME: provide real address
                .addr = try std.net.Address.parseIp4("127.0.0.1", 1010),
            },
            .observers = std.ArrayList(*DhtHostObserver).initCapacity(allocator, 2),
            .codec = CborCodec.init(),
            .routingTable = DhtRoutingTable.init(),
        };
    }

    pub fn addObserver(self: *DhtHost, observer: *DhtHostObserver) void {
        self.observers.append(self.allocator, observer);
    }

    pub fn removeObserver(self: *DhtHost, observer: *DhtHostObserver) void {
        for (self.observers.items, 0..) |item, i| {
            if (observer == item) {
                self.observers.swapRemove(i);
            }
        }
    }

    /// Bootstrap the DhtHost to connect to the mainline Dht
    pub fn bootstrap(self: *DhtHost, seeds: []const std.net.Address) !void {
        _ = self;
        _ = seeds;
    }

    // fn processRequest(self: *DhtHost, sender: DhtNodeId, req: DhtRequest) DhtResponse {
    //     return switch (req) {
    //         .ping => .{ .pong = {} },
    //         .find_node => |r| .{ .nodes = .{ .nodes = self.findClosest(r.target) } },
    //         // ...
    //     };
    // }

    /// process a bytestream received from the network
    /// this is called from the IO thread
    pub fn onPacketReceived(self: *DhtHost, from: std.net.Address, data: []const u8) !void {
        _ = self;
        _ = from;
        _ = data;
        // try to decode as a dht message
        // const msg = try self.codec.decode(data);
        // enqueue to the worker.
        // FIXME: check how modern zig is doing concurrency

        // we should post this to the worker thread
        // and the worker thread would
        // a) prepare a IOMessage
        // b) call processMessage()

        // self.channel.post(&self.processMessage, self, msg);
    }

    // Process a broker message
    // called from a worker thread

    // pub fn processIOMessage(self: *DhtHost, msg: IOMessage) !void {
    //     switch (msg.task) {
    //         .message_received => |dht_msg| self.onMessageReceived(dht_msg),
    //     }
    // }

    pub fn onMessageReceived(self: *DhtHost, msg: DhtMessage) void {
        switch (msg.payload) {
            .request => |req| {
                // Requests need responses - dispatch to handler
                const response = self.handleRequest(msg.sender_id, req);
                self.sendResponse(msg.transaction_id, msg.sender_id, response);
            },
            .response => |resp| {
                // Responses complete pending operations
                self.completePending(msg.transaction_id, resp);
            },
        }
    }

    fn handleRequest(self: *DhtHost, sender: DhtNodeId, req: DhtRequest) DhtResponse {
        // Update routing table - sender is a possible alive node
        // fixme: pass the ip endpoint
        self.routingTable.nodeIsAlive(sender);

        return switch (req) {
            .ping => self.ping(sender),
            .find_node => |r| self.findNode(sender, r.target),
            .find_value => |r| self.get(sender, r.key),
            .store => |r| self.put(sender, r.key, r.value, r.signature, r.seq),
        };
    }

    // ping - called when a ping message arrives
    pub fn ping(self: *DhtHost, sender: DhtNodeId) void {
        blk: {
            self.event_queue.push(.{ .ping_received = sender }) catch {};
            break :blk .{ .pong = {} };
        }
    }

    // get - get a value from the DHT with the given key
    pub fn get(self: *DhtHost, sender: DhtNodeId, key: DhtKey) void {
        _ = self;
        _ = sender;
        _ = key;
    }

    // put - set a value into the DHT with the given key
    pub fn put(self: *DhtHost, sender: DhtNodeId, key: DhtKey, value: []const u8, signature: []u8, seq: i32) void {
        _ = self;
        _ = sender;
        _ = key;
        _ = value;
        _ = signature;
        _ = seq;
        // self.storage.put(key, value);
        // self.event_queue.push(.{ .store_received = .{ .key = key, .value = value } }) catch {};
    }

    // findNode - find a given node by node id
    pub fn findNode(self: *DhtHost, sender: DhtNodeId, target: DhtNodeId) void {
        _ = self;
        _ = sender;
        _ = target;
        // const nodes = self.routing_table.findClosest(target);
    }
};
