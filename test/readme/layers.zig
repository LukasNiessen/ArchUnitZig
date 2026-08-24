const std = @import("std");
const archunit = @import("archunit");

test "service may depend only on domain" {
    var architecture = try archunit.projectLayers(std.testing.allocator, .{});
    defer architecture.deinit(std.testing.allocator);
    var domain_stage = try architecture.layer("domain");
    defer domain_stage.deinit();
    var with_domain = try domain_stage.definedBy(.{ .glob = "src/domain/**" });
    defer with_domain.deinit(std.testing.allocator);
    var service_stage = try with_domain.layer("service");
    defer service_stage.deinit();
    var with_service = try service_stage.definedBy(.{ .glob = "src/service/**" });
    defer with_service.deinit(std.testing.allocator);
    var policy_stage = try with_service.whereLayer("service");
    defer policy_stage.deinit();
    var rule = try policy_stage.mayOnlyDependOnLayers(&.{"domain"});
    defer rule.deinit(std.testing.allocator);
    try archunit.expectPasses(&rule, .init(.init(std.testing.allocator, std.testing.io)));
}
