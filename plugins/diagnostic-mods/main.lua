-- Diagnostic de mods
--
-- Vérifie ce que le jeu a chargé et signale ce qui cloche : un bus sans scripts, sans
-- girouettes ou sans billets, un HOF qui ne va pas avec la carte, des termini de l'horaire
-- absents du HOF, une carte sans points de départ ni horaire. Pendant la conduite, il relève
-- aussi les tuiles où les images par seconde chutent, les chocs à l'arrêt (souvent un
-- maillage de collision raté) et les passages hors des voies de circulation.
--
-- Le rapport s'affiche en jeu (Ctrl+G ou le menu pause) et peut être écrit dans un fichier
-- texte à joindre à un signalement de bug. Rien n'est envoyé nulle part.

local fmt, ui = omsi.fmt, omsi.ui
local PANEL = "diagnostic"

local settings = omsi.plugin.settings({
  { key = "auto", type = "bool", label = "Analyser en montant dans un bus", default = true },
  { key = "fps_min", type = "number", label = "Signaler les tuiles sous (images/s)", default = 30, min = 10, max = 120, step = 5 },
  { key = "hors_voie", type = "bool", label = "Signaler les passages hors des voies", default = true },
  { key = "alerte", type = "bool", label = "Notification quand un problème est trouvé", default = true },
}, "Diagnostic de mods")

omsi.on("setting", function(key, value) settings[key] = value end)

local findings = {}      -- { level, area, text, hint }
local last_run = nil
local page = 1
local PER_PAGE = 7

-- Relevés pendant la conduite
local tile_fps = {}      -- "x,y" -> { sum, n, file }
local stand_crashes = {} -- liste de { tile, kj }
local off_lane = {}      -- "x,y" -> secondes hors voie
local off_lane_run = 0

local LEVELS = { error = 1, warn = 2, info = 3, ok = 4 }
local COLORS = { error = "#FF5F57", warn = "#F4B400", info = "#3D8BFF", ok = "#34B26E" }
local ICONS = { error = "error", warn = "warning", info = "info", ok = "check_circle" }
local NAMES = { error = "PROBLÈME", warn = "ATTENTION", info = "INFO", ok = "OK" }

