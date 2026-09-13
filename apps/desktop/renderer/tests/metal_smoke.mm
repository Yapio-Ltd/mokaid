#include <mokaid/engine/office.hpp>
#include <mokaid/renderer/renderer.hpp>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <chrono>
#include <iostream>
#include <thread>

void benchmarkPoses(const mokaid::engine::Frame &frame) {
  using clock = std::chrono::steady_clock;
  std::vector<mokaid::engine::Instance> avatars;
  for (const auto &instance : frame.instances)
    if (!instance.agentId.empty()) avatars.push_back(instance);
  if (avatars.empty()) return;
  for (const int layers : {1, 2}) {
    for (auto &instance : avatars) {
      instance.animationSamples = {{"working", 0, layers == 1 ? 1.F : .5F}};
      if (layers == 2) instance.animationSamples.push_back({"idle", 0, .5F});
    }
    float checksum = 0;
    constexpr int frames = 300;
    const auto start = clock::now();
    for (int frameIndex = 0; frameIndex < frames; ++frameIndex) {
      for (auto &instance : avatars) {
        for (auto &sample : instance.animationSamples)
          sample.seconds = static_cast<float>(frameIndex) / 60.F;
        const auto pose = mokaid::engine::evaluateInstancePose(instance);
        checksum += pose.world.back().m[0];
      }
    }
    const double mean = std::chrono::duration<double, std::milli>(clock::now() - start).count() / frames;
    std::cout << "Pose CPU mean for " << avatars.size() << " avatars, " << layers
              << " layer(s): " << mean << " ms; checksum " << checksum << '\n';
  }
}

// Verification-only readback. Production rendering never copies frames to CPU.
int main(int argc, char **argv) {
  @autoreleasepool {
    try {
      if (argc < 4 || argc > 5) throw std::runtime_error("usage: metal_smoke <asset-dir> <shader-dir> <png-output> [agent-count]");
      const int agentCount=argc==5?std::clamp(std::stoi(argv[4]),0,9):9;
      id<MTLDevice> device = MTLCreateSystemDefaultDevice();
      if (!device) throw std::runtime_error("No Metal GPU is available");
      id<MTLCommandQueue> queue = [device newCommandQueue];
      mokaid::renderer::Context context{(__bridge void *)device, (__bridge void *)queue};
      auto renderer = mokaid::renderer::createRenderer(context, argv[2]);
      auto office = std::make_unique<mokaid::engine::Office>();
      office->load(argv[1]);
      std::vector<mokaid::engine::Agent> agents;
      const char *types[] = {"male", "female", "corporate", "developer", "design", "finance", "research", "legal", "female"};
      for (int i=0;i<agentCount;++i) agents.push_back({std::to_string(i), types[i], "working", types[i], i});
      office->setAgents(std::move(agents));
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
      benchmarkPoses(*office->snapshot(1.5F));
      constexpr NSUInteger width=1440, height=960;
      std::vector<id<MTLCommandBuffer>> submitted;
      for (int i=0;i<12;++i) {
        // Stress resources Qt may record with unretained command buffers.
        // Resize while preceding frames remain in flight, including odd sizes.
        const NSUInteger frameWidth=i==11?width:width-static_cast<NSUInteger>(i%3)*117;
        const NSUInteger frameHeight=i==11?height:height-static_cast<NSUInteger>(i%3)*73;
        renderer->resize(frameWidth,frameHeight);
        auto descriptor=[MTLCommandBufferDescriptor new];
        descriptor.retainedReferences=NO;
        id<MTLCommandBuffer> commands=[queue commandBufferWithDescriptor:descriptor];
        if(!commands)throw std::runtime_error("Command buffer allocation failed");
        context.commands=(__bridge void*)commands;
        const auto frame=office->snapshot(static_cast<float>(frameWidth)/frameHeight);
        if(frame->instances.size()!=static_cast<std::size_t>(agentCount+1))throw std::runtime_error("Office scene snapshot is incomplete");
        if(i==0)for(const auto&instance:frame->instances){
          const auto&scene=*instance.scene;
          const auto [min,max]=mokaid::engine::poseBounds(scene,mokaid::engine::evaluatePose(scene,instance.animation,instance.animationTime));
          std::cout<<"asset "<<instance.agentId<<" posed Y="<<min.y<<".."<<max.y<<"; seated pelvis="<<scene.sittingPelvisHeight<<'\n';
        }
        renderer->render(context,*frame);
        [commands commit];
        submitted.push_back(commands);
      }
      const auto stats=renderer->statistics();
      id<MTLTexture> texture=(__bridge id<MTLTexture>)renderer->texture();
      // Destruction must not free buffers still referenced by GPU work.
      renderer.reset();
      for(id<MTLCommandBuffer> commands:submitted){
        [commands waitUntilCompleted];
        if(commands.status==MTLCommandBufferStatusError)
          throw std::runtime_error(commands.error.localizedDescription.UTF8String);
      }
      const NSUInteger rowBytes=((width*4+255)/256)*256;
      id<MTLBuffer> readback=[device newBufferWithLength:rowBytes*height options:MTLResourceStorageModeShared];
      id<MTLCommandBuffer> commands=[queue commandBuffer];
      id<MTLBlitCommandEncoder> blit=[commands blitCommandEncoder];
      [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:rowBytes destinationBytesPerImage:rowBytes*height];
      [blit endEncoding]; [commands commit]; [commands waitUntilCompleted];
      if(commands.status==MTLCommandBufferStatusError)throw std::runtime_error("Frame readback failed");
      CGColorSpaceRef colorSpace=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      CGContextRef bitmap=CGBitmapContextCreate(readback.contents,width,height,8,rowBytes,colorSpace,static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast)|kCGBitmapByteOrder32Big);
      if(!bitmap)throw std::runtime_error("PNG bitmap creation failed");
      CGImageRef image=CGBitmapContextCreateImage(bitmap);
      NSURL *url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]]];
      CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,nullptr);
      if(!destination)throw std::runtime_error("PNG destination creation failed");
      CGImageDestinationAddImage(destination,image,nullptr);
      const bool written=CGImageDestinationFinalize(destination);
      CFRelease(destination);CGImageRelease(image);CGContextRelease(bitmap);CGColorSpaceRelease(colorSpace);
      if(!written)throw std::runtime_error("PNG output failed");
      std::cout<<"Metal GPU: "<<device.name.UTF8String<<"; "<<stats.drawCalls<<" draws; "<<stats.triangles<<" triangles; last encode "<<stats.cpuMilliseconds<<" ms\n";
      std::cout<<"12 unretained command buffers, in-flight resize and renderer destruction passed\n";
      return 0;
    } catch(const std::exception&e) {std::cerr<<e.what()<<'\n';return 1;}
  }
}
