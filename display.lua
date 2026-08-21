-- Draconic Evolution Energy Core foyer display for CC:Tweaked
-- Dense large-format telemetry console. Generic: owner/site name is user-configurable.

local PROTOCOL="destorage.telemetry.v1"
local CONFIG_FILE=".destorage_display.cfg"
local STALE_MS=2000
local AVG_WINDOW_MS=10000
local C=colors

local function findWirelessModem()
 for _,n in ipairs(peripheral.getNames()) do if peripheral.getType(n)=="modem" then local m=peripheral.wrap(n); if m and m.isWireless and m.isWireless() then return n end end end
end
local function findMonitor() return peripheral.find("monitor",function(_,p) return p.isColor and p.isColor() end) end
local function loadConfig()
 if fs.exists(CONFIG_FILE) then local h=fs.open(CONFIG_FILE,"r");local c=textutils.unserialize(h.readAll());h.close();if type(c)=="table" then return c end end
end
local function saveConfig(c) local h=fs.open(CONFIG_FILE,"w");h.write(textutils.serialize(c));h.close() end
local function setupConfig(old)
 term.setBackgroundColor(C.black);term.setTextColor(C.white);term.clear();term.setCursorPos(1,1)
 print("DE Storage Display - Setup\n")
 write("Site / display name") if old and old.displayName then write(" ["..old.displayName.."]") end write(": ")
 local n=read();if n=="" then n=(old and old.displayName) or "ENERGY CORE" end
 write("System subtitle") if old and old.subtitle then write(" ["..old.subtitle.."]") end write(": ")
 local s=read();if s=="" then s=(old and old.subtitle) or "ENERGY CONTROL" end
 local c={displayName=n,subtitle=s};saveConfig(c);return c
end
local cfg=loadConfig() or setupConfig(nil)
-- Delete .destorage_display.cfg and reboot to rerun setup at any time.
local modemName=findWirelessModem();if not modemName then error("No wireless modem found",0) end;if not rednet.isOpen(modemName) then rednet.open(modemName) end
local mon=findMonitor();if not mon then error("No Advanced Monitor found",0) end
mon.setTextScale(.5);local W,H=mon.getSize()
local packet,lastPacketMs;local samples={};local history={};local peakIn,peakOut=0,0;local minNet,maxNet=0,0;local rxCount=0;local startMs=os.epoch("utc")

