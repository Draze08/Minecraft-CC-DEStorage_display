-- Draconic Evolution Energy Core foyer display for CC:Tweaked
-- Generic display name, persistent config, legacy-config safe.

local PROTOCOL="destorage.telemetry.v1"
local CONFIG_FILE=".destorage_display.cfg"
local STALE_MS=2000
local AVG_WINDOW_MS=10000
local C=colors

local function findWirelessModem()
 for _,n in ipairs(peripheral.getNames()) do if peripheral.getType(n)=="modem" then local m=peripheral.wrap(n);if m and m.isWireless and m.isWireless() then return n end end end
end
local function findMonitor() return peripheral.find("monitor",function(_,p)return p.isColor and p.isColor() end) end
local function saveConfig(c)local h=fs.open(CONFIG_FILE,"w");h.write(textutils.serialize(c));h.close() end
local function loadConfig()
 if not fs.exists(CONFIG_FILE) then return nil end
 local h=fs.open(CONFIG_FILE,"r");if not h then return nil end
 local raw=h.readAll();h.close();local c=textutils.unserialize(raw)
 if type(c)~="table" then return nil end
 if type(c.displayName)~="string" or c.displayName=="" then if type(c.name)=="string" and c.name~="" then c.displayName=c.name else return nil end end
 c.subtitle=nil;saveConfig(c);return c
end
local function askName(oldName)
 term.setBackgroundColor(C.black);term.setTextColor(C.white);term.clear();term.setCursorPos(1,1)
 print("DE Storage Display - Configuration\n")
 if oldName then print("Current display name: "..oldName);write("New display name [Enter to keep]: ") else write("Display name: ") end
 local n=read();if n=="" then n=oldName or "ENERGY CORE" end;local c={displayName=n};saveConfig(c);return c
end
local args={...};local cfg=loadConfig();if args[1]=="config" then cfg=askName(cfg and cfg.displayName or nil) elseif not cfg then cfg=askName(nil) end
if type(cfg.displayName)~="string" or cfg.displayName=="" then cfg.displayName="ENERGY CORE";saveConfig(cfg) end

local modemName=findWirelessModem();if not modemName then error("No wireless modem found",0) end;if not rednet.isOpen(modemName) then rednet.open(modemName) end
local mon=findMonitor();if not mon then error("No Advanced Monitor found",0) end
mon.setTextScale(.5);local W,H=mon.getSize()
local packet,lastPacketMs;local samples={};local history={};local peakIn,peakOut=0,0;local minNet,maxNet=0,0;local rxCount=0;local startMs=os.epoch("utc")
local flowRange=1;local rangeLastHighMs=startMs;local recentFlow={}

