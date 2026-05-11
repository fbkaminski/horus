const std = @import("std");
const builtin = @import("builtin");
const base = @import("../core/base.zig");
const platform_file = @import("platform.zig");
const thread_file = @import("../core/single_thread_task_runner.zig");
const thread_registry_file = @import("../core/thread_registry.zig");
const work_queue = @import("../core/work_queue.zig");
const service_file = @import("service.zig");
const channel_file = @import("../channel/channel.zig");
const named_channel_file = @import("../channel/named_process_channel.zig");
const io_buffer = @import("../net/io_buffer.zig");
const io_file = if (builtin.os.tag == .linux) @import("../io/linux.zig") else @import("../io/darwin.zig");
const IO = io_file.IO;
const IOBuffer = io_buffer.IOBuffer;
const SingleThreadTaskRunner = thread_file.SingleThreadTaskRunner;
const ThreadRegistry = thread_registry_file.ThreadRegistry;
const Task = base.Task;
const TaskQueue = base.TaskQueue;

const Platform = platform_file.Platform;
const ServiceHandle = service_file.ServiceHandle;
const ServiceId = service_file.ServiceId;
const CapToken = service_file.CapToken;
const InterfaceId = service_file.InterfaceId;
const Channel = channel_file.Channel;
const ChannelListener = channel_file.ChannelListener;
const ChannelListenerDelegate = channel_file.ChannelListenerDelegate;
const ChannelDelegate = channel_file.ChannelDelegate;
const NamedProcessChannel = named_channel_file.NamedProcessChannel;
const NamedProcessServerChannel = named_channel_file.NamedProcessServerChannel;

const SERVICE_MANAGER_SOCKET_PATH: []const u8 = "/tmp/dht_host.sock";

pub const ServiceManagerState = enum {
    init,
    running,
    stopped,
};

pub const ServiceManager = struct {
    allocator: std.mem.Allocator,
    task_runner: SingleThreadTaskRunner,
    services: std.AutoHashMap(ServiceId, ServiceHandle),
    last_service_id: ServiceId,
    server_channel: NamedProcessServerChannel,
    state: ServiceManagerState,
    clients: ClientContextPool,
    server_delegate: ChannelListenerDelegate,
    shutting_down: bool,

    pub fn init(self: *ServiceManager, allocator: std.mem.Allocator, thread_registry: *ThreadRegistry) !void {
        self.allocator = allocator;
        self.services = .init(allocator);
        self.last_service_id = 1000;
        self.state = .init;
        self.shutting_down = false;
        self.clients = try ClientContextPool.init(allocator);
        self.server_delegate = .{
            .ptr = self,
            .vtable = &delegate_vtable,
        };
        try self.task_runner.init(allocator, thread_registry, .service);
        try self.server_channel.init(allocator, SERVICE_MANAGER_SOCKET_PATH, &self.task_runner.io, &self.server_delegate);
    }

    pub fn start(self: *ServiceManager) !void {
        try self.task_runner.start(
            spawnOnThread,
            self,
        );
    }

    pub fn shutdown(self: *ServiceManager) void {
        self.task_runner.stop();
    }

    pub fn deinit(self: *ServiceManager) void {
        self.server_channel.close();
        self.task_runner.deinit();
        self.clients.deinit();
    }

    // register a new service and return the Service handler
    // FIXME: some form of service manifest, interface, etc ??
    pub fn registerService(self: *ServiceManager, interface_id: InterfaceId, capability: CapToken) !ServiceId {
        const service = try self.allocator.create(ServiceHandle);
        const serviceId = self.generateServiceId();
        service.id = serviceId;
        service.interface_id = interface_id;
        service.capability = capability;
        service.generation = 0;
        self.services.put(serviceId, service);
    }

    // revoke a service
    pub fn revokeService(self: *ServiceManager, id: ServiceId) void {
        self.services.remove(id);
    }

    fn spawnOnThread(self: *ServiceManager) !void {
        std.debug.assert(self.task_runner.isCurrentThread());
        try self.server_channel.serve();
        self.state = .running;
        try self.task_runner.run();
        self.state = .stopped;
    }

    fn generateServiceId(self: *ServiceManager) ServiceId {
        self.lastServiceId += 1;
        return self.lastServiceId;
    }

    fn onConnection(self: *ServiceManager, channel: *Channel) void {
        std.debug.assert(self.task_runner.isCurrentThread());
        std.log.info("ServiceManager.onConnection: new client connection", .{});
        const named_process_channel: *NamedProcessChannel = @fieldParentPtr("base", channel);
        const client_context = self.allocator.create(ClientContext) catch return;
        client_context.init(self, &self.task_runner, named_process_channel);
        // add into the pool
        self.clients.addClient(client_context) catch return;
    }

    fn onServerChannelClosed(self: *ServiceManager, server: *ChannelListener) void {
        std.log.info("ServiceManager.onServerChannelClosed: server closed the connection", .{});
        _ = server;
        _ = self;
    }

    fn onContextDone(self: *ServiceManager, client_context: *ClientContext) void {
        std.debug.assert(self.clients.removeClient(client_context));
        client_context.deinit(self.allocator);
        if (self.shutting_down) {
            const platform = Platform.get();
            if (platform) |p| p.shutdown() catch return;
        }
    }

    const delegate_vtable = ChannelListenerDelegate.VTable{
        .onConnection = struct {
            fn f(ptr: *anyopaque, server: *ChannelListener, channel: *Channel) void {
                _ = server;
                const self: *ServiceManager = @ptrCast(@alignCast(ptr));
                self.onConnection(channel);
            }
        }.f,
        .onClose = struct {
            fn f(ptr: *anyopaque, server: *ChannelListener) void {
                const self: *ServiceManager = @ptrCast(@alignCast(ptr));
                self.onServerChannelClosed(server);
            }
        }.f,
    };
};

