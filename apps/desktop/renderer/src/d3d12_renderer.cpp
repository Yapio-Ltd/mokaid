#include <array>
#include <chrono>
#include <cstring>
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <fstream>
#include <mokaid/renderer/renderer.hpp>
#include <unordered_map>
#include <windows.h>
#include <wrl/client.h>

namespace mokaid::renderer {
namespace {
using Microsoft::WRL::ComPtr;
void check(HRESULT h, const char *operation) {
  if (FAILED(h))
    throw std::runtime_error(std::string(operation) + " failed (HRESULT " +
                             std::to_string(static_cast<unsigned long>(h)) +
                             ")");
}
struct Handle {
  HANDLE value{};
  ~Handle() {
    if (value)
      CloseHandle(value);
  }
  Handle() = default;
  Handle(const Handle &) = delete;
  Handle &operator=(const Handle &) = delete;
};
std::vector<char> read(const std::filesystem::path &p) {
  std::ifstream f(p, std::ios::binary);
  if (!f)
    throw std::runtime_error("Compiled DXIL shader missing");
  return {std::istreambuf_iterator<char>(f), {}};
}
struct Uniforms {
  engine::Mat4 viewProjection, model;
  engine::Vec4 color, emissive, camera, params;
};
struct MeshGpu {
  ComPtr<ID3D12Resource> vertices, indices;
  D3D12_VERTEX_BUFFER_VIEW vb{};
  D3D12_INDEX_BUFFER_VIEW ib{};
};
struct SceneGpu {
  std::shared_ptr<const engine::Scene> source;
  std::vector<MeshGpu> meshes;
  std::vector<ComPtr<ID3D12Resource>> textures;
  std::vector<UINT> descriptors;
};
struct FrameSlot {
  ComPtr<ID3D12CommandAllocator> allocator;
  ComPtr<ID3D12Resource> color, depth, constants;
  ComPtr<ID3D11Texture2D> imported;
  std::vector<ComPtr<ID3D12Resource>> staging;
  std::uint64_t produced{}, consumed{};
  std::byte *mapped{};
};
class D3D12Renderer final : public Renderer {
  ComPtr<ID3D12Device> device_;
  ComPtr<ID3D11Device5> qtDevice_;
  ComPtr<ID3D11DeviceContext4> qtContext_;
  ComPtr<ID3D12CommandQueue> queue_;
  ComPtr<ID3D12GraphicsCommandList> commands_;
  ComPtr<ID3D12Fence> produced_, consumed_;
  ComPtr<ID3D11Fence> qtProduced_, qtConsumed_;
  Handle completion_;
  ComPtr<ID3D12DescriptorHeap> rtv_, dsv_, srv_;
  UINT rtvStep_{}, dsvStep_{}, srvStep_{}, nextDescriptor_{1};
  ComPtr<ID3D12RootSignature> root_;
  ComPtr<ID3D12PipelineState> opaque_, transparent_;
  ComPtr<ID3D12Resource> white_;
  std::array<FrameSlot, 3> slots_;
  std::size_t slot_{2};
  std::uint64_t serial_{}, consumerSerial_{};
  UINT width_{}, height_{};
  Statistics stats_;
  std::unordered_map<const engine::Scene *, SceneGpu> scenes_;
  static constexpr std::size_t constantsCapacity = 32 * 1024 * 1024;
  D3D12_CPU_DESCRIPTOR_HANDLE cpu(ID3D12DescriptorHeap *h, UINT step,
                                  UINT index) const {
    auto r = h->GetCPUDescriptorHandleForHeapStart();
    r.ptr += static_cast<SIZE_T>(step) * index;
    return r;
  }
  D3D12_GPU_DESCRIPTOR_HANDLE gpu(UINT index) const {
    auto r = srv_->GetGPUDescriptorHandleForHeapStart();
    r.ptr += static_cast<UINT64>(srvStep_) * index;
    return r;
  }
  void wait(std::uint64_t value) {
    if (!value || produced_->GetCompletedValue() >= value)
      return;
    check(produced_->SetEventOnCompletion(value, completion_.value),
          "SetEventOnCompletion");
    if (WaitForSingleObject(completion_.value, 30000) != WAIT_OBJECT_0)
      throw std::runtime_error("D3D12 GPU completion timeout");
  }
  ComPtr<ID3D12Resource> buffer(std::size_t bytes, D3D12_HEAP_TYPE type,
                                D3D12_RESOURCE_STATES state) {
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type = type;
    D3D12_RESOURCE_DESC d{};
    d.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    d.Width = bytes;
    d.Height = 1;
    d.DepthOrArraySize = 1;
    d.MipLevels = 1;
    d.SampleDesc.Count = 1;
    d.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ComPtr<ID3D12Resource> r;
    check(device_->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &d,
                                           state, nullptr, IID_PPV_ARGS(&r)),
          "Create buffer");
    return r;
  }
  void transition(ID3D12Resource *r, D3D12_RESOURCE_STATES from,
                  D3D12_RESOURCE_STATES to) {
    D3D12_RESOURCE_BARRIER b{};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = r;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = from;
    b.Transition.StateAfter = to;
    commands_->ResourceBarrier(1, &b);
  }
  ComPtr<ID3D12Resource> uploadBuffer(const void *data, std::size_t bytes,
                                      D3D12_RESOURCE_STATES state,
                                      FrameSlot &f) {
    auto staging = buffer(bytes, D3D12_HEAP_TYPE_UPLOAD,
                          D3D12_RESOURCE_STATE_GENERIC_READ);
    void *mapped{};
    D3D12_RANGE empty{};
    check(staging->Map(0, &empty, &mapped), "Map vertex upload");
    std::memcpy(mapped, data, bytes);
    staging->Unmap(0, nullptr);
    auto target =
        buffer(bytes, D3D12_HEAP_TYPE_DEFAULT, D3D12_RESOURCE_STATE_COPY_DEST);
    commands_->CopyBufferRegion(target.Get(), 0, staging.Get(), 0, bytes);
    transition(target.Get(), D3D12_RESOURCE_STATE_COPY_DEST, state);
    f.staging.push_back(staging);
    return target;
  }
  ComPtr<ID3D12Resource> uploadTexture(const engine::Texture &t,
                                       UINT descriptor, FrameSlot &f) {
    const auto &base = t.mips.front();
    D3D12_RESOURCE_DESC desc{};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = base.width;
    desc.Height = base.height;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = static_cast<UINT16>(t.mips.size());
    desc.Format = t.srgb ? DXGI_FORMAT_R8G8B8A8_UNORM_SRGB : DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    ComPtr<ID3D12Resource> tex;
    check(device_->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc,
                                           D3D12_RESOURCE_STATE_COPY_DEST,
                                           nullptr, IID_PPV_ARGS(&tex)),
          "Create sampled texture");
    std::vector<D3D12_PLACED_SUBRESOURCE_FOOTPRINT> layouts(t.mips.size());
    std::vector<UINT> rows(t.mips.size());
    std::vector<UINT64> rowBytes(t.mips.size());
    UINT64 total{};
    device_->GetCopyableFootprints(&desc, 0, desc.MipLevels, 0, layouts.data(),
                                   rows.data(), rowBytes.data(), &total);
    auto staging =
        buffer(static_cast<std::size_t>(total), D3D12_HEAP_TYPE_UPLOAD,
               D3D12_RESOURCE_STATE_GENERIC_READ);
    void *mapped{};
    D3D12_RANGE empty{};
    check(staging->Map(0, &empty, &mapped), "Map texture upload");
    for (std::size_t i = 0; i < t.mips.size(); ++i) {
      const auto &m = t.mips[i];
      for (UINT row = 0; row < m.height; ++row)
        std::memcpy(static_cast<std::byte *>(mapped) + layouts[i].Offset +
                        static_cast<std::size_t>(row) *
                            layouts[i].Footprint.RowPitch,
                    m.rgba.data() + static_cast<std::size_t>(row) * m.width * 4,
                    m.width * 4);
      stats_.textureBytes += m.rgba.size();
    }
    staging->Unmap(0, nullptr);
    for (UINT i = 0; i < desc.MipLevels; ++i) {
      D3D12_TEXTURE_COPY_LOCATION src{};
      src.pResource = staging.Get();
      src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
      src.PlacedFootprint = layouts[i];
      D3D12_TEXTURE_COPY_LOCATION dst{};
      dst.pResource = tex.Get();
      dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
      dst.SubresourceIndex = i;
      commands_->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    }
    transition(tex.Get(), D3D12_RESOURCE_STATE_COPY_DEST,
               D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    D3D12_SHADER_RESOURCE_VIEW_DESC view{};
    view.Format = desc.Format;
    view.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
    view.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
    view.Texture2D.MipLevels = desc.MipLevels;
    device_->CreateShaderResourceView(tex.Get(), &view,
                                      cpu(srv_.Get(), srvStep_, descriptor));
    f.staging.push_back(staging);
    return tex;
  }
  SceneGpu &upload(const std::shared_ptr<const engine::Scene> &scene,
                   FrameSlot &f) {
    auto [it, inserted] = scenes_.try_emplace(scene.get());
    if (!inserted)
      return it->second;
    auto &g = it->second;
    g.source = scene;
    for (const auto &m : scene->meshes) {
      MeshGpu mesh;
      mesh.vertices = uploadBuffer(
          m.vertices.data(), m.vertices.size() * sizeof(engine::Vertex),
          D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER, f);
      mesh.indices = uploadBuffer(m.indices.data(), m.indices.size() * 4,
                                  D3D12_RESOURCE_STATE_INDEX_BUFFER, f);
      mesh.vb = {mesh.vertices->GetGPUVirtualAddress(),
                 static_cast<UINT>(m.vertices.size() * sizeof(engine::Vertex)),
                 sizeof(engine::Vertex)};
      mesh.ib = {mesh.indices->GetGPUVirtualAddress(),
                 static_cast<UINT>(m.indices.size() * 4), DXGI_FORMAT_R32_UINT};
      g.meshes.push_back(std::move(mesh));
    }
    for (const auto &t : scene->textures) {
      if (nextDescriptor_ >= 4096)
        throw std::runtime_error("Texture descriptor budget exceeded");
      g.descriptors.push_back(nextDescriptor_);
      g.textures.push_back(uploadTexture(t, nextDescriptor_++, f));
    }
    return g;
  }

public:
  D3D12Renderer(const Context &c, const std::filesystem::path &path) {
    if (!c.device || !c.deviceContext)
      throw std::runtime_error("Qt Direct3D11 device unavailable");
    auto *qt = static_cast<ID3D11Device *>(c.device);
    check(qt->QueryInterface(IID_PPV_ARGS(&qtDevice_)), "D3D11Device5");
    check(static_cast<ID3D11DeviceContext *>(c.deviceContext)
              ->QueryInterface(IID_PPV_ARGS(&qtContext_)),
          "D3D11DeviceContext4");
    ComPtr<IDXGIDevice> dxgi;
    check(qt->QueryInterface(IID_PPV_ARGS(&dxgi)), "DXGI device");
    ComPtr<IDXGIAdapter> adapter;
    check(dxgi->GetAdapter(&adapter), "Qt GPU adapter");
    check(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_11_0,
                            IID_PPV_ARGS(&device_)),
          "D3D12 device on Qt adapter");
    D3D12_COMMAND_QUEUE_DESC q{};
    q.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    check(device_->CreateCommandQueue(&q, IID_PPV_ARGS(&queue_)),
          "D3D12 command queue");
    check(device_->CreateFence(0, D3D12_FENCE_FLAG_SHARED,
                               IID_PPV_ARGS(&produced_)),
          "Producer fence");
    check(device_->CreateFence(0, D3D12_FENCE_FLAG_SHARED,
                               IID_PPV_ARGS(&consumed_)),
          "Consumer fence");
    Handle ph, ch;
    check(device_->CreateSharedHandle(produced_.Get(), nullptr, GENERIC_ALL,
                                      nullptr, &ph.value),
          "Share producer fence");
    check(device_->CreateSharedHandle(consumed_.Get(), nullptr, GENERIC_ALL,
                                      nullptr, &ch.value),
          "Share consumer fence");
    check(qtDevice_->OpenSharedFence(ph.value, IID_PPV_ARGS(&qtProduced_)),
          "Import producer fence");
    check(qtDevice_->OpenSharedFence(ch.value, IID_PPV_ARGS(&qtConsumed_)),
          "Import consumer fence");
    completion_.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!completion_.value)
      throw std::runtime_error("GPU wait event creation failed");
    D3D12_DESCRIPTOR_HEAP_DESC hd{};
    hd.NumDescriptors = 3;
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
    check(device_->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&rtv_)), "RTV heap");
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_DSV;
    check(device_->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&dsv_)), "DSV heap");
    hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
    hd.NumDescriptors = 4096;
    hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
    check(device_->CreateDescriptorHeap(&hd, IID_PPV_ARGS(&srv_)), "SRV heap");
    rtvStep_ = device_->GetDescriptorHandleIncrementSize(
        D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    dsvStep_ = device_->GetDescriptorHandleIncrementSize(
        D3D12_DESCRIPTOR_HEAP_TYPE_DSV);
    srvStep_ = device_->GetDescriptorHandleIncrementSize(
        D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    for (auto &f : slots_) {
      check(device_->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                            IID_PPV_ARGS(&f.allocator)),
            "Frame allocator");
      f.constants = buffer(constantsCapacity, D3D12_HEAP_TYPE_UPLOAD,
                           D3D12_RESOURCE_STATE_GENERIC_READ);
      void *mapped{};
      D3D12_RANGE empty{};
      check(f.constants->Map(0, &empty, &mapped), "Map frame uniforms");
      f.mapped = static_cast<std::byte *>(mapped);
    }
    check(device_->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT,
                                     slots_[0].allocator.Get(), nullptr,
                                     IID_PPV_ARGS(&commands_)),
          "Create command list");
    check(commands_->Close(), "Close initial command list");
    D3D12_DESCRIPTOR_RANGE range{};
    range.RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    range.NumDescriptors = 1;
    range.BaseShaderRegister = 0;
    range.OffsetInDescriptorsFromTableStart =
        D3D12_DESCRIPTOR_RANGE_OFFSET_APPEND;
    D3D12_DESCRIPTOR_RANGE emissionRange = range;
    emissionRange.BaseShaderRegister = 1;
    D3D12_DESCRIPTOR_RANGE materialRange = range;
    materialRange.BaseShaderRegister = 2;
    std::array<D3D12_ROOT_PARAMETER, 5> params{};
    for (UINT i = 0; i < 2; ++i) {
      params[i].ParameterType = D3D12_ROOT_PARAMETER_TYPE_CBV;
      params[i].Descriptor.ShaderRegister = i;
      params[i].ShaderVisibility = D3D12_SHADER_VISIBILITY_ALL;
    }
    params[2].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[2].DescriptorTable = {1, &range};
    params[2].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    params[3].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[3].DescriptorTable = {1, &emissionRange};
    params[3].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    params[4].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[4].DescriptorTable = {1, &materialRange};
    params[4].ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_STATIC_SAMPLER_DESC sampler{};
    sampler.Filter = D3D12_FILTER_ANISOTROPIC;
    sampler.AddressU = sampler.AddressV = sampler.AddressW =
        D3D12_TEXTURE_ADDRESS_MODE_WRAP;
    sampler.MaxAnisotropy = 4;
    sampler.ComparisonFunc = D3D12_COMPARISON_FUNC_ALWAYS;
    sampler.MaxLOD = D3D12_FLOAT32_MAX;
    sampler.ShaderVisibility = D3D12_SHADER_VISIBILITY_PIXEL;
    D3D12_ROOT_SIGNATURE_DESC rd{};
    rd.NumParameters = static_cast<UINT>(params.size());
    rd.pParameters = params.data();
    rd.NumStaticSamplers = 1;
    rd.pStaticSamplers = &sampler;
    rd.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ComPtr<ID3DBlob> blob, error;
    check(D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &blob,
                                      &error),
          "Serialize root signature");
    check(device_->CreateRootSignature(0, blob->GetBufferPointer(),
                                       blob->GetBufferSize(),
                                       IID_PPV_ARGS(&root_)),
          "Create root signature");
    const auto vs = read(path / "office.vs.dxil"),
               ps = read(path / "office.ps.dxil");
    const D3D12_INPUT_ELEMENT_DESC layout[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0,
         D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"NORMAL", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 12,
         D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 24,
         D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"BLENDINDICES", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 32,
         D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0},
        {"BLENDWEIGHT", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 48,
         D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA, 0}};
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd{};
    pd.pRootSignature = root_.Get();
    pd.VS = {vs.data(), vs.size()};
    pd.PS = {ps.data(), ps.size()};
    pd.InputLayout = {layout, 5};
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.RasterizerState.DepthClipEnable = TRUE;
    pd.BlendState.RenderTarget[0].RenderTargetWriteMask =
        D3D12_COLOR_WRITE_ENABLE_ALL;
    pd.DepthStencilState.DepthEnable = TRUE;
    pd.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ALL;
    pd.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC_LESS;
    pd.SampleMask = UINT_MAX;
    pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets = 1;
    pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pd.DSVFormat = DXGI_FORMAT_D32_FLOAT;
    pd.SampleDesc.Count = 1;
    check(device_->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&opaque_)),
          "Opaque pipeline");
    auto &blend = pd.BlendState.RenderTarget[0];
    blend.BlendEnable = TRUE;
    blend.SrcBlend = D3D12_BLEND_SRC_ALPHA;
    blend.DestBlend = D3D12_BLEND_INV_SRC_ALPHA;
    blend.BlendOp = D3D12_BLEND_OP_ADD;
    blend.SrcBlendAlpha = D3D12_BLEND_ONE;
    blend.DestBlendAlpha = D3D12_BLEND_INV_SRC_ALPHA;
    blend.BlendOpAlpha = D3D12_BLEND_OP_ADD;
    pd.DepthStencilState.DepthWriteMask = D3D12_DEPTH_WRITE_MASK_ZERO;
    check(
        device_->CreateGraphicsPipelineState(&pd, IID_PPV_ARGS(&transparent_)),
        "Transparent pipeline");
  }
  ~D3D12Renderer() override {
    if (device_ && FAILED(device_->GetDeviceRemovedReason()))
      return;
    try {
      for (const auto &f : slots_) {
        wait(f.produced);
        if (f.consumed && consumed_->GetCompletedValue() < f.consumed) {
          check(consumed_->SetEventOnCompletion(f.consumed, completion_.value),
                "Wait Qt composition");
          WaitForSingleObject(completion_.value, 30000);
        }
      }
    } catch (...) { /* Device loss cannot throw from resource destruction. */
    }
  }
  void resize(UINT w, UINT h) override {
    check(device_->GetDeviceRemovedReason(), "D3D12 device health");
    slot_ = (slot_ + 1) % slots_.size();
    if (width_ == w && height_ == h)
      return;
    for (auto &f : slots_) {
      wait(f.produced);
      if (f.consumed && consumed_->GetCompletedValue() < f.consumed) {
        check(consumed_->SetEventOnCompletion(f.consumed, completion_.value),
              "Retire shared texture");
        if (WaitForSingleObject(completion_.value, 30000) != WAIT_OBJECT_0)
          throw std::runtime_error("Qt composition retirement timeout");
      }
    }
    width_ = w;
    height_ = h;
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    for (UINT i = 0; i < slots_.size(); ++i) {
      auto &f = slots_[i];
      f.imported.Reset();
      f.color.Reset();
      f.depth.Reset();
      D3D12_RESOURCE_DESC d{};
      d.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
      d.Width = w;
      d.Height = h;
      d.DepthOrArraySize = 1;
      d.MipLevels = 1;
      d.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
      d.SampleDesc.Count = 1;
      d.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
      check(device_->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_SHARED, &d,
                                             D3D12_RESOURCE_STATE_COMMON,
                                             nullptr, IID_PPV_ARGS(&f.color)),
            "Create shared RGBA8 output");
      Handle shared;
      check(device_->CreateSharedHandle(f.color.Get(), nullptr, GENERIC_ALL,
                                        nullptr, &shared.value),
            "Share render target");
      check(qtDevice_->OpenSharedResource1(shared.value,
                                           IID_PPV_ARGS(&f.imported)),
            "Import render target into Qt");
      device_->CreateRenderTargetView(f.color.Get(), nullptr,
                                      cpu(rtv_.Get(), rtvStep_, i));
      d.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
      d.Format = DXGI_FORMAT_D32_FLOAT;
      D3D12_CLEAR_VALUE clear{};
      clear.Format = d.Format;
      clear.DepthStencil.Depth = 1;
      check(device_->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &d,
                                             D3D12_RESOURCE_STATE_DEPTH_WRITE,
                                             &clear, IID_PPV_ARGS(&f.depth)),
            "Create depth target");
      device_->CreateDepthStencilView(f.depth.Get(), nullptr,
                                      cpu(dsv_.Get(), dsvStep_, i));
    }
  }
  void *texture() const override { return slots_[slot_].imported.Get(); }
  void render(const Context &, const engine::Frame &frame) override {
    check(device_->GetDeviceRemovedReason(), "D3D12 device health");
    auto &f = slots_[slot_];
    const auto start = std::chrono::steady_clock::now();
    wait(f.produced);
    f.staging.clear();
    if (f.consumed)
      check(queue_->Wait(consumed_.Get(), f.consumed),
            "GPU wait for Qt consumer");
    check(f.allocator->Reset(), "Reset frame allocator");
    check(commands_->Reset(f.allocator.Get(), opaque_.Get()),
          "Reset frame commands");
    if (!white_) {
      engine::Texture t;
      t.mips.push_back({1, 1, {255, 255, 255, 255}});
      white_ = uploadTexture(t, 0, f);
    }
    for (const auto &i : frame.instances)
      upload(i.scene, f);
    std::vector<engine::Pose> poses;
    poses.reserve(frame.instances.size());
    for (const auto &instance : frame.instances)
      poses.push_back(engine::evaluateInstancePose(instance));
    transition(f.color.Get(), D3D12_RESOURCE_STATE_COMMON,
               D3D12_RESOURCE_STATE_RENDER_TARGET);
    const auto rt = cpu(rtv_.Get(), rtvStep_, static_cast<UINT>(slot_)),
               ds = cpu(dsv_.Get(), dsvStep_, static_cast<UINT>(slot_));
    const float clear[4] = {.013F, .018F, .022F, 1};
    commands_->ClearRenderTargetView(rt, clear, 0, nullptr);
    commands_->ClearDepthStencilView(ds, D3D12_CLEAR_FLAG_DEPTH, 1, 0, 0,
                                     nullptr);
    commands_->OMSetRenderTargets(1, &rt, FALSE, &ds);
    D3D12_VIEWPORT viewport{
        0, 0, static_cast<float>(width_), static_cast<float>(height_), 0, 1};
    D3D12_RECT scissor{0, 0, static_cast<LONG>(width_),
                       static_cast<LONG>(height_)};
    commands_->RSSetViewports(1, &viewport);
    commands_->RSSetScissorRects(1, &scissor);
    commands_->SetGraphicsRootSignature(root_.Get());
    ID3D12DescriptorHeap *heaps[] = {srv_.Get()};
    commands_->SetDescriptorHeaps(1, heaps);
    commands_->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    stats_.drawCalls = 0;
    stats_.triangles = 0;
    std::size_t offset = 0;
    for (int alpha = 0; alpha < 2; ++alpha) {
      commands_->SetPipelineState(alpha ? transparent_.Get() : opaque_.Get());
      for (std::size_t instanceIndex = 0; instanceIndex < frame.instances.size(); ++instanceIndex) {
        const auto &i = frame.instances[instanceIndex];
        const auto &s = *i.scene;
        const auto &pose = poses[instanceIndex];
        const auto &g = scenes_.at(i.scene.get());
        for (std::size_t j = 0; j < s.meshes.size(); ++j) {
          const auto &m = s.meshes[j];
          const auto &mat = s.materials[m.material];
          if ((mat.alphaMode == 2) != (alpha == 1))
            continue;
          const Uniforms u{frame.viewProjection,
                           i.transform * pose.world[m.node],
                           mat.color,
                           {mat.emissive.x, mat.emissive.y, mat.emissive.z, mat.metallic},
                           {frame.camera.x, frame.camera.y, frame.camera.z, 1},
                           {m.skin >= 0 ? 1.F : 0.F,
                            static_cast<float>(mat.alphaMode), mat.alphaCutoff,
                            mat.roughness}};
          const auto bones = engine::skinMatrices(s, m, pose);
          if (offset + 256 + sizeof(bones) > constantsCapacity)
            throw std::runtime_error("Per-frame uniform budget exceeded");
          std::memcpy(f.mapped + offset, &u, sizeof u);
          commands_->SetGraphicsRootConstantBufferView(
              0, f.constants->GetGPUVirtualAddress() + offset);
          offset += 256;
          std::memcpy(f.mapped + offset, bones.data(), sizeof bones);
          commands_->SetGraphicsRootConstantBufferView(
              1, f.constants->GetGPUVirtualAddress() + offset);
          offset += sizeof bones;
          commands_->SetGraphicsRootDescriptorTable(
              2, gpu(mat.texture >= 0
                         ? g.descriptors[static_cast<std::size_t>(mat.texture)]
                         : 0));
          commands_->IASetVertexBuffers(0, 1, &g.meshes[j].vb);
          commands_->SetGraphicsRootDescriptorTable(
              3, gpu(mat.emissiveTexture >= 0
                         ? g.descriptors[static_cast<std::size_t>(mat.emissiveTexture)]
                         : 0));
          commands_->IASetIndexBuffer(&g.meshes[j].ib);
          commands_->SetGraphicsRootDescriptorTable(
              4, gpu(mat.metallicRoughnessTexture >= 0
                         ? g.descriptors[static_cast<std::size_t>(mat.metallicRoughnessTexture)]
                         : 0));
          commands_->DrawIndexedInstanced(static_cast<UINT>(m.indices.size()),
                                          1, 0, 0, 0);
          ++stats_.drawCalls;
          stats_.triangles += m.indices.size() / 3;
        }
      }
    }
    transition(f.color.Get(), D3D12_RESOURCE_STATE_RENDER_TARGET,
               D3D12_RESOURCE_STATE_COMMON);
    check(commands_->Close(), "Close frame commands");
    ID3D12CommandList *lists[] = {commands_.Get()};
    queue_->ExecuteCommandLists(1, lists);
    f.produced = ++serial_;
    check(queue_->Signal(produced_.Get(), f.produced), "Signal produced image");
    check(qtContext_->Wait(qtProduced_.Get(), f.produced),
          "Qt GPU wait for produced image");
    stats_.cpuMilliseconds = std::chrono::duration<double, std::milli>(
                                 std::chrono::steady_clock::now() - start)
                                 .count();
  }
  void afterComposition(const Context &) override {
    auto &f = slots_[slot_];
    if (!f.produced)
      return;
    // Qt may composite an image repeatedly between native frames. Each read
    // needs its own fence value before a producer may reuse that ring slot.
    f.consumed = ++consumerSerial_;
    check(qtContext_->Signal(qtConsumed_.Get(), f.consumed),
          "Signal Qt composition consumed");
    qtContext_->Flush();
  }
  Statistics statistics() const override { return stats_; }
};
} // namespace
std::unique_ptr<Renderer> createRenderer(const Context &c,
                                         const std::filesystem::path &p) {
  return std::make_unique<D3D12Renderer>(c, p);
}
} // namespace mokaid::renderer
