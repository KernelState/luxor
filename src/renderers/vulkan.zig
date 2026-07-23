const lu = @import("../luxor.zig");
const std = @import("std");
const vk = @import("vulkan");

const Vulkan = @This();

const Vertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
    // Packed: shape_type (u8), has_texture (u8), has_gradient (u8), _pad (u8)
    flags: u32,
    corner_radius: f32,
    rect_size: [2]f32,
    // For rounded rect: tl, tr, bl, br radii packed; for circle: radius
    shape_data: [4]f32,
};

const MaxVerticesPerBatch = 65536;
const MaxIndicesPerBatch = 98304;
const MaxTexturesPerBatch = 16;
const MaxFramesInFlight = 2;

const FrameData = struct {
    cmd_pool: vk.CommandPool,
    cmd_buffer: vk.CommandBuffer,
    fence: vk.Fence,
    image_available: vk.Semaphore,
    render_finished: vk.Semaphore,
    vertex_buffer: vk.Buffer,
    vertex_memory: vk.DeviceMemory,
    vertex_mapped: [*]Vertex,
    index_buffer: vk.Buffer,
    index_memory: vk.DeviceMemory,
    index_mapped: [*]u32,
    uniform_buffer: vk.Buffer,
    uniform_memory: vk.DeviceMemory,
    uniform_mapped: [*]u8,
    descriptor_pool: vk.DescriptorPool,
    descriptor_set: vk.DescriptorSet,
};

const TextureObject = struct {
    image: vk.Image,
    memory: vk.DeviceMemory,
    view: vk.ImageView,
    sampler: vk.Sampler,
    width: u32,
    height: u32,
    format: lu.Renderer.TextureFormat,
    staging_buffer: ?vk.Buffer,
    staging_memory: ?vk.DeviceMemory,
};

const SvgObject = struct {
    vertex_buffer: vk.Buffer,
    vertex_memory: vk.DeviceMemory,
    index_buffer: vk.Buffer,
    index_memory: vk.DeviceMemory,
    vertex_count: u32,
    index_count: u32,
    width: f32,
    height: f32,
};

const SurfaceObject = struct {
    base: vk.SurfaceKHR,
    swapchain: vk.SwapchainKHR,
    extent: vk.Extent2D,
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
    images: []vk.Image,
    image_views: []vk.ImageView,
    framebuffers: []vk.Framebuffer,
    render_pass: vk.RenderPass,
    pipeline: vk.Pipeline,
    pipeline_layout: vk.PipelineLayout,
    descriptor_set_layout: vk.DescriptorSetLayout,
    depth_image: vk.Image,
    depth_memory: vk.DeviceMemory,
    depth_view: vk.ImageView,
    current_frame: usize,
    frames: [MaxFramesInFlight]FrameData,
    vertices: std.ArrayList(Vertex),
    indices: std.ArrayList(u32),
    clip_stack: std.ArrayList(lu.Renderer.Rect),
    current_texture_bindings: [MaxTexturesPerBatch]vk.ImageView,
    texture_binding_count: u32,
    current_image_index: u32 = 0,
    needs_rebuild: bool,
};

const ObjectType = enum { surface, texture, svg };

const ObjectEntry = struct {
    type: ObjectType,
    data: union {
        surface: SurfaceObject,
        texture: TextureObject,
        svg: SvgObject,
    },
};

// ============================================================================
// Vulkan State
// ============================================================================

instance: vk.Instance = .null_handle,
dev: vk.Device = .null_handle,
gpu: vk.PhysicalDevice = .null_handle,
gpu_props: vk.PhysicalDeviceProperties = undefined,

gqueue: vk.Queue = .null_handle,
gqueue_index: u32 = undefined,
tqueue: vk.Queue = .null_handle,
tqueue_index: u32 = undefined,

memory_props: vk.PhysicalDeviceMemoryProperties = undefined,

objs: std.AutoHashMap(lu.Renderer.ObjectId, ObjectEntry),
next_id: std.atomic.Value(u64),

gpa: std.mem.Allocator,

// Frame tracking
current_surface: ?lu.Renderer.ObjectId = null,
current_cmd_buffer: vk.CommandBuffer = .null_handle,
current_frame_data: ?*FrameData = null,

// Shader modules
vert_module: vk.ShaderModule = .null_handle,
frag_module: vk.ShaderModule = .null_handle,

// Default sampler
default_sampler: vk.Sampler = .null_handle,

// Default 1x1 white texture for solid color draws
default_texture_view: vk.ImageView = .null_handle,
default_texture_id: lu.Renderer.ObjectId = 0,

// Function pointers
var createInstance: vk.PfnCreateInstance = undefined;
var destroyInstance: vk.PfnDestroyInstance = undefined;
var enumeratePhysicalDevices: vk.PfnEnumeratePhysicalDevices = undefined;
var getPhysicalDeviceQueueFamilyProperties: vk.PfnGetPhysicalDeviceQueueFamilyProperties = undefined;
var getPhysicalDeviceMemoryProperties: vk.PfnGetPhysicalDeviceMemoryProperties = undefined;
var getPhysicalDeviceProperties: vk.PfnGetPhysicalDeviceProperties = undefined;
var createDevice: vk.PfnCreateDevice = undefined;
var destroyDevice: vk.PfnDestroyDevice = undefined;
var getDeviceQueue: vk.PfnGetDeviceQueue = undefined;
var enumerateDeviceExtensionProperties: vk.PfnEnumerateDeviceExtensionProperties = undefined;

// Surface
var getPhysicalDeviceSurfaceSupportKHR: vk.PfnGetPhysicalDeviceSurfaceSupportKHR = undefined;
var getPhysicalDeviceSurfaceCapabilitiesKHR: vk.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR = undefined;
var getPhysicalDeviceSurfaceFormatsKHR: vk.PfnGetPhysicalDeviceSurfaceFormatsKHR = undefined;
var getPhysicalDeviceSurfacePresentModesKHR: vk.PfnGetPhysicalDeviceSurfacePresentModesKHR = undefined;
var createSwapchainKHR: vk.PfnCreateSwapchainKHR = undefined;
var destroySwapchainKHR: vk.PfnDestroySwapchainKHR = undefined;
var getSwapchainImagesKHR: vk.PfnGetSwapchainImagesKHR = undefined;
var destroySurfaceKHR: vk.PfnDestroySurfaceKHR = undefined;

// Images
var createImage: vk.PfnCreateImage = undefined;
var destroyImage: vk.PfnDestroyImage = undefined;
var bindImageMemory: vk.PfnBindImageMemory = undefined;
var getImageMemoryRequirements: vk.PfnGetImageMemoryRequirements = undefined;
var createImageView: vk.PfnCreateImageView = undefined;
var destroyImageView: vk.PfnDestroyImageView = undefined;
var createSampler: vk.PfnCreateSampler = undefined;
var destroySampler: vk.PfnDestroySampler = undefined;

// Buffers
var createBuffer: vk.PfnCreateBuffer = undefined;
var destroyBuffer: vk.PfnDestroyBuffer = undefined;
var bindBufferMemory: vk.PfnBindBufferMemory = undefined;
var getBufferMemoryRequirements: vk.PfnGetBufferMemoryRequirements = undefined;
var mapMemory: vk.PfnMapMemory = undefined;
var unmapMemory: vk.PfnUnmapMemory = undefined;
var flushMappedMemoryRanges: vk.PfnFlushMappedMemoryRanges = undefined;
var allocateMemory: vk.PfnAllocateMemory = undefined;
var freeMemory: vk.PfnFreeMemory = undefined;

// Commands
var createCommandPool: vk.PfnCreateCommandPool = undefined;
var destroyCommandPool: vk.PfnDestroyCommandPool = undefined;
var allocateCommandBuffers: vk.PfnAllocateCommandBuffers = undefined;
var beginCommandBuffer: vk.PfnBeginCommandBuffer = undefined;
var endCommandBuffer: vk.PfnEndCommandBuffer = undefined;
var cmdBeginRenderPass: vk.PfnCmdBeginRenderPass = undefined;
var cmdEndRenderPass: vk.PfnCmdEndRenderPass = undefined;
var cmdBindPipeline: vk.PfnCmdBindPipeline = undefined;
var cmdBindVertexBuffers: vk.PfnCmdBindVertexBuffers = undefined;
var cmdBindIndexBuffer: vk.PfnCmdBindIndexBuffer = undefined;
var cmdDrawIndexed: vk.PfnCmdDrawIndexed = undefined;
var cmdSetViewport: vk.PfnCmdSetViewport = undefined;
var cmdSetScissor: vk.PfnCmdSetScissor = undefined;
var cmdCopyBufferToImage: vk.PfnCmdCopyBufferToImage = undefined;
var cmdPipelineBarrier: vk.PfnCmdPipelineBarrier = undefined;

// Sync
var createFence: vk.PfnCreateFence = undefined;
var destroyFence: vk.PfnDestroyFence = undefined;
var waitForFences: vk.PfnWaitForFences = undefined;
var resetFences: vk.PfnResetFences = undefined;
var createSemaphore: vk.PfnCreateSemaphore = undefined;
var destroySemaphore: vk.PfnDestroySemaphore = undefined;

// Render pass & pipeline
var createRenderPass: vk.PfnCreateRenderPass = undefined;
var destroyRenderPass: vk.PfnDestroyRenderPass = undefined;
var createFramebuffer: vk.PfnCreateFramebuffer = undefined;
var destroyFramebuffer: vk.PfnDestroyFramebuffer = undefined;
var createPipelineLayout: vk.PfnCreatePipelineLayout = undefined;
var destroyPipelineLayout: vk.PfnDestroyPipelineLayout = undefined;
var createGraphicsPipelines: vk.PfnCreateGraphicsPipelines = undefined;
var destroyPipeline: vk.PfnDestroyPipeline = undefined;
var createShaderModule: vk.PfnCreateShaderModule = undefined;
var destroyShaderModule: vk.PfnDestroyShaderModule = undefined;
var createDescriptorSetLayout: vk.PfnCreateDescriptorSetLayout = undefined;
var destroyDescriptorSetLayout: vk.PfnDestroyDescriptorSetLayout = undefined;
var createDescriptorPool: vk.PfnCreateDescriptorPool = undefined;
var destroyDescriptorPool: vk.PfnDestroyDescriptorPool = undefined;
var allocateDescriptorSets: vk.PfnAllocateDescriptorSets = undefined;
var updateDescriptorSets: vk.PfnUpdateDescriptorSets = undefined;

// Presentation
var queuePresentKHR: vk.PfnQueuePresentKHR = undefined;
var acquireNextImageKHR: vk.PfnAcquireNextImageKHR = undefined;

