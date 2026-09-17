#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <chrono>
#include <mokaid/renderer/renderer.hpp>
#include <unordered_map>
#include "office_lighting.hpp"

namespace mokaid::renderer {
namespace {
struct Uniforms {
  engine::Mat4 viewProjection, model;
  engine::Vec4 color, emissive, camera, params, display;
};
static_assert(sizeof(Uniforms) == 208);
struct GpuMesh {
  id<MTLBuffer> vertices;
  id<MTLBuffer> indices;
};
struct GpuScene {
  std::shared_ptr<const engine::Scene> source;
  std::vector<GpuMesh> meshes;
  std::vector<id<MTLTexture>> textures;
};
struct EncodingLease {
  id<MTLRenderCommandEncoder> encoder;
  id<MTLCommandBuffer> commands;
  NSMutableArray<id> *resources;
  std::shared_ptr<std::atomic_bool> failed;
  ~EncodingLease() {
    // End and retain recorded work even if a later bone allocation throws.
    // Qt can safely continue its own encoder on this borrowed command buffer.
    [encoder endEncoding];
    const auto retained = resources;
    const auto failure = failed;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
      (void)retained.count;
      if (buffer.status == MTLCommandBufferStatusError)
        failure->store(true, std::memory_order_release);
    }];
  }
};
class MetalRenderer final : public Renderer {
  id<MTLDevice> device_;
  id<MTLRenderPipelineState> opaque_, transparent_;
  id<MTLComputePipelineState> downsample_, blur_, composite_;
  id<MTLDepthStencilState> depth_, noDepthWrite_;
  id<MTLSamplerState> sampler_;
  id<MTLTexture> color_, hdr_, emission_, bloomA_, bloomB_, depthTexture_, white_;
  id<MTLBuffer> identityBones_;
  std::unordered_map<const engine::Scene *, GpuScene> scenes_;
  Statistics stats_;
  std::shared_ptr<std::atomic_bool> commandFailed_{
      std::make_shared<std::atomic_bool>(false)};
  std::uint32_t width_{}, height_{};
  GpuScene &upload(const std::shared_ptr<const engine::Scene> &scene) {
    auto [it, inserted] = scenes_.try_emplace(scene.get());
    if (!inserted)
      return it->second;
    auto &gpu = it->second;
    gpu.source = scene;
    for (const auto &m : scene->meshes) {
      GpuMesh g;
      g.vertices =
          [device_ newBufferWithBytes:m.vertices.data()
                               length:m.vertices.size() * sizeof(engine::Vertex)
                              options:MTLResourceStorageModeShared];
      g.indices = [device_ newBufferWithBytes:m.indices.data()
                                       length:m.indices.size() * 4
                                      options:MTLResourceStorageModeShared];
      if (!g.vertices || !g.indices)
        throw std::runtime_error("Metal geometry allocation failed");
      gpu.meshes.push_back(g);
    }
    for (const auto &t : scene->textures) {
      const auto &m = t.mips.front();
      auto desc = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:t.srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm
                                       width:m.width
                                      height:m.height
                                   mipmapped:YES];
      desc.mipmapLevelCount = t.mips.size();
      desc.storageMode = MTLStorageModeShared;
      desc.usage = MTLTextureUsageShaderRead;
      id<MTLTexture> tex = [device_ newTextureWithDescriptor:desc];
      if (!tex)
        throw std::runtime_error("Metal texture allocation failed");
      for (std::size_t l = 0; l < t.mips.size(); ++l) {
        const auto &mip = t.mips[l];
        [tex replaceRegion:MTLRegionMake2D(0, 0, mip.width, mip.height)
               mipmapLevel:l
                 withBytes:mip.rgba.data()
               bytesPerRow:mip.width * 4];
        stats_.textureBytes += mip.rgba.size();
      }
      gpu.textures.push_back(tex);
    }
    return gpu;
  }