local function clamp(v,a,b)return math.max(a,math.min(b,v))end
local function put(x,y,s,fg,bg)if y<1 or y>H or x>W then return end;mon.setCursorPos(math.max(1,x),y);mon.setTextColor(fg or C.white);mon.setBackgroundColor(bg or C.black);mon.write(string.sub(tostring(s),1,math.max(0,W-x+1)))end
local function center(y,s,fg)s=tostring(s or "");local x=math.floor((W-#s)/2)+1;put(x,y,s,fg)end
local function line(y,x1,x2,ch,fg)put(x1,y,string.rep(ch or "-",math.max(0,x2-x1+1)),fg or C.gray)end
local function box(x1,y1,x2,y2,title)if x2<=x1 or y2<=y1 then return end;line(y1,x1+1,x2-1,"-",C.lightGray);line(y2,x1+1,x2-1,"-",C.lightGray);for y=y1+1,y2-1 do put(x1,y,"|",C.lightGray);put(x2,y,"|",C.lightGray)end;put(x1,y1,"+",C.lightGray);put(x2,y1,"+",C.lightGray);put(x1,y2,"+",C.lightGray);put(x2,y2,"+",C.lightGray);if title then put(x1+2,y1," "..title.." ",C.cyan)end end
local suffix={{15,"P"},{12,"T"},{9,"G"},{6,"M"},{3,"k"}}
local function fmt(v,d)v=tonumber(v) or 0;local sign=v<0 and "-" or "";local n=math.abs(v);for _,s in ipairs(suffix)do local p=10^s[1];if n>=p then return string.format("%s%."..(d or 2).."f%s",sign,n/p,s[2])end end;return string.format("%s%d",sign,math.floor(n+.5))end
local function commas(n)n=tonumber(n) or 0;local s=tostring(math.floor(math.abs(n)+.5));local r=string.reverse(s);r=string.gsub(r,"(%d%d%d)","%1,");r=string.reverse(r);r=string.gsub(r,"^,","");return (n<0 and "-" or "")..r end
local function fmtTime(sec)if not sec or sec<0 or sec==math.huge then return "--" end;local d=math.floor(sec/86400);sec=sec%86400;local h=math.floor(sec/3600);sec=sec%3600;local m=math.floor(sec/60);local s=math.floor(sec%60);if d>0 then return string.format("%dd %02dh %02dm %02ds",d,h,m,s)end;return string.format("%02dh %02dm %02ds",h,m,s)end
local function bar(x,y,w,v,maxv,fill,empty)local f=clamp(math.floor((math.abs(v)/math.max(1,maxv))*w+.5),0,w);put(x,y,string.rep(" ",f),C.white,fill);put(x+f,y,string.rep(" ",w-f),C.white,empty or C.gray)end
local function solidStorage(x,y,w,pct)local f=clamp(math.floor(pct*w+.5),0,w);for yy=y,y+1 do put(x,yy,string.rep(" ",f),C.white,C.lime);put(x+f,yy,string.rep(" ",w-f),C.white,C.gray)end end
local function averages(now)local a,b,c,n=0,0,0,0;local keep={};for _,s in ipairs(samples)do if now-s.t<=AVG_WINDOW_MS then keep[#keep+1]=s;a=a+s.input;b=b+s.output;c=c+s.net;n=n+1 end end;samples=keep;if n==0 then return 0,0,0 end;return a/n,b/n,c/n end
local tiers={{1,4e6},{2,273e6},{3,1.64e9},{4,9.88e9},{5,59.3e9},{6,356e9},{7,2.14e12},{8,9.22e18}}
local function tierFor(cap)local best="?";local err=math.huge;for _,t in ipairs(tiers)do local e=math.abs(cap-t[2])/t[2];if e<err then err=e;best=t[1]end end;return best end
local function niceRange(v)
 v=math.max(1,v*1.25);local p=10^math.floor(math.log(v)/math.log(10));local n=v/p;local m
 if n<=1 then m=1 elseif n<=1.25 then m=1.25 elseif n<=1.5 then m=1.5 elseif n<=2 then m=2 elseif n<=2.5 then m=2.5 elseif n<=3 then m=3 elseif n<=4 then m=4 elseif n<=5 then m=5 elseif n<=7.5 then m=7.5 else m=10 end
 return m*p
end
local function updateFlowRange(now,current)
 local target=niceRange(current)
 if flowRange<=1 then flowRange=target;rangeLastHighMs=now;return end
 if current>flowRange then flowRange=target;rangeLastHighMs=now
 elseif current>flowRange*.60 then rangeLastHighMs=now
 elseif now-rangeLastHighMs>=30000 and target<flowRange then flowRange=target;rangeLastHighMs=now end
end
local function recentPeak(now)
 local keep={};local p=0;for _,s in ipairs(recentFlow)do if now-s.t<=30000 then keep[#keep+1]=s;p=math.max(p,s.v)end end;recentFlow=keep;return p
end
local function waiting(msg)mon.setBackgroundColor(C.black);mon.clear();center(math.floor(H/2)-2,string.upper(cfg.displayName),C.magenta);center(math.floor(H/2),"DRACONIC ENERGY CORE",C.cyan);center(math.floor(H/2)+3,msg,C.red)end

local function draw()
 local now=os.epoch("utc");if not packet then waiting("AWAITING CORE TELEMETRY")return end;if now-lastPacketMs>STALE_MS then waiting("!! TELEMETRY LINK LOST !!")return end
 local stored=tonumber(packet.stored) or 0;local cap=tonumber(packet.capacity) or 0;local input=tonumber(packet.input) or 0;local output=tonumber(packet.output) or 0;local net=tonumber(packet.net) or (input-output);local pct=cap>0 and stored/cap or 0;peakIn=math.max(peakIn,input);peakOut=math.max(peakOut,output);minNet=math.min(minNet,net);maxNet=math.max(maxNet,net)
 local currentMax=math.max(input,output,math.abs(net));updateFlowRange(now,currentMax);local peak30=recentPeak(now);local ai,ao,an=averages(now);local state="STANDBY";local sc=C.lightGray;if net>0 then state="CHARGING";sc=C.lime elseif net<0 then state="DISCHARGING";sc=C.orange end
 local etaFull=an>0 and ((cap-stored)/an)/20 or nil;local etaEmpty=an<0 and (stored/math.abs(an))/20 or nil;local uptime=(now-startMs)/1000;local tier=tierFor(cap);local utilization=flowRange>0 and currentMax/flowRange or 0;local ioRatio=input>0 and output/input or 0;local reserve=math.max(0,cap-stored);local headroom=flowRange>0 and math.max(0,(flowRange-currentMax)/flowRange) or 0
 mon.setBackgroundColor(C.black);mon.clear()
 center(1,string.upper(cfg.displayName),C.magenta);center(2,"TIER "..tier.." DRACONIC ENERGY CORE",C.lightGray);center(3,"<<<  SYSTEM "..state.."  >>>",sc);line(4,1,W,"=",C.lightGray)
 local a=math.floor(W*.22);local b=math.floor(W*.73)
 box(1,5,a,17,"CORE STATUS");box(a+1,5,b,17,"ENERGY STORAGE");box(b+1,5,W,17,"CORE INFORMATION")
 put(3,7,"STATUS",C.lightGray);put(15,7,"ONLINE",C.lime);put(3,9,"LINK",C.lightGray);put(15,9,"ONLINE",C.lime);put(3,11,"STATE",C.lightGray);put(15,11,state,sc);put(3,13,"TELEMETRY",C.lightGray);put(15,13,"10 Hz",C.cyan);put(3,15,"PACKETS",C.lightGray);put(15,15,commas(rxCount),C.white)
 put(a+4,7,"STORED",C.lightGray);put(a+18,7,fmt(stored,4).." OP",C.yellow);put(b-30,7,"CAPACITY",C.lightGray);put(b-18,7,fmt(cap,4).." OP",C.yellow);local sw=b-a-10;solidStorage(a+4,9,sw,pct);put(b-15,12,string.format("%9.5f%%",pct*100),C.white);line(14,a+4,b-4,"-",C.gray);put(a+4,15,"0%",C.gray);put(math.floor((a+b)/2)-2,15,"50%",C.gray);put(b-8,15,"100%",C.gray)
 put(b+3,7,"CORE TIER",C.lightGray);put(b+20,7,tostring(tier),C.white);put(b+3,9,"CORE TYPE",C.lightGray);put(b+20,9,"ENERGY CORE",C.white);put(b+3,11,"CAPACITY RAW",C.lightGray);put(b+20,11,fmt(cap,2).." OP",C.yellow);put(b+3,13,"RESERVE",C.lightGray);put(b+20,13,fmt(reserve,2).." OP",C.cyan);put(b+3,15,"SOURCE ID",C.lightGray);put(b+20,15,tostring(packet.sender or "--"),C.white)
 local r2t=18;local r2b=31;local flowR=math.floor(W*.70);box(1,r2t,flowR,r2b,"POWER FLOW (OP/t)");box(flowR+1,r2t,W,r2b,"POWER FLOW STATUS");local gx=30;local gw=math.max(15,flowR-gx-12);local rows={{"INPUT","+",input,C.lime},{"OUTPUT","-",output,C.orange},{"NET",net>=0 and "+" or "-",math.abs(net),C.lightBlue}};for i,r in ipairs(rows)do local y=r2t+2+i*3;put(3,y,string.format("%-7s %s%10s",r[1],r[2],fmt(r[3],2)),r[4]);bar(gx,y,gw,r[3],flowRange,r[4],C.gray)end
 put(gx,r2b-1,"0",C.gray);local mid=fmt(flowRange/2,2);put(gx+math.floor(gw/2)-math.floor(#mid/2),r2b-1,mid,C.gray);local mx=fmt(flowRange,2);put(gx+gw-#mx,r2b-1,mx,C.gray)
 put(flowR+4,r2t+3,"<<< "..state.." >>>",sc);put(flowR+4,r2t+6,"TO CORE",C.lightGray);put(flowR+20,r2t+6,"+"..fmt(input,2),C.lime);put(flowR+4,r2t+8,"TO NETWORK",C.lightGray);put(flowR+20,r2t+8,"-"..fmt(output,2),C.orange);put(flowR+4,r2t+10,"NET",C.lightGray);put(flowR+20,r2t+10,(net>=0 and "+" or "")..fmt(net,2),C.lightBlue)
 local r3t=32;local r3b=H-2;local c1=math.floor(W*.34);local c2=math.floor(W*.65);box(1,r3t,c1,r3b,"ENERGY STATISTICS (10s AVG)");box(c1+1,r3t,c2,r3b,"TIME / RESERVE ESTIMATE");box(c2+1,r3t,W,r3b,"SYSTEM DIAGNOSTICS")
 put(3,r3t+2,"AVG INPUT",C.lightGray);put(20,r3t+2,"+"..fmt(ai,2).." OP/t",C.lime);put(3,r3t+4,"AVG OUTPUT",C.lightGray);put(20,r3t+4,"-"..fmt(ao,2).." OP/t",C.orange);put(3,r3t+6,"AVG NET",C.lightGray);put(20,r3t+6,(an>=0 and "+" or "")..fmt(an,2).." OP/t",C.lightBlue);put(3,r3t+9,"PEAK INPUT",C.lightGray);put(20,r3t+9,fmt(peakIn,2),C.lime);put(3,r3t+11,"PEAK OUTPUT",C.lightGray);put(20,r3t+11,fmt(peakOut,2),C.orange);put(3,r3t+13,"NET RANGE",C.lightGray);put(20,r3t+13,fmt(minNet,1).." / +"..fmt(maxNet,1),C.cyan)
 local eta=an>0 and etaFull or etaEmpty;put(c1+4,r3t+2,an>=0 and "ESTIMATED TIME TO FULL" or "ESTIMATED TIME TO EMPTY",C.lightGray);put(c1+4,r3t+4,fmtTime(eta),C.magenta);put(c1+4,r3t+7,"ENERGY REMAINING",C.lightGray);put(c1+4,r3t+8,fmt(reserve,4).." OP",C.yellow);put(c1+4,r3t+11,"DISPLAY UPTIME",C.lightGray);put(c1+4,r3t+12,fmtTime(uptime),C.cyan);put(c1+4,r3t+15,"CORE FILL RATE",C.lightGray);put(c1+4,r3t+16,string.format("%.8f %%/s",cap>0 and an*20/cap*100 or 0),sc)
 put(c2+3,r3t+2,"FLOW RANGE",C.lightGray);put(c2+22,r3t+2,fmt(flowRange,2).." OP/t",C.cyan);put(c2+3,r3t+4,"30s PEAK",C.lightGray);put(c2+22,r3t+4,fmt(peak30,2).." OP/t",C.yellow);put(c2+3,r3t+6,"HEADROOM",C.lightGray);put(c2+22,r3t+6,string.format("%6.2f%%",headroom*100),C.lime);put(c2+3,r3t+8,"OUTPUT / INPUT",C.lightGray);put(c2+22,r3t+8,string.format("%6.2f%%",ioRatio*100),C.orange);put(c2+3,r3t+10,"PACKET AGE",C.lightGray);put(c2+22,r3t+10,tostring(now-lastPacketMs).." ms",C.lime);put(c2+3,r3t+12,"SAMPLE WINDOW",C.lightGray);put(c2+22,r3t+12,tostring(#samples),C.white);put(c2+3,r3t+15,"CORE CONDITION",C.lightGray);put(c2+22,r3t+15,"NOMINAL",C.lime)
 line(H,1,W,"=",C.lightGray);put(2,H,"LIVE TELEMETRY // RF 10 Hz // DISPLAY 20 Hz",C.gray);local clock=textutils.formatTime(os.time(),true);put(math.floor(W/2)-math.floor(#clock/2),H,clock,C.yellow);local age=tostring(now-lastPacketMs).."ms";put(math.max(2,W-#age-6),H,"LINK "..age,C.lime)
end

local function receiver()while true do local _,msg=rednet.receive(PROTOCOL);if type(msg)=="table" and msg.version==1 and type(msg.stored)=="number" then packet=msg;lastPacketMs=os.epoch("utc");rxCount=rxCount+1;local i=tonumber(msg.input) or 0;local o=tonumber(msg.output) or 0;local n=tonumber(msg.net) or (i-o);samples[#samples+1]={t=lastPacketMs,input=i,output=o,net=n};history[#history+1]=n;if #history>120 then table.remove(history,1)end;recentFlow[#recentFlow+1]={t=lastPacketMs,v=math.max(i,o,math.abs(n))} end end end
local function renderer()while true do draw();sleep(.05)end end
parallel.waitForAny(receiver,renderer)