local function add(level, area, text, hint)
  findings[#findings + 1] = { level = level, area = area, text = text, hint = hint }
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function tile_files()
  local files = {}
  for _, t in ipairs(omsi.map.tiles()) do files[t.x .. "," .. t.y] = t.file end
  return files
end

-- Les vérifications ----------------------------------------------------------------------

local function check_game()
  local s = omsi.game.settings()
  add("info", "Jeu", string.format("openOMSI %s sur %s, graphismes « %s », langue %s",
    omsi.game.version(), omsi.game.platform(), tostring(s.graphics), tostring(s.language)))
  local plugins = omsi.plugin.list()
  add("info", "Plugins", #plugins .. " plugin(s) chargé(s) : " .. table.concat(plugins, ", "))
end

local function check_map()
  local info = omsi.map.info()
  if not info then
    add("error", "Carte", "Aucune carte n'est chargée, ou sa global.cfg n'a pas été lue.")
    return
  end
  add("info", "Carte", string.format("%s (%s)", tostring(info.friendly_name or info.name), tostring(info.path)))

  local tiles = omsi.map.tiles()
  if #tiles == 0 then
    add("error", "Carte", "La carte n'a aucune tuile.", "Vérifiez la section [map] de global.cfg.")
  else
    add("ok", "Carte", #tiles .. " tuile(s) déclarée(s).")
  end

  if #omsi.map.entrypoints() == 0 then
    add("warn", "Carte", "Aucun point de départ (entrypoint).", "Le joueur ne peut pas choisir où commencer.")
  end

  local lines = omsi.timetable.lines()
  if #lines == 0 then
    add("warn", "Horaire", "La carte n'a aucune ligne d'horaire.", "Dossier TTData absent ou vide : pas de service possible.")
  else
    local driveable, today = 0, 0
    for _, l in ipairs(lines) do
      if l.user_allowed then driveable = driveable + 1 end
      for _, t in ipairs(l.tours or {}) do
        if t.today then today = today + 1 end
      end
    end
    add("ok", "Horaire", string.format("%d ligne(s), %d jouable(s), %d service(s) aujourd'hui.", #lines, driveable, today))
    if driveable == 0 then
      add("warn", "Horaire", "Aucune ligne n'est ouverte au joueur.", "Toutes les lignes sont réservées au trafic IA.")
    end
    if today == 0 then
      add("warn", "Horaire", "Aucun service ne roule à la date du jeu.", "Changez la date, ou vérifiez les jours des services.")
    end
  end
end

local function check_bus()
  if not omsi.has_vehicle() then
    add("info", "Bus", "Vous n'êtes pas dans un véhicule : les vérifications du bus sont sautées.")
    return
  end
  local file = omsi.bus.file() or "?"
  add("info", "Bus", string.format("%s (%s)", tostring(omsi.vehicle()), file))

  if not omsi.vehicle_manufacturer() or not omsi.vehicle_model() then
    add("warn", "Bus", "Le nom du bus est incomplet.", "La section [friendlyname] du fichier .bus manque ou est mal remplie.")
  end

  local vars = omsi.vars()
  if #vars == 0 then
    add("error", "Bus", "Le bus n'a aucune variable de script.", "Ses fichiers .osc ne sont pas chargés : vérifiez [script] dans le .bus.")
  else
    add("ok", "Bus", #vars .. " variables de script.")
    if omsi.var("Velocity") == nil then
      add("warn", "Bus", "La variable « Velocity » manque.", "Beaucoup de plugins et d'afficheurs s'en servent.")
    end
  end

  if omsi.bus.engine_running() == nil then
    add("warn", "Bus", "L'état du moteur est illisible.", "Le script du moteur ne donne pas les variables habituelles.")
  end
  if omsi.bus.door_count() == 0 then
    add("warn", "Bus", "Aucune porte n'est reliée aux touches.", "Les passagers ne pourront pas monter.")
  end
  local mass = omsi.bus.mass()
  if not mass or mass <= 0 then
    add("error", "Bus", "La masse du bus est nulle ou inconnue.", "Vérifiez la section [mass] du fichier .bus.")
  end
  if #omsi.bus.wheels() == 0 then
    add("error", "Bus", "Le bus n'a aucune roue.", "Vérifiez les sections [axis] du fichier .bus.")
  end

  local dests = omsi.bus.destinations()
  if #dests == 0 then
    add("warn", "Girouette", "Le bus ne connaît aucune destination.", "Aucun fichier HOF n'est chargé pour ce bus ou cette carte.")
  else
    add("ok", "Girouette", #dests .. " destination(s) dans le HOF.")
  end

  local tickets = omsi.bus.tickets()
  if #tickets == 0 then
    add("warn", "Billets", "La carte ne vend aucun billet.", "Il manque un ticketpack (TicketPacks) pour cette carte.")
  else
    add("ok", "Billets", #tickets .. " billet(s) en vente.")
  end

  local hof = omsi.hof.get()
  if not hof then
    add("warn", "HOF", "Aucun fichier HOF chargé.", "Copiez le HOF de la carte dans le dossier du bus, ou choisissez-le au démarrage.")
  else
    add("ok", "HOF", string.format("%s : %d termini, %d arrêts.", tostring(hof.name or hof.path), #(hof.termini or {}), #(hof.bus_stops or {})))
    if #(hof.termini or {}) == 0 then
      add("error", "HOF", "Le HOF ne contient aucun terminus.", "Le fichier est vide ou mal formé.")
    end
  end
end

local function check_duty()
  if not omsi.duty.active() then return end
  local tour = omsi.duty.tour()
  if not tour then return end
  local missing, seen = {}, {}
  for _, trip in ipairs(tour.trips or {}) do
    local t = trip.terminus
    if t and not seen[t] then
      seen[t] = true
      if not omsi.hof.terminus(t) then missing[#missing + 1] = t end
    end
  end
  if #missing > 0 then
    add("error", "Service", string.format("%d terminus de l'horaire absent(s) du HOF : %s",
      #missing, table.concat(missing, ", ", 1, math.min(#missing, 6))),
      "Le HOF du bus n'est pas celui de cette carte, ou il est trop ancien. La girouette et l'IBIS ne suivront pas.")
  else
    add("ok", "Service", string.format("Ligne %s / %s : tous les termini sont dans le HOF.", tostring(tour.line), tostring(tour.number)))
  end

  local unplaced = 0
  for _, s in ipairs(omsi.duty.stops()) do
    if s.stops and not s.x then unplaced = unplaced + 1 end
  end
  if unplaced > 0 then
    add("info", "Service", unplaced .. " arrêt(s) de la course sans position connue.",
      "Leur tuile n'est peut-être pas encore chargée. S'il en reste loin du départ, l'arrêt manque sur la carte.")
  end
end

local function check_driving()
  local files = tile_files()
  local slow = {}
  for key, t in pairs(tile_fps) do
    local avg = t.sum / t.n
    if t.n >= 10 and avg < settings.fps_min then
      slow[#slow + 1] = { key = key, avg = avg, file = files[key] }
    end
  end
  table.sort(slow, function(a, b) return a.avg < b.avg end)
  for i = 1, math.min(#slow, 5) do
    local s = slow[i]
    add("warn", "Performance", string.format("Tuile %s : %.0f images/s en moyenne (%s)", s.key, s.avg, tostring(s.file or "?")),
      "Trop d'objets, de textures lourdes ou d'arbres sur cette tuile.")
  end
  if count(tile_fps) > 0 and #slow == 0 then
    add("ok", "Performance", string.format("Aucune tuile sous %d images/s sur %d tuile(s) parcourue(s).", settings.fps_min, count(tile_fps)))
  end

  for i = 1, math.min(#stand_crashes, 5) do
    local c = stand_crashes[i]
    add("warn", "Collision", string.format("Choc presque à l'arrêt (%.0f kJ) sur la tuile %s (%s)", c.kj, c.tile, tostring(files[c.tile] or "?")),
      "Souvent un maillage de collision d'objet ou de bus mal placé.")
  end

  if settings.hors_voie then
    local list = {}
    for key, secs in pairs(off_lane) do
      if secs >= 10 then list[#list + 1] = { key = key, secs = secs } end
    end
    table.sort(list, function(a, b) return a.secs > b.secs end)
    for i = 1, math.min(#list, 3) do
      local o = list[i]
      add("info", "Voies", string.format("%s hors des voies de circulation sur la tuile %s (%s)",
        fmt.duration(o.secs), o.key, tostring(files[o.key] or "?")),
        "Si vous rouliez sur une route, une spline n'a sans doute pas de voie : l'IA et les limites n'y marchent pas.")
    end
  end
end

local function run()
  findings = {}
  local t0 = omsi.util.ms()
  for _, step in ipairs({ check_game, check_map, check_bus, check_duty, check_driving }) do
    local ok, err = pcall(step)
    if not ok then add("warn", "Diagnostic", "Une vérification a échoué : " .. tostring(err)) end
  end
  table.sort(findings, function(a, b)
    if LEVELS[a.level] ~= LEVELS[b.level] then return LEVELS[a.level] < LEVELS[b.level] end
    return a.area < b.area
  end)
  last_run = { clock = omsi.info_value("clock"), ms = omsi.util.ms() - t0, date = omsi.util.date() }
  page = 1
end

local function totals()
  local n = { error = 0, warn = 0, info = 0, ok = 0 }
  for _, f in ipairs(findings) do n[f.level] = n[f.level] + 1 end
  return n
end

-- Le rapport -----------------------------------------------------------------------------

local function write_report()
  if not last_run then run() end
  local d = last_run.date
  local name = string.format("rapport-%04d%02d%02d-%02d%02d%02d.txt", d.year, d.month, d.day, d.hour, d.minute, d.second)
  local n = totals()
  local out = {
    "Rapport de diagnostic openOMSI",
    string.format("Date : %04d-%02d-%02d %02d:%02d UTC", d.year, d.month, d.day, d.hour, d.minute),
    string.format("Résultat : %d problème(s), %d avertissement(s), %d info(s), %d point(s) OK", n.error, n.warn, n.info, n.ok),
    "",
  }
  for _, f in ipairs(findings) do
    out[#out + 1] = string.format("[%s] %s : %s", NAMES[f.level], f.area, f.text)
    if f.hint then out[#out + 1] = "    -> " .. f.hint end
  end
  local ok, why = omsi.files.write(name, table.concat(out, "\n") .. "\n")
  if ok then
    omsi.files.write(name:gsub("%.txt$", ".json"), omsi.json.encode({ findings = findings, totals = n }, true))
    ui.toast(omsi.files.dir() .. "/" .. name, { title = "Rapport écrit", icon = "description", seconds = 10 })
    omsi.log("Rapport de diagnostic : " .. omsi.files.dir() .. "/" .. name)
  else
    ui.toast("Écriture impossible : " .. tostring(why), { title = "Rapport", icon = "error", color = "#FF5F57" })
  end
end

-- Le panneau -----------------------------------------------------------------------------

local function show_panel()
  if omsi.data.panel_visible ~= true then
    ui.remove(PANEL)
    return
  end
  local n = totals()
  local pages = math.max(1, math.ceil(#findings / PER_PAGE))
  page = math.max(1, math.min(page, pages))
  local children = {
    { type = "row", children = {
      { type = "icon", name = "build", color = "#3D8BFF" },
      { type = "text", text = "Diagnostic de mods", size = 16, weight = "bold", grow = true },
      { type = "badge", text = n.error .. " problème(s)", color = n.error > 0 and "#C62828" or "#2E7D32" },
      { type = "badge", text = n.warn .. " attention", color = n.warn > 0 and "#B26A00" or "#5F6368" },
    } },
  }
  if #findings == 0 then
    children[#children + 1] = { type = "text", text = "Lancez une analyse.", color = "#9AA0A6" }
  end
  for i = (page - 1) * PER_PAGE + 1, math.min(#findings, page * PER_PAGE) do
    local f = findings[i]
    local box = { type = "box", color = COLORS[f.level], children = {
      { type = "row", children = {
        { type = "icon", name = ICONS[f.level], size = 16, color = COLORS[f.level] },
        { type = "text", text = f.area, size = 12, weight = "bold", color = COLORS[f.level], grow = true },
      } },
      { type = "text", text = f.text, size = 13 },
    } }
    if f.hint then box.children[#box.children + 1] = { type = "text", text = f.hint, size = 12, color = "#9AA0A6" } end
    children[#children + 1] = box
  end
  if pages > 1 then
    children[#children + 1] = { type = "row", children = {
      { type = "button", id = "prev", icon = "chevron_left", text = "" },
      { type = "text", text = string.format("Page %d / %d", page, pages), align = "center", grow = true },
      { type = "button", id = "next", icon = "chevron_right", text = "" },
    } }
  end
  children[#children + 1] = { type = "row", children = {
    { type = "button", id = "run", text = "Analyser", icon = "refresh", grow = true },
    { type = "button", id = "report", text = "Écrire le rapport", icon = "description", grow = true },
    { type = "button", id = "close", icon = "close", text = "" },
  } }
  if last_run then
    children[#children + 1] = { type = "text", size = 11, color = "#7A7F85",
      text = string.format("Analyse à %s (heure du jeu), %d ms", last_run.clock and fmt.clock(last_run.clock) or "?", math.floor(last_run.ms)) }
  end
  ui.set(PANEL, { anchor = "top_right", x = 16, y = 120, width = 420, accent = "#3D8BFF", draggable = true, children = children })
end

local function set_visible(on)
  omsi.data.panel_visible = on
  if on then
    if not last_run then run() end
    ui.focus(true)
  end
  show_panel()
end

local function auto_run()
  run()
  local n = totals()
  if settings.alerte and n.error + n.warn > 0 then
    ui.toast(string.format("%d problème(s) et %d avertissement(s). Ctrl+G pour les voir.", n.error, n.warn),
      { title = "Diagnostic de mods", icon = n.error > 0 and "error" or "warning",
        color = n.error > 0 and "#FF5F57" or "#F4B400", seconds = 8 })
  end
  show_panel()
end

-- Relevés pendant la conduite --------------------------------------------------------------

omsi.every(1, function()
  if not omsi.has_vehicle() or omsi.world.paused() then return end
  local tx, ty = omsi.map.tile()
  if not tx then return end
  local key = tx .. "," .. ty
  local fps = omsi.game.fps()
  if fps and fps > 0 then
    local t = tile_fps[key] or { sum = 0, n = 0 }
    t.sum, t.n = t.sum + fps, t.n + 1
    tile_fps[key] = t
  end
  if settings.hors_voie and math.abs(omsi.speed()) > 10 then
    if omsi.map.speed_limit() == nil then
      off_lane_run = off_lane_run + 1
      if off_lane_run >= 3 then off_lane[key] = (off_lane[key] or 0) + 1 end
    else
      off_lane_run = 0
    end
  end
end)

omsi.on("crash", function(kj, kmh)
  if (kmh or 99) < 3 and #stand_crashes < 20 then
    local tx, ty = omsi.map.tile()
    stand_crashes[#stand_crashes + 1] = { tile = tx and (tx .. "," .. ty) or "?", kj = kj or 0 }
  end
end)

omsi.on("vehicle", function(name)
  if name and settings.auto then omsi.after(5, auto_run) end
end)
omsi.on("duty_start", function()
  if settings.auto then omsi.after(3, auto_run) end
end)

omsi.on("ui_click", function(panel, element)
  if panel ~= PANEL then return end
  if element == "close" then set_visible(false) return end
  if element == "run" then run()
  elseif element == "report" then write_report()
  elseif element == "prev" then page = page - 1
  elseif element == "next" then page = page + 1 end
  show_panel()
end)

omsi.input.hotkey("Ctrl+KeyG", function() set_visible(omsi.data.panel_visible ~= true) end)
ui.set_menu_item("diagnostic", "Diagnostic de mods", "build")
omsi.on("menu_item", function(id)
  if id == "diagnostic" then set_visible(true) end
end)

show_panel()
