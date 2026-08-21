-- Draconic Evolution Energy Core foyer display for CC:Tweaked
-- Receives telemetry from relay.lua over rednet and renders to an Advanced Monitor.

local PROTOCOL = "destorage.telemetry.v1"
local CONFIG_FILE = ".destorage_display.cfg"
local STALE_MS = 2000
local AVG_WINDOW_MS = 10000

local C = colors

local function findWirelessModem()
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "modem" then
      local modem = peripheral.wrap(name)
      if modem and modem.isWireless and modem.isWireless() then return name end
    end
  end
end

local function findMonitor()
  local monitor, name = peripheral.find("monitor", function(n, m)
    return m.isColor and m.isColor()
  end)
  return name, monitor
end

local function loadConfig()
  if fs.exists(CONFIG_FILE) then
    local h = fs.open(CONFIG_FILE, "r")
    local cfg = textutils.unserialize(h.readAll())
    h.close()
    if type(cfg) == "table" then return cfg end
  end
  return nil
end

local function saveConfig(cfg)
  local h = fs.open(CONFIG_FILE, "w")
  h.write(textutils.serialize(cfg))
  h.close()
end

local function setupConfig()
  term.clear()
  term.setCursorPos(1, 1)
  print("DE Storage Display - First Setup")
  print()
  write("Display name: ")
  local name = read()
  if name == "" then name = "ENERGY CORE" end
  local cfg = { displayName = name }
  saveConfig(cfg)
  return cfg
end

local cfg = loadConfig() or setupConfig()
local modemName = findWirelessModem()
if not modemName then error("No wireless modem found", 0) end
if not rednet.isOpen(modemName) then rednet.open(modemName) end

local monitorName, mon = findMonitor()
if not mon then error("No Advanced Monitor found (direct or wired-network attached)", 0) end

mon.setTextScale(0.5)
local W, H = mon.getSize()

local packet, lastPacketMs
local samples = {}
local peakIn, peakOut = 0, 0

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end
local function writeAt(x, y, text, fg, bg)
  if y < 1 or y > H or x > W then return end
  mon.setCursorPos(math.max(1, x), y)
  mon.setTextColor(fg or C.white)
  mon.setBackgroundColor(bg or C.black)
  mon.write(tostring(text):sub(1, math.max(0, W - x + 1)))
