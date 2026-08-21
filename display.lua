-- Draconic Evolution Energy Core foyer display for CC:Tweaked
-- Large-format animated telemetry dashboard.

local PROTOCOL="destorage.telemetry.v1"
local CONFIG_FILE=".destorage_display.cfg"
local STALE_MS=2000
local AVG_WINDOW_MS=10000
local C=colors

local function findWirelessModem()
 for _,n in ipairs(peripheral.getNames()) do
  if peripheral.getType(n)=="modem" then local m=peripheral.wrap(n); if m and m.isWireless and m.isWireless() then return n end end
 end
end
local function findMonitor()
 local m=peripheral.find("monitor",function(_,p) return p.isColor and p.isColor() end); return m
end
local function loadConfig()
 if fs.exists(CONFIG_FILE) then local h=fs.open(CONFIG_FILE,"r"); local c=textutils.unserialize(h.readAll()); h.close(); if type(c)=="table" then return c end end
end
local function saveConfig(c) local h=fs.open(CONFIG_FILE,"w"); h.write(textutils.serialize(c)); h.close() end
local function setupConfig()
 term.clear(); term.setCursorPos(1,1); print("DE Storage Display - First Setup\n"); write("Display name: "); local n=read(); if n=="" then n="ENERGY CORE" end
 local c={displayName=n}; saveConfig(c); return c
end

local cfg=loadConfig() or setupConfig()
local modemName=findWirelessModem(); if not modemName then error("No wireless modem found",0) end
if not rednet.isOpen(modemName) then rednet.open(modemName) end
local mon=findMonitor(); if not mon then error("No Advanced Monitor found",0) end
mon.setTextScale(0.5)
local W,H=mon.getSize()
local packet,lastPacketMs
local samples,history={},{ }
local peakIn,peakOut=0,0
local frame=0

local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function put(x,y,s,fg,bg)
 if y<1 or y>H or x>W then return end
 mon.setCursorPos(math.max(1,x),y); mon.setTextColor(fg or C.white); mon.setBackgroundColor(bg or C.black); mon.write(tostring(s):sub(1,math.max(0,W-x+1)))
