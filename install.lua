-- Installer for Minecraft-CC-DEStorage_display
-- Selects and installs either the core telemetry relay or foyer display.

local BASE = "https://raw.githubusercontent.com/Draze08/Minecraft-CC-DEStorage_display/main/"

local function banner()
  term.clear()
  term.setCursorPos(1,1)
  print("DE Storage Display Installer")
  print("============================")
  print()
  print("Select this computer's role:")
  print()
  print("  1. Relay")
  print("     DE pylon -> wired modem -> this PC -> wireless")
  print()
  print("  2. Display")
  print("     wireless -> this PC -> Advanced Monitor")
  print()
end

local function download(url, path)
  if fs.exists(path) then fs.delete(path) end
  local ok, err = pcall(function() shell.run("wget", url, path) end)
  if not ok or not fs.exists(path) then
    error("Failed to download " .. path .. (err and (": "..tostring(err)) or ""), 0)
  end
end

banner()
write("Selection [1/2]: ")
local choice = read()

local source, role
if choice == "1" then
  source, role = "relay.lua", "Relay"
elseif choice == "2" then
  source, role = "display.lua", "Display"
else
  printError("Invalid selection.")
  return
end

print()
print("Installing " .. role .. "...")
download(BASE .. source, "destorage.lua")

local startup = [[-- DE Storage Display auto-start
shell.run("destorage.lua")
]]
local h = fs.open("startup.lua", "w")
h.write(startup)
h.close()

print("Installed: " .. source .. " -> destorage.lua")
print("Created:   startup.lua")
print()
print("Role: " .. role)
print("Rebooting in 2 seconds...")
sleep(2)
os.reboot()