end
local function center(y, text, fg)
  writeAt(math.floor((W - #text) / 2) + 1, y, text, fg)
end
local function hline(y, x1, x2, ch, fg)
  writeAt(x1, y, string.rep(ch or "-", math.max(0, x2 - x1 + 1)), fg or C.gray)
end
local function box(x1, y1, x2, y2, title)
  if x2 <= x1 or y2 <= y1 then return end
  hline(y1, x1 + 1, x2 - 1, "-", C.gray); hline(y2, x1 + 1, x2 - 1, "-", C.gray)
  for y = y1 + 1, y2 - 1 do writeAt(x1, y, "|", C.gray); writeAt(x2, y, "|", C.gray) end
  writeAt(x1, y1, "+", C.gray); writeAt(x2, y1, "+", C.gray); writeAt(x1, y2, "+", C.gray); writeAt(x2, y2, "+", C.gray)
  if title then writeAt(x1 + 2, y1, " " .. title .. " ", C.cyan) end
end

local suffixes = { {12,"T"},{9,"G"},{6,"M"},{3,"k"} }
local function fmt(v, decimals)
  local sign = v < 0 and "-" or ""
  local n = math.abs(v)
  for _, s in ipairs(suffixes) do
    local p = 10 ^ s[1]
    if n >= p then return string.format("%s%." .. (decimals or 2) .. "f%s", sign, n / p, s[2]) end
  end
  return string.format("%s%d", sign, math.floor(n + 0.5))
end
local function fmtTime(seconds)
  if not seconds or seconds < 0 or seconds == math.huge then return "--" end
  local d = math.floor(seconds / 86400); seconds = seconds % 86400
  local h = math.floor(seconds / 3600); seconds = seconds % 3600
  local m = math.floor(seconds / 60); local s = math.floor(seconds % 60)
  if d > 0 then return string.format("%dd %02dh %02dm", d,h,m) end
  return string.format("%02dh %02dm %02ds",h,m,s)
end

local function gauge(x, y, width, value, maxValue, fill, empty)
  maxValue = math.max(1, maxValue)
  local filled = clamp(math.floor((math.abs(value) / maxValue) * width + 0.5), 0, width)
  writeAt(x, y, string.rep(" ", filled), C.white, fill)
  writeAt(x + filled, y, string.rep(" ", width - filled), C.white, empty or C.gray)
end

local function averages(now)
  local totalIn,totalOut,totalNet,n = 0,0,0,0
  local keep = {}
  for _,s in ipairs(samples) do
    if now - s.t <= AVG_WINDOW_MS then
      keep[#keep+1]=s; totalIn=totalIn+s.input; totalOut=totalOut+s.output; totalNet=totalNet+s.net; n=n+1
    end
  end
  samples=keep
  if n==0 then return 0,0,0 end
  return totalIn/n,totalOut/n,totalNet/n
end

local function drawWaiting(message)
  mon.setBackgroundColor(C.black); mon.clear()
  center(math.max(2, math.floor(H/2)-1), cfg.displayName:upper(), C.purple)
  center(math.floor(H/2)+1, message, C.red)
end

local function draw()
  local now=os.epoch("utc")
  if not packet then drawWaiting("WAITING FOR CORE TELEMETRY") return end
  if now-lastPacketMs > STALE_MS then drawWaiting("!! TELEMETRY LOST !!") return end

  local stored,cap,input,output,net=packet.stored,packet.capacity,packet.input,packet.output,packet.net
  peakIn=math.max(peakIn,input); peakOut=math.max(peakOut,output)
  local avgIn,avgOut,avgNet=averages(now)
  local pct=cap>0 and stored/cap or 0
  local flowMax=math.max(120000, peakIn, peakOut, math.abs(net))
  flowMax=math.ceil(flowMax/10000)*10000

  mon.setBackgroundColor(C.black); mon.clear()
  center(1,cfg.displayName:upper(),C.purple)
  center(2,"DRACONIC ENERGY CORE",C.lightGray)

  local split=math.floor(W*0.66)
  box(1,4,split,10,"ENERGY STORAGE")
  writeAt(3,6,"STORED",C.lightGray); writeAt(12,6,fmt(stored,3).." OP",C.yellow)
  writeAt(math.max(3,split-24),6,"CAP "..fmt(cap,3).." OP",C.yellow)
  local barX,barW=3,math.max(10,split-6)
  gauge(barX,8,barW,pct,1,C.lime,C.gray)
  writeAt(3,9,string.format("%.3f%%",pct*100),C.lime)

  box(split+1,4,W,10,"CORE STATUS")
  local state,stateColor="IDLE",C.lightGray
  if net>0 then state,stateColor="CHARGING",C.lime elseif net<0 then state,stateColor="DISCHARGING",C.orange end
  writeAt(split+3,6,"STATUS",C.lightGray); writeAt(split+12,6,state,stateColor)
  writeAt(split+3,8,"LINK",C.lightGray); writeAt(split+12,8,"ONLINE",C.lime)

  local flowBottom=math.min(H-7,18)
  box(1,11,W,flowBottom,"LIVE POWER FLOW (OP/t)")
  local labelW=18
  local gx=labelW+2; local gw=math.max(10,W-gx-10)
  local rows={{"INPUT",input,C.lime},{"OUTPUT",output,C.orange},{"NET",net,C.lightBlue}}
  for i,r in ipairs(rows) do
    local y=12+i
    writeAt(3,y,string.format("%-6s %9s",r[1],(r[3]==C.orange and "-" or (r[1]=="NET" and (r[2]>=0 and "+" or "") or "+"))..fmt(math.abs(r[2]),1)),r[3])
    gauge(gx,y,gw,r[2],flowMax,r[3],C.gray)
  end
  writeAt(gx,flowBottom-1,"0",C.gray); writeAt(math.max(gx,W-12),flowBottom-1,fmt(flowMax,0),C.gray)

  if H>=25 then
    local statTop=flowBottom+1; local statBottom=H-2; local mid=math.floor(W/2)
    box(1,statTop,mid,statBottom,"10s AVERAGES")
    writeAt(3,statTop+2,"INPUT  "..fmt(avgIn,2).." OP/t",C.lime)
    writeAt(3,statTop+3,"OUTPUT "..fmt(avgOut,2).." OP/t",C.orange)
    writeAt(3,statTop+4,"NET    "..(avgNet>=0 and "+" or "")..fmt(avgNet,2).." OP/t",C.lightBlue)
    writeAt(3,statTop+6,"PEAK IN  "..fmt(peakIn,2),C.lightGray)
    writeAt(3,statTop+7,"PEAK OUT "..fmt(peakOut,2),C.lightGray)

    box(mid+1,statTop,W,statBottom,"ESTIMATE")
    local eta
    if avgNet>0 then eta=((cap-stored)/avgNet)/20 end
    writeAt(mid+3,statTop+2,"TIME TO FULL",C.lightGray)
    writeAt(mid+3,statTop+3,fmtTime(eta),C.magenta)
    writeAt(mid+3,statTop+5,"NET FLOW",C.lightGray)
    writeAt(mid+3,statTop+6,(avgNet>=0 and "+" or "")..fmt(avgNet,2).." OP/t",avgNet>=0 and C.lime or C.orange)
  end

  writeAt(2,H,"LIVE TELEMETRY  |  10 Hz RF / 20 Hz DISPLAY",C.gray)
end

local function receiver()
  while true do
    local _,msg=rednet.receive(PROTOCOL)
    if type(msg)=="table" and msg.version==1 and type(msg.stored)=="number" then
      packet=msg; lastPacketMs=os.epoch("utc")
      samples[#samples+1]={t=lastPacketMs,input=msg.input or 0,output=msg.output or 0,net=msg.net or 0}
    end
  end
end

local function renderer()
  while true do draw(); sleep(0.05) end
end

parallel.waitForAny(receiver,renderer)