end
local function center(y,s,fg,bg) put(math.floor((W-#s)/2)+1,y,s,fg,bg) end
local function line(y,x1,x2,ch,fg) put(x1,y,string.rep(ch or "-",math.max(0,x2-x1+1)),fg) end
local function box(x1,y1,x2,y2,title,accent)
 accent=accent or C.gray; if x2<=x1 or y2<=y1 then return end
 line(y1,x1+1,x2-1,"-",accent); line(y2,x1+1,x2-1,"-",accent)
 for y=y1+1,y2-1 do put(x1,y,"|",accent); put(x2,y,"|",accent) end
 put(x1,y1,"+",accent); put(x2,y1,"+",accent); put(x1,y2,"+",accent); put(x2,y2,"+",accent)
 if title then put(x1+2,y1," "..title.." ",C.cyan) end
end
local suffix={{15,"P"},{12,"T"},{9,"G"},{6,"M"},{3,"k"}}
local function fmt(v,d)
 local sign=v<0 and "-" or ""; local n=math.abs(v)
 for _,s in ipairs(suffix) do local p=10^s[1]; if n>=p then return string.format("%s%."..(d or 2).."f%s",sign,n/p,s[2]) end end
 return string.format("%s%d",sign,math.floor(n+.5))
end
local function fmtTime(sec)
 if not sec or sec<0 or sec==math.huge then return "--" end
 local d=math.floor(sec/86400); sec=sec%86400; local h=math.floor(sec/3600); sec=sec%3600; local m=math.floor(sec/60); local s=math.floor(sec%60)
 if d>0 then return string.format("%dd %02dh %02dm",d,h,m) end; return string.format("%02dh %02dm %02ds",h,m,s)
end
local function bar(x,y,w,v,maxv,fill,empty)
 local f=clamp(math.floor((math.abs(v)/math.max(1,maxv))*w+.5),0,w); put(x,y,string.rep(" ",f),C.white,fill); put(x+f,y,string.rep(" ",w-f),C.white,empty or C.gray)
end
local function averages(now)
 local a,b,c,n=0,0,0,0; local keep={}
 for _,s in ipairs(samples) do if now-s.t<=AVG_WINDOW_MS then keep[#keep+1]=s;a=a+s.input;b=b+s.output;c=c+s.net;n=n+1 end end
 samples=keep; if n==0 then return 0,0,0 end; return a/n,b/n,c/n
end
local function spark(x,y,w,h,data,maxAbs)
 if #data<2 then return end
 maxAbs=math.max(1,maxAbs); local mid=y+math.floor(h/2); line(mid,x,x+w-1,"-",C.gray)
 local start=math.max(1,#data-w+1)
 for i=start,#data do
  local px=x+(i-start); local v=data[i]; local mag=math.floor(math.abs(v)/maxAbs*math.max(1,math.floor(h/2)-1)+.5)
  if v>=0 then for dy=1,mag do put(px,mid-dy,"|",C.lime) end else for dy=1,mag do put(px,mid+dy,"|",C.orange) end end
 end
end
local function coreGraphic(cx,cy,r,pct,stateColor)
 -- animated pseudo-spherical DE core using character cells
 for yy=-r,r do
  local half=math.floor(math.sqrt(math.max(0,r*r-yy*yy))*1.8)
  for xx=-half,half do
   local edge=(math.abs(xx)>=half-1)
   local pattern=((xx+yy+frame)%5==0 or (xx-yy-frame)%7==0)
   local fg=edge and C.purple or (pattern and C.cyan or C.blue)
   put(cx+xx,cy+yy,pattern and "*" or " ",fg,fg)
  end
 end
 -- orbiting indicators
 local pts={{-math.floor(r*1.9),0},{math.floor(r*1.9),0},{0,-r-1},{0,r+1}}
 for i,p in ipairs(pts) do local pulse=((frame+i)%4<2) and C.yellow or stateColor; put(cx+p[1],cy+p[2],"<>" ,pulse) end
 center(cy+r+3,string.format("CORE CHARGE  %.3f%%",pct*100),C.lightBlue)
end
local function waiting(msg)
 mon.setBackgroundColor(C.black);mon.clear();center(math.floor(H/2)-2,cfg.displayName:upper(),C.purple);center(math.floor(H/2),"DRACONIC ENERGY CORE",C.cyan);center(math.floor(H/2)+3,msg,C.red)
end

local function draw()
 frame=(frame+1)%420; local now=os.epoch("utc")
 if not packet then waiting("AWAITING WIRELESS TELEMETRY") return end
 if now-lastPacketMs>STALE_MS then waiting("!! TELEMETRY LINK LOST !!") return end
 local stored,cap,input,output,net=packet.stored,packet.capacity,packet.input,packet.output,packet.net
 peakIn=math.max(peakIn,input);peakOut=math.max(peakOut,output)
 local ai,ao,an=averages(now); local pct=cap>0 and stored/cap or 0
 local state="STANDBY";local stateColor=C.lightGray;if net>0 then state="CHARGING";stateColor=C.lime elseif net<0 then state="DISCHARGING";stateColor=C.orange end
 local flowMax=math.ceil(math.max(120000,peakIn,peakOut,math.abs(net))/10000)*10000
 mon.setBackgroundColor(C.black);mon.clear()
 -- header
 put(2,1,"[ RYUGU POWER SYSTEM ]",C.purple); center(1,cfg.displayName:upper().." // DRACONIC ENERGY CORE",C.cyan); put(math.max(2,W-22),1,"LINK: ONLINE",C.lime)
 line(2,1,W,"=",C.purple)
 -- top telemetry strip
 box(1,3,W,10,"CORE TELEMETRY",C.purple)
 put(4,5,"STORED",C.lightGray);put(15,5,fmt(stored,3).." OP",C.yellow)
 put(math.floor(W*.35),5,"CAPACITY",C.lightGray);put(math.floor(W*.35)+12,5,fmt(cap,3).." OP",C.yellow)
 put(math.floor(W*.67),5,"STATE",C.lightGray);put(math.floor(W*.67)+9,5,state,stateColor)
 put(4,7,string.format("CHARGE %8.4f%%",pct*100),C.lightBlue)
 local bx=24;local bw=math.max(20,W-bx-5);bar(bx,7,bw,pct,1,C.cyan,C.gray)
 put(4,9,"IN  +"..fmt(input,2).." OP/t",C.lime);put(math.floor(W*.35),9,"OUT -"..fmt(output,2).." OP/t",C.orange);put(math.floor(W*.67),9,"NET "..(net>=0 and "+" or "")..fmt(net,2).." OP/t",stateColor)
 -- lower layout
 local top=12; local bottom=H-2; local leftW=math.floor(W*.31);local rightX=math.floor(W*.70);local centerL=leftW+2;local centerR=rightX-2
 box(1,top,leftW,bottom,"POWER FLOW",C.gray)
 put(3,top+2,"LIVE TRANSFER",C.cyan)
 local gw=math.max(10,leftW-18)
 local flows={{"INPUT",input,C.lime},{"OUTPUT",output,C.orange},{"NET",net,C.lightBlue}}
 for i,rw in ipairs(flows) do local y=top+3+i*2;put(3,y,string.format("%-6s %9s",rw[1],(rw[1]=="OUTPUT" and "-" or (rw[1]=="NET" and rw[2]<0 and "-" or "+"))..fmt(math.abs(rw[2]),1)),rw[3]);bar(18,y,gw,rw[2],flowMax,rw[3],C.gray) end
 put(3,top+11,"10 SEC AVERAGE",C.cyan);put(3,top+13,"IN    +"..fmt(ai,2),C.lime);put(3,top+14,"OUT   -"..fmt(ao,2),C.orange);put(3,top+15,"NET   "..(an>=0 and "+" or "")..fmt(an,2),an>=0 and C.lime or C.orange)
 put(3,top+18,"SESSION PEAKS",C.cyan);put(3,top+20,"INPUT  "..fmt(peakIn,2).." OP/t",C.lightGray);put(3,top+21,"OUTPUT "..fmt(peakOut,2).." OP/t",C.lightGray)
 -- center hero core
 box(centerL,top,centerR,bottom,"ENERGY CORE",C.purple)
 local cx=math.floor((centerL+centerR)/2);local availableH=bottom-top-10;local r=math.max(5,math.min(10,math.floor(availableH/2)))
 coreGraphic(cx,top+5+r,r,pct,stateColor)
 local etaFull=an>0 and ((cap-stored)/an)/20 or nil;local etaEmpty=an<0 and (stored/math.abs(an))/20 or nil
 center(bottom-6,"OPERATIONAL STATE",C.gray);center(bottom-5,state,stateColor)
 if an>0 then center(bottom-3,"EST. FULL  "..fmtTime(etaFull),C.magenta) elseif an<0 then center(bottom-3,"EST. EMPTY "..fmtTime(etaEmpty),C.orange) else center(bottom-3,"ENERGY RESERVE STABLE",C.lightGray) end
 -- right history
 box(rightX,top,W,bottom,"TRANSFER HISTORY",C.gray)
 put(rightX+2,top+2,"NET FLOW // RECENT",C.cyan)
 local graphX=rightX+3;local graphW=math.max(10,W-rightX-5);local graphY=top+4;local graphH=math.min(15,math.max(7,bottom-top-16))
 spark(graphX,graphY,graphW,graphH,history,flowMax)
 put(rightX+2,graphY+graphH+2,"SCALE +/- "..fmt(flowMax,1).." OP/t",C.gray)
 put(rightX+2,graphY+graphH+4,"WIRELESS LINK",C.cyan);put(rightX+18,graphY+graphH+4,"ONLINE",C.lime)
 put(rightX+2,graphY+graphH+5,"SOURCE ID",C.gray);put(rightX+18,graphY+graphH+5,tostring(packet.sender or "--"),C.white)
 put(rightX+2,graphY+graphH+7,"PACKET",C.gray);put(rightX+18,graphY+graphH+7,"#"..tostring(packet.sequence or 0),C.white)
 -- footer animated scanner
 local scanW=math.max(1,W-4);local scan=(frame%scanW)+2;line(H,2,W-1,"-",C.gray);put(scan,H,"###",stateColor);put(2,H,"LIVE",C.lime);put(math.max(2,W-27),H,"RF 10Hz // UI 20Hz",C.gray)
end

local function receiver()
 while true do
  local _,msg=rednet.receive(PROTOCOL)
  if type(msg)=="table" and msg.version==1 and type(msg.stored)=="number" then
   packet=msg;lastPacketMs=os.epoch("utc");samples[#samples+1]={t=lastPacketMs,input=msg.input or 0,output=msg.output or 0,net=msg.net or 0};history[#history+1]=msg.net or 0;if #history>120 then table.remove(history,1) end
  end
 end
end
local function renderer() while true do draw();sleep(.05) end end
parallel.waitForAny(receiver,renderer)
