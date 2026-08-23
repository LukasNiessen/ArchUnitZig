pub const BuilderError = @import("files/fluentapi/files.zig").BuilderError;
pub const FilesScope = @import("files/fluentapi/files.zig").FilesScope;
pub const FilesHaveNoCycles = @import("files/fluentapi/files.zig").FilesHaveNoCycles;
pub const FilesMatchPattern = @import("files/fluentapi/files.zig").FilesMatchPattern;
pub const FilesDependOnBuilder = @import("files/fluentapi/files.zig").FilesDependOnBuilder;
pub const FilesDependOn = @import("files/fluentapi/files.zig").FilesDependOn;
pub const FilesExternalModuleBuilder = @import("files/fluentapi/files.zig").FilesExternalModuleBuilder;
pub const FilesExternalModules = @import("files/fluentapi/files.zig").FilesExternalModules;
pub const FilesShould = @import("files/fluentapi/files.zig").FilesShould;
pub const FilesShouldNot = @import("files/fluentapi/files.zig").FilesShouldNot;
pub const ProjectOptions = @import("files/fluentapi/files.zig").ProjectOptions;
pub const ScopePatterns = @import("files/fluentapi/files.zig").ScopePatterns;
pub const SelectedFiles = @import("files/fluentapi/files.zig").SelectedFiles;
pub const files = @import("files/fluentapi/files.zig").files;
pub const projectFiles = @import("files/fluentapi/files.zig").projectFiles;
pub const gatherMatchingFileViolations = @import("files/assertion/matching_files.zig").gatherMatchingFileViolations;
pub const gatherFileDependencyViolations = @import("files/assertion/depend_on_files.zig").gatherFileDependencyViolations;
pub const ExternalModuleCategory = @import("files/assertion/depend_on_external_modules.zig").ExternalModuleCategory;
pub const ExternalModuleCategories = @import("files/assertion/depend_on_external_modules.zig").ExternalModuleCategories;
pub const defaultExternalModuleCategories = @import("files/assertion/depend_on_external_modules.zig").defaultExternalModuleCategories;
pub const gatherExternalModuleDependencyViolations = @import("files/assertion/depend_on_external_modules.zig").gatherExternalModuleDependencyViolations;

test {
    _ = @import("files/assertion/matching_files.zig");
    _ = @import("files/assertion/depend_on_files.zig");
    _ = @import("files/assertion/depend_on_external_modules.zig");
    _ = @import("files/fluentapi/files.zig");
}
