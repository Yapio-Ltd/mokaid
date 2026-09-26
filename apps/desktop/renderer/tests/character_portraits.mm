#include <mokaid/engine/scene.hpp>
#include <mokaid/renderer/renderer.hpp>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <filesystem>
#include <iostream>

// Isolated native-renderer evidence: source geometry, production skinning,
// textures and shaders, with a fixed close-up camera for each catalog avatar.
static void saveImage(id<MTLDevice> device, id<MTLCommandQueue> queue,
                      id<MTLTexture> texture, const std::filesystem::path &path) {
  const NSUInteger width=texture.width, height=texture.height;
  const NSUInteger rowBytes=((width*4+255)/256)*256;
  id<MTLBuffer> readback=[device newBufferWithLength:rowBytes*height options:MTLResourceStorageModeShared];
  id<MTLCommandBuffer> commands=[queue commandBuffer];
  id<MTLBlitCommandEncoder> blit=[commands blitCommandEncoder];
  [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
    sourceSize:MTLSizeMake(width,height,1) toBuffer:readback destinationOffset:0
    destinationBytesPerRow:rowBytes destinationBytesPerImage:rowBytes*height];
  [blit endEncoding]; [commands commit]; [commands waitUntilCompleted];
  if(commands.status==MTLCommandBufferStatusError) throw std::runtime_error("Readback failed");
  CGColorSpaceRef colorSpace=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bitmap=CGBitmapContextCreate(readback.contents,width,height,8,rowBytes,colorSpace,
    static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedLast)|kCGBitmapByteOrder32Big);
  if(!bitmap) throw std::runtime_error("Portrait bitmap creation failed");
  CGImageRef image=CGBitmapContextCreateImage(bitmap);
  NSURL *url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
  CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,nullptr);
  if(!destination) throw std::runtime_error("Portrait output creation failed");
  CGImageDestinationAddImage(destination,image,nullptr);
  const bool written=CGImageDestinationFinalize(destination);
  CFRelease(destination);CGImageRelease(image);CGContextRelease(bitmap);CGColorSpaceRelease(colorSpace);
  if(!written) throw std::runtime_error("Portrait write failed");
}
int main(int argc,char **argv) {
  @autoreleasepool {
    try {
      if(argc<4||argc>5) throw std::runtime_error("character_portraits <assets> <shaders> <output-directory> [avatar-key]");
      namespace e=mokaid::engine;
      id<MTLDevice> device=MTLCreateSystemDefaultDevice();
      if(!device) throw std::runtime_error("No Metal GPU available");
      id<MTLCommandQueue> queue=[device newCommandQueue];
      mokaid::renderer::Context context{(__bridge void*)device,(__bridge void*)queue};
      auto renderer=mokaid::renderer::createRenderer(context,argv[2]);
      renderer->resize(900,1000);
      std::filesystem::create_directories(argv[3]);
      for(const auto *key:{"male","design","finance","corporate","legal","research","developer","byte","nyx","moss","female"}) {
        if(argc==5&&std::string_view(argv[4])!=key) continue;
        auto scene=e::loadScene(std::filesystem::path(argv[1])/(std::string("avatar_")+key+".mokaidasset"));
        const float scale=1.75F/scene->referenceHeight;
        // Isolate the global environment/key/fill from office desk lamps. At
        // the origin an authored gold lamp sits almost inside the face.
        e::Instance actor{scene,e::trs({40,-scene->referenceMinY*scale,40},{0,0,0,1},{scale,scale,scale}),"idle",0,key};
        const auto head=e::headPosition(*scene,std::array<e::AnimationSample,1>{{{"idle",0,1}}});
        const auto worldHead=e::transform(actor.transform,{head.x,head.y,head.z,1});
        // A consistent portrait includes the face, hair and upper torso.
        const e::Vec3 target{worldHead.x,worldHead.y-.38F,worldHead.z};
        for(const auto *view:{"front","quarter"}) {
          e::Frame frame;
          frame.instances.push_back(actor);
          frame.camera=target+(std::string_view(view)=="front"?e::Vec3{0,.02F,2.35F}:e::Vec3{.7F,.06F,2.25F});
          frame.viewProjection=e::perspective(.42F,.9F)*e::lookAt(frame.camera,target);
          frame.sequence=1;
          id<MTLCommandBuffer> commands=[queue commandBuffer];
          context.commands=(__bridge void*)commands;
          renderer->render(context,frame);
          [commands commit]; [commands waitUntilCompleted];
          if(commands.status==MTLCommandBufferStatusError) throw std::runtime_error(commands.error.localizedDescription.UTF8String);
          saveImage(device,queue,(__bridge id<MTLTexture>)renderer->texture(),
            std::filesystem::path(argv[3])/(std::string(key)+"-"+view+".png"));
        }
        std::cout<<key<<": two native portraits; "<<scene->meshes.size()<<" meshes; "<<scene->residentBytes<<" resident bytes\n";
      }
      return 0;
    } catch(const std::exception &error) {std::cerr<<error.what()<<'\n';return 1;}
  }
}
