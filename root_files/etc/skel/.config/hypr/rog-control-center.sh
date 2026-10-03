#!/bin/bash
[ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ] || exit 1

for i in $(seq 1 60); do
    busctl --user list 2>/dev/null | grep -q org.kde.StatusNotifierWatcher && break
    sleep 0.5
done

exec rog-control-center --background