// ============================================================================
// VTable
// ============================================================================

pub const vtable = lu.Renderer.VTable{
    .init = init,
    .deinit = deinit,
    .createSurface = createSurface,
    .destroySurface = destroySurface,
    .getSurfaceInfo = getSurfaceInfo,
    .resizeSurface = resizeSurface,
    .uploadTexture = uploadTexture,
    .destroyTexture = destroyTexture,
    .getTextureInfo = getTextureInfo,
    .beginFrame = beginFrame,
    .endFrame = endFrame,
    .drawRect = drawRect,
    .drawCircle = drawCircle,
    .drawTriangle = drawTriangle,
    .drawSvg = drawSvg,
    .drawMask = drawMask,
    .pushClip = pushClip,
    .popClip = popClip,
};

const swapchain_extensions = [1][:0]const u8{"VK_KHR_swapchain"};

// ============================================================================
// Shader SPIR-V (compiled GLSL)
// ============================================================================

const vert_spv = @embedFile("shaders/2d.vert.spv");
const frag_spv = @embedFile("shaders/2d.frag.spv");

// ============================================================================
// Helpers
// ============================================================================

fn findMemoryType(self: *Vulkan, type_filter: u32, props: vk.MemoryPropertyFlags) !u32 {
    for (0..self.memory_props.memory_type_count) |i| {
        if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and
            self.memory_props.memory_types[i].property_flags.contains(props))
        {
            return @intCast(i);
        }
    }
    return error.NoSuitableMemoryType;
}

fn createBufferAlloc(self: *Vulkan, size: vk.DeviceSize, usage: vk.BufferUsageFlags, props: vk.MemoryPropertyFlags) !struct { vk.Buffer, vk.DeviceMemory } {
    const buffer_info = vk.BufferCreateInfo{
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
    };
    var buffer: vk.Buffer = undefined;
    if (createBuffer(self.dev, &buffer_info, null, &buffer) != .success)
        return error.FailedToCreateBuffer;

    var mem_reqs: vk.MemoryRequirements = undefined;
    getBufferMemoryRequirements(self.dev, buffer, &mem_reqs);

    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try self.findMemoryType(mem_reqs.memory_type_bits, props),
    };
    var memory: vk.DeviceMemory = undefined;
    if (allocateMemory(self.dev, &alloc_info, null, &memory) != .success)
        return error.FailedToAllocateMemory;

    if (bindBufferMemory(self.dev, buffer, memory, 0) != .success)
        return error.FailedToBindBufferMemory;

    return .{ buffer, memory };
}

fn createImage2DAlloc(self: *Vulkan, width: u32, height: u32, format: vk.Format, usage: vk.ImageUsageFlags, props: vk.MemoryPropertyFlags) !struct { vk.Image, vk.DeviceMemory } {
    const image_info = vk.ImageCreateInfo{
        .image_type = .@"2d",
        .format = format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = usage,
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    };
    var image: vk.Image = undefined;
    if (createImage(self.dev, &image_info, null, &image) != .success)
        return error.FailedToCreateImage;

    var mem_reqs: vk.MemoryRequirements = undefined;
    getImageMemoryRequirements(self.dev, image, &mem_reqs);

    const alloc_info = vk.MemoryAllocateInfo{
        .allocation_size = mem_reqs.size,
        .memory_type_index = try self.findMemoryType(mem_reqs.memory_type_bits, props),
    };
    var memory: vk.DeviceMemory = undefined;
    if (allocateMemory(self.dev, &alloc_info, null, &memory) != .success)
        return error.FailedToAllocateMemory;

    if (bindImageMemory(self.dev, image, memory, 0) != .success)
        return error.FailedToBindImageMemory;

    return .{ image, memory };
}

fn transitionImageLayout(_: *Vulkan, cmd: vk.CommandBuffer, image: vk.Image, old_layout: vk.ImageLayout, new_layout: vk.ImageLayout) void {
    var barrier = vk.ImageMemoryBarrier{
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_access_mask = .{},
        .dst_access_mask = .{},
    };

    var src_stage: vk.PipelineStageFlags = undefined;
    var dst_stage: vk.PipelineStageFlags = undefined;

    if (old_layout == .undefined and new_layout == .transfer_dst_optimal) {
        barrier.src_access_mask = .{};
        barrier.dst_access_mask = .{ .transfer_write_bit = true };
        src_stage = .{ .top_of_pipe_bit = true };
        dst_stage = .{ .transfer_bit = true };
    } else if (old_layout == .transfer_dst_optimal and new_layout == .shader_read_only_optimal) {
        barrier.src_access_mask = .{ .transfer_write_bit = true };
        barrier.dst_access_mask = .{ .shader_read_bit = true };
        src_stage = .{ .transfer_bit = true };
        dst_stage = .{ .fragment_shader_bit = true };
    } else {
        barrier.src_access_mask = .{};
        barrier.dst_access_mask = .{};
        src_stage = .{ .top_of_pipe_bit = true };
        dst_stage = .{ .bottom_of_pipe_bit = true };
    }

    cmdPipelineBarrier(cmd, src_stage, dst_stage, .{}, 0, null, 0, null, 1, &barrier);
}

fn createShaderModuleFromCode(self: *Vulkan, code: []const u8) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = code.len,
        .p_code = @ptrCast(@alignCast(code.ptr)),
    };
    var module: vk.ShaderModule = undefined;
    if (createShaderModule(self.dev, &create_info, null, &module) != .success)
        return error.FailedToCreateShaderModule;
    return module;
}

fn generateId(self: *Vulkan) lu.Renderer.ObjectId {
    return self.next_id.fetchAdd(1, .monotonic);
}

// ============================================================================
// Load Functions
// ============================================================================

