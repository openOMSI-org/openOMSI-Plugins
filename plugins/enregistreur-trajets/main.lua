-- Enregistreur de trajets
--
-- Enregistre chaque course : la position, la vitesse, le retard et les passagers à
-- intervalles réguliers, et les événements (arrêts, chocs, feux rouges, freinages brusques).
-- Chaque trajet est gardé dans le dossier de données du plugin, en JSON (pour d'autres
-- outils) et en résumé texte (à partager). Un trajet enregistré peut être redessiné sur la
-- carte comme une trace colorée selon la vitesse.
--
-- Ctrl+R lance ou arrête un enregistrement libre, Ctrl+T ouvre le panneau des trajets.
-- Le panneau est aussi dans le menu pause (Échap).

local fmt, ui, json = omsi.fmt, omsi.ui, omsi.json
local PANEL = "trajets"
local MAX_SAMPLES = 5000
local MAX_TRACE_POINTS = 3000

local settings = omsi.plugin.settings({
  { key = "auto", type = "bool", label = "Enregistrer chaque course d'un service", default = true },
  { key = "intervalle", type = "number", label = "Un point toutes les (s)", default = 2, min = 0.5, max = 10, step = 0.5 },
  { key = "garder", type = "number", label = "Trajets gardés", default = 50, min = 5, max = 500, step = 5 },
  { key = "trace_direct", type = "bool", label = "Dessiner la trace pendant l'enregistrement", default = false },
  { key = "hauteur_trace", type = "number", label = "Hauteur de la trace (m)", default = 0.6, min = 0, max = 5, step = 0.1 },
}, "Enregistreur de trajets")

omsi.on("setting", function(key, value) settings[key] = value end)

local index = omsi.storage.get("index") or {}      -- les trajets gardés, le plus récent en premier
local records = omsi.storage.get("records") or {}  -- meilleur temps par course : clé -> secondes

local rec = nil          -- l'enregistrement en cours
local selected = 1       -- le trajet choisi dans l'historique
local loaded = nil       -- le trajet choisi, lu depuis son fichier
local tab = 1
local trace_cables = 0

-- Outils ---------------------------------------------------------------------------------

local function now_id()
  local d = omsi.util.date()
  return string.format("%04d%02d%02d-%02d%02d%02d", d.year, d.month, d.day, d.hour, d.minute, d.second)
end

local function real_date()
  local d = omsi.util.date()
  return string.format("%04d-%02d-%02d %02d:%02d UTC", d.year, d.month, d.day, d.hour, d.minute)
end

