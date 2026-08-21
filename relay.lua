-- Draconic Evolution Energy Core telemetry relay for CC:Tweaked
-- Reads one draconic_rf_storage peripheral over a wired modem/direct connection
-- and broadcasts core-wide telemetry over a wireless modem.

local PROTOCOL = "destorage.telemetry.v1"
local BROADCAST_INTERVAL = 0.10 -- seconds (10 Hz)

local function die(msg)
  printError(msg)
  error(msg, 0)
end

local function findWirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem and modem.isWireless and modem.isWireless() then
        return name, modem
      end
    end
  end
end

local function findCore()
  -- peripheral.find returns the wrapped peripheral, not its network name.
  local core = peripheral.find("draconic_rf_storage")
  if not core then return nil, nil end

  -- Resolve a friendly peripheral name separately for status output.
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "draconic_rf_storage" then
      return name, core
    end
  end

  return "draconic_rf_storage", core
end

term.clear()
term.setCursorPos(1, 1)
print("DE Storage Telemetry Relay")
print("--------------------------")

local modemName = findWirelessModem()
if not modemName then
  die("No wireless modem found. Attach a CC:Tweaked wireless modem.")
end

if not rednet.isOpen(modemName) then
  rednet.open(modemName)
end

local coreName, core = findCore()
if not core then
  die("No draconic_rf_storage peripheral found. Ensure a wired modem exposes an Energy Pylon to this computer.")
end

print("Wireless modem: " .. modemName)
print("DE peripheral:   " .. coreName)
print("Protocol:        " .. PROTOCOL)
print("Broadcast:       10 Hz")
print()
print("Relay online.")

local sequence = 0

while true do
  sequence = sequence + 1

  local ok, packet = pcall(function()
    return {
      version = 1,
      sequence = sequence,
      sender = os.getComputerID(),
      sentAt = os.epoch("utc"),
      stored = core.getEnergyStored(),
      capacity = core.getMaxEnergyStored(),
      input = core.getInputPerTick(),
      output = core.getOutputPerTick(),
      net = core.getTransferPerTick(),
    }
  end)

  if ok then
    rednet.broadcast(packet, PROTOCOL)
  else
    term.setCursorPos(1, 8)
    term.clearLine()
    term.setTextColor(colors.red)
    write("CORE READ ERROR")
    term.setTextColor(colors.white)
  end

  sleep(BROADCAST_INTERVAL)
end