pub fn loadFunctions() !void {
    const lib = try std.DynLib.open("libvulkan.so.1");
    defer lib.close();

    createInstance = lib.lookup(vk.PfnCreateInstance, "vkCreateInstance") orelse return error.FailedToFindVulkanFunction;
    destroyInstance = lib.lookup(vk.PfnDestroyInstance, "vkDestroyInstance") orelse return error.FailedToFindVulkanFunction;
    enumeratePhysicalDevices = lib.lookup(vk.PfnEnumeratePhysicalDevices, "vkEnumeratePhysicalDevices") orelse return error.FailedToFindVulkanFunction;
    getPhysicalDeviceQueueFamilyProperties = lib.lookup(vk.PfnGetPhysicalDeviceQueueFamilyProperties, "vkGetPhysicalDeviceQueueFamilyProperties") orelse return error.FailedToFindVulkanFunction;
    getPhysicalDeviceMemoryProperties = lib.lookup(vk.PfnGetPhysicalDeviceMemoryProperties, "vkGetPhysicalDeviceMemoryProperties") orelse return error.FailedToFindVulkanFunction;
    getPhysicalDeviceProperties = lib.lookup(vk.PfnGetPhysicalDeviceProperties, "vkGetPhysicalDeviceProperties") orelse return error.FailedToFindVulkanFunction;
    createDevice = lib.lookup(vk.PfnCreateDevice, "vkCreateDevice") orelse return error.FailedToFindVulkanFunction;
    destroyDevice = lib.lookup(vk.PfnDestroyDevice, "vkDestroyDevice") orelse return error.FailedToFindVulkanFunction;
    getDeviceQueue = lib.lookup(vk.PfnGetDeviceQueue, "vkGetDeviceQueue") orelse return error.FailedToFindVulkanFunction;
    enumerateDeviceExtensionProperties = lib.lookup(vk.PfnEnumerateDeviceExtensionProperties, "vkEnumerateDeviceExtensionProperties") orelse return error.FailedToFindVulkanFunction;

    getPhysicalDeviceSurfaceSupportKHR = lib.lookup(vk.PfnGetPhysicalDeviceSurfaceSupportKHR, "vkGetPhysicalDeviceSurfaceSupportKHR") orelse return error.FailedToFindVulkanFunction;
    getPhysicalDeviceSurfaceCapabilitiesKHR = lib.lookup(vk.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR") orelse return error.FailedToFindVulkanFunction;
    getPhysicalDeviceSurfaceFormatsKHR = lib.lookup(vk.PfnGetPhysicalDeviceSurfaceFormatsKHR, "vkGetPhysicalDeviceSurfaceFormatsKHR") orelse return error.FailedToFindVulkanFunction;
    getPhysicalDeviceSurfacePresentModesKHR = lib.lookup(vk.PfnGetPhysicalDeviceSurfacePresentModesKHR, "vkGetPhysicalDeviceSurfacePresentModesKHR") orelse return error.FailedToFindVulkanFunction;
    createSwapchainKHR = lib.lookup(vk.PfnCreateSwapchainKHR, "vkCreateSwapchainKHR") orelse return error.FailedToFindVulkanFunction;
    destroySwapchainKHR = lib.lookup(vk.PfnDestroySwapchainKHR, "vkDestroySwapchainKHR") orelse return error.FailedToFindVulkanFunction;
    getSwapchainImagesKHR = lib.lookup(vk.PfnGetSwapchainImagesKHR, "vkGetSwapchainImagesKHR") orelse return error.FailedToFindVulkanFunction;
    destroySurfaceKHR = lib.lookup(vk.PfnDestroySurfaceKHR, "vkDestroySurfaceKHR") orelse return error.FailedToFindVulkanFunction;

    createImage = lib.lookup(vk.PfnCreateImage, "vkCreateImage") orelse return error.FailedToFindVulkanFunction;
    destroyImage = lib.lookup(vk.PfnDestroyImage, "vkDestroyImage") orelse return error.FailedToFindVulkanFunction;
    bindImageMemory = lib.lookup(vk.PfnBindImageMemory, "vkBindImageMemory") orelse return error.FailedToFindVulkanFunction;
    getImageMemoryRequirements = lib.lookup(vk.PfnGetImageMemoryRequirements, "vkGetImageMemoryRequirements") orelse return error.FailedToFindVulkanFunction;
    createImageView = lib.lookup(vk.PfnCreateImageView, "vkCreateImageView") orelse return error.FailedToFindVulkanFunction;
    destroyImageView = lib.lookup(vk.PfnDestroyImageView, "vkDestroyImageView") orelse return error.FailedToFindVulkanFunction;
    createSampler = lib.lookup(vk.PfnCreateSampler, "vkCreateSampler") orelse return error.FailedToFindVulkanFunction;
    destroySampler = lib.lookup(vk.PfnDestroySampler, "vkDestroySampler") orelse return error.FailedToFindVulkanFunction;

    createBuffer = lib.lookup(vk.PfnCreateBuffer, "vkCreateBuffer") orelse return error.FailedToFindVulkanFunction;
    destroyBuffer = lib.lookup(vk.PfnDestroyBuffer, "vkDestroyBuffer") orelse return error.FailedToFindVulkanFunction;
    bindBufferMemory = lib.lookup(vk.PfnBindBufferMemory, "vkBindBufferMemory") orelse return error.FailedToFindVulkanFunction;
    getBufferMemoryRequirements = lib.lookup(vk.PfnGetBufferMemoryRequirements, "vkGetBufferMemoryRequirements") orelse return error.FailedToFindVulkanFunction;
    mapMemory = lib.lookup(vk.PfnMapMemory, "vkMapMemory") orelse return error.FailedToFindVulkanFunction;
    unmapMemory = lib.lookup(vk.PfnUnmapMemory, "vkUnmapMemory") orelse return error.FailedToFindVulkanFunction;
    flushMappedMemoryRanges = lib.lookup(vk.PfnFlushMappedMemoryRanges, "vkFlushMappedMemoryRanges") orelse return error.FailedToFindVulkanFunction;
    allocateMemory = lib.lookup(vk.PfnAllocateMemory, "vkAllocateMemory") orelse return error.FailedToFindVulkanFunction;
    freeMemory = lib.lookup(vk.PfnFreeMemory, "vkFreeMemory") orelse return error.FailedToFindVulkanFunction;

    createCommandPool = lib.lookup(vk.PfnCreateCommandPool, "vkCreateCommandPool") orelse return error.FailedToFindVulkanFunction;
    destroyCommandPool = lib.lookup(vk.PfnDestroyCommandPool, "vkDestroyCommandPool") orelse return error.FailedToFindVulkanFunction;
    allocateCommandBuffers = lib.lookup(vk.PfnAllocateCommandBuffers, "vkAllocateCommandBuffers") orelse return error.FailedToFindVulkanFunction;
    beginCommandBuffer = lib.lookup(vk.PfnBeginCommandBuffer, "vkBeginCommandBuffer") orelse return error.FailedToFindVulkanFunction;
    endCommandBuffer = lib.lookup(vk.PfnEndCommandBuffer, "vkEndCommandBuffer") orelse return error.FailedToFindVulkanFunction;
    cmdBeginRenderPass = lib.lookup(vk.PfnCmdBeginRenderPass, "vkCmdBeginRenderPass") orelse return error.FailedToFindVulkanFunction;
    cmdEndRenderPass = lib.lookup(vk.PfnCmdEndRenderPass, "vkCmdEndRenderPass") orelse return error.FailedToFindVulkanFunction;
    cmdBindPipeline = lib.lookup(vk.PfnCmdBindPipeline, "vkCmdBindPipeline") orelse return error.FailedToFindVulkanFunction;
    cmdBindVertexBuffers = lib.lookup(vk.PfnCmdBindVertexBuffers, "vkCmdBindVertexBuffers") orelse return error.FailedToFindVulkanFunction;
    cmdBindIndexBuffer = lib.lookup(vk.PfnCmdBindIndexBuffer, "vkCmdBindIndexBuffer") orelse return error.FailedToFindVulkanFunction;
    cmdDrawIndexed = lib.lookup(vk.PfnCmdDrawIndexed, "vkCmdDrawIndexed") orelse return error.FailedToFindVulkanFunction;
    cmdSetViewport = lib.lookup(vk.PfnCmdSetViewport, "vkCmdSetViewport") orelse return error.FailedToFindVulkanFunction;
    cmdSetScissor = lib.lookup(vk.PfnCmdSetScissor, "vkCmdSetScissor") orelse return error.FailedToFindVulkanFunction;
    cmdCopyBufferToImage = lib.lookup(vk.PfnCmdCopyBufferToImage, "vkCmdCopyBufferToImage") orelse return error.FailedToFindVulkanFunction;
    cmdPipelineBarrier = lib.lookup(vk.PfnCmdPipelineBarrier, "vkCmdPipelineBarrier") orelse return error.FailedToFindVulkanFunction;

    createFence = lib.lookup(vk.PfnCreateFence, "vkCreateFence") orelse return error.FailedToFindVulkanFunction;
    destroyFence = lib.lookup(vk.PfnDestroyFence, "vkDestroyFence") orelse return error.FailedToFindVulkanFunction;
    waitForFences = lib.lookup(vk.PfnWaitForFences, "vkWaitForFences") orelse return error.FailedToFindVulkanFunction;
    resetFences = lib.lookup(vk.PfnResetFences, "vkResetFences") orelse return error.FailedToFindVulkanFunction;
    createSemaphore = lib.lookup(vk.PfnCreateSemaphore, "vkCreateSemaphore") orelse return error.FailedToFindVulkanFunction;
    destroySemaphore = lib.lookup(vk.PfnDestroySemaphore, "vkDestroySemaphore") orelse return error.FailedToFindVulkanFunction;

    createRenderPass = lib.lookup(vk.PfnCreateRenderPass, "vkCreateRenderPass") orelse return error.FailedToFindVulkanFunction;
    destroyRenderPass = lib.lookup(vk.PfnDestroyRenderPass, "vkDestroyRenderPass") orelse return error.FailedToFindVulkanFunction;
    createFramebuffer = lib.lookup(vk.PfnCreateFramebuffer, "vkCreateFramebuffer") orelse return error.FailedToFindVulkanFunction;
    destroyFramebuffer = lib.lookup(vk.PfnDestroyFramebuffer, "vkDestroyFramebuffer") orelse return error.FailedToFindVulkanFunction;
    createPipelineLayout = lib.lookup(vk.PfnCreatePipelineLayout, "vkCreatePipelineLayout") orelse return error.FailedToFindVulkanFunction;
    destroyPipelineLayout = lib.lookup(vk.PfnDestroyPipelineLayout, "vkDestroyPipelineLayout") orelse return error.FailedToFindVulkanFunction;
    createGraphicsPipelines = lib.lookup(vk.PfnCreateGraphicsPipelines, "vkCreateGraphicsPipelines") orelse return error.FailedToFindVulkanFunction;
    destroyPipeline = lib.lookup(vk.PfnDestroyPipeline, "vkDestroyPipeline") orelse return error.FailedToFindVulkanFunction;
    createShaderModule = lib.lookup(vk.PfnCreateShaderModule, "vkCreateShaderModule") orelse return error.FailedToFindVulkanFunction;
    destroyShaderModule = lib.lookup(vk.PfnDestroyShaderModule, "vkDestroyShaderModule") orelse return error.FailedToFindVulkanFunction;
    createDescriptorSetLayout = lib.lookup(vk.PfnCreateDescriptorSetLayout, "vkCreateDescriptorSetLayout") orelse return error.FailedToFindVulkanFunction;
    destroyDescriptorSetLayout = lib.lookup(vk.PfnDestroyDescriptorSetLayout, "vkDestroyDescriptorSetLayout") orelse return error.FailedToFindVulkanFunction;
    createDescriptorPool = lib.lookup(vk.PfnCreateDescriptorPool, "vkCreateDescriptorPool") orelse return error.FailedToFindVulkanFunction;
    destroyDescriptorPool = lib.lookup(vk.PfnDestroyDescriptorPool, "vkDestroyDescriptorPool") orelse return error.FailedToFindVulkanFunction;
    allocateDescriptorSets = lib.lookup(vk.PfnAllocateDescriptorSets, "vkAllocateDescriptorSets") orelse return error.FailedToFindVulkanFunction;
    updateDescriptorSets = lib.lookup(vk.PfnUpdateDescriptorSets, "vkUpdateDescriptorSets") orelse return error.FailedToFindVulkanFunction;

    queuePresentKHR = lib.lookup(vk.PfnQueuePresentKHR, "vkQueuePresentKHR") orelse return error.FailedToFindVulkanFunction;
    acquireNextImageKHR = lib.lookup(vk.PfnAcquireNextImageKHR, "vkAcquireNextImageKHR") orelse return error.FailedToFindVulkanFunction;
}

// ============================================================================
// Initialization
// ============================================================================

pub fn initInstance(self: *Vulkan) !void {
    const exs = lu.Platform.current.getExtensions();
    const application_info = vk.ApplicationInfo{
        .application_version = vk.makeApiVersion(0, 0, 1, 0),
        .p_application_name = "luxor",
        .p_engine_name = "luxor",
        .engine_version = vk.makeApiVersion(0, 0, 1, 0),
        .api_version = vk.API_VERSION_1_3,
    };
    const instance_info = vk.InstanceCreateInfo{
        .enabled_extension_count = @intCast(exs.len),
        .pp_enabled_extension_names = exs.ptr,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = &.{},
        .p_application_info = &application_info,
    };
    if (createInstance(&instance_info, null, &self.instance) != .success)
        return error.FailedToCreateInstance;
}

pub fn loadGPU(self: *Vulkan) !void {
    var devc: u32 = 0;
    if (enumeratePhysicalDevices(self.instance, &devc, null) != .success)
        return error.FailedToEnumerateVulkanDevices;
    const devs = try self.gpa.alloc(vk.PhysicalDevice, devc);
    defer self.gpa.free(devs);
    if (enumeratePhysicalDevices(self.instance, &devc, devs.ptr) != .success)
        return error.FailedToEnumerateVulkanDevices;
    if (devc == 0)
        return error.NoVulkanDevicesFound;

    var gpu: ?vk.PhysicalDevice = null;
    for (devs) |d| {
        var pc: u32 = 0;
        if (enumerateDeviceExtensionProperties(d, null, &pc, null) != .success)
            return error.FailedToEnumerateExtensionProperties;
        const props = try self.gpa.alloc(vk.ExtensionProperties, pc);
        defer self.gpa.free(props);
        if (enumerateDeviceExtensionProperties(d, null, &pc, props.ptr) != .success)
            return error.FailedToEnumerateExtensionProperties;

        var supp = [_]bool{false} ** swapchain_extensions.len;
        main: for (swapchain_extensions, 0..) |ex, i| {
            for (props) |prop| {
                if (std.mem.eql(u8, &prop.extension_name, ex)) {
                    supp[i] = true;
                    continue :main;
                }
            }
        }
        var supported = true;
        for (supp) |s| {
            supported = supported and s;
        }
        if (supported)
            gpu = d;
    }
    self.gpu = gpu orelse return error.NoSupportedGPU;
    getPhysicalDeviceMemoryProperties(self.gpu, &self.memory_props);
    getPhysicalDeviceProperties(self.gpu, &self.gpu_props);
}

fn loadQueue(self: *Vulkan, q: u32, qt: u1) !void {
    const queue_info = vk.DeviceQueueCreateInfo{
        .queue_family_index = q,
        .queue_count = 1,
        .p_queue_priorities = &@as(f32, 1.0),
    };
    const device_features = vk.PhysicalDeviceFeatures{};
    const device_info = vk.DeviceCreateInfo{
        .p_queue_create_infos = @ptrCast(&queue_info),
        .queue_create_info_count = 1,
        .p_enabled_features = &device_features,
        .enabled_extension_count = swapchain_extensions.len,
        .pp_enabled_extension_names = &swapchain_extensions,
        .enabled_layer_count = 0,
    };
    if (createDevice(self.gpu, &device_info, null, &self.dev) != .success)
        return error.FailedToCreateLogicalDevice;
    if (getDeviceQueue(
        self.dev,
        q,
        0,
        if (qt == 0) &self.gqueue else &self.tqueue,
    ) != .success)
        return error.FailedToGetDeviceQueue;
}

pub fn loadQueueFamilies(self: *Vulkan) !void {
    var qc: u32 = 0;
    if (getPhysicalDeviceQueueFamilyProperties(self.gpu, &qc, null) != .success)
        return error.FailedToListQueueFamilies;
    const qfs = try self.gpa.alloc(vk.QueueFamilyProperties, qc);
    defer self.gpa.free(qfs);
    if (getPhysicalDeviceQueueFamilyProperties(self.gpu, &qc, qfs.ptr) != .success)
        return error.FailedToListQueueFamilies;

    var gf: u32 = 0;
    var tf: u32 = 0;
    for (qfs, 0..) |qf, i| {
        if (qf.queue_flags.graphics_bit) {
            gf = @intCast(i);
        }
        if (qf.queue_flags.transfer_bit) {
            tf = @intCast(i);
        }
    }
    try self.loadQueue(gf, 0);
    try self.loadQueue(tf, 1);
    self.gqueue_index = gf;
    self.tqueue_index = tf;
}

pub fn init(alloc: std.mem.Allocator) !*anyopaque {
    const self = try alloc.create(Vulkan);
    self.* = .{
        .gpa = alloc,
        .objs = std.AutoHashMap(lu.Renderer.ObjectId, ObjectEntry).init(alloc),
        .next_id = std.atomic.Value(u64).init(1),
    };
    try loadFunctions();
    try self.initInstance();
    try self.loadGPU();
    try self.loadQueueFamilies();

    // Create default sampler
    const sampler_info = vk.SamplerCreateInfo{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 1,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .mip_lod_bias = 0,
    };
    if (createSampler(self.dev, &sampler_info, null, &self.default_sampler) != .success)
        return error.FailedToCreateSampler;

    // Create 1x1 white texture for solid color draws
    const white_pixel = [_]u8{ 255, 255, 255, 255 };
    self.default_texture_id = try self.uploadTexture(&white_pixel, 1, 1, .rgba8);
    const white_entry = self.objs.get(self.default_texture_id) orelse return error.FailedToCreateDefaultTexture;
    self.default_texture_view = white_entry.data.texture.view;

    return self;
}

// ============================================================================
// Surface Management
// ============================================================================

fn createSurfaceRenderPass(self: *Vulkan, surface_format: vk.Format) !vk.RenderPass {
    const color_attachment = vk.AttachmentDescription{
        .format = surface_format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = &color_attachment_ref,
    };

    const dependency = vk.SubpassDependency{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
    };

    const render_pass_info = vk.RenderPassCreateInfo{
        .attachment_count = 1,
        .p_attachments = &color_attachment,
        .subpass_count = 1,
        .p_subpasses = &subpass,
        .dependency_count = 1,
        .p_dependencies = &dependency,
    };

    var render_pass: vk.RenderPass = undefined;
    if (createRenderPass(self.dev, &render_pass_info, null, &render_pass) != .success)
        return error.FailedToCreateRenderPass;
    return render_pass;
}

fn createSurfacePipeline(self: *Vulkan, surface: *SurfaceObject) !void {
    if (self.vert_module == .null_handle) {
        self.vert_module = try self.createShaderModuleFromCode(vert_spv);
    }
    if (self.frag_module == .null_handle) {
        self.frag_module = try self.createShaderModuleFromCode(frag_spv);
    }

    const shader_stages = [2]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = self.vert_module,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = self.frag_module,
            .p_name = "main",
        },
    };

    const binding_desc = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };

    const attribute_descs = [7]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "pos") },
        .{ .location = 1, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "uv") },
        .{ .location = 2, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "color") },
        .{ .location = 3, .binding = 0, .format = .r32_uint, .offset = @offsetOf(Vertex, "flags") },
        .{ .location = 4, .binding = 0, .format = .r32_sfloat, .offset = @offsetOf(Vertex, "corner_radius") },
        .{ .location = 5, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "rect_size") },
        .{ .location = 6, .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @offsetOf(Vertex, "shape_data") },
    };

    const vertex_input = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = &binding_desc,
        .vertex_attribute_description_count = attribute_descs.len,
        .p_vertex_attribute_descriptions = &attribute_descs,
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .scissor_count = 1,
    };

    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .cull_mode = .{ .none = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .line_width = 1,
    };

    const multisampling = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = vk.FALSE,
    };

    const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
        .blend_enable = vk.TRUE,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };

    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .attachment_count = 1,
        .p_attachments = &color_blend_attachment,
    };

    const dynamic_states = [2]vk.DynamicState{ .viewport, .scissor };
    const dynamic_state = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = dynamic_states.len,
        .p_dynamic_states = &dynamic_states,
    };

    // Descriptor set layout for textures
    const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_type = .uniform_buffer,
        .descriptor_count = 1,
        .stage_flags = .{ .vertex_bit = true },
    };

    const sampler_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = MaxTexturesPerBatch,
        .stage_flags = .{ .fragment_bit = true },
    };

    const bindings = [2]vk.DescriptorSetLayoutBinding{ ubo_layout_binding, sampler_layout_binding };
    const layout_info = vk.DescriptorSetLayoutCreateInfo{
        .binding_count = bindings.len,
        .p_bindings = &bindings,
    };

    if (createDescriptorSetLayout(self.dev, &layout_info, null, &surface.descriptor_set_layout) != .success)
        return error.FailedToCreateDescriptorSetLayout;

    const pipeline_layout_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = &surface.descriptor_set_layout,
    };

    if (createPipelineLayout(self.dev, &pipeline_layout_info, null, &surface.pipeline_layout) != .success)
        return error.FailedToCreatePipelineLayout;

    const pipeline_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = shader_stages.len,
        .p_stages = &shader_stages,
        .p_vertex_input_state = &vertex_input,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterizer,
        .p_multisample_state = &multisampling,
        .p_color_blend_state = &color_blending,
        .p_dynamic_state = &dynamic_state,
        .layout = surface.pipeline_layout,
        .render_pass = surface.render_pass,
        .subpass = 0,
    };

    if (createGraphicsPipelines(self.dev, .null_handle, 1, &pipeline_info, null, &surface.pipeline) != .success)
        return error.FailedToCreateGraphicsPipeline;
}