local function clamp(v,a,b)return math.max(a,math.min(b,v))end
local function put(x,y,s,fg,bg)if y<1 or y>H or x>W then return end;mon.setCursorPos(math.max(1,x),y);mon.setTextColor(fg or C.white);mon.setBackgroundColor(bg or C.black);mon.write(tostring(s):sub(1,math.max(0,W-x+1)))end
local function center(y,s,fg)local x=math.floor((W-#s)/2)+1;put(x,y,s,fg)end
local function line(y,x1,x2,ch,fg)put(x1,y,string.rep(ch or "-",math.max(0,x2-x1+1)),fg or C.gray)end
local function box(x1,y1,x2,y2,title)
 if x2<=x1 or y2<=y1 then return end;line(y1,x1+1,x2-1,"-",C.lightGray);line(y2,x1+1,x2-1,"-",C.lightGray)
 for y=y1+1,y2-1 do put(x1,y,"|",C.lightGray);put(x2,y,"|",C.lightGray)end;put(x1,y1,"+",C.lightGray);put(x2,y1,"+",C.lightGray);put(x1,y2,"+",C.lightGray);put(x2,y2,"+",C.lightGray)
 if title then put(x1+2,y1," "..title.." ",C.cyan)end
end
local suffix={{15,"P"},{12,"T"},{9,"G"},{6,"M"},{3,"k"}}
local function fmt(v,d)local sign=v<0 and "-" or "";local n=math.abs(v);for _,s in ipairs(suffix)do local p=10^s[1];if n>=p then return string.format("%s%."..(d or 2).."f%s",sign,n/p,s[2])end end;return string.format("%s%d",sign,math.floor(n+.5))end
local function commas(n)local s=tostring(math.floor(math.abs(n)+.5));local r=s:reverse():gsub("(%d%d%d)","%1,"):reverse():gsub("^,","");return (n<0 and "-" or "")..r end
local function fmtTime(sec)if not sec or sec<0 or sec==math.huge then return "--" end;local d=math.floor(sec/86400);sec=sec%86400;local h=math.floor(sec/3600);sec=sec%3600;local m=math.floor(sec/60);local s=math.floor(sec%60);if d>0 then return string.format("%dd %02dh %02dm %02ds",d,h,m,s)end;return string.format("%02dh %02dm %02ds",h,m,s)end
local function bar(x,y,w,v,maxv,fill,empty)local f=clamp(math.floor((math.abs(v)/math.max(1,maxv))*w+.5),0,w);put(x,y,string.rep(" ",f),C.white,fill);put(x+f,y,string.rep(" ",w-f),C.white,empty or C.gray)end
local function segmented(x,y,w,pct,fill)local n=math.max(1,math.floor(w/2));local on=clamp(math.floor(pct*n+.5),0,n);for i=1,n do put(x+(i-1)*2,y,"[]",i<=on and fill or C.lightGray)end end
local function averages(now)local a,b,c,n=0,0,0,0;local keep={};for _,s in ipairs(samples)do if now-s.t<=AVG_WINDOW_MS then keep[#keep+1]=s;a=a+s.input;b=b+s.output;c=c+s.net;n=n+1 end end;samples=keep;if n==0 then return 0,0,0 end;return a/n,b/n,c/n end
local tiers={{1,4e6},{2,273e6},{3,1.64e9},{4,9.88e9},{5,59.3e9},{6,356e9},{7,2.14e12},{8,9.22e18}}
local function tierFor(cap)local best="?";local err=math.huge;for _,t in ipairs(tiers)do local e=math.abs(cap-t[2])/t[2];if e<err then err=e;best=t[1]end end;return best end
local function waiting(msg)mon.setBackgroundColor(C.black);mon.clear();center(math.floor(H/2)-2,cfg.displayName:upper(),C.purple);center(math.floor(H/2),cfg.subtitle:upper(),C.cyan);center(math.floor(H/2)+3,msg,C.red)end

local function draw()
 local now=os.epoch("utc");if not packet then waiting("AWAITING CORE TELEMETRY")return end;if now-lastPacketMs>STALE_MS then waiting("!! TELEMETRY LINK LOST !!")return end
 local stored,cap,input,output,net=packet.stored,packet.capacity,packet.input,packet.output,packet.net;local pct=cap>0 and stored/cap or 0;peakIn=math.max(peakIn,input);peakOut=math.max(peakOut,output);minNet=math.min(minNet,net);maxNet=math.max(maxNet,net)
 local ai,ao,an=averages(now);local flowMax=math.ceil(math.max(120000,peakIn,peakOut,math.abs(net))/10000)*10000;local state="STANDBY";local sc=C.lightGray;if net>0 then state="CHARGING";sc=C.lime elseif net<0 then state="DISCHARGING";sc=C.orange end
 local etaFull=an>0 and ((cap-stored)/an)/20 or nil;local etaEmpty=an<0 and (stored/math.abs(an))/20 or nil;local uptime=(now-startMs)/1000;local tier=tierFor(cap);local utilization=flowMax>0 and math.abs(net)/flowMax or 0;local ioRatio=input>0 and output/input or 0;local reserve=cap-stored
 mon.setBackgroundColor(C.black);mon.clear()
 -- masthead
 center(1,cfg.displayName:upper().."  //  "..cfg.subtitle:upper(),C.purple);center(2,"TIER "..tier.." DRACONIC ENERGY CORE",C.lightGray);center(3,"<<<  SYSTEM "..state.."  >>>",sc);line(4,1,W,"=",C.lightGray)
 -- row 1: status/storage/info
 local a=math.floor(W*.22);local b=math.floor(W*.73)
 box(1,5,a,17,"CORE STATUS");box(a+1,5,b,17,"ENERGY STORAGE");box(b+1,5,W,17,"CORE INFORMATION")
 put(3,7,"STATUS",C.lightGray);put(15,7,"ONLINE",C.lime);put(3,9,"LINK",C.lightGray);put(15,9,"ONLINE",C.lime);put(3,11,"STATE",C.lightGray);put(15,11,state,sc);put(3,13,"TELEMETRY",C.lightGray);put(15,13,"10 Hz",C.cyan);put(3,15,"PACKETS",C.lightGray);put(15,15,commas(rxCount),C.white)
 put(a+4,7,"STORED",C.lightGray);put(a+18,7,fmt(stored,4).." OP",C.yellow);put(b-30,7,"CAPACITY",C.lightGray);put(b-18,7,fmt(cap,4).." OP",C.yellow)
 segmented(a+4,10,b-a-10,pct,C.lime);put(b-15,12,string.format("%9.5f%%",pct*100),C.white);line(14,a+4,b-4,"-",C.gray);put(a+4,15,"0%",C.gray);put(math.floor((a+b)/2)-2,15,"50%",C.gray);put(b-8,15,"100%",C.gray)
 put(b+3,7,"CORE TIER",C.lightGray);put(b+20,7,tostring(tier),C.white);put(b+3,9,"CORE TYPE",C.lightGray);put(b+20,9,"ENERGY CORE",C.white);put(b+3,11,"CAPACITY RAW",C.lightGray);put(b+20,11,fmt(cap,2).." OP",C.yellow);put(b+3,13,"RESERVE",C.lightGray);put(b+20,13,fmt(reserve,2).." OP",C.cyan);put(b+3,15,"SOURCE ID",C.lightGray);put(b+20,15,tostring(packet.sender or "--"),C.white)
 -- row 2 power flow + state
 local r2t=18;local r2b=31;local flowR=math.floor(W*.70);box(1,r2t,flowR,r2b,"POWER FLOW (OP/t)");box(flowR+1,r2t,W,r2b,"POWER FLOW STATUS")
 local gx=30;local gw=math.max(15,flowR-gx-12);local rows={{"INPUT","+",input,C.lime},{"OUTPUT","-",output,C.orange},{"NET",net>=0 and "+" or "-",math.abs(net),C.lightBlue}}
 for i,r in ipairs(rows)do local y=r2t+2+i*3;put(3,y,string.format("%-7s %s%10s",r[1],r[2],fmt(r[3],2)),r[4]);bar(gx,y,gw,r[3],flowMax,r[4],C.gray);put(flowR-10,y,fmt(flowMax,0),C.lightGray)end
 put(flowR+4,r2t+3,"<<< "..state.." >>>",sc);put(flowR+4,r2t+6,"TO CORE",C.lightGray);put(flowR+20,r2t+6,"+"..fmt(input,2),C.lime);put(flowR+4,r2t+8,"TO NETWORK",C.lightGray);put(flowR+20,r2t+8,"-"..fmt(output,2),C.orange);put(flowR+4,r2t+10,"NET",C.lightGray);put(flowR+20,r2t+10,(net>=0 and "+" or "")..fmt(net,2),C.lightBlue)
 -- row 3: stats / estimate / diagnostics
 local r3t=32;local r3b=H-2;local c1=math.floor(W*.34);local c2=math.floor(W*.65);box(1,r3t,c1,r3b,"ENERGY STATISTICS (10s AVG)");box(c1+1,r3t,c2,r3b,"TIME / RESERVE ESTIMATE");box(c2+1,r3t,W,r3b,"SYSTEM DIAGNOSTICS")
 put(3,r3t+2,"AVG INPUT",C.lightGray);put(20,r3t+2,"+"..fmt(ai,2).." OP/t",C.lime);put(3,r3t+4,"AVG OUTPUT",C.lightGray);put(20,r3t+4,"-"..fmt(ao,2).." OP/t",C.orange);put(3,r3t+6,"AVG NET",C.lightGray);put(20,r3t+6,(an>=0 and "+" or "")..fmt(an,2).." OP/t",C.lightBlue);put(3,r3t+9,"PEAK INPUT",C.lightGray);put(20,r3t+9,fmt(peakIn,2),C.lime);put(3,r3t+11,"PEAK OUTPUT",C.lightGray);put(20,r3t+11,fmt(peakOut,2),C.orange);put(3,r3t+13,"NET RANGE",C.lightGray);put(20,r3t+13,fmt(minNet,1).." / +"..fmt(maxNet,1),C.cyan)
 local eta=an>0 and etaFull or etaEmpty;put(c1+4,r3t+2,an>=0 and "ESTIMATED TIME TO FULL" or "ESTIMATED TIME TO EMPTY",C.lightGray);put(c1+4,r3t+4,fmtTime(eta),C.magenta);put(c1+4,r3t+7,"ENERGY REMAINING",C.lightGray);put(c1+4,r3t+8,fmt(reserve,4).." OP",C.yellow);put(c1+4,r3t+11,"DISPLAY UPTIME",C.lightGray);put(c1+4,r3t+12,fmtTime(uptime),C.cyan);put(c1+4,r3t+15,"CORE FILL RATE",C.lightGray);put(c1+4,r3t+16,string.format("%.8f %%/s",cap>0 and an*20/cap*100 or 0),sc)
 put(c2+3,r3t+2,"TRANSFER UTIL.",C.lightGray);put(c2+22,r3t+2,string.format("%6.2f%%",utilization*100),C.cyan);put(c2+3,r3t+4,"OUTPUT / INPUT",C.lightGray);put(c2+22,r3t+4,string.format("%6.2f%%",ioRatio*100),C.orange);put(c2+3,r3t+6,"PACKET AGE",C.lightGray);put(c2+22,r3t+6,tostring(now-lastPacketMs).." ms",C.lime);put(c2+3,r3t+8,"SAMPLE WINDOW",C.lightGray);put(c2+22,r3t+8,tostring(#samples),C.white);put(c2+3,r3t+10,"FLOW SCALE",C.lightGray);put(c2+22,r3t+10,fmt(flowMax,2),C.white);put(c2+3,r3t+12,"PROTOCOL",C.lightGray);put(c2+22,r3t+12,"v1",C.white);put(c2+3,r3t+15,"CORE CONDITION",C.lightGray);put(c2+22,r3t+15,"NOMINAL",C.lime)
 -- footer
 line(H,1,W,"=",C.lightGray);put(2,H,"LIVE TELEMETRY // RF 10 Hz // DISPLAY 20 Hz",C.gray);local clock=textutils.formatTime(os.time(),true);put(math.floor(W/2)-#clock/2,H,clock,C.yellow);put(math.max(2,W-28),H,"SEQ #"..tostring(packet.sequence or 0),C.yellow)
end

local function receiver()while true do local _,msg=rednet.receive(PROTOCOL);if type(msg)=="table" and msg.version==1 and type(msg.stored)=="number" then packet=msg;lastPacketMs=os.epoch("utc");rxCount=rxCount+1;samples[#samples+1]={t=lastPacketMs,input=msg.input or 0,output=msg.output or 0,net=msg.net or 0};history[#history+1]=msg.net or 0;if #history>120 then table.remove(history,1)end end end end
local function renderer()while true do draw();sleep(.05)end end
parallel.waitForAny(receiver,renderer)
