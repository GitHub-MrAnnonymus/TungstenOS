hl.env("DMS_RUN_GREETER", "1")

hl.monitor({ output = "eDP-2", mode = "2560x1600@165.002", position = "0x0", scale = 1.6, vrr = 2 })

hl.config({
    misc = {
        disable_hyprland_logo = true
    }
})