public:
  MetalRenderer(const Context &context, const std::filesystem::path &shaders)
      : device_((__bridge id<MTLDevice>)context.device) {
    if (!device_)
      throw std::runtime_error("Qt Metal device is unavailable");
    NSError *error = nil;
    NSString *path = [NSString
        stringWithUTF8String:(shaders / "office.metallib").string().c_str()];
    id<MTLLibrary> library =
        [device_ newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
    if (!library)
      throw std::runtime_error("Cannot load compiled Metal shader library");
    auto desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [library newFunctionWithName:@"officeVertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"officeFragment"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    desc.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
    desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    opaque_ = [device_ newRenderPipelineStateWithDescriptor:desc error:&error];
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor =
        MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[1].blendingEnabled = YES;
    desc.colorAttachments[1].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[1].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[1].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[1].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    transparent_ = [device_ newRenderPipelineStateWithDescriptor:desc
                                                           error:&error];
    if (!opaque_ || !transparent_)
      throw std::runtime_error("Metal pipeline creation failed");
    downsample_ = [device_ newComputePipelineStateWithFunction:[library newFunctionWithName:@"bloomDownsample"] error:&error];
    blur_ = [device_ newComputePipelineStateWithFunction:[library newFunctionWithName:@"bloomBlur"] error:&error];
    composite_ = [device_ newComputePipelineStateWithFunction:[library newFunctionWithName:@"officeComposite"] error:&error];
    if (!downsample_ || !blur_ || !composite_)
      throw std::runtime_error("Metal post-processing pipeline creation failed");
    auto d = [[MTLDepthStencilDescriptor alloc] init];
    d.depthCompareFunction = MTLCompareFunctionLess;
    d.depthWriteEnabled = YES;
    depth_ = [device_ newDepthStencilStateWithDescriptor:d];
    d.depthWriteEnabled = NO;
    noDepthWrite_ = [device_ newDepthStencilStateWithDescriptor:d];
    auto s = [[MTLSamplerDescriptor alloc] init];
    s.minFilter = MTLSamplerMinMagFilterLinear;
    s.magFilter = MTLSamplerMinMagFilterLinear;
    s.mipFilter = MTLSamplerMipFilterLinear;
    s.sAddressMode = MTLSamplerAddressModeRepeat;
    s.tAddressMode = MTLSamplerAddressModeRepeat;
    s.maxAnisotropy = 4;
    sampler_ = [device_ newSamplerStateWithDescriptor:s];
    auto td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB
                                     width:1
                                    height:1
                                 mipmapped:NO];
    white_ = [device_ newTextureWithDescriptor:td];
    const std::uint32_t white = 0xffffffff;
    [white_ replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
              mipmapLevel:0
                withBytes:&white
              bytesPerRow:4];
    const std::array<engine::Mat4, engine::maxSkinJoints> identity{};
    identityBones_ = [device_ newBufferWithBytes:identity.data()
                                          length:sizeof(identity)
                                         options:MTLResourceStorageModeShared];
  }
  void resize(std::uint32_t w, std::uint32_t h) override {
    if (w == width_ && h == height_)
      return;
    auto desc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:w
                                    height:h
                                 mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    id<MTLTexture> nextColor = [device_ newTextureWithDescriptor:desc];
    desc.pixelFormat = MTLPixelFormatRGBA16Float;
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> nextHdr = [device_ newTextureWithDescriptor:desc];
    id<MTLTexture> nextEmission = [device_ newTextureWithDescriptor:desc];
    desc.width = std::max(1U, (w + 1) / 2);
    desc.height = std::max(1U, (h + 1) / 2);
    desc.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead;
    id<MTLTexture> nextBloomA = [device_ newTextureWithDescriptor:desc];
    id<MTLTexture> nextBloomB = [device_ newTextureWithDescriptor:desc];
    desc.width = w; desc.height = h;
    desc.pixelFormat = MTLPixelFormatDepth32Float;
    desc.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> nextDepth = [device_ newTextureWithDescriptor:desc];
    if (!nextColor || !nextDepth || !nextHdr || !nextEmission || !nextBloomA || !nextBloomB)
      throw std::runtime_error("Metal render target allocation failed");
    color_ = nextColor; hdr_ = nextHdr; emission_ = nextEmission;
    bloomA_ = nextBloomA; bloomB_ = nextBloomB;
    depthTexture_ = nextDepth;
    width_ = w;
    height_ = h;
  }
  void *texture() const override { return (__bridge void *)color_; }
  void render(const Context &context, const engine::Frame &frame) override {
    if (commandFailed_->load(std::memory_order_acquire))
      throw std::runtime_error(
          "Metal command buffer failed; recreate the viewport");
    const auto start = std::chrono::steady_clock::now();
    id<MTLCommandBuffer> commands =
        (__bridge id<MTLCommandBuffer>)context.commands;
    if (!commands || !color_)
      return;
    for (const auto &i : frame.instances)
      upload(i.scene);
    // Evaluate each instance once, shared by opaque and transparent passes.
    std::vector<engine::Pose> poses;
    poses.reserve(frame.instances.size());
    for (const auto &instance : frame.instances)
      poses.push_back(engine::evaluateInstancePose(instance));
    // Keep resources through completion even if Qt internally records an
    // unretained command buffer. This also protects resize and item deletion.
    NSMutableArray<id> *inFlight = [NSMutableArray
        arrayWithObjects:color_, hdr_, emission_, bloomA_, bloomB_, downsample_, blur_, composite_,
                         depthTexture_, opaque_, transparent_, depth_,
                         noDepthWrite_, sampler_, white_, identityBones_, nil];
    for (const auto &[key, gpu] : scenes_) {
      (void)key;
      for (const auto &mesh : gpu.meshes) {
        [inFlight addObject:mesh.vertices];
        [inFlight addObject:mesh.indices];
      }
      for (id<MTLTexture> texture : gpu.textures)
        [inFlight addObject:texture];
    }
    {
      auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
      pass.colorAttachments[0].texture = hdr_;
      pass.colorAttachments[1].texture = emission_;
      pass.colorAttachments[1].loadAction = MTLLoadActionClear;
      pass.colorAttachments[1].storeAction = MTLStoreActionStore;
      pass.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 1);
      pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      pass.colorAttachments[0].clearColor =
          // Inverse display transform of Theme.background (#0b0b10).
          MTLClearColorMake(.008505, .008505, .011558, 1);
      pass.depthAttachment.texture = depthTexture_;
      pass.depthAttachment.loadAction = MTLLoadActionClear;
      pass.depthAttachment.storeAction = MTLStoreActionDontCare;
      pass.depthAttachment.clearDepth = 1;
      id<MTLRenderCommandEncoder> encoder =
          [commands renderCommandEncoderWithDescriptor:pass];
      if (!encoder)
        throw std::runtime_error("Metal render encoder creation failed");
      const EncodingLease encoding{encoder, commands, inFlight, commandFailed_};
      [encoder setCullMode:MTLCullModeNone];
      [encoder setFragmentSamplerState:sampler_ atIndex:0];
      const auto lighting = lightingFor(frame);
      [encoder setFragmentBytes:&lighting length:sizeof(lighting) atIndex:3];
      stats_.drawCalls = 0;
      stats_.triangles = 0;
      for (int alphaPass = 0; alphaPass < 2; ++alphaPass) {
        [encoder setRenderPipelineState:alphaPass ? transparent_ : opaque_];
        [encoder setDepthStencilState:alphaPass ? noDepthWrite_ : depth_];
        for (std::size_t instanceIndex = 0; instanceIndex < frame.instances.size(); ++instanceIndex) {
          const auto &i = frame.instances[instanceIndex];
          const auto &s = *i.scene;
          const auto &pose = poses[instanceIndex];
          const auto &gpu = scenes_.at(i.scene.get());
          for (std::size_t j = 0; j < s.meshes.size(); ++j) {
            const auto &m = s.meshes[j];
            const auto &mat = s.materials[m.material];
            if ((i.surfaceMask & (1U << mat.surfaceKind)) == 0) continue;
            if ((mat.alphaMode == 2) != (alphaPass == 1))
              continue;
            const Uniforms u{frame.viewProjection,
                             i.transform * pose.world[m.node],
                             mat.color,
                             {mat.emissive.x, mat.emissive.y, mat.emissive.z, mat.metallic},
                             {frame.camera.x, frame.camera.y, frame.camera.z, 1},
                             {m.skin >= 0 ? 1.F : 0.F,
                              static_cast<float>(mat.alphaMode), mat.alphaCutoff,
                              mat.roughness},
                             {static_cast<float>(mat.surfaceKind), frame.sceneSeconds,
                              static_cast<float>(m.material + m.node * 3), 0}};
            id<MTLBuffer> boneBuffer = identityBones_;
            if (m.skin >= 0) {
              const auto bones = engine::skinMatrices(s, m, pose);
              boneBuffer =
                  [device_ newBufferWithBytes:bones.data()
                                       length:sizeof(bones)
                                      options:MTLResourceStorageModeShared];
            }
            if (!boneBuffer)
              throw std::runtime_error("Metal skin palette allocation failed");
            [encoder setVertexBuffer:gpu.meshes[j].vertices offset:0 atIndex:0];
            [encoder setVertexBytes:&u length:sizeof(u) atIndex:1];
            [inFlight addObject:boneBuffer];
            [encoder setVertexBuffer:boneBuffer offset:0 atIndex:2];
            [encoder setFragmentBytes:&u length:sizeof(u) atIndex:1];
            [encoder
                setFragmentTexture:mat.texture >= 0
                                       ? gpu.textures[static_cast<std::size_t>(
                                             mat.texture)]
                                       : white_
                           atIndex:0];
            [encoder setFragmentTexture:mat.emissiveTexture >= 0
                   ? gpu.textures[static_cast<std::size_t>(mat.emissiveTexture)]
                   : white_ atIndex:1];
            [encoder setFragmentTexture:mat.metallicRoughnessTexture >= 0
                   ? gpu.textures[static_cast<std::size_t>(mat.metallicRoughnessTexture)]
                   : white_ atIndex:2];
            [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                indexCount:m.indices.size()
                                 indexType:MTLIndexTypeUInt32
                               indexBuffer:gpu.meshes[j].indices
                         indexBufferOffset:0];
            ++stats_.drawCalls;
            stats_.triangles += m.indices.size() / 3;
          }
        }
      }
    } // Finish the geometry encoder before dispatching post processing.
    auto compute = [&](id<MTLComputePipelineState> pipeline,
                       id<MTLTexture> source, id<MTLTexture> target,
                       const std::array<float, 2> direction) {
      id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
      if (!encoder) throw std::runtime_error("Metal bloom encoder creation failed");
      [encoder setComputePipelineState:pipeline];
      [encoder setTexture:source atIndex:0];
      [encoder setTexture:target atIndex:1];
      [encoder setBytes:direction.data() length:sizeof(direction) atIndex:0];
      [encoder dispatchThreads:MTLSizeMake(target.width, target.height, 1)
          threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
      [encoder endEncoding];
    };
    compute(downsample_, emission_, bloomA_, {0, 0});
    compute(blur_, bloomA_, bloomB_, {2, 0});
    compute(blur_, bloomB_, bloomA_, {0, 2});
    id<MTLComputeCommandEncoder> composite = [commands computeCommandEncoder];
    if (!composite) throw std::runtime_error("Metal composition encoder creation failed");
    [composite setComputePipelineState:composite_];
    [composite setTexture:hdr_ atIndex:0];
    [composite setTexture:bloomA_ atIndex:1];
    [composite setTexture:color_ atIndex:2];
    [composite dispatchThreads:MTLSizeMake(width_, height_, 1)
        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
    [composite endEncoding];
    stats_.cpuMilliseconds = std::chrono::duration<double, std::milli>(
                                 std::chrono::steady_clock::now() - start)
                                 .count();
  }
  void afterComposition(const Context &context) override {
    // Qt can sample a paused image in command buffers that contain no native
    // render pass. Lease that last image for every composition, not only for
    // the command buffer that originally produced it.
    id<MTLCommandBuffer> commands =
        (__bridge id<MTLCommandBuffer>)context.commands;
    if (!commands || !color_)
      return;
    const auto image = color_;
    const auto failed = commandFailed_;
    [commands addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
      (void)image.width;
      if (buffer.status == MTLCommandBufferStatusError)
        failed->store(true, std::memory_order_release);
    }];
  }
  Statistics statistics() const override { return stats_; }
};
} // namespace
std::unique_ptr<Renderer> createRenderer(const Context &c,
                                         const std::filesystem::path &p) {
  return std::make_unique<MetalRenderer>(c, p);
}
} // namespace mokaid::renderer
