#pragma once
#include "scene.hpp"

namespace mokaid::engine {
// A static, material-batched extension in native world coordinates. Furniture
// is sampled from the shipped Blender room, so adjacent suites retain its
// authored detail without duplicating the full room or changing its navigation.
// Also completes the two missing hero-room monitor assemblies, preserving
// their explicit live-display semantics. Surface kind 4 is the immersion-only
// architectural canopy and must be masked out in overview. The caller caches
// this scene at load time and renders it at identity.
std::shared_ptr<const Scene> makeSurroundingOffices(const Scene &office);
} // namespace mokaid::engine
