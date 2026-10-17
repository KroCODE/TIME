-- Project Triune Plane of Time route; run with /lua run time.
-- The ImGui Start button begins the selected route.
local mq = require('mq')
local ImGui = require('ImGui')
-- Configuration and saved per-character preferences.
local VERSION = '1.0'
local hub4={1.57,-199.10,348.75}
local hub5={-1.11,-195.95,3.75}
local starts={'Full run from Bazaar','Plane of Time zone-in (before DZ)','Inside DZ - Before Herald','Auto-detect Phase 1 / 2 location','Phase 3 - ledge jump','Phase 3 - lower waves','Phase 4 zone up','Phase 4 - already inside (past switches)','Phase 5 zone up','Phase 5 - already inside (past switches)','Rallos Zek - start at encounter'}
local name=tostring(mq.TLO.Me.CleanName() or mq.TLO.Me.Name() or 'Unknown'):gsub('[^%w_%-]','_')
local configPath=(mq.configDir or '.')..'/time_'..name..'.lua'
local cfg={start=1,stopBeforeP4=false,stopBeforeP5=false,stopRZ=true,burnRZ=false,killQuarm=false,holdRadius=10,
  instanceShort='potimeb', noAggro=30, completedStep=0,
  compact=false,fullX=150,fullY=120,fullW=520,fullH=680,compactX=150,compactY=120,compactW=360,compactH=125}
local function save()
  local f=io.open(configPath,'w'); if not f then return end
  f:write('return {\n')
  for k,v in pairs(cfg) do f:write(string.format(' [%q]=%s,\n',k,type(v)=='string' and string.format('%q',v) or tostring(v))) end
  f:write('}\n'); f:close()