fn createFrameData(self: *Vulkan, surface: *SurfaceObject) !void {
    for (0..MaxFramesInFlight) |i| {
        var frame = &surface.frames[i];

        const pool_info = vk.CommandPoolCreateInfo{
            .queue_family_index = self.gqueue_index,
            .flags = .{ .reset_command_buffer_bit = true },
        };
        if (createCommandPool(self.dev, &pool_info, null, &frame.cmd_pool) != .success)
            return error.FailedToCreateCommandPool;

        const alloc_info = vk.CommandBufferAllocateInfo{
            .command_pool = frame.cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        };
        if (allocateCommandBuffers(self.dev, &alloc_info, &frame.cmd_buffer) != .success)
            return error.FailedToAllocateCommandBuffers;

        const fence_info = vk.FenceCreateInfo{ .flags = .{ .signaled_bit = true } };
        if (createFence(self.dev, &fence_info, null, &frame.fence) != .success)
            return error.FailedToCreateFence;

        const semaphore_info = vk.SemaphoreCreateInfo{};
        if (createSemaphore(self.dev, &semaphore_info, null, &frame.image_available) != .success)
            return error.FailedToCreateSemaphore;
        if (createSemaphore(self.dev, &semaphore_info, null, &frame.render_finished) != .success)
            return error.FailedToCreateSemaphore;

        // Create vertex buffer (host visible, coherent)
        const vb_size = @as(vk.DeviceSize, MaxVerticesPerBatch * @sizeOf(Vertex));
        const vb_result = try self.createBufferAlloc(vb_size, .{ .vertex_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
        frame.vertex_buffer = vb_result[0];
        frame.vertex_memory = vb_result[1];
        if (mapMemory(self.dev, frame.vertex_memory, 0, vk.WHOLE_SIZE, .{}, @ptrCast(&frame.vertex_mapped)) != .success)
            return error.FailedToMapMemory;

        // Create index buffer (host visible, coherent)
        const ib_size = @as(vk.DeviceSize, MaxIndicesPerBatch * @sizeOf(u32));
        const ib_result = try self.createBufferAlloc(ib_size, .{ .index_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
        frame.index_buffer = ib_result[0];
        frame.index_memory = ib_result[1];
        if (mapMemory(self.dev, frame.index_memory, 0, vk.WHOLE_SIZE, .{}, @ptrCast(&frame.index_mapped)) != .success)
            return error.FailedToMapMemory;

        // Create uniform buffer
        const ub_size = @as(vk.DeviceSize, 256); // MVP matrix + other uniforms
        const ub_result = try self.createBufferAlloc(ub_size, .{ .uniform_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
        frame.uniform_buffer = ub_result[0];
        frame.uniform_memory = ub_result[1];
        if (mapMemory(self.dev, frame.uniform_memory, 0, vk.WHOLE_SIZE, .{}, @ptrCast(&frame.uniform_mapped)) != .success)
            return error.FailedToMapMemory;

        // Create descriptor pool
        const pool_sizes = [2]vk.DescriptorPoolSize{
            .{ .type = .uniform_buffer, .descriptor_count = 1 },
            .{ .type = .combined_image_sampler, .descriptor_count = MaxTexturesPerBatch },
        };
        const dp_info = vk.DescriptorPoolCreateInfo{
            .max_sets = 1,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
        };
        if (createDescriptorPool(self.dev, &dp_info, null, &frame.descriptor_pool) != .success)
            return error.FailedToCreateDescriptorPool;

        // Allocate descriptor set
        const ds_alloc = vk.DescriptorSetAllocateInfo{
            .descriptor_pool = frame.descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &surface.descriptor_set_layout,
        };
        if (allocateDescriptorSets(self.dev, &ds_alloc, &frame.descriptor_set) != .success)
            return error.FailedToAllocateDescriptorSets;
    }
}

fn rebuildSwapchain(self: *Vulkan, surface: *SurfaceObject) !void {
    // Wait for device idle
    // (In real implementation, wait for fences)

    // Clean up old swapchain resources
    for (surface.framebuffers) |fb| {
        destroyFramebuffer(self.dev, fb, null);
    }
    self.gpa.free(surface.framebuffers);
    for (surface.image_views) |view| {
        destroyImageView(self.dev, view, null);
    }
    self.gpa.free(surface.image_views);
    if (surface.swapchain != .null_handle) {
        destroySwapchainKHR(self.dev, surface.swapchain, null);
    }

    var caps: vk.SurfaceCapabilitiesKHR = undefined;
    if (getPhysicalDeviceSurfaceCapabilitiesKHR(self.gpu, surface.base, &caps) != .success)
        return error.FailedToGetSurfaceCapabilities;

    const extent = if (caps.current_extent.width != std.math.maxInt(u32))
        caps.current_extent
    else
        vk.Extent2D{
            .width = std.math.clamp(800, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(600, caps.min_image_extent.height, caps.max_image_extent.height),
        };

    var image_count = caps.min_image_count + 1;
    if (caps.max_image_count > 0 and image_count > caps.max_image_count) {
        image_count = caps.max_image_count;
    }

    const swapchain_info = vk.SwapchainCreateInfoKHR{
        .surface = surface.base,
        .min_image_count = image_count,
        .image_format = surface.format.format,
        .image_color_space = surface.format.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = null,
        .pre_transform = caps.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = surface.present_mode,
        .clipped = vk.TRUE,
        .old_swapchain = .null_handle,
    };

    if (createSwapchainKHR(self.dev, &swapchain_info, null, &surface.swapchain) != .success)
        return error.FailedToCreateSwapchain;

    surface.extent = extent;

    // Get swapchain images
    var img_count: u32 = 0;
    if (getSwapchainImagesKHR(self.dev, surface.swapchain, &img_count, null) != .success)
        return error.FailedToGetSwapchainImages;
    surface.images = try self.gpa.realloc(surface.images, img_count);
    if (getSwapchainImagesKHR(self.dev, surface.swapchain, &img_count, surface.images.ptr) != .success)
        return error.FailedToGetSwapchainImages;

    // Create image views
    surface.image_views = try self.gpa.realloc(surface.image_views, img_count);
    for (surface.images, 0..) |img, i| {
        const view_info = vk.ImageViewCreateInfo{
            .image = img,
            .view_type = .@"2d",
            .format = surface.format.format,
            .components = .{
                .r = .identity,
                .g = .identity,
                .b = .identity,
                .a = .identity,
            },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        if (createImageView(self.dev, &view_info, null, &surface.image_views[i]) != .success)
            return error.FailedToCreateImageView;
    }

    // Create framebuffers
    surface.framebuffers = try self.gpa.realloc(surface.framebuffers, img_count);
    for (surface.image_views, 0..) |view, i| {
        const attachments = [1]vk.ImageView{view};
        const fb_info = vk.FramebufferCreateInfo{
            .render_pass = surface.render_pass,
            .attachment_count = 1,
            .p_attachments = &attachments,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };
        if (createFramebuffer(self.dev, &fb_info, null, &surface.framebuffers[i]) != .success)
            return error.FailedToCreateFramebuffer;
    }

    surface.needs_rebuild = false;
}

pub fn createSurface(self_: *anyopaque, surface_: lu.Renderer.Surface) !lu.Renderer.ObjectId {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const vk_surface: vk.SurfaceKHR = @ptrCast(surface_);

    var supported: vk.Bool32 = 0;
    if (getPhysicalDeviceSurfaceSupportKHR(
        self.gpu,
        self.gqueue_index,
        vk_surface,
        &supported,
    ) != .success or supported == 0)
        return error.DeviceUnsupported;

    var caps: vk.SurfaceCapabilitiesKHR = undefined;
    if (getPhysicalDeviceSurfaceCapabilitiesKHR(self.gpu, vk_surface, &caps) != .success)
        return error.FailedToGetSurfaceCapabilities;

    var fmts_c: u32 = 0;
    if (getPhysicalDeviceSurfaceFormatsKHR(self.gpu, vk_surface, &fmts_c, null) != .success)
        return error.FailedToGetVkDeviceFormats;
    if (fmts_c == 0)
        return error.NoSupportedSurfaceFormats;
    const fmts = try self.gpa.alloc(vk.SurfaceFormatKHR, fmts_c);
    defer self.gpa.free(fmts);
    if (getPhysicalDeviceSurfaceFormatsKHR(self.gpu, vk_surface, &fmts_c, fmts.ptr) != .success)
        return error.FailedToGetVkDeviceFormats;

    var modes_c: u32 = 0;
    if (getPhysicalDeviceSurfacePresentModesKHR(self.gpu, vk_surface, &modes_c, null) != .success)
        return error.FailedToGetPresentModes;
    if (modes_c == 0)
        return error.NoSupportedPresentModes;
    const modes = try self.gpa.alloc(vk.PresentModeKHR, modes_c);
    defer self.gpa.free(modes);
    if (getPhysicalDeviceSurfacePresentModesKHR(self.gpu, vk_surface, &modes_c, modes.ptr) != .success)
        return error.FailedToGetPresentModes;

    // Choose surface format
    var surface_format = fmts[0];
    for (fmts) |fmt| {
        if (fmt.format == .b8g8r8a8_unorm and fmt.color_space == .srgb_nonlinear_khr) {
            surface_format = fmt;
            break;
        }
    }

    // Choose present mode
    var present_mode: vk.PresentModeKHR = .fifo_khr;
    for (modes) |mode| {
        if (mode == .mailbox_khr) {
            present_mode = mode;
            break;
        }
    }

    var surface_obj = SurfaceObject{
        .base = vk_surface,
        .swapchain = .null_handle,
        .extent = .{ .width = 0, .height = 0 },
        .format = surface_format,
        .present_mode = present_mode,
        .images = try self.gpa.alloc(vk.Image, 0),
        .image_views = try self.gpa.alloc(vk.ImageView, 0),
        .framebuffers = try self.gpa.alloc(vk.Framebuffer, 0),
        .render_pass = try self.createSurfaceRenderPass(surface_format.format),
        .pipeline = .null_handle,
        .pipeline_layout = .null_handle,
        .descriptor_set_layout = .null_handle,
        .depth_image = .null_handle,
        .depth_memory = .null_handle,
        .depth_view = .null_handle,
        .current_frame = 0,
        .frames = undefined,
        .vertices = std.ArrayList(Vertex).init(self.gpa),
        .indices = std.ArrayList(u32).init(self.gpa),
        .clip_stack = std.ArrayList(lu.Renderer.Rect).init(self.gpa),
        .current_texture_bindings = undefined,
        .texture_binding_count = 0,
        .needs_rebuild = true,
    };

    try self.createSurfacePipeline(&surface_obj);
    try self.createFrameData(&surface_obj);
    try self.rebuildSwapchain(&surface_obj);

    const id = self.generateId();
    try self.objs.put(id, .{
        .type = .surface,
        .data = .{ .surface = surface_obj },
    });
    return id;
}

pub fn destroySurface(self_: *anyopaque, id: lu.Renderer.ObjectId) void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const entry = self.objs.getPtr(id) orelse return;
    if (entry.type != .surface) return;

    var surface = &entry.data.surface;

    // Wait for GPU
    for (surface.frames) |frame| {
        if (frame.fence != .null_handle) {
            _ = waitForFences(self.dev, 1, &frame.fence, vk.TRUE, std.math.maxInt(u64));
        }
    }

    // Cleanup frames
    for (surface.frames) |frame| {
        if (frame.vertex_memory != .null_handle) {
            unmapMemory(self.dev, frame.vertex_memory);
            freeMemory(self.dev, frame.vertex_memory, null);
        }
        if (frame.vertex_buffer != .null_handle) destroyBuffer(self.dev, frame.vertex_buffer, null);
        if (frame.index_memory != .null_handle) {
            unmapMemory(self.dev, frame.index_memory);
            freeMemory(self.dev, frame.index_memory, null);
        }
        if (frame.index_buffer != .null_handle) destroyBuffer(self.dev, frame.index_buffer, null);
        if (frame.uniform_memory != .null_handle) {
            unmapMemory(self.dev, frame.uniform_memory);
            freeMemory(self.dev, frame.uniform_memory, null);
        }
        if (frame.uniform_buffer != .null_handle) destroyBuffer(self.dev, frame.uniform_buffer, null);
        if (frame.descriptor_pool != .null_handle) destroyDescriptorPool(self.dev, frame.descriptor_pool, null);
        if (frame.fence != .null_handle) destroyFence(self.dev, frame.fence, null);
        if (frame.image_available != .null_handle) destroySemaphore(self.dev, frame.image_available, null);
        if (frame.render_finished != .null_handle) destroySemaphore(self.dev, frame.render_finished, null);
        if (frame.cmd_pool != .null_handle) destroyCommandPool(self.dev, frame.cmd_pool, null);
    }

    // Cleanup swapchain
    for (surface.framebuffers) |fb| destroyFramebuffer(self.dev, fb, null);
    self.gpa.free(surface.framebuffers);
    for (surface.image_views) |view| destroyImageView(self.dev, view, null);
    self.gpa.free(surface.image_views);
    self.gpa.free(surface.images);

    if (surface.swapchain != .null_handle) destroySwapchainKHR(self.dev, surface.swapchain, null);
    if (surface.render_pass != .null_handle) destroyRenderPass(self.dev, surface.render_pass, null);
    if (surface.pipeline != .null_handle) destroyPipeline(self.dev, surface.pipeline, null);
    if (surface.pipeline_layout != .null_handle) destroyPipelineLayout(self.dev, surface.pipeline_layout, null);
    if (surface.descriptor_set_layout != .null_handle) destroyDescriptorSetLayout(self.dev, surface.descriptor_set_layout, null);
    if (surface.depth_view != .null_handle) destroyImageView(self.dev, surface.depth_view, null);
    if (surface.depth_image != .null_handle) destroyImage(self.dev, surface.depth_image, null);
    if (surface.depth_memory != .null_handle) freeMemory(self.dev, surface.depth_memory, null);

    surface.vertices.deinit();
    surface.indices.deinit();
    surface.clip_stack.deinit();

    _ = self.objs.remove(id);
}

pub fn getSurfaceInfo(self_: *anyopaque, id: lu.Renderer.ObjectId) lu.Renderer.SurfaceInfo {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const entry = self.objs.get(id) orelse return .{ .width = 0, .height = 0, .format = .rgba8, .vsync = false };
    if (entry.type != .surface) return .{ .width = 0, .height = 0, .format = .rgba8, .vsync = false };

    const surface = entry.data.surface;
    return .{
        .width = surface.extent.width,
        .height = surface.extent.height,
        .format = .rgba8, // Could map from vk.Format
        .vsync = surface.present_mode == .fifo_khr,
    };
}

pub fn resizeSurface(self_: *anyopaque, id: lu.Renderer.ObjectId, width: u32, height: u32) !void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const entry = self.objs.getPtr(id) orelse return error.InvalidObject;
    if (entry.type != .surface) return error.NotASurface;

    var surface = &entry.data.surface;
    surface.extent = .{ .width = width, .height = height };
    surface.needs_rebuild = true;
}

// ============================================================================
// Texture Management
// ============================================================================

fn textureFormatToVk(format: lu.Renderer.TextureFormat) vk.Format {
    return switch (format) {
        .rgba8 => .r8g8b8a8_unorm,
        .bgra8 => .b8g8r8a8_unorm,
        .rgb8 => .r8g8b8_unorm,
        .rgba16f => .r16g16b16a16_sfloat,
        .r8 => .r8_unorm,
    };
}

pub fn uploadTexture(self_: *anyopaque, data: []const u8, width: u32, height: u32, format: lu.Renderer.TextureFormat) !lu.Renderer.ObjectId {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const vk_format = textureFormatToVk(format);
    const bytes_per_pixel: u32 = switch (format) {
        .rgba8, .bgra8 => 4,
        .rgb8 => 3,
        .rgba16f => 8,
        .r8 => 1,
    };
    const expected_size = width * height * bytes_per_pixel;
    if (data.len < expected_size) return error.InvalidTextureData;

    // Create staging buffer
    const staging_size = @as(vk.DeviceSize, data.len);
    const staging = try self.createBufferAlloc(staging_size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer {
        destroyBuffer(self.dev, staging[0], null);
        freeMemory(self.dev, staging[1], null);
    }

    var mapped: [*]u8 = undefined;
    if (mapMemory(self.dev, staging[1], 0, staging_size, .{}, @ptrCast(&mapped)) != .success)
        return error.FailedToMapMemory;
    @memcpy(mapped[0..data.len], data);
    unmapMemory(self.dev, staging[1]);

    // Create image
    const image_result = try self.createImage2DAlloc(width, height, vk_format, .{ .transfer_dst_bit = true, .sampled_bit = true }, .{ .device_local_bit = true });
    const image = image_result[0];
    const memory = image_result[1];

    // Create image view
    const view_info = vk.ImageViewCreateInfo{
        .image = image,
        .view_type = .@"2d",
        .format = vk_format,
        .components = .{
            .r = .identity,
            .g = .identity,
            .b = .identity,
            .a = .identity,
        },
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    var view: vk.ImageView = undefined;
    if (createImageView(self.dev, &view_info, null, &view) != .success)
        return error.FailedToCreateImageView;

    // Create sampler
    const sampler_info = vk.SamplerCreateInfo{
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .linear,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 1,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = vk.FALSE,
        .compare_enable = vk.FALSE,
        .compare_op = .always,
        .min_lod = 0,
        .max_lod = 0,
        .mip_lod_bias = 0,
    };
    var sampler: vk.Sampler = undefined;
    if (createSampler(self.dev, &sampler_info, null, &sampler) != .success)
        return error.FailedToCreateSampler;

    // Copy staging to image using transfer queue
    // (Simplified: using graphics queue for now)
    const cmd_pool_info = vk.CommandPoolCreateInfo{
        .queue_family_index = self.gqueue_index,
        .flags = .{ .transient_bit = true },
    };
    var cmd_pool: vk.CommandPool = undefined;
    if (createCommandPool(self.dev, &cmd_pool_info, null, &cmd_pool) != .success)
        return error.FailedToCreateCommandPool;
    defer destroyCommandPool(self.dev, cmd_pool, null);

    const cmd_alloc = vk.CommandBufferAllocateInfo{
        .command_pool = cmd_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var cmd: vk.CommandBuffer = undefined;
    if (allocateCommandBuffers(self.dev, &cmd_alloc, &cmd) != .success)
        return error.FailedToAllocateCommandBuffers;

    const begin_info = vk.CommandBufferBeginInfo{ .flags = .{ .one_time_submit_bit = true } };
    if (beginCommandBuffer(cmd, &begin_info) != .success)
        return error.FailedToBeginCommandBuffer;

    self.transitionImageLayout(cmd, image, .undefined, .transfer_dst_optimal);

    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    cmdCopyBufferToImage(cmd, staging[0], image, .transfer_dst_optimal, 1, &region);

    self.transitionImageLayout(cmd, image, .transfer_dst_optimal, .shader_read_only_optimal);

    if (endCommandBuffer(cmd) != .success)
        return error.FailedToEndCommandBuffer;

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = &cmd,
    };
    if (vk.QueueSubmit(self.gqueue, 1, &submit_info, .null_handle) != .success)
        return error.FailedToSubmit;
    if (vk.QueueWaitIdle(self.gqueue) != .success)
        return error.FailedToWaitIdle;

    const id = self.generateId();
    try self.objs.put(id, .{
        .type = .texture,
        .data = .{ .texture = .{
            .image = image,
            .memory = memory,
            .view = view,
            .sampler = sampler,
            .width = width,
            .height = height,
            .format = format,
            .staging_buffer = null,
            .staging_memory = null,
        }},
    });
    return id;
}

pub fn destroyTexture(self_: *anyopaque, id: lu.Renderer.ObjectId) void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const entry = self.objs.getPtr(id) orelse return;
    if (entry.type != .texture) return;

    const tex = entry.data.texture;
    if (tex.sampler != .null_handle) destroySampler(self.dev, tex.sampler, null);
    if (tex.view != .null_handle) destroyImageView(self.dev, tex.view, null);
    if (tex.image != .null_handle) destroyImage(self.dev, tex.image, null);
    if (tex.memory != .null_handle) freeMemory(self.dev, tex.memory, null);

    _ = self.objs.remove(id);
}

pub fn getTextureInfo(self_: *anyopaque, id: lu.Renderer.ObjectId) lu.Renderer.TextureInfo {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const entry = self.objs.get(id) orelse return .{ .width = 0, .height = 0, .format = .rgba8 };
    if (entry.type != .texture) return .{ .width = 0, .height = 0, .format = .rgba8 };

    const tex = entry.data.texture;
    return .{
        .width = tex.width,
        .height = tex.height,
        .format = tex.format,
    };
}

// ============================================================================
// SVG Management (placeholder - needs tessellation library)
// ============================================================================

pub fn uploadSvg(self_: *anyopaque, data: []const u8) !lu.Renderer.ObjectId {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    _ = data;

    // TODO: Parse SVG, tessellate paths into triangles
    // For now, create a placeholder 1x1 white texture
    const white_pixel = [4]u8{ 255, 255, 255, 255 };
    return self.uploadTexture(&white_pixel, 1, 1, .rgba8);
}

pub fn destroySvg(self_: *anyopaque, id: lu.Renderer.ObjectId) void {
    // SVGs are stored as textures for now
    destroyTexture(self_, id);
}

// ============================================================================
// Frame Management
// ============================================================================

pub fn beginFrame(self_: *anyopaque, surface_id: lu.Renderer.ObjectId) !void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const entry = self.objs.getPtr(surface_id) orelse return error.InvalidSurface;
    if (entry.type != .surface) return error.NotASurface;

    var surface = &entry.data.surface;
    self.current_surface = surface_id;

    // Rebuild swapchain if needed
    if (surface.needs_rebuild) {
        try self.rebuildSwapchain(surface);
    }

    const frame_idx = surface.current_frame % MaxFramesInFlight;
    const frame = &surface.frames[frame_idx];
    self.current_frame_data = frame;

    // Wait for frame fence
    if (waitForFences(self.dev, 1, &frame.fence, vk.TRUE, std.math.maxInt(u64)) != .success)
        return error.FailedToWaitForFence;
    if (resetFences(self.dev, 1, &frame.fence) != .success)
        return error.FailedToResetFence;

    // Acquire next image
    var image_index: u32 = 0;
    const result = acquireNextImageKHR(self.dev, surface.swapchain, std.math.maxInt(u64), frame.image_available, .null_handle, &image_index);
    if (result == .error_out_of_date_khr) {
        surface.needs_rebuild = true;
        return error.SwapchainOutOfDate;
    } else if (result != .success and result != .suboptimal_khr) {
        return error.FailedToAcquireImage;
    }

    surface.current_image_index = image_index;

    // Reset command buffer
    // (Using VK_COMMAND_POOL_RESET_RELEASE_RESOURCES_BIT in pool creation)

    // Begin recording
    const begin_info = vk.CommandBufferBeginInfo{ .flags = .{ .one_time_submit_bit = true } };
    if (beginCommandBuffer(frame.cmd_buffer, &begin_info) != .success)
        return error.FailedToBeginCommandBuffer;

    self.current_cmd_buffer = frame.cmd_buffer;

    // Begin render pass
    const clear_color = vk.ClearValue{ .color = .{ .float_32 = .{ 0, 0, 0, 1 } } };
    const render_pass_info = vk.RenderPassBeginInfo{
        .render_pass = surface.render_pass,
        .framebuffer = surface.framebuffers[image_index],
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = surface.extent,
        },
        .clear_value_count = 1,
        .p_clear_values = &clear_color,
    };
    cmdBeginRenderPass(frame.cmd_buffer, &render_pass_info, .@"inline");

    // Bind pipeline
    cmdBindPipeline(frame.cmd_buffer, .graphics, surface.pipeline);

    // Set viewport
    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(surface.extent.width),
        .height = @floatFromInt(surface.extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    cmdSetViewport(frame.cmd_buffer, 0, 1, &viewport);

    // Set initial scissor (full surface)
    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = surface.extent,
    };
    cmdSetScissor(frame.cmd_buffer, 0, 1, &scissor);

    // Update uniform buffer with ortho projection
    const ortho = orthographicMatrix(0, @floatFromInt(surface.extent.width), @floatFromInt(surface.extent.height), 0, -1, 1);
    @memcpy(frame.uniform_mapped[0..@sizeOf([16]f32)], std.mem.asBytes(&ortho));

    // Clear vertex/index buffers
    surface.vertices.clearRetainingCapacity();
    surface.indices.clearRetainingCapacity();
    surface.clip_stack.clearRetainingCapacity();
    surface.texture_binding_count = 0;

    return;
}

fn orthographicMatrix(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) [16]f32 {
    return .{
        2 / (right - left), 0, 0, -(right + left) / (right - left),
        0, 2 / (top - bottom), 0, -(top + bottom) / (top - bottom),
        0, 0, -2 / (far - near), -(far + near) / (far - near),
        0, 0, 0, 1,
    };
}

pub fn endFrame(self_: *anyopaque) !void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const surface_id = self.current_surface orelse return error.NoActiveFrame;
    const entry = self.objs.getPtr(surface_id) orelse return error.InvalidSurface;
    if (entry.type != .surface) return error.NotASurface;

    var surface = &entry.data.surface;
    const frame = self.current_frame_data orelse return error.NoActiveFrame;

    // Flush remaining vertices if any
    if (surface.vertices.items.len > 0) {
        try self.flushBatch(surface, frame);
    }

    cmdEndRenderPass(frame.cmd_buffer);

    if (endCommandBuffer(frame.cmd_buffer) != .success)
        return error.FailedToEndCommandBuffer;

    // Submit
    const wait_stages = vk.PipelineStageFlags{ .color_attachment_output_bit = true };
    const submit_info = vk.SubmitInfo{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &frame.image_available,
        .p_wait_dst_stage_mask = &wait_stages,
        .command_buffer_count = 1,
        .p_command_buffers = &frame.cmd_buffer,
        .signal_semaphore_count = 1,
        .p_signal_semaphores = &frame.render_finished,
    };

    if (vk.QueueSubmit(self.gqueue, 1, &submit_info, frame.fence) != .success)
        return error.FailedToSubmit;

    var present_info = vk.PresentInfoKHR{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = &frame.render_finished,
        .swapchain_count = 1,
        .p_swapchains = &surface.swapchain,
        .p_image_indices = &surface.current_image_index,
    };

    _ = queuePresentKHR(self.gqueue, &present_info);

    surface.current_frame = (surface.current_frame + 1) % MaxFramesInFlight;
    self.current_surface = null;
    self.current_frame_data = null;
}

// ============================================================================
// Batch Flushing
// ============================================================================

fn flushBatch(self: *Vulkan, surface: *SurfaceObject, frame: *FrameData) !void {
    const vertex_count = surface.vertices.items.len;
    const index_count = surface.indices.items.len;
    if (vertex_count == 0 or index_count == 0) return;

    // Copy vertex data to mapped buffer
    @memcpy(frame.vertex_mapped[0..vertex_count], surface.vertices.items);
    // Copy index data to mapped buffer
    @memcpy(frame.index_mapped[0..index_count], surface.indices.items);

    // Update descriptor set with texture binding
    const tex_view = if (surface.texture_binding_count > 0)
        surface.current_texture_bindings[0]
    else
        self.default_texture_view;

    var image_info = vk.DescriptorImageInfo{
        .sampler = self.default_sampler,
        .image_view = tex_view,
        .image_layout = .shader_read_only_optimal,
    };
    var descriptor_write = vk.WriteDescriptorSet{
        .dst_set = frame.descriptor_set,
        .dst_binding = 1,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = &image_info,
        .p_buffer_info = null,
        .p_texel_buffer_view = null,
    };
    updateDescriptorSets(self.dev, 1, &descriptor_write, 0, null);

    // Bind vertex and index buffers
    const offsets = [1]vk.DeviceSize{0};
    cmdBindVertexBuffers(frame.cmd_buffer, 0, 1, &frame.vertex_buffer, &offsets);
    cmdBindIndexBuffer(frame.cmd_buffer, frame.index_buffer, 0, .uint32);

    // Draw
    cmdDrawIndexed(frame.cmd_buffer, @intCast(index_count), 1, 0, 0, 0);

    // Clear for next batch
    surface.vertices.clearRetainingCapacity();
    surface.indices.clearRetainingCapacity();
    surface.texture_binding_count = 0;
}

fn ensureBatchCapacity(self: *Vulkan, surface: *SurfaceObject, extra_vertices: u32, extra_indices: u32) void {
    if (surface.vertices.items.len + extra_vertices > MaxVerticesPerBatch or
        surface.indices.items.len + extra_indices > MaxIndicesPerBatch)
    {
        const frame_idx = surface.current_frame % MaxFramesInFlight;
        self.flushBatch(surface, &surface.frames[frame_idx]) catch return;
    }
}

// ============================================================================
// Drawing
// ============================================================================

fn encodeFlags(shape_type: u8, has_texture: bool, has_gradient: bool) u32 {
    return @as(u32, shape_type) |
        (@as(u32, @intFromBool(has_texture)) << 8) |
        (@as(u32, @intFromBool(has_gradient)) << 16);
}

pub fn drawRect(self_: *anyopaque, rect: lu.Renderer.Rect, pos: lu.Pos, corners: lu.Corners, bg: lu.Renderer.Background) void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const surface_id = self.current_surface orelse return;
    const entry = self.objs.getPtr(surface_id) orelse return;
    if (entry.type != .surface) return;
    var surface = &entry.data.surface;

    self.ensureBatchCapacity(surface, 4, 6);

    const w = @as(f32, @floatFromInt(rect.w));
    const h = @as(f32, @floatFromInt(rect.h));
    const x = @as(f32, @floatFromInt(pos.x));
    const y = @as(f32, @floatFromInt(pos.y));

    var color: [4]f32 = .{ 1, 1, 1, 1 };
    var uv_rect = lu.Renderer.UVRect{};
    var has_texture: bool = false;

    switch (bg) {
        .solid => |c| {
            color = .{ c.r, c.g, c.b, c.a };
        },
        .texture => |t| {
            has_texture = true;
            uv_rect = t.uv;
            const tex_entry = self.objs.get(t.id) orelse return;
            if (tex_entry.type != .texture) return;
            if (surface.texture_binding_count == 0 or
                surface.current_texture_bindings[0] != tex_entry.data.texture.view)
            {
                if (surface.texture_binding_count > 0) {
                    self.ensureBatchCapacity(surface, 0, 0);
                    const frame_idx = surface.current_frame % MaxFramesInFlight;
                    self.flushBatch(surface, &surface.frames[frame_idx]) catch return;
                }
                surface.current_texture_bindings[0] = tex_entry.data.texture.view;
                surface.texture_binding_count = 1;
            }
        },
        .gradient => |g| {
            if (g.stops.len > 0) {
                const c = g.stops[0].color;
                color = .{ c.r, c.g, c.b, c.a };
            }
        },
    }

    const shape_data = [4]f32{
        @floatFromInt(corners.top_left),
        @floatFromInt(corners.top_right),
        @floatFromInt(corners.bottom_left),
        @floatFromInt(corners.bottom_right),
    };
    const max_radius = @max(corners.top_left, corners.top_right, corners.bottom_left, corners.bottom_right);

    const base_index = @as(u32, @intCast(surface.vertices.items.len));

    const positions = [4][2]f32{
        .{ x, y },
        .{ x + w, y },
        .{ x, y + h },
        .{ x + w, y + h },
    };
    const uvs = [4][2]f32{
        .{ uv_rect.x, uv_rect.y },
        .{ uv_rect.x + uv_rect.w, uv_rect.y },
        .{ uv_rect.x, uv_rect.y + uv_rect.h },
        .{ uv_rect.x + uv_rect.w, uv_rect.y + uv_rect.h },
    };

    inline for (0..4) |i| {
        surface.vertices.append(.{
            .pos = positions[i],
            .uv = uvs[i],
            .color = color,
            .flags = encodeFlags(0, has_texture, false),
            .corner_radius = @floatFromInt(max_radius),
            .rect_size = .{ w, h },
            .shape_data = shape_data,
        }) catch return;
    }

    surface.indices.appendSlice(&.{
        base_index, base_index + 1, base_index + 2,
        base_index + 1, base_index + 3, base_index + 2,
    }) catch return;
}

pub fn drawCircle(self_: *anyopaque, radius: f32, pos: lu.Pos, bg: lu.Renderer.Background) void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const surface_id = self.current_surface orelse return;
    const entry = self.objs.getPtr(surface_id) orelse return;
    if (entry.type != .surface) return;
    var surface = &entry.data.surface;

    const segments: u32 = 64;
    self.ensureBatchCapacity(surface, segments + 1, segments * 3);

    var color: [4]f32 = .{ 1, 1, 1, 1 };
    var uv_rect = lu.Renderer.UVRect{};
    var has_texture: bool = false;

    switch (bg) {
        .solid => |c| {
            color = .{ c.r, c.g, c.b, c.a };
        },
        .texture => |t| {
            has_texture = true;
            uv_rect = t.uv;
            const tex_entry = self.objs.get(t.id) orelse return;
            if (tex_entry.type != .texture) return;
            if (surface.texture_binding_count == 0 or
                surface.current_texture_bindings[0] != tex_entry.data.texture.view)
            {
                if (surface.texture_binding_count > 0) {
                    self.ensureBatchCapacity(surface, 0, 0);
                    const frame_idx = surface.current_frame % MaxFramesInFlight;
                    self.flushBatch(surface, &surface.frames[frame_idx]) catch return;
                }
                surface.current_texture_bindings[0] = tex_entry.data.texture.view;
                surface.texture_binding_count = 1;
            }
        },
        .gradient => |g| {
            if (g.stops.len > 0) {
                const c = g.stops[0].color;
                color = .{ c.r, c.g, c.b, c.a };
            }
        },
    }

    const center_x = @as(f32, @floatFromInt(pos.x)) + radius;
    const center_y = @as(f32, @floatFromInt(pos.y)) + radius;
    const diameter = radius * 2;

    const base_index = @as(u32, @intCast(surface.vertices.items.len));

    // Center vertex
    surface.vertices.append(.{
        .pos = .{ center_x, center_y },
        .uv = .{ uv_rect.x + uv_rect.w * 0.5, uv_rect.y + uv_rect.h * 0.5 },
        .color = color,
        .flags = encodeFlags(1, has_texture, false),
        .corner_radius = 0,
        .rect_size = .{ diameter, diameter },
        .shape_data = .{ radius, 0, 0, 0 },
    }) catch return;

    // Rim vertices
    var i: u32 = 0;
    while (i < segments) : (i += 1) {
        const angle = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) * std.math.pi * 2.0;
        const vx = center_x + @cos(angle) * radius;
        const vy = center_y + @sin(angle) * radius;
        const u = uv_rect.x + uv_rect.w * ((@cos(angle) + 1.0) * 0.5);
        const v = uv_rect.y + uv_rect.h * ((@sin(angle) + 1.0) * 0.5);

        surface.vertices.append(.{
            .pos = .{ vx, vy },
            .uv = .{ u, v },
            .color = color,
            .flags = encodeFlags(1, has_texture, false),
            .corner_radius = 0,
            .rect_size = .{ diameter, diameter },
            .shape_data = .{ radius, 0, 0, 0 },
        }) catch return;
    }

    // Indices: triangle fan (center, rim[i], rim[i+1])
    i = 0;
    while (i < segments) : (i += 1) {
        const next = (i + 1) % segments;
        surface.indices.appendSlice(&.{
            base_index,
            base_index + i + 1,
            base_index + next + 1,
        }) catch return;
    }
}

pub fn drawTriangle(self_: *anyopaque, a: lu.Pos, b: lu.Pos, c: lu.Pos, bg: lu.Renderer.Background) void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const surface_id = self.current_surface orelse return;
    const entry = self.objs.getPtr(surface_id) orelse return;
    if (entry.type != .surface) return;
    var surface = &entry.data.surface;

    self.ensureBatchCapacity(surface, 3, 3);

    var color: [4]f32 = .{ 1, 1, 1, 1 };
    var has_texture: bool = false;

    switch (bg) {
        .solid => |col| {
            color = .{ col.r, col.g, col.b, col.a };
        },
        .texture => |t| {
            has_texture = true;
            const tex_entry = self.objs.get(t.id) orelse return;
            if (tex_entry.type != .texture) return;
            if (surface.texture_binding_count == 0 or
                surface.current_texture_bindings[0] != tex_entry.data.texture.view)
            {
                if (surface.texture_binding_count > 0) {
                    self.ensureBatchCapacity(surface, 0, 0);
                    const frame_idx = surface.current_frame % MaxFramesInFlight;
                    self.flushBatch(surface, &surface.frames[frame_idx]) catch return;
                }
                surface.current_texture_bindings[0] = tex_entry.data.texture.view;
                surface.texture_binding_count = 1;
            }
        },
        .gradient => |g| {
            if (g.stops.len > 0) {
                const col = g.stops[0].color;
                color = .{ col.r, col.g, col.b, col.a };
            }
        },
    }

    const base_index = @as(u32, @intCast(surface.vertices.items.len));

    const verts = [3][2]f32{
        .{ @floatFromInt(a.x), @floatFromInt(a.y) },
        .{ @floatFromInt(b.x), @floatFromInt(b.y) },
        .{ @floatFromInt(c.x), @floatFromInt(c.y) },
    };

    inline for (0..3) |i| {
        surface.vertices.append(.{
            .pos = verts[i],
            .uv = .{ 0, 0 },
            .color = color,
            .flags = encodeFlags(2, has_texture, false),
            .corner_radius = 0,
            .rect_size = .{ 0, 0 },
            .shape_data = .{ 0, 0, 0, 0 },
        }) catch return;
    }

    surface.indices.appendSlice(&.{
        base_index, base_index + 1, base_index + 2,
    }) catch return;
}

