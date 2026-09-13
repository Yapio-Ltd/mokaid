#pragma once
#include <cstdint>
#include <string>
#include <string_view>

namespace mokaid::core {
enum class Scope { public_api, identity, workspace, administration };
struct SessionContext {
    std::string user_id;
    std::string workspace_id;
    std::uint64_t generation{};
    bool authenticated{};
    bool online{true};
    bool platform_admin{};
};
inline bool mayRequest(const SessionContext& session, Scope scope, bool mutating) {
    if (scope == Scope::public_api) return true; // Health/auth must be able to recover connectivity.
    if (!session.authenticated || (mutating && !session.online)) return false;
    if (scope == Scope::administration) return session.online && session.platform_admin;
    return scope != Scope::workspace || !session.workspace_id.empty();
}
// Length prefixes prevent collisions even when account/server names contain separators.
inline std::string cacheKey(std::string_view origin, std::string_view user,
                            std::string_view workspace, std::string_view resource) {
    std::string result;
    for (const auto value : {origin, user, workspace, resource}) {
        result += std::to_string(value.size()) + ":";
        result += value;
    }
    return result;
}
inline bool isSafeApiPath(std::string_view path) {
    return path.starts_with("/api/") && path.find("..") == std::string_view::npos
        && path.find('\\') == std::string_view::npos && path.find('#') == std::string_view::npos
        && path.find('\r') == std::string_view::npos && path.find('\n') == std::string_view::npos;
}
}
