-- Render on the integrated GPU when one is present; the NVIDIA GPU stays secondary.
local function exists(path)
	local f = io.open(path, "r")
	if f then f:close() return true end
	return false
end

local devices = {}
if exists("/dev/dri/amd-igpu") then
	table.insert(devices, "/dev/dri/amd-igpu")
	hl.env("VK_DRIVER_FILES", "/usr/share/vulkan/icd.d/radeon_icd.json")
	hl.env("LIBVA_DRIVER_NAME", "radeonsi")
	hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")
elseif exists("/dev/dri/intel-igpu") then
	table.insert(devices, "/dev/dri/intel-igpu")
	hl.env("VK_DRIVER_FILES", "/usr/share/vulkan/icd.d/intel_icd.x86_64.json")
	hl.env("LIBVA_DRIVER_NAME", "iHD")
	hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")
end
if exists("/dev/dri/nvidia-dgpu") then
	table.insert(devices, "/dev/dri/nvidia-dgpu")
end
if #devices > 0 then
	hl.env("AQ_DRM_DEVICES", table.concat(devices, ":"))
end
