pub const BuilderError = @import("files/fluentapi/files.zig").BuilderError;
pub const FilesScope = @import("files/fluentapi/files.zig").FilesScope;
pub const ProjectOptions = @import("files/fluentapi/files.zig").ProjectOptions;
pub const SelectedFiles = @import("files/fluentapi/files.zig").SelectedFiles;
pub const files = @import("files/fluentapi/files.zig").files;
pub const projectFiles = @import("files/fluentapi/files.zig").projectFiles;

test {
    _ = @import("files/fluentapi/files.zig");
}
