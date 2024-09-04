const std = @import("std");
const os = std.os;
const io = std.io;
const posix = std.posix;

const builtin = @import("builtin");

const windows = if (builtin.os.tag == .windows) @cImport({
    @cInclude("windows.h");
}) else void;

/// ReadMode defines the read behaivour when using raw mode
pub const ReadMode = enum {
    blocking,
    nonblocking,
};

pub fn enableRawMode(handle: posix.fd_t, blocking: ReadMode) !RawTerm {
    // var original_termios = try os.tcgetattr(handle);
    const original_termios = try posix.tcgetattr(handle);

    var termios = original_termios;

    // https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
    // All of this are bitflags, so we do NOT and then AND to disable

    // ICRNL (iflag) : fix CTRL-M (carriage returns)
    // IXON (iflag)  : disable Ctrl-S and Ctrl-Q

    // OPOST (oflag) : turn off all output processing

    // ECHO (lflag)  : disable prints every key to terminal
    // ICANON (lflag): disable to reads byte per byte instead of line (or when user press enter)
    // IEXTEN (lflag): disable Ctrl-V
    // ISIG (lflag)  : disable Ctrl-C and Ctrl-Z

    // Miscellaneous flags (most modern terminal already have them disabled)
    // BRKINT, INPCK, ISTRIP and CS8

    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = false;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;

    termios.oflag.OPOST = false;

    termios.cflag.CSIZE = .CS8;

    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;

    switch (blocking) {
        // Wait until it reads at least one byte
        .blocking => termios.cc[@intFromEnum(posix.V.MIN)] = 1,

        // Don't wait
        .nonblocking => termios.cc[@intFromEnum(posix.V.MIN)] = 0,
    }

    // Wait 100 miliseconds at maximum.
    termios.cc[@intFromEnum(posix.V.TIME)] = 1;

    // apply changes
    try posix.tcsetattr(handle, .FLUSH, termios);

    return RawTerm{
        .orig_termios = original_termios,
        .handle = handle,
    };
}

/// A raw terminal representation, you can enter terminal raw mode
/// using this struct. Raw mode is essential to create a TUI.
pub const RawTerm = struct {
    orig_termios: std.posix.termios,

    /// The OS-specific file descriptor or file handle.
    handle: os.linux.fd_t,

    const Self = @This();

    /// Returns to the previous terminal state
    pub fn disableRawMode(self: *Self) !void {
        try posix.tcsetattr(self.handle, .FLUSH, self.orig_termios);
    }
};

pub const RawWinTerm = struct {
    handle: if (builtin.os.tag == .windows) windows.HANDLE else void,
    original_mode: if (builtin.os.tag == .windows) windows.DWORD else void,

    const Self = @This();

    pub fn init() !RawWinTerm {
        const handle = try getWindowsStdinHandle();
        if (handle == windows.INVALID_HANDLE_VALUE) {
            return error.InvalidHandle;
        }

        var original_mode: windows.DWORD = undefined;
        if (windows.GetConsoleMode(handle, &original_mode) == 0) {
            const err = windows.GetLastError();
            std.debug.print("GetConsoleMode failed. Error: {}\n", .{err});
            return error.GetConsoleModeFailure;
        }

        // Define the mode we want
        const raw_mode = original_mode & ~@as(windows.DWORD, windows.ENABLE_ECHO_INPUT |
            windows.ENABLE_LINE_INPUT |
            windows.ENABLE_PROCESSED_INPUT |
            windows.ENABLE_MOUSE_INPUT);

        if (windows.SetConsoleMode(handle, raw_mode) == 0) {
            return error.SetConsoleModeFailure;
        }

        return RawWinTerm{
            .handle = handle,
            .original_mode = original_mode,
        };
    }

    pub fn deinit(self: *RawWinTerm) !void {
        const result = windows.SetConsoleMode(self.handle, self.original_mode);
        if (result == 0) {
            return error.SetConsoleModeFailure;
        }
    }
};

pub fn getWindowsStdinHandle() !windows.HANDLE {
    const handle = windows.CreateFileA(
        "CONIN$",
        windows.GENERIC_READ | windows.GENERIC_WRITE,
        windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        null,
        windows.OPEN_EXISTING,
        0,
        null,
    );

    if (handle == windows.INVALID_HANDLE_VALUE) {
        const err = windows.GetLastError();
        std.debug.print("CreateFile failed. Error: {}\n", .{err});
        return error.CreateFileFailure;
    }

    return handle;
}

/// Returned by `getSize()`
pub const TermSize = struct {
    width: u16,
    height: u16,
};

/// Get the terminal size, use `fd` equals to 0 use stdin
pub fn getSize(fd: posix.fd_t) !TermSize {
    if (builtin.os.tag != .linux) {
        return error.UnsupportedPlatform;
    }

    var ws: posix.winsize = undefined;

    // https://github.com/ziglang/zig/blob/master/lib/std/os/linux/errno/generic.zig
    const err = std.os.linux.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(err) != .SUCCESS) {
        return error.IoctlError;
    }

    return TermSize{
        .width = ws.ws_col,
        .height = ws.ws_row,
    };
}

test "entering stdin raw mode" {
    if (builtin.os.tag == .linux) {
        const tty = (try std.fs.cwd().openFile("/dev/tty", .{})).reader();

        const termsize = try getSize(tty.context.handle);
        std.debug.print("Terminal size: {d}x{d}\n", .{ termsize.width, termsize.height });

        // stdin.handle is the same as os.STDIN_FILENO
        // var term = try enableRawMode(tty.context.handle, .blocking);
        // defer term.disableRawMode() catch {};
    }
    if (builtin.os.tag == .windows) {
        var console_handle = RawWinTerm.init() catch |err| {
            std.debug.print("Failed to enable raw mode: {any}\n", .{err});
            return err;
        };
        defer console_handle.deinit() catch |err| {
            std.debug.print("Failed to disable raw mode: {any}\n", .{err});
        };
    }
}