end
local ok,loaded=pcall(dofile,configPath)
if ok and type(loaded)=='table' then for k,v in pairs(cfg) do if type(loaded[k])==type(v) then cfg[k]=loaded[k] end end end
cfg.noAggro=30
cfg.start=1
-- Runtime status and event logging.
local S={phase='Ready',detail='',running=false,request=false,stop=false,paused=false,complete=false,log={},stage='',checkpoint=0,aggroSince=nil,holdSeconds=0,layout=nil,geometryAt=0}
local function log(s)
  local t=os.date('%H:%M:%S')..' '..s
  S.log[#S.log+1]=t; if #S.log>110 then table.remove(S.log,1) end
  print('[Time] '..s)
end
local function val(fn,default) local good,v=pcall(fn); if good and v~=nil then return v end; return default end
local function cmd(s) mq.cmd(s) end
local function zone() return tostring(val(function() return mq.TLO.Zone.ShortName() end,'unknown')):lower() end
local function pos() return tonumber(val(function() return mq.TLO.Me.Y() end,0)) or 0,tonumber(val(function() return mq.TLO.Me.X() end,0)) or 0,tonumber(val(function() return mq.TLO.Me.Z() end,0)) or 0 end
local function dist(p) local y,x,z=pos(); return math.sqrt((y-p[1])^2+(x-p[2])^2+(z-p[3])^2) end
local function hp() return tonumber(val(function() return mq.TLO.Me.PctHPs() end,100)) or 100 end
local function isDead() return val(function() return mq.TLO.Me.Dead() end,false)==true or hp()<=0 end
-- Detect active combat and manage movement, switches, and TAC.
local function targets()
  local count=tonumber(val(function() return mq.TLO.Me.XTarget() end,0)) or 0
  local n=0
  for i=1,math.min(40,count) do
    local x=val(function() return mq.TLO.Me.XTarget(i) end,nil)
    if x and (tonumber(val(function() return x.ID() end,0)) or 0)>0 then
      local t=tostring(val(function() return x.Type() end,''))
      if t=='NPC' or t=='Auto Hater' then n=n+1 end
    end
  end
  return n
end
-- Live hostile XTargets are checked independently of the current target.
-- TAC can temporarily target the player to cast a buff while mobs remain alive.
local function liveHostileXTarget()
  local count=tonumber(val(function() return mq.TLO.Me.XTarget() end,0)) or 0
  for i=1,math.min(40,count) do
    local xt=val(function() return mq.TLO.Me.XTarget(i) end,nil)
    local id=xt and (tonumber(val(function() return xt.ID() end,0)) or 0) or 0
    if id>0 then
      local xtType=tostring(val(function() return xt.Type() end,'')):lower()
      if xtType=='npc' or xtType=='auto hater' then
        local sp=val(function() return mq.TLO.Spawn('id '..id) end,nil)
        local actualID=sp and (tonumber(val(function() return sp.ID() end,0)) or 0) or 0
        if actualID==id then
          local typ=tostring(val(function() return sp.Type() end,'')):lower()
          local pct=tonumber(val(function() return sp.PctHPs() end,0)) or 0
          local distance=tonumber(val(function() return sp.Distance() end,9999)) or 9999
          if typ=='npc' and pct>0 and distance<=180 then return id end
        end
      end
    end
  end
  return nil
end
local lastHP,damageTime=nil,-1e5
local function aggro()
  local h=hp(); if lastHP and h<lastHP then damageTime=os.time() end; lastHP=h
  return val(function() return mq.TLO.Me.Combat() end,false)==true
      or os.time()-damageTime<3
      or liveHostileXTarget()~=nil
end
-- During boss/add fights, always prioritize a living hostile XTarget #2.
-- Outside those fights, restore an enemy target only if TAC leaves a friendly target selected.
local lastTargetRecovery=0
local lastPriorityLogID=0
local lastSlot2SeenID=0
local function hostileSlotID(slot,maxDistance)
  local xt=val(function() return mq.TLO.Me.XTarget(slot) end,nil)
  local id=xt and (tonumber(val(function() return xt.ID() end,0)) or 0) or 0
  if id<=0 then return 0 end
  local kind=tostring(val(function() return xt.Type() end,'')):lower()
  if kind~='' and kind~='npc' and kind~='auto hater' then return 0 end
  local sp=val(function() return mq.TLO.Spawn('id '..id) end,nil)
  if sp and (tonumber(val(function() return sp.ID() end,0)) or 0)==id then
    local spawnType=tostring(val(function() return sp.Type() end,'')):lower()
    if spawnType~='' and spawnType~='npc' and spawnType~='auto hater' then return 0 end
    local distance=tonumber(val(function() return sp.Distance() end,nil))
    if distance and distance>(maxDistance or 250) then return 0 end
  end
  -- The XTarget ID is the authoritative slot occupant. Some Project Triune
  -- clients briefly report 0 HP or cannot resolve Spawn(id) while the add
  -- is still alive; those values must not suppress slot #2 targeting.
  return id
end

local lastTargetFailureID=0
local lastTargetFailureTime=0
local function recoverFriendlyTarget()
  if not S.tacCombatActive then return end
  -- During Quarm, never select an XTarget add or friendly target.
  if S.quarmLock then
    local locked=S.quarmID or 0
    if locked<=0 then return end
    local current=tonumber(val(function() return mq.TLO.Target.ID() end,0)) or 0
    if current~=locked then
      cmd('/target id '..locked)
      mq.delay(75)
      if (tonumber(val(function() return mq.TLO.Target.ID() end,0)) or 0)==locked then cmd('/attack on') end
    end
    return
  end
  local current=tonumber(val(function() return mq.TLO.Target.ID() end,0)) or 0
  local desired=0
  local slot2=0
  if S.addPriorityCombat then
    slot2=hostileSlotID(2,250)
    desired=slot2>0 and slot2 or hostileSlotID(1,250)
  else
    local meID=tonumber(val(function() return mq.TLO.Me.ID() end,0)) or 0
    local kind=tostring(val(function() return mq.TLO.Target.Type() end,'')):lower()
    if current~=0 and current~=meID and (kind=='npc' or kind=='auto hater') then return end
    desired=hostileSlotID(2,250)
    if desired==0 then desired=liveHostileXTarget() or 0 end
  end
  if S.addPriorityCombat and slot2~=lastSlot2SeenID then
    log('Boss targeting: XTarget #2 ID '..slot2..(slot2>0 and ' - add priority' or ' - slot clear'))
    lastSlot2SeenID=slot2
  end
  if desired<=0 or desired==current then return end
  if not S.addPriorityCombat and os.clock()-lastTargetRecovery<0.20 then return end
  lastTargetRecovery=os.clock()
  cmd('/target id '..desired)
  mq.delay(75)
  local confirmed=(tonumber(val(function() return mq.TLO.Target.ID() end,0)) or 0)==desired
  if confirmed then
    cmd('/attack on')
    if S.addPriorityCombat and desired~=lastPriorityLogID then
      log('Combat priority target: '..(slot2==desired and 'XTarget #2 (add)' or 'XTarget #1 (boss)')..' ID '..desired)
      lastPriorityLogID=desired
    end
  elseif S.addPriorityCombat and (desired~=lastTargetFailureID or os.clock()-lastTargetFailureTime>5) then
    log('Target request failed: XTarget '..(slot2==desired and '#2' or '#1')..' ID '..desired)
    lastTargetFailureID=desired; lastTargetFailureTime=os.clock()
  end
end

local function motionStop() cmd('/nav stop'); cmd('/moveto off') end
local function tacOn() S.tacCombatActive=true; cmd('/ac manual'); cmd('/ac burn off'); cmd('/ac run') end
local function tacPause() S.tacCombatActive=false; cmd('/ac pause') end
local function controls()
  mq.doevents()
  if S.stop then error('STOP REQUESTED') end
  while S.paused do motionStop(); tacPause(); mq.delay(150); mq.doevents(); if S.stop then error('STOP REQUESTED') end end
  if isDead() then error('CHARACTER DIED: manual recovery required') end
  recoverFriendlyTarget()
end
local function await(fn,sec,label)
  local t=os.time()+sec
  while os.time()<t do controls(); if fn() then return true end; mq.delay(150) end
  if label then log('Timeout: '..label) end
  return false
end
local function gotoPoint(p,label,radius,timeout,keepTAC)
  radius=radius or 16; timeout=timeout or 180
  S.phase=label; S.detail=string.format('Y %.1f X %.1f Z %.1f',p[1],p[2],p[3])
  if dist(p)<=radius then return end
  for attempt=1,3 do
    controls(); cmd(string.format('/nav locyxz %.2f %.2f %.2f',p[1],p[2],p[3]))
    local last=dist(p); local progress=os.time(); local endAt=os.time()+timeout
    while os.time()<endAt do
      controls()
      if dist(p)<=radius then motionStop(); return end
      if keepTAC and aggro() then
        motionStop(); tacOn(); S.phase='Combat interrupts '..label
        if not await(function() return not aggro() end,240,'combat interruption') then error('Combat did not clear during travel') end
        cmd(string.format('/nav locyxz %.2f %.2f %.2f',p[1],p[2],p[3]))
      end
      local d=dist(p)
      if d<last-2 then last=d; progress=os.time() end
      if os.time()-progress>18 then break end
      mq.delay(200)
    end
    motionStop(); log(label..' retry '..attempt..'/3, distance '..string.format('%.1f',dist(p)))
  end
  error('Could not reach '..label..' (navmesh/path check required)')
end
local function door(id,location,label)
  if location then gotoPoint(location,label..' switch',15,160,true) end
  controls(); S.phase='Switch '..id..' - '..label
  cmd('/doortarget id '..id); mq.delay(350)
  local actual=tonumber(val(function() return mq.TLO.DoorTarget.ID() end,0)) or 0
  if actual~=id then log('WARNING: door target ID not confirmed for switch '..id..' (observed '..actual..')') end
  cmd('/face fast door'); mq.delay(200); cmd('/click left door'); mq.delay(500)
  log('Used switch '..id..' ('..label..')')
end
local function through(id,at,destination,label,keep)
  door(id,at,label)
  gotoPoint(destination,label..' far side',20,210,keep)
end
-- Combat completion: count 30 quiet seconds from arrival, resetting on new aggro.
local function waitNoAggro(label,needCombat,hold)
  S.phase=label; S.detail='Waiting for waves / aggro clear'
  local clearAt=nil; local deadline=os.time()+900
  while os.time()<deadline do
    controls()
    if aggro() then clearAt=nil; S.holdSeconds=0; S.detail='Hostile/active combat; waiting for waves to clear'
    else
      if not clearAt then clearAt=os.time() end
      S.holdSeconds=os.time()-clearAt
      if S.holdSeconds>=cfg.noAggro then log(label..': '..cfg.noAggro..' seconds clear'); return end
      if hold and dist(hold)>cfg.holdRadius then
        gotoPoint(hold,'Return to Phase 3 holding point',cfg.holdRadius,100,true)
      end
    end
    mq.delay(200)
  end
  error('Timed out waiting for combat / no-aggro: '..label)
end
local function namedDefeat(mob,label,timeout)
  timeout=timeout or 780; S.phase=label or ('Defeat '..mob)
  local saw=false; local missingAt=nil; local deadline=os.time()+timeout
  while os.time()<deadline do
    controls()
    local sp=val(function() return mq.TLO.Spawn('npc ="'..mob..'"') end,nil)
    local id=sp and tonumber(val(function() return sp.ID() end,0)) or 0
    if id>0 then saw=true; missingAt=nil
    elseif saw and not aggro() then
      if not missingAt then missingAt=os.time() end
      if os.time()-missingAt>=3 then log('Named no longer present, combat clear: '..mob); return end
    end
    mq.delay(200)
  end
  error('Named defeat not confirmed: '..mob..' (must have been observed alive)')
end
local function namedDefeatOrClear(mob,label,timeout)
  timeout=timeout or 780
  S.phase=label or ('Defeat '..mob)
  local saw=false
  local clearAt=nil
  local deadline=os.time()+timeout
  while os.time()<deadline do
    controls()
    local sp=val(function() return mq.TLO.Spawn('npc ="'..mob..'"') end,nil)
    local id=sp and (tonumber(val(function() return sp.ID() end,0)) or 0) or 0
    local living=false
    if id>0 then
      local typeName=tostring(val(function() return sp.Type() end,'')):lower()
      local health=tonumber(val(function() return sp.PctHPs() end,0)) or 0
      living=(typeName=='npc' and health>0)
    end
    if living then saw=true; clearAt=nil; S.holdSeconds=0
    elseif aggro() then clearAt=nil; S.holdSeconds=0
    else
      if not clearAt then clearAt=os.time() end
      S.holdSeconds=os.time()-clearAt
      local required=saw and 3 or cfg.noAggro
      S.detail=string.format('%s: clear %d/%d sec%s',mob,S.holdSeconds,required,
        saw and ' (boss observed)' or ' (resume verification)')
      if S.holdSeconds>=required then
        log(mob..': boss absent, no active aggro; proceeding to hub')
        return
      end
    end
    mq.delay(200)
  end
  error('Timed out checking '..mob..' completion')
end

local function fightWaves(where,boss,hold)
  if where then gotoPoint(where,'Travel to '..boss,18,200,true) end
  tacOn(); log('Combat: '..boss)
  waitNoAggro(boss..' + waves',true,hold)
end
-- Boss encounters: prioritize adds, then return to the primary target.
local function livingNPC(id)
  if not id or id<=0 then return nil end
  local sp=val(function() return mq.TLO.Spawn('id '..id) end,nil)
  if not sp or (tonumber(val(function() return sp.ID() end,0)) or 0)~=id then return nil end
  local kind=tostring(val(function() return sp.Type() end,'')):lower()
  local h=tonumber(val(function() return sp.PctHPs() end,0)) or 0
  if kind~='npc' or h<=0 then return nil end
  return sp
end
local function encounterTargets(bossName, sameNameAdds, mainID)
  local bossID=0
  if sameNameAdds then
    if livingNPC(mainID) then bossID=mainID end
  else
    local boss=val(function() return mq.TLO.Spawn('npc ="'..bossName..'"') end,nil)
    local id=boss and tonumber(val(function() return boss.ID() end,0)) or 0
    if livingNPC(id) then bossID=id end
  end
  local count=tonumber(val(function() return mq.TLO.Me.XTarget() end,0)) or 0
  local addID,addDistance=nil,math.huge
  local candidates={}
  for i=1,math.min(count,40) do
    local xt=val(function() return mq.TLO.Me.XTarget(i) end,nil)
    local id=xt and tonumber(val(function() return xt.ID() end,0)) or 0
    local sp=livingNPC(id)
    if sp then
      local d=tonumber(val(function() return sp.Distance() end,9999)) or 9999
      local mobName=tostring(val(function() return sp.CleanName() end,''))
      if d<=140 and (not sameNameAdds or mobName:lower()==bossName:lower()) then
        if sameNameAdds then candidates[#candidates+1]={id=id,d=d} end
        if id~=bossID and d<addDistance then addID,addDistance=id,d end
      end
    end
  end
  return addID,bossID,candidates
end

local function initialVallonMain()
  local tgt=val(function() return mq.TLO.Target end,nil)
  local id=tgt and tonumber(val(function() return tgt.ID() end,0)) or 0
  local sp=livingNPC(id)
  if sp and tostring(val(function() return sp.CleanName() end,'')):lower()=='vallon zek' then
    return id
  end
  local near=val(function() return mq.TLO.Spawn('npc ="Vallon Zek"') end,nil)
  local nearID=near and tonumber(val(function() return near.ID() end,0)) or 0
  if livingNPC(nearID) then return nearID end
  return 0
end

-- Select the actual occupant of XTarget #2 first, then #1.
local function priorityXTargets()
  local second=hostileSlotID(2,250)
  local first=hostileSlotID(1,250)
  return second>0 and second or first,second>0
end

local function fightBossAdds(where,bossName,sameNameAdds,enableBurn)
  gotoPoint(where,'Travel to '..bossName,18,220,true)
  tacOn()
  S.addPriorityCombat=true
  lastPriorityLogID=0
  lastSlot2SeenID=0
  if enableBurn then cmd('/ac burn on'); log('TAC Burn enabled for '..bossName) end
  S.phase=bossName..' and adds'
  log(bossName..': prioritize living XTarget #2, then XTarget #1')
  local clearAt=nil
  local mainID=sameNameAdds and initialVallonMain() or 0
  if sameNameAdds then log('Vallon primary target ID: '..mainID..' (other live Vallons prioritized)') end
  local deadline=os.time()+900
  while os.time()<deadline do
    controls()
    if sameNameAdds and mainID==0 then
      mainID=initialVallonMain()
      if mainID>0 then log('Vallon primary identified: '..mainID) end
    end
    local addID,bossID,candidates=encounterTargets(bossName,sameNameAdds,mainID)
    if sameNameAdds and mainID>0 then
      addID=nil
      local best=math.huge
      for _,c in ipairs(candidates) do
        if c.id~=mainID and c.d<best then addID,best=c.id,c.d end
      end
    end
    -- Prefer XTarget #2 over #1; retain NPC-scan fallback when neither is usable.
    local slotTarget,slotIsAdd=priorityXTargets()
    local busy=aggro()
    local wanted=slotTarget>0 and slotTarget or (addID or (bossID>0 and bossID or nil))
    local targetingAdd=slotTarget>0 and slotIsAdd or (addID~=nil and wanted==addID)
    if busy or wanted or bossID>0 then clearAt=nil; S.holdSeconds=0 end
    local current=tonumber(val(function() return mq.TLO.Target.ID() end,0)) or 0
    -- Enforce slot priority every tick, including while the boss is selected.
    -- controls() also enforces this when other routines are waiting.
    if wanted and wanted>0 and current~=wanted then
      recoverFriendlyTarget()
      -- Fallback NPC targeting applies only if neither slot has a living hostile.
      if slotTarget==0 and (tonumber(val(function() return mq.TLO.Target.ID() end,0)) or 0)~=wanted then
        cmd('/target id '..wanted)
        mq.delay(75)
        if (tonumber(val(function() return mq.TLO.Target.ID() end,0)) or 0)==wanted then cmd('/attack on') end
      end
    end
    if not busy and not wanted and bossID==0 then
      if not clearAt then clearAt=os.time() end
      S.holdSeconds=os.time()-clearAt
      S.detail=string.format('%s clear: %d/%d seconds',bossName,S.holdSeconds,cfg.noAggro)
      if S.holdSeconds>=cfg.noAggro then
        cmd('/attack off')
        S.addPriorityCombat=false
        if enableBurn then cmd('/ac burn off') end
        log(bossName..' encounter clear')
        return
      end
    else
      if busy or wanted or bossID>0 then clearAt=nil; S.holdSeconds=0 end
      S.detail=targetingAdd and ('Fighting XTarget #2: '..bossName) or (wanted and ('Fighting '..bossName) or 'Waiting for encounter')
    end
    mq.delay(100)
  end
  S.addPriorityCombat=false
  if enableBurn then cmd('/ac burn off') end
  error(bossName..' encounter timed out: mobs or aggro still present')
end

-- Bazaar travel, Attune Map, expedition switch, and Herald dialogue.
local function bazaar()
  if zone()=='bazaar' then return end
  S.phase='Travel to Bazaar (AA 331)'
  if not await(function() return val(function() return mq.TLO.Me.AltAbilityReady(331)() end,false) end,180,'Bazaar AA readiness') then error('Bazaar AA 331 unavailable') end
  cmd('/alt activate 331')
  if not await(function() return zone()=='bazaar' or zone()=='ecommons' end,80,'Bazaar port') then error('Bazaar port not verified') end
  if zone()=='ecommons' then error('AA landed in EC tunnel. Manually reach Bazaar and restart (do not assume Bazaar).') end
end
local function mapPort()
  gotoPoint({-646.5,2.9,4.8},'Attune the Map',18,180)
  door(146,nil,'Attune the Map')
  if not await(function() return val(function() return mq.TLO.Window('WaypointsWnd').Open() end,false) end,10,'Waypoints window') then error('Attune window not open') end
  local cat=tonumber(val(function() return mq.TLO.Window('WaypointsWnd').Child('ContinentsList').List('=The Planes')() end,0)) or 0
  if cat<1 then error('Cannot locate The Planes category on Attune the Map') end
  cmd('/notify WaypointsWnd ContinentsList listselect '..cat); mq.delay(350)
  local row=tonumber(val(function() return mq.TLO.Window('WaypointsWnd').Child('WaypointsList').List('=The Plane of Time')() end,0)) or 0
  if row<1 then error('Cannot locate The Plane of Time waypoint') end
  cmd('/notify WaypointsWnd WaypointsList listselect '..row); mq.delay(250)
  cmd('/notify WaypointsWnd SelectedWaypointButton leftmouseup')
  mq.delay(500)
  if val(function() return mq.TLO.Window('ConfirmationDialogBox').Open() end,false) then cmd('/notify ConfirmationDialogBox Yes_Button leftmouseup') end
  if val(function() return mq.TLO.Window('LargeDialogWindow').Open() end,false) then cmd('/notify LargeDialogWindow LDW_YesButton leftmouseup') end
  if not await(function() return zone()~='bazaar' end,90,'Plane of Time waypoint port') then error('Attune map port did not change zones') end
end
local function closeExpedition()
  for _,w in ipairs({'DynamicZoneWnd','ExpeditionInfoWnd'}) do
    if val(function() return mq.TLO.Window(w).Open() end,false) then cmd('/windowstate '..w..' close') end
  end
end
-- Expedition entry: get into confirmed interaction range for both uses of Switch 12.
local expeditionSwitchPoint={1667.44,707.17,19.24}
local function switch12Distance()
  return tonumber(val(function() return mq.TLO.DoorTarget.Distance() end,nil))
end
local function targetSwitch12()
  cmd('/doortarget id 12')
  mq.delay(350)
  local found=tonumber(val(function() return mq.TLO.DoorTarget.ID() end,0)) or 0
  if found~=12 then error('Switch 12 (TRANQSUND500) could not be targeted') end
end
local function approachExpeditionSwitch(label)
  S.phase=label
  motionStop()
  -- This coordinate gets us near the switch; the remaining distance is measured
  -- against the switch itself, not the recorded navigation point.
  if dist(expeditionSwitchPoint)>14 then
    gotoPoint(expeditionSwitchPoint,label..' approach',12,250)
  end
  targetSwitch12()
  local distance=switch12Distance()
  if not distance then
    error('Switch 12 distance unavailable: cannot confirm safe interaction range')
  end
  log(string.format('%s: initial Switch 12 distance %.1f',label,distance))
  if distance>5 then
    -- Continue moving toward the targeted switch until we are genuinely within
    -- click range. Release Forward even if an error or Stop interrupts the loop.
    cmd('/face fast door')
    cmd('/keypress forward hold')
    local success,err=pcall(function()
      local deadline=os.time()+14
      local last=distance
      local stalledAt=os.time()
      while os.time()<deadline do
        controls()
        mq.delay(100)
        distance=switch12Distance()
        if not distance then error('Lost distance measurement for Switch 12') end
        if distance<=5 then return end
        if distance<last-0.3 then last=distance; stalledAt=os.time() end
        if os.time()-stalledAt>=4 then
          error(string.format('Unable to move closer to Switch 12 (distance %.1f)',distance))
        end
        -- Reface in case movement was interrupted or slightly off-axis.
        if os.time()%2==0 then cmd('/face fast door') end
      end
      error(string.format('Timed out approaching Switch 12 (distance %.1f)',distance))
    end)
    cmd('/keypress forward')
    motionStop()
    if not success then error(err) end
  end
  -- Ensure the door is still selected and that stopping has not left us outside range.
  targetSwitch12()
  distance=switch12Distance()
  if not distance or distance>6 then
    error('Switch 12 is not within confirmed click range: '..tostring(distance))
  end
  cmd('/face fast door')
  mq.delay(250)
  log(string.format('%s: ready to click Switch 12 at distance %.1f',label,distance))
end
local function clickExpeditionSwitch(label)
  -- Avoid the generic door helper here: it only logs a click, not interaction range.
  approachExpeditionSwitch(label)
  motionStop()
  cmd('/click left door')
  mq.delay(650)
  log(label..': Switch 12 clicked')
end
-- Plane of Time DZ: the first Switch 12 click requests an expedition (or enters
-- an already active one). The second click is made from the recorded portal-side
-- location after a fixed settling delay. Do not depend on Me.DZ() availability.
local expeditionEntryPoint={1680.52,708.24,21.49}
local function enterExpeditionClick(attempt)
  S.phase='Enter expedition - move to Switch 12'
  -- Use the in-game confirmed click location, not the expedition-request point.
  gotoPoint(expeditionEntryPoint,'Switch 12 DZ entry position',5,150)
  motionStop()
  targetSwitch12()
  cmd('/face fast door')
  mq.delay(350)
  controls()
  cmd('/click left door')
  log(string.format('DZ entry attempt %d: clicked Switch 12 from Y %.1f X %.1f Z %.1f',
      attempt,select(1,pos()),select(2,pos()),select(3,pos())))
end
local function expedition()
  local priorZone=zone()
  local py,px,pz=pos()
  local function transitioned()
    local y,x,z=pos()
    return zone()~=priorZone or math.sqrt((y-py)^2+(x-px)^2+(z-pz)^2)>120
  end

  -- First use. If the DZ already exists this may enter directly.
  clickExpeditionSwitch('Request / enter Plane of Time expedition')
  if await(transitioned,5) then
    log('DZ entered on first Switch 12 interaction')
    closeExpedition()
    return
  end

  -- The expedition window can show an active DZ while Me.DZ() returns false.
  -- Never block the second click on that TLO. Wait exactly as requested.
  S.phase='Waiting 10 seconds before second Switch 12 click'
  log('Waiting 10 seconds before moving to DZ entry location')
  local readyAt=os.time()+10
  while os.time()<readyAt do controls(); mq.delay(100) end

  for attempt=1,3 do
    enterExpeditionClick(attempt)
    if await(transitioned,20,'DZ teleport after Switch 12 click') then
      log('Expedition entry confirmed by zone or position change')
      closeExpedition()
      return
    end
    log('DZ entry click did not teleport; retry '..attempt..'/3')
    if attempt<3 then
      local retryAt=os.time()+5
      while os.time()<retryAt do controls(); mq.delay(100) end
    end
  end
  error('Could not enter Time DZ after three Switch 12 entry clicks from recorded location')
end
local function herald()
  gotoPoint({-22.56,865.96,397.37},'Herald of Druzzil Ro',18,200)
  cmd('/target "Herald of Druzzil Ro"'); mq.delay(400)
  local target=tostring(val(function() return mq.TLO.Target.CleanName() end,''))
  if not target:lower():find('herald of druzzil ro',1,true) then error('Cannot target Herald of Druzzil Ro') end
  cmd('/keypress h'); mq.delay(550); cmd('/say teleport'); mq.delay(550)
  cmd('/say Air Trial')
  log('Requested Air Trial via Herald (fixed route: Air -> Earth -> Fire -> Water -> Undead)')
  if not await(function() return dist({1352,-36,495.46})<95 end,50,'Air teleport') then
    error('Air Trial teleport not confirmed')
  end
end
-- Phase 3: make a one-way westward jump and stop at the lower-level holding area.
local function jumpPhase3()
  local upper={1152.56,755.27,494.91}
  local approach={1115.86,900.00,493.75}
  local hold={1107.04,1203.93,353.75}
  local STOP_X=1193.0  -- Stop BEFORE crossing the holding coordinate; do not turn around in lava.
  local function atLowerLevel()
    local _,_,z=pos()
    return z<390
  end
  local function westwardRunComplete()
    local y,x,z=pos()
    -- Only lower-level X progress matters for stopping manual movement.
    -- A loose Y limit prevents accepting a landing far outside the corridor.
    return z<390 and x>=STOP_X and math.abs(y-hold[1])<=65
  end
  local _,initialX,initialZ=pos()
  if initialZ>=410 then
    if dist(approach)>45 and dist(upper)>25 then
      gotoPoint(upper,'Phase 3 jump start',16,200)
    end
    gotoPoint(approach,'Phase 3 jump approach',14,160)
  else
    log('Phase 3 lower level detected; skip upper ledge')
  end
  tacPause()
  motionStop()
  local jumped=false
  local jumping=initialZ>=410
  local lastX=select(2,pos())
  local progressAt=os.time()
  local lastJumpAt=-100
  local deadline=os.time()+90
  S.phase='Phase 3: westward jump and lower landing'
  local success,err=pcall(function()
    if not westwardRunComplete() then
      -- Face west ONCE. Never face the exact hold point while Forward is held,
      -- because it would reverse direction after passing the destination X.
      local y,x=pos()
      cmd(string.format('/face fast loc %.2f %.2f',y,x+500))
      mq.delay(250)
      cmd('/keypress forward hold')
      while os.time()<deadline do
        local wasPaused=S.paused
        if wasPaused or S.stop then cmd('/keypress forward') end
        controls()
        if wasPaused then
          local py,px=pos()
          cmd(string.format('/face fast loc %.2f %.2f',py,px+500))
          cmd('/keypress forward hold')
        end
        local yNow,xNow,zNow=pos()
        if jumping and not jumped and xNow>=915 and zNow>455 then
          cmd('/keypress jump')
          jumped=true
          lastJumpAt=os.time()
          log(string.format('Phase 3 ledge jump at X %.1f',xNow))
        end
        if westwardRunComplete() then
          log(string.format('Phase 3 lower landing reached (Y %.1f X %.1f Z %.1f); stopping Forward',yNow,xNow,zNow))
          break
        end
        if xNow>lastX+2 then lastX=xNow; progressAt=os.time() end
        if os.time()-progressAt>5 then
          if atLowerLevel() and os.time()-lastJumpAt>2 then
            cmd('/keypress jump')
            lastJumpAt=os.time()
            log(string.format('Phase 3 forward movement stalled at X %.1f; jump while holding Forward',xNow))
          end
          if os.time()-progressAt>18 then
            error(string.format('Phase 3 westward movement stalled (Y %.1f X %.1f Z %.1f)',yNow,xNow,zNow))
          end
        end
        mq.delay(75)
      end
    end
  end)
  -- Always release movement before any navigation or error handling.
  cmd('/keypress forward')
  motionStop()
  if not success then error(err) end
  if jumping and not jumped and not atLowerLevel() then error('Phase 3 jump not confirmed') end
  if not westwardRunComplete() then
    error('Phase 3 lower landing not reached; stopped movement rather than running in circles')
  end
  if dist(hold)>10 then
    -- Short lower-floor correction only AFTER manual Forward has been released.
    gotoPoint(hold,'Phase 3 lower holding position',10,45,true)
  end
end

-- Ordered phase route; each step is a resumable internal checkpoint.
local steps={}
local function add(label,fn) steps[#steps+1]={label=label,run=fn} end
add('Bazaar / Plane of Time / Expedition / Herald',function()
  if cfg.start==3 then
    -- Already inside the expedition: go straight to the Herald; do not request another DZ.
    if dist({-22.56,865.96,397.37})>600 then
      error('Inside DZ - Before Herald requires being inside the expedition near the Herald area')
    end
    herald()
    return
  end
  if cfg.start==2 then
    if zone()~=cfg.instanceShort and zone()~='potimeb' and zone()~='potime' then
      error('Plane of Time zone-in start requires being in Plane of Time')
    end
    if dist({110,0,7.75})>=140 then
      error('Plane of Time zone-in start requires being near the pre-expedition zone-in')
    end
  else
    if zone()=='bazaar' then mapPort()
    elseif zone()~=cfg.instanceShort and zone()~='potimeb' and zone()~='potime' then bazaar(); mapPort() end
  end
  if dist({110,0,7.75})<140 then expedition() end
  if dist({-22.56,865.96,397.37})>100 then gotoPoint({-22.56,865.96,397.37},'Herald approach',22,250) end
  herald()
end)
-- Phase 1: Air, Earth, Fire, Water, and Undead trials.
add('Air Trial waves - Neimon of Air',function() fightWaves({1352,-36,495.46},'Neimon of Air') end)
add('Air trial exit switch 46',function() through(46,{1351.52,78.41,494.95},{1502.46,315.76,495.18},'Air exit') end)
add('Earth trial switch 45 and waves',function()
  through(45,{1644.03,105.88,494.67},{1644.57,-8.99,494.53},'Earth entrance',true)
  fightWaves(nil,'Terlok of Earth')
end)
add('Earth exit switch 43',function() through(43,{1640.10,77.65,494.92},{1496.12,292.39,494.33},'Earth exit') end)
add('Leave Air/Earth wing switch 38',function() through(38,{1501.15,450.11,494.92},{1096.11,636.86,493.75},'Air Earth wing exit') end)
add('Enter Fire/Water wing switch 13',function() through(13,{713.66,477.59,494.96},{706.51,302.71,494.61},'Fire Water wing entry') end)
add('Fire trial switch 8 and waves',function()
  through(8,{577.77,105.63,494.59},{577.70,-17.34,494.69},'Fire trial entry',true)
  fightWaves(nil,'Kazrok of Fire')
end)
add('Fire trial exit switch 5',function() through(5,{579.44,78.92,494.77},{719.38,325.27,495.32},'Fire trial exit') end)
add('Water trial switch 28 and waves',function()
  through(28,{874.24,104.04,494.51},{863.96,-22.25,494.90},'Water trial entry',true)
  fightWaves(nil,'Anar of Water')
end)
add('Water trial exit switch 28',function() through(28,{863.13,79.47,494.89},{728.40,290.05,494.12},'Water trial exit') end)
add('Leave Fire/Water wing switch 16',function() through(16,{713.70,451.03,494.91},{1107.07,628.52,493.75},'Fire Water wing exit') end)
add('Undead outer door switch 36',function() through(36,{1112.81,478.99,493.75},{1112.45,101.73,493.98},'Undead outer entry') end)
add('Undead trial switch 29 and waves',function()
  through(29,nil,{1114.54,-9.72,494.40},'Undead trial entry',true)
  fightWaves(nil,'Rythor of the Undead')
end)
-- Phase 2: clear corridor and wing encounters.
add('Phase 2 - Undead exit switch 32 / corridor waves',function()
  through(32,{1111.73,72.11,495.25},{1106.37,203.70,494.10},'Undead trial exit',true)
  tacOn(); waitNoAggro('Phase 2 Undead corridor',true)
  gotoPoint({1114.18,447.33,495.25},'Undead corridor outer end',15,200,true)
  waitNoAggro('Phase 2 Undead outer end',false)
end)
add('Phase 2 - Undead outer exit switch 33',function() through(33,{1114.18,447.33,495.25},{1119.94,645.30,493.75},'Undead wing exit',true) end)
add('Phase 2 - Air/Earth wing combat',function()
  through(41,{1502.67,483.01,494.85},{1506.12,446.50,495.25},'Phase 2 Air/Earth entry',true)
  tacOn(); waitNoAggro('Phase 2 Air/Earth wing mobs',true)
  through(38,{1501.15,450.11,494.92},{1088.36,633.21,493.75},'Phase 2 Air/Earth exit',true)
end)
add('Phase 2 - Fire/Water wing combat',function()
  through(13,{711.98,480.26,494.93},{711.02,447.26,495.25},'Phase 2 Fire/Water entry',true)
  tacOn(); waitNoAggro('Phase 2 Fire/Water wing mobs',true)
  through(16,{711.45,454.52,495.04},{1152.56,755.27,494.91},'Phase 2 Fire/Water exit',true)
end)
-- Phase 3: drop, wave encounters, and transition to Phase 4.
add('Phase 3 - Run jump and drop',jumpPhase3)
add('Phase 3 - Dreamwarp / Champion waves',function()
  local hold={1107.04,1203.93,353.75}
  gotoPoint(hold,'Phase 3 hold',14,170,true)
  tacOn()
  local bosses={'Dreamwarp','Champion of Torment'}
  local clearAt=nil
  local deadline=os.time()+1800
  S.phase='Phase 3: Dreamwarp / Champion waves'
  while os.time()<deadline do
    controls()
    local busy=aggro()
    for _,b in ipairs(bosses) do
      local sp=val(function() return mq.TLO.Spawn('npc ="'..b..'"') end,nil)
      if (sp and tonumber(val(function() return sp.ID() end,0)) or 0)>0 then busy=true end
    end
    if busy then
      clearAt=nil; S.holdSeconds=0
      S.detail='Combat / named enemies present; remaining at Phase 3 hold'
    else
      if not clearAt then clearAt=os.time() end
      S.holdSeconds=os.time()-clearAt
      S.detail=string.format('Phase 3 lower waves: no aggro %d/%d sec',S.holdSeconds,cfg.noAggro)
      if dist(hold)>cfg.holdRadius then
        gotoPoint(hold,'Return to Phase 3 holding point',cfg.holdRadius,100,true)
      end
      if S.holdSeconds>=cfg.noAggro then
        log('Phase 3 lower waves clear (including restart with no mobs); advancing to Guardian / Avatar')
        return
      end
    end
    mq.delay(200)
  end
  error('Timed out waiting for Phase 3 lower waves to clear')
end)
add('Phase 3 - Supernatural Guardian / Avatar',function()
  local battle={1109.53,1496.04,371.75}
  gotoPoint(battle,'Final Phase 3 battle',18,200,true)
  tacOn()
  local bosses={'Supernatural Guardian','Avatar of the Elements'}
  local seen={false,false}
  local started=false
  local clearAt=nil
  local arrivedAt=os.time()
  local deadline=os.time()+900
  S.phase='Final Phase 3: Guardian / Avatar'
  while os.time()<deadline do
    controls()
    local busy=aggro()
    for i,b in ipairs(bosses) do
      local sp=val(function() return mq.TLO.Spawn('npc ="'..b..'"') end,nil)
      local id=sp and tonumber(val(function() return sp.ID() end,0)) or 0
      if id>0 then seen[i]=true; started=true; busy=true end
    end
    if busy then
      started=true
      clearAt=nil
      S.holdSeconds=0
      S.detail='Combat active; waiting for Guardian / Avatar and adds'
    else
      if not clearAt then clearAt=os.time() end
      S.holdSeconds=os.time()-clearAt
      local required=cfg.noAggro
      S.detail=string.format('No aggro: %d/%d sec (Guardian seen: %s; Avatar seen: %s)',
        S.holdSeconds,required,tostring(seen[1]),tostring(seen[2]))
      if S.holdSeconds>=required then
        log('Final Phase 3 encounter clear; '..S.holdSeconds..' sec no active aggro')
        return
      end
    end
    mq.delay(200)
  end
  error('Timed out waiting for final Phase 3 combat to clear')
end)
add('Phase 3 to Phase 4 switch 62',function()
  if cfg.stopBeforeP4 then
    gotoPoint({1108.89,1624.63,371.75},'STOP AT PHASE 4 ZONE UP (Switch 62)',10,200,true)
    motionStop(); cmd('/ac burn off'); tacPause()
    log('Stopped before Phase 4 at Switch 62; switch NOT activated')
    S.complete=true; return 'end'
  end
  door(62,{1108.89,1624.63,371.75},'Phase 4 teleport')
  if not await(function() return dist({0,-395,348.75})<85 end,60,'Phase 4 arrival') then error('Phase 4 teleport position not confirmed') end
end)
-- Phase 4: bosses and return-to-hub routes.
add('Phase 4 switch 61 to return hub',function() through(61,{32.25,-285.71,348.75},hub4,'Phase 4 inner entrance') end)
add('Phase 4 - Terris Thule and adds',function() fightBossAdds({250.27,-257.62,346.75},'Terris Thule'); gotoPoint(hub4,'Phase 4 hub',18,190,true) end)
add('Phase 4 - Saryrn and adds',function() fightBossAdds({-274.10,-274.07,348.75},'Saryrn'); gotoPoint(hub4,'Phase 4 hub',18,190,true) end)
add('Phase 4 - Tallon Zek',function()
  gotoPoint({-101.67,386.57,358.75},'Tallon Zek',18,230,true); tacOn()
  namedDefeatOrClear('Tallon Zek','Tallon Zek death / resume',780)
end)
add('Phase 4 - Vallon Zek and adds',function()
  fightBossAdds({75.06,363.91,358.75},'Vallon Zek',true)
end)
add('Phase 4 to Phase 5 switch 24',function()
  if cfg.stopBeforeP5 then
    gotoPoint({4.23,227.52,348.75},'STOP AT PHASE 5 ZONE UP (Switch 24)',10,200,true)
    motionStop(); cmd('/ac burn off'); tacPause()
    log('Stopped before Phase 5 at Switch 24; switch NOT activated')
    S.complete=true; return 'end'
  end
  door(24,{4.23,227.52,348.75},'Phase 5 teleport')
  if not await(function() return dist({1.5,-377.65,3.75})<100 end,60,'Phase 5 arrival') then error('Phase 5 arrival unconfirmed') end
end)
-- Phase 5: bosses, optional Rallos Zek stop, and Quarm entrance.
add('Phase 5 switch 56 to return hub',function() through(56,{31.01,-289.28,3.75},hub5,'Phase 5 inner entrance') end)
add('Phase 5 - Cazic Thule',function()
  gotoPoint({234.90,-240.12,6.24},'Cazic Thule',18,220,true); tacOn()
  namedDefeatOrClear('Cazic Thule','Cazic Thule death / resume',780); gotoPoint(hub5,'Phase 5 hub',18,200,true)
end)
add('Phase 5 - Bertoxxulous',function()
  gotoPoint({-279.94,-280.07,21.75},'Bertoxxulous',18,220,true); tacOn()
  namedDefeatOrClear('Bertoxxulous','Bertoxxulous death / resume',780); gotoPoint(hub5,'Phase 5 hub',18,200,true)
end)
add('Phase 5 - Innoruuk and adds',function() fightBossAdds({272.13,270.75,3.75},'Innoruuk') end)
add('Phase 5 - Rallos Zek choice',function()
  if cfg.stopRZ and cfg.start~=11 then
    gotoPoint({-119.62,107.42,3.75},'STOP BEFORE RALLOS ZEK',17,200,true)
    tacPause(); log('Stopped before Rallos Zek at requested position'); S.complete=true; return 'end'
  end
  fightBossAdds({-222.86,215.07,3.75},'Rallos Zek',false,cfg.burnRZ)
end)
add('Phase 5 - Switch 59',function() through(59,{29.26,240.31,3.75},{-0.21,377.30,3.75},'Quarm access door',true) end)
add('Finish at Quarm entry switch 51',function()
  door(51,{-0.21,377.30,3.75},'Quarm area teleport')
  if not await(function() return dist({-1115,245,-1.24})<100 end,60,'Quarm area arrival') then error('Quarm arrival unconfirmed') end
  if not cfg.killQuarm then
    motionStop(); cmd('/ac burn off'); tacPause(); S.complete=true
    log('Arrived at Quarm entry; Quarm not engaged (option disabled)')
  else
    log('Quarm option enabled: proceeding to Quarm encounter')
  end
end)

-- Optional Quarm fight. Lock only Quarm as the combat target, ignoring XTarget adds.
local QUARM_POSITION={-1111.36,-342.12,-0.62}
local QUARM_SHIELD='Shield of the Immaculate (Legendary)'
local function quarmSpawn()
  local sp=val(function() return mq.TLO.Spawn('npc ="Quarm"') end,nil)
  local id=sp and (tonumber(val(function() return sp.ID() end,0)) or 0) or 0
  local typ=sp and tostring(val(function() return sp.Type() end,'')):lower() or ''
  local health=sp and (tonumber(val(function() return sp.PctHPs() end,0)) or 0) or 0
  if id>0 and typ=='npc' and health>0 then return id end
  return 0
end
local function hasTimewarp()
  -- The spell is a disease DoT; check named buffs and songs for the effect.
  local buff=val(function() return mq.TLO.Me.Buff('Timewarp').ID() end,0)
  local song=val(function() return mq.TLO.Me.Song('Timewarp').ID() end,0)
  return (tonumber(buff) or 0)>0 or (tonumber(song) or 0)>0
end
local function hasLegendaryShield()
  local item=val(function() return mq.TLO.FindItem('='..QUARM_SHIELD) end,nil)
  return item and (tonumber(val(function() return item.ID() end,0)) or 0)>0
end
local function fightQuarm()
  if not cfg.killQuarm then return end
  gotoPoint(QUARM_POSITION,'Approach Quarm',28,240,true)
  tacOn()
  S.quarmLock=true
  S.addPriorityCombat=false
  log('Quarm: target lock enabled; other mobs will not be selected')
  local seen=false
  local clearAt=nil
  local lastClick=0
  local shieldAvailable=hasLegendaryShield()
  if not shieldAvailable then log('Legendary Shield not found; automatic Timewarp curing unavailable') end
  local deadline=os.time()+1200
  while os.time()<deadline do
    controls()
    local id=quarmSpawn()
    if id>0 then
      S.quarmID=id
      seen=true
      clearAt=nil
      S.holdSeconds=0
      recoverFriendlyTarget()
      S.phase='Quarm combat - locked on Quarm'
    else
      S.quarmID=nil
      if not aggro() then
        if not clearAt then clearAt=os.time() end
        S.holdSeconds=os.time()-clearAt
        local required=seen and 3 or cfg.noAggro
        S.phase='Confirm Quarm defeat'
        S.detail=string.format('Quarm absent; clear %d/%d sec',S.holdSeconds,required)
        if S.holdSeconds>=required then
          S.quarmLock=false
          cmd('/attack off')
          tacPause()
          S.complete=true
          log('Quarm encounter finished; no Quarm target remains')
          return
        end
      else clearAt=nil; S.holdSeconds=0 end
    end
    if hasTimewarp() then
      if shieldAvailable and os.time()>lastClick then
        lastClick=os.time()
        cmd('/useitem "'..QUARM_SHIELD..'"')
        log('Timewarp detected: using '..QUARM_SHIELD)
      elseif not shieldAvailable and os.time()>lastClick+9 then
        lastClick=os.time()
        log('WARNING: Timewarp active; Legendary Shield not available')
      end
    end
    mq.delay(100)
  end
  S.quarmLock=false
  S.quarmID=nil
  error('Quarm fight timed out without a confirmed clear')
end
add('Optional Quarm encounter',fightQuarm)
-- Resume from identifiable trial rooms or Phase 2 combat areas.
-- Shared hallways cannot reveal which earlier trials have already been completed.
local resumeP12 = {step=nil, mode=nil}
local function detectPhase12Location()
  local y,x,z=pos()
  if z<465 or z>525 then
    error(string.format('Phase 1/2 auto-detect requires the trial level (current Z %.1f)',z))
  end
  local function near(y0,x0,dy,dx)
    return math.abs(y-y0)<=dy and math.abs(x-x0)<=dx
  end
  local trials={
    {1352,-36,2,'Air trial'},
    {1644,-9,4,'Earth trial'},
    {577,-17,8,'Fire trial'},
    {864,-22,10,'Water trial'},
    {1114,-10,14,'Undead trial'},
  }
  for _,entry in ipairs(trials) do
    if near(entry[1],entry[2],105,95) then
      resumeP12.step=entry[3]
      resumeP12.mode='trial'
      log('Auto-detect: inside '..entry[4]..'; resume wave combat without reopening entrance')
      return entry[3]
    end
  end
  if near(1112,300,85,145) then
    resumeP12.step=15
    resumeP12.mode='undeadCorridor'
    log('Auto-detect: Phase 2 Undead corridor after Switch 32')
    return 15
  end
  if near(1114,447,85,45) then
    resumeP12.step=16
    resumeP12.mode='undeadOuter'
    log('Auto-detect: Phase 2 Undead outer exit; use Switch 33')
    return 16
  end
  if near(1506,446,95,55) then
    resumeP12.step=17
    resumeP12.mode='airEarthWing'
    log('Auto-detect: Phase 2 Air/Earth wing encounter')
    return 17
  end
  if near(711,447,85,55) then
    resumeP12.step=18
    resumeP12.mode='fireWaterWing'
    log('Auto-detect: Phase 2 Fire/Water wing encounter')
    return 18
  end
  error(string.format('Cannot identify completed Phase 1/2 encounters from this shared corridor (Y %.1f X %.1f Z %.1f). Move into the active trial/wing combat area or start from a known checkpoint.',y,x,z))
end
local function runDetectedPhase12Step(i)
  if resumeP12.step~=i then return false end
  local mode=resumeP12.mode
  resumeP12.step=nil
  resumeP12.mode=nil
  if mode=='trial' then
    local boss=({[2]='Neimon of Air',[4]='Terlok of Earth',[8]='Kazrok of Fire',[10]='Anar of Water',[14]='Rythor of the Undead'})[i]
    if not boss then error('Unknown trial resume step '..i) end
    fightWaves(nil,boss)
    return true
  elseif mode=='undeadCorridor' then
    tacOn()
    waitNoAggro('Phase 2 Undead corridor',true)
    gotoPoint({1114.18,447.33,495.25},'Undead corridor outer end',15,200,true)
    waitNoAggro('Phase 2 Undead outer end',false)
    return true
  elseif mode=='airEarthWing' then
    tacOn()
    waitNoAggro('Phase 2 Air/Earth wing mobs',true)
    through(38,{1501.15,450.11,494.92},{1088.36,633.21,493.75},'Phase 2 Air/Earth exit',true)
    return true
  elseif mode=='fireWaterWing' then
    tacOn()
    waitNoAggro('Phase 2 Fire/Water wing mobs',true)
    through(16,{711.45,454.52,495.04},{1152.56,755.27,494.91},'Phase 2 Fire/Water exit',true)
    return true
  end
  return false
end
-- Starting points identify the next required transition using actual character location.
local function indexForStart()
  -- Direct starts assume the transition doors have already been passed.
  -- Verify phase elevation to avoid sending a character into the wrong route.
  if cfg.start==8 then
    local y,x,z=pos()
    if z<285 or z>410 or math.abs(y)>650 then
      error(string.format('Phase 4 inside start requires Phase 4 level (Y %.1f X %.1f Z %.1f)',y,x,z))
    end
    log('Already inside Phase 4: skip Switches 62 and 61')
    return 24
  end
  if cfg.start==10 then
    local y,x,z=pos()
    if z< -30 or z>75 or math.abs(y)>650 then
      error(string.format('Phase 5 inside start requires Phase 5 level (Y %.1f X %.1f Z %.1f)',y,x,z))
    end
    log('Already inside Phase 5: skip Switches 24 and 56')
    return 30
  end
  if cfg.start==11 then
    local y,x,z=pos()
    if z< -30 or z>75 or math.abs(y)>650 then
      error(string.format('Rallos Zek start requires Phase 5 level (Y %.1f X %.1f Z %.1f)',y,x,z))
    end
    log('Starting at Rallos Zek; Stop Before Rallos Zek setting ignored for this start')
    return 33
  end
  if cfg.start==4 then return detectPhase12Location() end
  if cfg.start==1 or cfg.start==2 or cfg.start==3 then return 1 end
  if cfg.start==5 then return 19 end
  if cfg.start==6 then return 20 end
  if cfg.start==7 then
    local y,x,z=pos()
    if y>750 and x>850 and z>250 and z<450 then
      log('Phase 4 zone up: activate Switch 62 from the end of Phase 3')
      return 22
    end
    if dist(hub4)<30 then return 24 end
    if z>275 and z<425 and math.abs(y)<650 and x<100 then return 23 end
    error(string.format('Phase 4 zone up: unknown position (Y %.1f X %.1f Z %.1f)',y,x,z))
  end
  if cfg.start==9 then
    local y,x,z=pos()
    if z>250 and math.abs(y)<650 and x<800 then
      log('Phase 5 zone up: activate Switch 24 from Phase 4')
      return 28
    end
    if dist(hub5)<30 then return 30 end
    if z<100 and math.abs(y)<650 then return 29 end
    error(string.format('Phase 5 zone up: unknown position (Y %.1f X %.1f Z %.1f)',y,x,z))
  end
  return 1
end
-- Run selected start through the phase sequence; save progress internally.
local function run()
  S.complete=false; S.phase='Starting'; S.holdSeconds=0
  local success,err=pcall(function()
    local idx=indexForStart()
    if idx==1 then cfg.completedStep=0; save() end
    for i=idx,#steps do
      controls(); S.stage=steps[i].label; S.phase='Step '..i..'/'..#steps..': '..S.stage
      log(S.phase)
      local result
      if not runDetectedPhase12Step(i) then result=steps[i].run() end
      S.checkpoint=i; cfg.completedStep=i; save()
      if result=='end' then break end
    end
    S.complete=true
  end)
  motionStop(); cmd('/ac burn off'); tacPause()
  if not success then S.phase=S.stop and 'Stopped' or 'ERROR'; log('Run interrupted: '..tostring(err))
  elseif S.complete then S.phase='Completed'
  else S.phase='Finished' end
  S.running=false; S.request=false; save()
end
-- ImGui controls for starting points, stop options, and runtime status.
local function checkbox(label,key)
  local checked = ImGui.Checkbox(label, cfg[key])
  if type(checked)=='boolean' and checked~=cfg[key] and not S.running then
    cfg[key]=checked
    save()
  end
end
local function render()
  local view=cfg.compact and 'compact' or 'full'
  if S.layout~=view then
    ImGui.SetNextWindowPos(cfg[view..'X'],cfg[view..'Y'],ImGuiCond.Always)
    ImGui.SetNextWindowSize(cfg[view..'W'],cfg[view..'H'],ImGuiCond.Always)
    S.layout=view
  end
  local visible,open=ImGui.Begin('Plane of Time Automation v'..VERSION..'###TimeAutomation',true)
  if visible then
    local x,y=ImGui.GetWindowPos(); local w,h=ImGui.GetWindowSize()
    if type(x)=='number' and type(y)=='number' and type(w)=='number' and type(h)=='number' then
      cfg[view..'X'],cfg[view..'Y'],cfg[view..'W'],cfg[view..'H']=math.floor(x),math.floor(y),math.floor(w),math.floor(h)
      if os.time()-S.geometryAt>3 then save(); S.geometryAt=os.time() end
    end
    ImGui.Text('Status: '..S.phase)
    ImGui.Text('No aggro: '..string.format('%.0f',S.holdSeconds)..' / '..cfg.noAggro..' sec')
    if not cfg.compact then
      ImGui.Separator()
      if ImGui.BeginCombo('Starting point',starts[cfg.start]) then
        for i,v in ipairs(starts) do if ImGui.Selectable(v,cfg.start==i) and not S.running then cfg.start=i;save() end end
        ImGui.EndCombo()
      end
      ImGui.TextWrapped('Phase 1 order: Air -> Earth -> Fire -> Water -> Undead (fixed)')
      checkbox('Stop at Phase 4 Zone Up', 'stopBeforeP4')
      checkbox('Stop at Phase 5 Zone Up', 'stopBeforeP5')
      checkbox('Stop Before Rallos Zek', 'stopRZ')
      checkbox('Kill Quarm after entering Quarm area', 'killQuarm')
      if not cfg.stopRZ then checkbox('Use TAC Burn on Rallos Zek','burnRZ') end
      ImGui.TextWrapped('Phase 3: Automatically return to holding position between waves (always on).')
      ImGui.TextWrapped('Zone-up stops leave the character at the transition switch without activating it.')
      ImGui.Separator(); ImGui.Text('Recent activity')
      if ImGui.BeginChild('TimeLog',0,210,true) then
        for i=math.max(1,#S.log-35),#S.log do ImGui.TextWrapped(S.log[i]) end
      end
      ImGui.EndChild()
    end
    if ImGui.Button('Start') and not S.running then
      S.stop=false; S.paused=false; S.running=true; S.request=true; save()
    end
    ImGui.SameLine()
    if ImGui.Button(S.paused and 'Resume' or 'Pause') and S.running then
      S.paused=not S.paused; if S.paused then motionStop(); tacPause() end
    end
    ImGui.SameLine()
    if ImGui.Button('Stop') then S.stop=true; S.paused=false; motionStop(); cmd('/ac burn off'); tacPause() end
    ImGui.SameLine()
    if ImGui.Button(cfg.compact and 'Full' or 'Compact') then cfg.compact=not cfg.compact;save() end
    ImGui.SameLine()
    if ImGui.Button('End') then
      S.stop=true; S.paused=false; motionStop(); cmd('/ac burn off'); tacPause()
      save()
      cmd('/lua stop time')
    end
  end
  ImGui.End()
  if not open then S.stop=true; S.paused=false; motionStop(); tacPause() end
end
mq.imgui.init('TimeAutomationUI',render)
log('Ready for live run. /lua run time; press Start in the ImGui window.')
while true do
  if S.request and S.running then S.request=false;run() end
  mq.doevents(); mq.delay(100)
end
