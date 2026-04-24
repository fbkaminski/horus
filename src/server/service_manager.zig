// Minimal First Implementation
// Step 1 — The bootstrap socket listener
//  Add an io_uring accept loop in the service manager for the Unix socket.
//  Each accepted connection becomes a Connection tracked in the ServiceTable.
//  This is just another fd in your existing io_uring event loop — IORING_OP_ACCEPT on the socket,
//  then IORING_OP_RECV on each client fd.
// Step 2 — Register/Resolve messages
//  Define the wire format for RegisterService and ResolveHandle —
//  a simple fixed-header struct is enough at first, no IDL needed yet.
//  The service manager processes these as regular messages dispatched through the RunLoop.
// Step 3 — Handle introduction via SCM_RIGHTS
//  When ResolveHandle is processed, socketpair(AF_UNIX, SOCK_SEQPACKET),
//  send one fd back to the caller via sendmsg with SCM_RIGHTS,
//  store the other end in the ServiceEntry.
//  SOCK_SEQPACKET is the right socket type here —
//  message boundaries preserved, ordered delivery, no partial reads, unlike SOCK_STREAM.
// Step 4 — Wire a test service
//  Register a trivial service (a ping responder) from a separate process,
//  resolve it from a third process, exchange a message directly over the introduced channel.
//  At that point the core mechanism is proven.

const std = @import("std");
const builtin = @import("builtin");
const base = @import("../core/base.zig");
const thread_file = @import("../core/single_thread_task_runner.zig");
const io_linux = @import("../io/linux.zig");
const thread_registry_file = @import("../core/thread_registry.zig");
const work_queue = @import("../core/work_queue.zig");
const service_file = @import("service.zig");
const channel_file = @import("../channel/channel.zig");
const named_channel_file = @import("../channel/named_process_channel.zig");
const SingleThreadTaskRunner = thread_file.SingleThreadTaskRunner;
const IO = io_linux.IO;
const ThreadRegistry = thread_registry_file.ThreadRegistry;
const Task = base.Task;
const TaskQueue = base.TaskQueue;

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

    pub fn init(self: *ServiceManager, allocator: std.mem.Allocator, thread_registry: *ThreadRegistry) !void {
        self.allocator = allocator;
        self.services = .init(allocator);
        self.last_service_id = 1000;
        self.state = .init;
        self.clients = try ClientContextPool.init(allocator);
        self.server_delegate = .{
            .ptr = self,
            .vtable = &delegate_vtable,
        };
        try self.task_runner.init(allocator, thread_registry, .service);
        try self.server_channel.init(allocator, SERVICE_MANAGER_SOCKET_PATH, &self.task_runner.io, &self.server_delegate);
    }

    pub fn spawn(self: *ServiceManager) !void {
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
        _ = self;
        _ = server;
    }

    fn onContextDone(self: *ServiceManager, client_context: *ClientContext) void {
        std.debug.assert(self.clients.removeClient(client_context));
        client_context.deinit(self.allocator);
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
    delegate: ChannelDelegate,

    pub fn init(self: *ClientContext, manager: *ServiceManager, task_runner: *SingleThreadTaskRunner, channel: *NamedProcessChannel) void {
        self.service_manager = manager;
        self.task_runner = task_runner;
        self.channel = channel;
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
            .message = undefined,
        };
        // define ourselves as the delegate of the client channel
        self.channel.setDelegate(&self.delegate);
    }

    pub fn deinit(self: *ClientContext, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    fn onDataAvailable(self: *ClientContext, client: *Channel, data: []u8) void {
        _ = client;
        std.debug.assert(self.task_runner.isCurrentThread());
        //std.debug.assert(client == self.channel);
        self.read_cb.message = data;
        self.task_runner.postTaskTo(.workers, &self.read_cb.node);
    }

    fn onConnectionClosed(self: *ClientContext, client: *Channel) void {
        _ = client;
        std.debug.assert(self.task_runner.isCurrentThread());
        //std.debug.assert(client == self.channel);
        std.log.info("ClientContext.onConnectionClosed: client connection closed.", .{});
    }

    fn processIncomingDataOnWorkerThread(self: *ClientContext, buf: []u8) void {
        std.log.info("ClientContext.recvOnWorkerThread: processing message \"{s}\" on task_runner {d}", .{ buf, std.Thread.getCurrentId() });
        self.task_runner.postTaskTo(.service, &self.read_cb.response_node);
    }

    fn processIncomingDataReplyOnServiceThread(self: *ClientContext, client: *NamedProcessChannel) void {
        std.debug.assert(self.task_runner.isCurrentThread());
        std.log.info("ClientContext.closeConnectionOnServiceThread: response after readDataOnWorkerThread on task_runner {d}\n", .{std.Thread.getCurrentId()});
        client.deinit();
        // this will clean ourselves
        self.service_manager.onContextDone(self);
    }

    const delegate_vtable = ChannelDelegate.VTable{
        .onDataAvailable = struct {
            fn f(ptr: *anyopaque, channel: *Channel, data: []u8) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onDataAvailable(channel, data);
            }
        }.f,
        .onConnectionClosed = struct {
            fn f(ptr: *anyopaque, channel: *Channel) void {
                const self: *ClientContext = @ptrCast(@alignCast(ptr));
                self.onConnectionClosed(channel);
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
        message: []u8,

        fn callback(task: *Task) void {
            const self: *ReadCallback = @fieldParentPtr("task", task);
            self.context.processIncomingDataOnWorkerThread(self.message);
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
