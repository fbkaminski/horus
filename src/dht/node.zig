const std = @import("std");
const message = @import("message.zig");
const bencode = @import("bencode.zig");
const Key = message.Key;
const NodeId = message.NodeId;
const NodeInfo = message.NodeInfo;
const DhtMessage = message.DhtMessage;
const DhtRequest = message.DhtRequest;
const DhtResponse = message.DhtResponse;
const BencodeCodec = bencode.BencodeCodec;

/// A Dht Node Observer
pub const DhtNodeObserver = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onPing: *const fn (ptr: *anyopaque, node: *DhtNode) void,
        onStore: *const fn (ptr: *anyopaque, node: *DhtNode, key: Key, value: []const u8) void,
        onFindNode: *const fn (ptr: *anyopaque, node: *DhtNode, target: NodeId) void,
        onFindValue: *const fn (ptr: *anyopaque, node: *DhtNode, key: Key) void,
        onPong: *const fn (ptr: *anyopaque, node: *DhtNode, from: NodeId) void,
        onNodesFound: *const fn (ptr: *anyopaque, node: *DhtNode, nodes: []const NodeInfo) void,
        onValueFound: *const fn (ptr: *anyopaque, node: *DhtNode, value: []const u8) void,
        onBootstrap: *const fn (ptr: *anyopaque, node: *DhtNode) void,
        onError: *const fn (ptr: *anyopaque, node: *DhtNode, err: anyerror) void,
    };

    pub fn init(ptr: anytype) DhtNodeObserver {
        const T = @TypeOf(ptr);
        const PtrInfo = @typeInfo(T);

        comptime if (PtrInfo != .Pointer) @compileError("Expected pointer");

        const Child = PtrInfo.Pointer.child;

        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .onPing = @ptrCast(&Child.onPing),
                .onStore = @ptrCast(&Child.onStore),
                .onFindNode = @ptrCast(&Child.onFindNode),
                .onFindValue = @ptrCast(&Child.onFindValue),
                .onPong = @ptrCast(&Child.onPong),
                .onNodesFound = @ptrCast(&Child.onNodesFound),
                .onValueFound = @ptrCast(&Child.onValueFound),
                .onBootstrap = @ptrCast(&Child.onBootstrap),
                .onError = @ptrCast(&Child.onError),
            },
        };
    }

    pub fn onPing(self: DhtNodeObserver, node: *DhtNode) void {
        self.vtable.onPing(self.ptr, node);
    }

    // onStore - called when a store message arrives
    pub fn onStore(self: DhtNodeObserver, node: *DhtNode, key: Key, value: []const u8) void {
        self.vtable.onStore(self.ptr, node, key, value);
    }

    // onFindNode - called when a find node message arrives
    pub fn onFindNode(self: DhtNodeObserver, node: *DhtNode, target: NodeId) void {
        _ = self;
    }

    // onFindValue - called when a find value message arrives
    pub fn onFindValue(self: DhtNodeObserver, node: *DhtNode, key: Key) void {
        _ = self;
    }

    pub fn onPong(self: DhtNodeObserver, node: *DhtNode, from: NodeId) void {}

    pub fn onNodesFound(self: DhtNodeObserver, node: *DhtNode, nodes: []const NodeInfo) void {}

    pub fn onValueFound(self: DhtNodeObserver, node: *DhtNode, value: []const u8) void {}

    // TODO: which parameters to give back
    pub fn onBootstrap(self: DhtNodeObserver, node: *DhtNode) void {}

    pub fn onError(self: DhtNodeObserver, node: *DhtNode) void {
        _ = self;
    }
};