-- Réduit une liste à n valeurs au plus, en prenant des points espacés régulièrement.
local function thin(values, n)
  if #values <= n then return values end
  local out = {}
  for i = 1, n do
    out[i] = values[math.floor((i - 1) * (#values - 1) / (n - 1)) + 1]
  end
  return out
end

local function speed_color(kmh, top)
  -- du bleu (lent) au vert puis au rouge (rapide)
  local f = math.max(0, math.min(1, kmh / math.max(top, 1)))
  if f < 0.5 then
    return { 0.2, 0.4 + f * 1.0, 1.0 - f * 1.6 }
  end
  return { 0.2 + (f - 0.5) * 1.6, 0.9 - (f - 0.5) * 1.4, 0.2 }
end

-- La trace sur la carte ------------------------------------------------------------------

local function clear_trace()
  omsi.cable.clear()
  trace_cables = 0
end

local function draw_trace(samples, prefix)
  local pts = {}
  for _, s in ipairs(samples) do
    if s.x then pts[#pts + 1] = s end
  end
  pts = thin(pts, MAX_TRACE_POINTS)
  if #pts < 2 then return 0 end
  local top = 0
  for _, s in ipairs(pts) do top = math.max(top, s.v or 0) end
  local lift = settings.hauteur_trace
  local chunk, n = 20, 0
  local i = 1
  while i < #pts do
    local last = math.min(i + chunk, #pts)
    local flat, sum = {}, 0
    for j = i, last do
      local s = pts[j]
      flat[#flat + 1] = s.x
      flat[#flat + 1] = s.y
      flat[#flat + 1] = (s.z or omsi.map.ground(s.x, s.y) or 0) + lift
      sum = sum + (s.v or 0)
    end
    n = n + 1
    omsi.cable.set(prefix .. n, flat, { radius = 0.12, color = speed_color(sum / (last - i + 1), top) })
    i = last
  end
  return n
end

-- L'enregistrement -----------------------------------------------------------------------

local function event(kind, text)
  if not rec then return end
  local x, y = omsi.position()
  rec.events[#rec.events + 1] = { t = math.floor((omsi.time() - rec.t0) * 10) / 10, kind = kind, text = text, x = x, y = y }
end

local function sample()
  if not rec or #rec.samples >= MAX_SAMPLES then return end
  local x, y, z = omsi.position()
  if not x then return end
  local s = {
    t = math.floor((omsi.time() - rec.t0) * 10) / 10,
    x = math.floor(x * 10) / 10, y = math.floor(y * 10) / 10, z = math.floor(z * 10) / 10,
    v = math.floor((omsi.speed() or 0) * 10) / 10,
    d = omsi.duty.delay(),
    p = (omsi.bus.passengers()),
  }
  local last = rec.samples[#rec.samples]
  if last then
    local dx, dy = s.x - last.x, s.y - last.y
    rec.distance = rec.distance + math.sqrt(dx * dx + dy * dy)
  end
  rec.top_speed = math.max(rec.top_speed, s.v)
  rec.samples[#rec.samples + 1] = s
end

local function start(kind)
  if rec then return end
  local d = omsi.duty.get()
  local trip_title
  if d then
    trip_title = string.format("Ligne %s, service %s, course %d vers %s", d.line, d.tour, d.trip, tostring(d.terminus))
  end
  rec = {
    id = now_id(),
    kind = kind,                         -- "course" ou "libre"
    title = trip_title or ("Trajet libre sur " .. (omsi.map.name() or "?")),
    date = real_date(),
    map = omsi.map.name(),
    bus = omsi.vehicle(),
    bus_number = omsi.bus.number(),
    line = d and d.line, tour = d and d.tour, trip = d and d.trip,
    trip_name = d and d.trip_name, terminus = d and d.terminus,
    clock_start = omsi.info_value("clock"),
    t0 = omsi.time(),
    samples = {}, events = {},
    distance = 0, top_speed = 0,
    stops = 0, crashes = 0, red_lights = 0, jolts = 0, boarded = 0, alighted = 0, tickets = 0,
  }
  sample()
  ui.toast(rec.title, { title = "Enregistrement lancé", icon = "videocam", seconds = 4 })
end

local function summary_text(r)
  local lines = {
    "Trajet openOMSI : " .. r.title,
    "Date : " .. r.date,
    "Carte : " .. tostring(r.map),
    "Bus : " .. tostring(r.bus) .. (r.bus_number and (" n° " .. r.bus_number) or ""),
    "Départ (heure du jeu) : " .. (r.clock_start and fmt.clock(r.clock_start) or "-"),
    "Durée : " .. fmt.duration(r.duration or 0),
    "Distance : " .. fmt.distance(r.distance),
    string.format("Vitesse moyenne : %s, maximale : %s",
      fmt.speed((r.duration or 0) > 0 and r.distance / r.duration * 3.6 or 0), fmt.speed(r.top_speed)),
    "Retard à l'arrivée : " .. (r.delay_end and fmt.delay(r.delay_end) or "-"),
    string.format("Arrêts desservis : %d   Montées : %d   Descentes : %d   Billets : %d",
      r.stops, r.boarded, r.alighted, r.tickets),
    string.format("Chocs : %d   Feux rouges grillés : %d   Freinages ou virages brusques : %d",
      r.crashes, r.red_lights, r.jolts),
  }
  if r.rating then
    lines[#lines + 1] = string.format("Notes du jeu : conduite %d %%, confort %d %%, billetterie %d %%",
      r.rating.driving or 0, r.rating.comfort or 0, r.rating.tickets or 0)
  end
  if r.record then lines[#lines + 1] = "Nouveau record sur cette course !" end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Arrêts :"
  for _, e in ipairs(r.events) do
    if e.kind == "arret" then lines[#lines + 1] = "  " .. fmt.duration(e.t) .. "  " .. e.text end
  end
  return table.concat(lines, "\n") .. "\n"
end

local function forget_old()
  while #index > settings.garder do
    local old = table.remove(index)
    omsi.files.delete("trajets/" .. old.id .. ".json")
    omsi.files.delete("trajets/" .. old.id .. ".txt")
  end
end

local function stop(how)
  if not rec then return end
  local r = rec
  rec = nil
  r.duration = omsi.time() - r.t0
  r.delay_end = omsi.duty.delay()
  r.end_how = how
  if r.duration < 10 or #r.samples < 2 then
    ui.toast("Trop court, rien n'est gardé.", { title = "Enregistrement arrêté", icon = "stop_circle" })
    return
  end

  -- Record sur cette course (seulement une course arrivée au terminus)
  if r.kind == "course" and how == "arrived" and r.trip_name then
    local key = tostring(r.line) .. "|" .. r.trip_name
    if not records[key] or r.duration < records[key] then
      if records[key] then r.record = true end
      records[key] = r.duration
      omsi.storage.set("records", records)
    end
  end

  omsi.files.mkdir("trajets")
  local ok, why = omsi.files.write("trajets/" .. r.id .. ".json", json.encode(r))
  if not ok then
    omsi.warn("Impossible d'écrire le trajet : " .. tostring(why))
    ui.toast("Le trajet n'a pas pu être écrit : " .. tostring(why), { title = "Enregistreur", icon = "error", color = "#FF5F57" })
    return
  end
  omsi.files.write("trajets/" .. r.id .. ".txt", summary_text(r))
  table.insert(index, 1, {
    id = r.id, title = r.title, date = r.date, duration = r.duration, distance = r.distance,
    delay_end = r.delay_end, map = r.map, record = r.record,
  })
  forget_old()
  omsi.storage.set("index", index)
  omsi.storage.save()
  selected, loaded = 1, nil
  ui.toast(string.format("%s, %s%s", fmt.duration(r.duration), fmt.distance(r.distance), r.record and " - record !" or ""),
    { title = "Trajet enregistré", icon = "save", color = "#34B26E", seconds = 6 })
end

omsi.every(0.5, function()
  if not rec then return end
  local last = rec.samples[#rec.samples]
  if not last or omsi.time() - rec.t0 - last.t >= settings.intervalle then sample() end
end)

-- Trace en direct
omsi.every(10, function()
  if rec and settings.trace_direct then
    clear_trace()
    trace_cables = draw_trace(rec.samples, "live")
  end
end)

-- Événements de la course ----------------------------------------------------------------

omsi.on("stop_arrive", function(name, _, number, delay)
  if not rec then return end
  rec.stops = rec.stops + 1
  event("arret", string.format("%d. %s (%s)", number or 0, tostring(name), fmt.delay(delay or 0)))
end)
omsi.on("crash", function(kj, kmh)
  if not rec then return end
  rec.crashes = rec.crashes + 1
  event("choc", string.format("%.0f kJ à %.0f km/h", kj or 0, kmh or 0))
end)
omsi.on("red_light", function(kmh)
  if not rec then return end
  rec.red_lights = rec.red_lights + 1
  event("feu_rouge", string.format("%.0f km/h", kmh or 0))
end)
omsi.on("jolt", function(along, across)
  if not rec then return end
  rec.jolts = rec.jolts + 1
  event("secousse", string.format("%.1f / %.1f m/s²", along or 0, across or 0))
end)
omsi.on("pedestrian", function(count)
  if rec then event("pieton", tostring(count)) end
end)
omsi.on("passenger_board", function(count) if rec then rec.boarded = rec.boarded + (count or 0) end end)
omsi.on("passenger_alight", function(count) if rec then rec.alighted = rec.alighted + (count or 0) end end)
omsi.on("ticket_sold", function() if rec then rec.tickets = rec.tickets + 1 end end)

omsi.on("trip_start", function()
  if settings.auto and not rec then start("course") end
end)
omsi.on("duty_start", function()
  if settings.auto and not rec then start("course") end
end)
omsi.on("trip_done", function(_, how, driving, comfort, tickets)
  if rec and rec.kind == "course" then
    rec.rating = { driving = driving, comfort = comfort, tickets = tickets }
    stop(how)
  end
end)
omsi.on("duty_end", function()
  if rec and rec.kind == "course" then stop("given_up") end
end)
omsi.on("vehicle", function(name)
  if not name and rec then stop("left") end
end)

-- Le panneau -----------------------------------------------------------------------------

local function load_selected()
  local entry = index[selected]
  if not entry then loaded = nil return end
  if loaded and loaded.id == entry.id then return end
  local text = omsi.files.read("trajets/" .. entry.id .. ".json")
  loaded = text and json.decode(text) or nil
  if loaded then loaded.id = entry.id end
end

local function current_children()
  if not rec then
    return {
      { type = "text", text = "Aucun enregistrement en cours.", color = "#9AA0A6" },
      { type = "text", text = settings.auto and "Chaque course d'un service est enregistrée toute seule." or
          "L'enregistrement automatique est désactivé dans les réglages.", size = 12, color = "#9AA0A6" },
      { type = "button", id = "rec", text = "Lancer un trajet libre", icon = "videocam" },
    }
  end
  local speeds = {}
  local from = math.max(1, #rec.samples - 119)
  for i = from, #rec.samples do speeds[#speeds + 1] = rec.samples[i].v end
  local dur = omsi.time() - rec.t0
  return {
    { type = "row", children = {
      { type = "icon", name = "videocam", color = "#FF5F57" },
      { type = "text", text = rec.title, weight = "medium", grow = true },
    } },
    { type = "table", columns = { "Durée", "Distance", "Arrêts", "Chocs" }, rows = {
      { fmt.duration(dur), fmt.distance(rec.distance), tostring(rec.stops), tostring(rec.crashes) },
    } },
    { type = "text", text = "Vitesse (dernières minutes)", size = 12, color = "#9AA0A6" },
    { type = "chart", values = #speeds > 1 and speeds or { 0, 0 }, min = 0, height = 40, fill = true },
    { type = "button", id = "rec", text = "Arrêter et garder", icon = "stop_circle" },
  }
end

local function history_children()
  if #index == 0 then
    return { { type = "text", text = "Aucun trajet enregistré pour l'instant.", color = "#9AA0A6" } }
  end
  selected = math.max(1, math.min(selected, #index))
  load_selected()
  local rows = {}
  local first = math.max(1, math.min(selected - 2, #index - 4))
  for i = first, math.min(#index, first + 4) do
    local e = index[i]
    local mark = i == selected and "> " or ""
    rows[#rows + 1] = {
      { text = mark .. e.title, color = i == selected and "#F47F30" or nil },
      fmt.duration(e.duration or 0),
      { text = e.delay_end and fmt.delay(e.delay_end) or "-",
        color = e.delay_end and (e.delay_end > 120 and "#FF5F57" or "#34B26E") or nil },
    }
  end
  local children = {
    { type = "table", columns = { "Trajet", "Durée", "Retard" }, widths = { 4, 1.4, 1 }, aligns = { "left", "right", "right" }, rows = rows },
    { type = "row", children = {
      { type = "button", id = "prev", icon = "expand_less", text = "Précédent", grow = true },
      { type = "button", id = "next", icon = "expand_more", text = "Suivant", grow = true },
    } },
  }
  if loaded then
    local speeds, delays = {}, {}
    for _, s in ipairs(loaded.samples or {}) do
      speeds[#speeds + 1] = s.v or 0
      if s.d then delays[#delays + 1] = s.d end
    end
    children[#children + 1] = { type = "text", size = 12, color = "#9AA0A6", text = string.format(
      "%s · %s · %s · %d arrêts · %d chocs%s", loaded.date or "", fmt.distance(loaded.distance or 0),
      tostring(loaded.bus or "?"), loaded.stops or 0, loaded.crashes or 0, loaded.record and " · record" or "") }
    children[#children + 1] = { type = "text", text = "Vitesse", size = 12, color = "#9AA0A6" }
    children[#children + 1] = { type = "chart", values = thin(#speeds > 1 and speeds or { 0, 0 }, 300), min = 0, height = 40, fill = true }
    if #delays > 1 then
      children[#children + 1] = { type = "text", text = "Retard (s)", size = 12, color = "#9AA0A6" }
      children[#children + 1] = { type = "chart", values = thin(delays, 300), height = 32, style = "line" }
    end
  else
    children[#children + 1] = { type = "text", text = "Le fichier de ce trajet est introuvable.", color = "#FF5F57" }
  end
  children[#children + 1] = { type = "row", children = {
    { type = "button", id = "trace", text = "Trace sur la carte", icon = "route", grow = true },
    { type = "button", id = "untrace", text = "Effacer", icon = "delete" },
  } }
  children[#children + 1] = { type = "button", id = "delete", text = "Supprimer ce trajet", icon = "delete", color = "#8B2D2D" }
  return children
end

local function show_panel()
  if omsi.data.panel_visible ~= true then
    ui.remove(PANEL)
    return
  end
  local children = {
    { type = "row", children = {
      { type = "icon", name = "route", color = "#F47F30" },
      { type = "text", text = "Mes trajets", size = 16, weight = "bold", grow = true },
      { type = "badge", text = rec and "REC" or (#index .. " gardés"), color = rec and "#C62828" or "#5F6368" },
    } },
    { type = "tabs", id = "tab", tabs = { "En cours", "Historique" }, selected = tab },
  }
  local body = tab == 1 and current_children() or history_children()
  for _, c in ipairs(body) do children[#children + 1] = c end
  children[#children + 1] = { type = "row", children = {
    { type = "text", text = "Fichiers : dossier de données du plugin, sous trajets/", size = 11, color = "#7A7F85", grow = true },
    { type = "button", id = "close", icon = "close", text = "" },
  } }
  ui.set(PANEL, { anchor = "top_left", x = 16, y = 120, width = 380, accent = "#F47F30", draggable = true, children = children })
end

local function set_visible(on)
  omsi.data.panel_visible = on
  if on then ui.focus(true) end
  show_panel()
end

omsi.every(1, function()
  if omsi.data.panel_visible == true then show_panel() end
end)

omsi.on("ui_change", function(panel, element, value)
  if panel == PANEL and element == "tab" then
    tab = value
    show_panel()
  end
end)

omsi.on("ui_click", function(panel, element)
  if panel ~= PANEL then return end
  if element == "close" then set_visible(false)
  elseif element == "rec" then
    if rec then stop("manual") else start("libre") end
  elseif element == "prev" then selected = math.max(1, selected - 1)
  elseif element == "next" then selected = math.min(#index, selected + 1)
  elseif element == "trace" then
    load_selected()
    if loaded then
      if loaded.map and loaded.map ~= omsi.map.name() then
        ui.toast("Ce trajet a été fait sur la carte " .. loaded.map .. ".", { title = "Trace", icon = "map" })
      else
        clear_trace()
        trace_cables = draw_trace(loaded.samples or {}, "trace")
        ui.toast(trace_cables > 0 and "La trace est dessinée sur la route (bleu lent, rouge rapide)." or "Pas assez de points.",
          { title = "Trace", icon = "route" })
      end
    end
  elseif element == "untrace" then clear_trace()
  elseif element == "delete" then
    local e = table.remove(index, selected)
    if e then
      omsi.files.delete("trajets/" .. e.id .. ".json")
      omsi.files.delete("trajets/" .. e.id .. ".txt")
      omsi.storage.set("index", index)
      loaded = nil
    end
  end
  show_panel()
end)

omsi.input.hotkey("Ctrl+KeyR", function()
  if rec then stop("manual") else start("libre") end
  show_panel()
end)
omsi.input.hotkey("Ctrl+KeyT", function() set_visible(omsi.data.panel_visible ~= true) end)
ui.set_menu_item("trajets", "Mes trajets enregistrés", "route")
omsi.on("menu_item", function(id)
  if id == "trajets" then set_visible(true) end
end)

omsi.on("stop", function()
  -- Le jeu se ferme ou le plugin est rechargé : on garde ce qui a été enregistré.
  if rec then stop("closed") end
end)

show_panel()