pub fn drawSvg(self_: *anyopaque, svg_id: lu.Renderer.ObjectId, pos: lu.Pos, size: lu.Rect) void {
    const bg: lu.Renderer.Background = .{ .texture = .{ .id = svg_id } };
    drawRect(self_, size, pos, lu.Corners.all(0), bg);
}

pub fn drawMask(self_: *anyopaque, mask: lu.Renderer.Mask, pos: lu.Pos, bg: lu.Renderer.Background) void {
    switch (mask) {
        .rect => |r| {
            drawRect(self_, r.rect, pos, r.corners, bg);
        },
        .circle => |c| {
            drawCircle(self_, c.radius, pos, bg);
        },
        .triangle => |t| {
            drawTriangle(self_, t.a, t.b, t.c, bg);
        },
        .svg => {
            // TODO: SVG mask support
        },
    }
}

// ============================================================================
// Clipping
// ============================================================================

pub fn pushClip(self_: *anyopaque, rect: lu.Renderer.Rect) void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const surface_id = self.current_surface orelse return;
    const entry = self.objs.getPtr(surface_id) orelse return;
    if (entry.type != .surface) return;
    var surface = &entry.data.surface;

    surface.clip_stack.append(.{ .w = rect.w, .h = rect.h }) catch return;

    // Flush current batch before changing scissor
    if (surface.vertices.items.len > 0) {
        const frame_idx = surface.current_frame % MaxFramesInFlight;
        self.flushBatch(surface, &surface.frames[frame_idx]) catch return;
    }

    // Set scissor rect
    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = rect.w, .height = rect.h },
    };
    cmdSetScissor(self.current_cmd_buffer, 0, 1, &scissor);
}