/// A Dht Node
pub const DhtNode = struct {
    id: NodeId,
    observer: DhtNodeObserver,
    codec: BencodeCodec,

    pub fn init(id: NodeId, observer: DhtNodeObserver) DhtNode {
        return .{
            .observer = observer,
            .codec = BencodeCodec.init(),
        };
    }

    /// Bootstrap the DhtNode to connect to the mainline Dht
    pub fn bootstrap(self: *DhtNode, seeds: []const std.net.Address) !void {}

    // fn processRequest(self: *DhtNode, sender: NodeId, req: DhtRequest) DhtResponse {
    //     return switch (req) {
    //         .ping => .{ .pong = {} },
    //         .find_node => |r| .{ .nodes = .{ .nodes = self.findClosest(r.target) } },
    //         // ...
    //     };
    // }

    /// process a bytestream received from the network
    /// this is called from the IO thread
    pub fn onPacketReceived(self: *DhtNode, from: std.net.Address, data: []const u8) !void {
        // try to decode as a dht message
        const msg = try self.codec.decode(data);
        // enqueue to the worker.
        // FIXME: check how modern zig is doing concurrency

        // we should post this to the worker thread
        // and the worker thread would
        // a) prepare a IOMessage
        // b) call processMessage()

        //self.channel.post(&self.processMessage, self, msg);
    }

    /// Process a broker message
    /// called from a worker thread
    pub fn processIOMessage(self: *DhtNode, msg: IOMessage) !void {
        switch (msg.task) {
            .message_received => |dht_msg| self.onMessageReceived(dht_msg),
        }
    }

    pub fn onMessageReceived(self: *DhtNode, message: DhtMessage) void {
        switch (message.payload) {
            .request => |req| {
                // Requests need responses - dispatch to handler
                const response = self.handleRequest(message.sender_id, req);
                self.sendResponse(message.transaction_id, message.sender_id, response);
            },
            .response => |resp| {
                // Responses complete pending operations
                self.completePending(message.transaction_id, resp);
            },
        }
    }

    fn handleRequest(self: *DhtNode, sender: NodeId, req: DhtRequest) DhtResponse {
        // Update routing table - sender is alive
        self.routing_table.touch(sender);

        return switch (req) {
            .ping => self.ping(sender),
            .get_peers => |r| self.getPeers(sender, r.info_hash, r.noseed, r.scrape, r.want),
            .find_node => |r| self.findNode(sender, r.target, r.want),
            .get => |r| self.get(sender, r.key, r.seq, r.want),
            .put => |r| self.put(sender, r.key, r.value, r.seq, r.pubkey, r.signature, r.cas, r.salt),
            .announce_peer => |r| self.announcePeer(sender, r.infohash, r.port, r.token, r.n, r.seed, r.implied_port),
        };
    }

    // ping - called when a ping message arrives
    pub fn ping(self: *DhtNode, sender: NodeId) void {
        blk: {
            self.event_queue.push(.{ .ping_received = sender }) catch {};
            break :blk .{ .pong = {} };
        }
    }

    pub fn getPeers(self: *DhtNode, info_hash: Key, noseed: ?bool, scrape: ?bool, want: ?[]NodeId) void {
        _ = self;
    }

    // findNode - find a given node by node id
    pub fn findNode(self: *DhtNode, sender: NodeId, target: NodeId, want: ?[]NodeId) void {
        _ = self;
        // const nodes = self.routing_table.findClosest(target);
    }

    // get - get a value from the DHT with the given key
    pub fn get(self: *DhtNode, sender: NodeId, key: Key, seq: ?i32, want: ?[]NodeId) void {
        _ = self;
    }

    // put - set a value into the DHT with the given key
    pub fn put(self: *DhtNode, sender: NodeId, key: Key, value: []const u8, seq: ?i32, pubkey: ?[]u8, signature: ?[]u8, cas: ?i32, salt: ?[]u8) void {
        _ = self;
        // self.storage.put(key, value);
        // self.event_queue.push(.{ .store_received = .{ .key = key, .value = value } }) catch {};
    }

    pub fn announcePeer(self: *DhtNode, infohash: Key, port: i16, token: []u8, n: ?[]u8, seed: ?i32, implied_port: ?i16) void {
        _ = self;
    }
};