const ClientContext = struct {
    service_manager: *ServiceManager,
    task_runner: *SingleThreadTaskRunner,
    channel: *NamedProcessChannel,
    read_cb: ReadCallback,
    write_buffer: *IOBuffer,
    delegate: ChannelDelegate,
    // a silly way of measuring pings
    ping: usize,

    pub fn init(self: *ClientContext, manager: *ServiceManager, task_runner: *SingleThreadTaskRunner, channel: *NamedProcessChannel) void {
        self.service_manager = manager;
        self.task_runner = task_runner;
        self.channel = channel;
        self.ping = 0;
        self.delegate = .{
            .ptr = self,
            .vtable = &delegate_vtable,
        };
        self.read_cb = .{
            .task = .{
                .callback = ReadCallback.callback,
            },
            .response_task = .{
                .callback = ReadCallback.responseCallback,
            },
            .node = .{
                .value = &self.read_cb.task,
            },
            .response_node = .{
                .value = &self.read_cb.response_task,
            },
            .context = self,
            .channel = channel,
            .buffer = null,
        };
        // define ourselves as the delegate of the client channel
        self.channel.setDelegate(&self.delegate);
        self.write_buffer = self.channel.connection.buffer_pool.acquire() catch return;
    }

    pub fn deinit(self: *ClientContext, allocator: std.mem.Allocator) void {
        self.channel.setDelegate(null);
        self.write_buffer.unref();
        self.channel.deinit();
        allocator.destroy(self);
    }

    fn onConnection(self: *ClientContext, client: *Channel) void {
        _ = self;
        _ = client;
        std.log.info("ClientContext.onConnection: connected.", .{});
    }

    fn onConnectionFailed(self: *ClientContext, client: *Channel, err: IO.ConnectError) void {
        _ = self;
        _ = client;
        std.log.info("ClientContext.onConnectionFailed: {}.", .{err});
    }

    fn onDisconnect(self: *ClientContext, client: *Channel) void {
        _ = self;
        _ = client;
        std.log.info("ClientContext.onDisconnect: client connection disconnected by the remote peer.", .{});
    }

    fn onConnectionClosed(self: *ClientContext, client: *Channel) void {
        std.debug.assert(self.task_runner.isCurrentThread());
        //std.debug.assert(client == self.channel);
        std.log.info("Service manager: client connection closed.", .{});
        //var named_client: *NamedProcessChannel = @ptrCast(client);
        //named_client.deinit();
        // this will clean ourselves
        self.service_manager.onContextDone(self);
        _ = client;
    }

    fn onReceive(self: *ClientContext, client: *Channel, buffer: *IOBuffer) void {
        _ = client;
        std.debug.assert(self.task_runner.isCurrentThread());
        //std.debug.assert(client == self.channel);
        self.read_cb.buffer = buffer;
        self.task_runner.postTaskTo(.workers, &self.read_cb.node);
    }

    fn onReceiveFailed(self: *ClientContext, client: *Channel, err: IO.RecvError) void {
        _ = self;
        _ = client;
        std.log.info("ClientContext.onReceiveFailed: {}", .{err});
    }

    fn onSend(self: *ClientContext, client: *Channel, sent: usize) void {
        _ = self;
        _ = client;
        std.log.info("ClientContext.onSend: sent {d} bytes", .{sent});
    }

    fn onSendFailed(self: *ClientContext, client: *Channel, err: IO.SendError) void {
        _ = self;
        _ = client;
        std.log.info("ClientContext.onSendFailed: {}", .{err});
    }

    fn processIncomingDataOnWorkerThread(self: *ClientContext, buffer: *IOBuffer) void {
        // we will use the buffer here
        std.log.info("Service manager: processing \"{s}\" on {d}", .{ buffer.readable(), std.Thread.getCurrentId() });
        // Note: here we are just testing things for now
        // and adjusting the socket lifetime
        // thats why this looks lame as of now :)
        const message = buffer.readable();
        const is_shutdown = (std.mem.eql(u8, message, "SHUTDOWN"));
        const is_ping = (std.mem.startsWith(u8, message, "PING"));
        if (is_ping) {
            self.ping += 1;
        } else if (is_shutdown) {
            self.service_manager.shutting_down = true;
        }
        buffer.unref();
        self.task_runner.postTaskTo(.service, &self.read_cb.response_node);
    }

    fn processIncomingDataReplyOnServiceThread(self: *ClientContext, client: *NamedProcessChannel) void {
        std.debug.assert(self.task_runner.isCurrentThread());
        std.log.info("Service manager: processing response on {d}\n", .{std.Thread.getCurrentId()});
        if (self.ping > 0) {
            self.write_buffer.write_pos = 0;
            @memcpy(self.write_buffer.writable()[0..4], "PONG");
            self.write_buffer.advance_write(4);
            client.connection.send(self.write_buffer);
            self.ping -= 1;
        }
    }

    const delegate_vtable = ChannelDelegate.VTable{
        .onConnection = struct {
            fn f(ptr: *anyopaque, channel: *Channel) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onConnection(channel);
            }
        }.f,
        .onConnectionFailed = struct {
            fn f(ptr: *anyopaque, channel: *Channel, err: IO.ConnectError) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onConnectionFailed(channel, err);
            }
        }.f,
        .onConnectionClosed = struct {
            fn f(ptr: *anyopaque, channel: *Channel) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onConnectionClosed(channel);
            }
        }.f,
        .onDisconnect = struct {
            fn f(ptr: *anyopaque, channel: *Channel) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onDisconnect(channel);
            }
        }.f,
        .onReceive = struct {
            fn f(ptr: *anyopaque, channel: *Channel, buffer: *IOBuffer) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onReceive(channel, buffer);
            }
        }.f,
        .onReceiveFailed = struct {
            fn f(ptr: *anyopaque, channel: *Channel, err: IO.RecvError) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onReceiveFailed(channel, err);
            }
        }.f,
        .onSend = struct {
            fn f(ptr: *anyopaque, channel: *Channel, sent: usize) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onSend(channel, sent);
            }
        }.f,
        .onSendFailed = struct {
            fn f(ptr: *anyopaque, channel: *Channel, err: IO.SendError) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onSendFailed(channel, err);
            }
        }.f,
    };

    const ReadCallback = struct {
        task: Task,
        node: TaskQueue.Node = .{ .value = undefined },
        response_task: Task,
        response_node: TaskQueue.Node = .{ .value = undefined },
        context: *ClientContext,
        channel: *NamedProcessChannel,
        buffer: ?*IOBuffer,

        fn callback(task: *Task) void {
            const self: *ReadCallback = @fieldParentPtr("task", task);
            self.context.processIncomingDataOnWorkerThread(self.buffer.?);
        }

        fn responseCallback(t: *Task) void {
            const self: *ReadCallback = @fieldParentPtr("response_task", t);
            self.context.processIncomingDataReplyOnServiceThread(self.channel);
        }
    };
};

const ClientContextPool = struct {
    allocator: std.mem.Allocator,
    clients: std.ArrayList(*ClientContext),

    pub fn init(allocator: std.mem.Allocator) !ClientContextPool {
        return .{
            .allocator = allocator,
            .clients = try std.ArrayList(*ClientContext).initCapacity(allocator, 10),
        };
    }

    pub fn deinit(self: *ClientContextPool) void {
        self.clients.deinit(self.allocator);
    }

    pub fn addClient(self: *ClientContextPool, client: *ClientContext) !void {
        try self.clients.append(self.allocator, client);
    }

    pub fn removeClient(self: *ClientContextPool, client: *ClientContext) bool {
        var removed = false;
        for (self.clients.items, 0..) |item, i| {
            if (client == item) {
                const ref = self.clients.swapRemove(i);
                removed = ref == client;
                break;
            }
        }
        return removed;
    }
};
