#include <mokaid/core/policy.hpp>
#include <cstdlib>
#include <iostream>
int main() {
    using namespace mokaid::core;
    auto check = [](bool condition, const char* message) {
        if (!condition) { std::cerr << message << '\n'; std::exit(1); }
    };
    SessionContext s{"alice", "workspace-a", 1, true, true, false};
    check(mayRequest(s, Scope::workspace, true), "member can write online");
    check(!mayRequest(s, Scope::administration, false), "member cannot access admin");
    s.platform_admin = true;
    s.online = false;
    check(!mayRequest(s, Scope::administration, false), "admin data unavailable offline");
    check(!mayRequest(s, Scope::workspace, true), "offline writes rejected");
    check(mayRequest(s, Scope::workspace, false), "member may read local cache");
    s.workspace_id.clear();
    check(!mayRequest(s, Scope::workspace, false), "admin does not bypass membership");
    check(cacheKey("a:b", "c", "d", "e") != cacheKey("a", "b:c", "d", "e"), "cache scope collisions");
    check(!isSafeApiPath("//evil.example/api/me"), "reject external URLs");
    check(!isSafeApiPath("/api/../admin"), "reject traversal");
    check(isSafeApiPath("/api/tasks?page=2"), "allow normal endpoint");
}
