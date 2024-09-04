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
    handle: windows.HANDLE,
    original_mode: windows.DWORD,

    const Self = @This();

    pub fn disableRawMode(self: *Self) !void {
        // Check if the handle is still valid
        var dummy: windows.DWORD = 0;
        if (windows.GetConsoleMode(self.handle, &dummy) == 0) {
            // Try to get a fresh handle
            const new_handle = windows.CreateFileA(
                "CONIN$",
                windows.GENERIC_READ | windows.GENERIC_WRITE,
                windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
                null,
                windows.OPEN_EXISTING,
                0,
                null,
            );
            if (new_handle == windows.INVALID_HANDLE_VALUE) {
                return error.FailedToGetNewHandle;
            }
            self.handle = new_handle;
        }
        const result = windows.SetConsoleMode(self.handle, self.original_mode);
        if (result == 0) {
            return error.SetConsoleModeFailed;
        }
        std.debug.print("Raw mode disabled successfully\n", .{});
    }
};

pub fn enableRawModeWin(handle: windows.HANDLE) !RawWinTerm {
    if (handle == windows.INVALID_HANDLE_VALUE) {
        return error.InvalidHandleValue;
    }

    var original_mode: windows.DWORD = 0;
    var result = windows.GetConsoleMode(handle, &original_mode);
    if (result == 0) {
        return error.GetConsoleModeFailed;
    }

    const not_raw_mode_mask: windows.DWORD = windows.ENABLE_LINE_INPUT | windows.ENABLE_ECHO_INPUT | windows.ENABLE_PROCESSED_INPUT;
    const flipped_mask: windows.DWORD = ~not_raw_mode_mask;

    const new_console_mode: windows.DWORD = original_mode & flipped_mask;

    result = windows.SetConsoleMode(handle, new_console_mode);
    if (result == 0) {
        return error.SetConsoleModeFailed;
    }

    return RawWinTerm{ .handle = handle, .original_mode = original_mode };
}

pub fn getWindowsStdinHandle() windows.HANDLE {
    const GENERIC_READ = 0x80000000;
    const GENERIC_WRITE = 0x40000000;
    const FILE_SHARE_READ = 0x00000001;
    const FILE_SHARE_WRITE = 0x00000002;
    const OPEN_EXISTING = 3;

    const console_handle = windows.CreateFileA(
        "CONIN$",
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        0,
        null,
    );

    return console_handle;
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
        const console_handle = getWindowsStdinHandle();

        if (console_handle == windows.INVALID_HANDLE_VALUE) {
            const err: windows.DWORD = windows.GetLastError();
            std.debug.print("GetLastError : {d}\n", .{err});
            return error.FailedToOpenConsole;
        }

        var term = enableRawModeWin(console_handle) catch |err| {
            std.debug.print("Failed to enable raw mode: {any}\n", .{err});
            _ = windows.CloseHandle(console_handle);
            return err;
        };
        defer term.disableRawMode() catch {};
        defer _ = windows.CloseHandle(console_handle);

        std.debug.print("Raw mode enabled successfully\n", .{});
    }
}
