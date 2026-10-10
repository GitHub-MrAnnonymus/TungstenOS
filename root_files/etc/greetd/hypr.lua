hl.env("DMS_RUN_GREETER", "1")
-- No JIT in QML: SELinux denies writable executable memory.
hl.env("QV4_FORCE_INTERPRETER", "1")

hl.config({
    misc = {
        disable_hyprland_logo = true
    }
})
