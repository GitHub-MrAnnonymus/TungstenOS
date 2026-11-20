-- Passed with --config in config.toml: without it dms-greeter uses its built-in config.
hl.env("DMS_RUN_GREETER", "1")
-- No JIT in QML: SELinux denies writable executable memory.
hl.env("QV4_FORCE_INTERPRETER", "1")

hl.config({
    -- Until the login screen draws, Hyprland shows its empty background: black like the
    -- boot splash's, without the splash text, so the moment is not visible.
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        background_color = 0xff000000
    },
    -- The login screen needs no screen capture, cursor tracking or plugins: deny them.
    ecosystem = {
        enforce_permissions = true
    }
})
hl.permission({ binary = ".*", type = "screencopy", mode = "deny" })
hl.permission({ binary = ".*", type = "cursorpos", mode = "deny" })
hl.permission({ binary = ".*", type = "input-capture", mode = "deny" })
hl.permission({ binary = ".*", type = "plugin", mode = "deny" })
