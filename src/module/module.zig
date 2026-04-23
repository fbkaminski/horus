pub const Module = struct {
    // wether this module is in-process our out-of-process
    in_process: bool,
};

// Generic Module Loader
pub const ModuleLoader = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        loadModule: *const fn (ptr: *anyopaque) void,
        unloadModule: *const fn (ptr: *anyopaque) void,
        onModuleLoaded: *const fn (ptr: *anyopaque, module: *Module) void,
        onModuleUnloaded: *const fn (ptr: *anyopaque, module: *Module) void,
    };

    pub fn loadModule(self: ModuleLoader) void {
        self.vtable.loadModule(self.ptr);
    }

    pub fn unloadModule(self: ModuleLoader) void {
        self.vtable.unloadModule(self.ptr);
    }

    pub fn onModuleLoaded(self: ModuleLoader, module: *Module) void {
        self.vtable.onModuleLoaded(self.ptr, module);
    }

    pub fn onModuleUnloaded(self: ModuleLoader, module: *Module) void {
        self.vtable.onModuleUnloaded(self.ptr, module);
    }
};