pub fn popClip(self_: *anyopaque) void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));
    const surface_id = self.current_surface orelse return;
    const entry = self.objs.getPtr(surface_id) orelse return;
    if (entry.type != .surface) return;
    var surface = &entry.data.surface;

    _ = surface.clip_stack.pop() orelse return;

    // Flush current batch before changing scissor
    if (surface.vertices.items.len > 0) {
        const frame_idx = surface.current_frame % MaxFramesInFlight;
        self.flushBatch(surface, &surface.frames[frame_idx]) catch return;
    }

    // Restore scissor to previous clip or full surface
    const scissor = if (surface.clip_stack.items.len > 0)
        vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = surface.clip_stack.items[surface.clip_stack.items.len - 1],
        }
    else
        vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = surface.extent,
        };

    cmdSetScissor(self.current_cmd_buffer, 0, 1, &scissor);
}

// ============================================================================
// Cleanup
// ============================================================================

pub fn deinit(self_: *anyopaque) void {
    const self: *Vulkan = @ptrCast(@alignCast(self_));

    // Destroy default texture
    if (self.default_texture_id != 0) {
        const entry = self.objs.get(self.default_texture_id);
        if (entry) |e| {
            if (e.type == .texture) {
                const tex = e.data.texture;
                if (tex.sampler != .null_handle) destroySampler(self.dev, tex.sampler, null);
                if (tex.view != .null_handle) destroyImageView(self.dev, tex.view, null);
                if (tex.image != .null_handle) destroyImage(self.dev, tex.image, null);
                if (tex.memory != .null_handle) freeMemory(self.dev, tex.memory, null);
            }
        }
        _ = self.objs.remove(self.default_texture_id);
    }

    // Destroy default sampler
    if (self.default_sampler != .null_handle) destroySampler(self.dev, self.default_sampler, null);

    // Destroy shader modules
    if (self.vert_module != .null_handle) destroyShaderModule(self.dev, self.vert_module, null);
    if (self.frag_module != .null_handle) destroyShaderModule(self.dev, self.frag_module, null);

    // Destroy all remaining objects
    var iter = self.objs.iterator();
    while (iter.next()) |kv| {
        switch (kv.value_ptr.type) {
            .surface => {
                var surface = &kv.value_ptr.data.surface;
                for (surface.frames) |frame| {
                    if (frame.vertex_memory != .null_handle) {
                        unmapMemory(self.dev, frame.vertex_memory);
                        freeMemory(self.dev, frame.vertex_memory, null);
                    }
                    if (frame.vertex_buffer != .null_handle) destroyBuffer(self.dev, frame.vertex_buffer, null);
                    if (frame.index_memory != .null_handle) {
                        unmapMemory(self.dev, frame.index_memory);
                        freeMemory(self.dev, frame.index_memory, null);
                    }
                    if (frame.index_buffer != .null_handle) destroyBuffer(self.dev, frame.index_buffer, null);
                    if (frame.uniform_memory != .null_handle) {
                        unmapMemory(self.dev, frame.uniform_memory);
                        freeMemory(self.dev, frame.uniform_memory, null);
                    }
                    if (frame.uniform_buffer != .null_handle) destroyBuffer(self.dev, frame.uniform_buffer, null);
                    if (frame.descriptor_pool != .null_handle) destroyDescriptorPool(self.dev, frame.descriptor_pool, null);
                    if (frame.fence != .null_handle) destroyFence(self.dev, frame.fence, null);
                    if (frame.image_available != .null_handle) destroySemaphore(self.dev, frame.image_available, null);
                    if (frame.render_finished != .null_handle) destroySemaphore(self.dev, frame.render_finished, null);
                    if (frame.cmd_pool != .null_handle) destroyCommandPool(self.dev, frame.cmd_pool, null);
                }
                for (surface.framebuffers) |fb| destroyFramebuffer(self.dev, fb, null);
                self.gpa.free(surface.framebuffers);
                for (surface.image_views) |view| destroyImageView(self.dev, view, null);
                self.gpa.free(surface.image_views);
                self.gpa.free(surface.images);
                if (surface.swapchain != .null_handle) destroySwapchainKHR(self.dev, surface.swapchain, null);
                if (surface.render_pass != .null_handle) destroyRenderPass(self.dev, surface.render_pass, null);
                if (surface.pipeline != .null_handle) destroyPipeline(self.dev, surface.pipeline, null);
                if (surface.pipeline_layout != .null_handle) destroyPipelineLayout(self.dev, surface.pipeline_layout, null);
                if (surface.descriptor_set_layout != .null_handle) destroyDescriptorSetLayout(self.dev, surface.descriptor_set_layout, null);
                if (surface.depth_view != .null_handle) destroyImageView(self.dev, surface.depth_view, null);
                if (surface.depth_image != .null_handle) destroyImage(self.dev, surface.depth_image, null);
                if (surface.depth_memory != .null_handle) freeMemory(self.dev, surface.depth_memory, null);
                surface.vertices.deinit();
                surface.indices.deinit();
                surface.clip_stack.deinit();
            },
            .texture => {
                const tex = kv.value_ptr.data.texture;
                if (tex.sampler != .null_handle) destroySampler(self.dev, tex.sampler, null);
                if (tex.view != .null_handle) destroyImageView(self.dev, tex.view, null);
                if (tex.image != .null_handle) destroyImage(self.dev, tex.image, null);
                if (tex.memory != .null_handle) freeMemory(self.dev, tex.memory, null);
            },
            .svg => {
                const svg = kv.value_ptr.data.svg;
                if (svg.vertex_buffer != .null_handle) {
                    unmapMemory(self.dev, svg.vertex_memory);
                    freeMemory(self.dev, svg.vertex_memory, null);
                    destroyBuffer(self.dev, svg.vertex_buffer, null);
                }
                if (svg.index_buffer != .null_handle) {
                    unmapMemory(self.dev, svg.index_memory);
                    freeMemory(self.dev, svg.index_memory, null);
                    destroyBuffer(self.dev, svg.index_buffer, null);
                }
            },
        }
    }
    self.objs.deinit();

    // Destroy device and instance
    if (self.dev != .null_handle) destroyDevice(self.dev, null);
    if (self.instance != .null_handle) destroyInstance(self.instance, null);
}
