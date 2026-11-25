-- Prise de service réaliste
--
-- Avant de partir, le chauffeur suit une checklist comme dans un vrai dépôt : frein de
-- stationnement, électricité, moteur, montée en pression de l'air, feux, essai des
-- clignotants et du klaxon, girouette, portes, tour du véhicule. Le plugin coche tout seul ce
-- qu'il peut lire sur le bus. À la fin du service, une checklist de remisage suit.
--
-- La checklist s'ouvre quand on monte dans un bus froid ou qu'on prend un service.
-- Ctrl+J l'ouvre ou la ferme ; elle est aussi dans le menu pause (Échap).

local fmt, ui = omsi.fmt, omsi.ui
local PANEL = "checklist"

local settings = omsi.plugin.settings({
  { key = "auto", type = "bool", label = "Ouvrir la checklist en montant dans un bus froid", default = true },
  { key = "feux", type = "choice", label = "Feux de croisement exigés", choices = { "toujours", "la nuit", "jamais" }, default = "toujours" },
  { key = "attente_air", type = "number", label = "Montée en pression de l'air (s)", default = 30, min = 0, max = 180, step = 5 },
  { key = "var_pression", type = "text", label = "Variable de pression du bus (vide : minuterie)", default = "" },
  { key = "seuil_pression", type = "number", label = "Pression minimale (unité du bus)", default = 7, min = 0, max = 20, step = 0.5 },
  { key = "bloquer", type = "bool", label = "Serrer le frein si l'on part trop tôt", default = false },
  { key = "fin_service", type = "bool", label = "Checklist de remisage en fin de service", default = true },
}, "Prise de service")

omsi.on("setting", function(key, value) settings[key] = value end)

local stats = omsi.storage.get("stats") or { done = 0, early = 0, best = nil, total_time = 0, parked = 0 }

-- État de la checklist en cours
local list = nil          -- { kind = "start" | "end", items, started, done_at, warned }
local seen = {}           -- ce qui s'est passé depuis l'ouverture : clignotants, klaxon
local engine_since = nil  -- temps de jeu où le moteur a démarré

local function is_night()
  local alt = omsi.sys("SunAlt")
  return alt ~= nil and alt < 0
end

local function lights_needed()
  if settings.feux == "toujours" then return true end
  if settings.feux == "la nuit" then return is_night() end
  return false
end

-- Chaque point : id, label, check() -> true / false / nil (nil : le bus ne le dit pas),
-- sticky (une fois fait, il reste fait), manual (le chauffeur le coche).

local function start_items()
  return {
    { id = "handbrake", label = "Frein de stationnement serré", sticky = true,
      check = function() return omsi.bus.handbrake() end },
    { id = "electrics", label = "Batterie et électricité", sticky = true,
      check = function() return omsi.bus.electrics() end },
    { id = "engine", label = "Moteur démarré", sticky = true,
      check = function() return omsi.bus.engine_running() end },
    { id = "air", label = "Pression d'air", sticky = true,
      check = function(item)
        local name = fmt.trim(settings.var_pression or "")
        if name ~= "" then
          local p = omsi.var(name)
          if p ~= nil then
            item.detail = string.format("%.1f / %.1f", p, settings.seuil_pression)
            return p >= settings.seuil_pression
          end
        end
        if not engine_since then
          item.detail = "moteur arrêté"
          return false
        end
        local left = settings.attente_air - (omsi.time() - engine_since)
        item.detail = left > 0 and string.format("encore %d s", math.ceil(left)) or nil
        return left <= 0
      end },
    { id = "lights", label = "Feux de croisement",
      check = function(item)
        if not lights_needed() then item.detail = "pas exigés"; return true end
        local h = omsi.bus.headlights()
        if h == nil then return nil end
        item.detail = nil
        return h >= 2
      end },
    { id = "indicators", label = "Essai des clignotants gauche et droit", sticky = true,
      check = function(item)
        if omsi.bus.indicator() == nil then return nil end
        item.detail = "G " .. (seen.left and "ok" or "-") .. "  D " .. (seen.right and "ok" or "-")
        return seen.left and seen.right
      end },
    { id = "horn", label = "Essai du klaxon", sticky = true,
      check = function() return seen.horn == true end },
    { id = "destination", label = "Girouette réglée", sticky = true,
      check = function(item)
        local name = omsi.bus.destination()
        if #omsi.bus.destinations() == 0 then return nil end
        item.detail = name
        return name ~= nil and name ~= ""
      end },
    { id = "doors", label = "Portes fermées",
      check = function()
        local open = omsi.bus.doors_open()
        if open == nil then return nil end
        return not open
      end },
    { id = "walk", label = "Tour du véhicule (cliquer)", manual = true },
  }
end

local function end_items()
  return {
    { id = "stopped", label = "Bus à l'arrêt", check = function() return math.abs(omsi.speed()) < 1 end },
    { id = "empty", label = "Plus aucun passager à bord", check = function()
        local n = omsi.bus.passengers()
        if n == nil then return nil end
        return n == 0
      end },
    { id = "handbrake", label = "Frein de stationnement serré", check = function() return omsi.bus.handbrake() end },
    { id = "doors", label = "Portes fermées", check = function()
        local open = omsi.bus.doors_open()
        if open == nil then return nil end
        return not open
      end },
    { id = "lights", label = "Feux éteints", check = function()
        local h = omsi.bus.headlights()
        if h == nil then return nil end
        return h == 0
      end },
    { id = "engine", label = "Moteur coupé", check = function()
        local r = omsi.bus.engine_running()
        if r == nil then return nil end
        return not r
      end },
    { id = "electrics", label = "Électricité coupée", check = function()
        local e = omsi.bus.electrics()
        if e == nil then return nil end
        return not e
      end },
  }
end

-- Le panneau -----------------------------------------------------------------------------

local function count_done()
  local done = 0
  for _, item in ipairs(list.items) do
    if item.ok then done = done + 1 end
  end
  return done
end

local function show_panel()
  if not list then
    ui.remove(PANEL)
    return
  end
  local done, total = count_done(), #list.items
  local title = list.kind == "start" and "Prise de service" or "Remisage du bus"
  local children = {
    { type = "row", children = {
      { type = "icon", name = list.kind == "start" and "departure_board" or "garage", color = "#F47F30" },
      { type = "text", text = title, size = 16, weight = "bold", grow = true },
      { type = "badge", text = string.format("%d / %d", done, total), color = done == total and "#2E7D32" or "#F47F30" },
    } },
    { type = "bar", value = total > 0 and done / total or 0, color = done == total and "#34B26E" or "#F47F30" },
  }
  for _, item in ipairs(list.items) do
    local color = item.ok and "#E8EAED" or "#9AA0A6"
    local row = { type = "row", id = item.manual and ("item_" .. item.id) or nil, clickable = item.manual or nil, children = {
      { type = "icon", name = item.ok and "check_circle" or "stop_circle", size = 18,
        color = item.ok and "#34B26E" or (item.na and "#5F6368" or "#9AA0A6") },
      { type = "text", text = item.label .. (item.na and " (non disponible)" or ""), color = color, grow = true, wrap = false },
    } }
    if item.detail and not item.ok then
      row.children[#row.children + 1] = { type = "text", text = item.detail, size = 12, color = "#F4B400" }
    end
    children[#children + 1] = row
  end
  if list.kind == "start" and list.warned then
    children[#children + 1] = { type = "box", color = "#FF5F57", children = {
      { type = "text", text = "Départ avant la fin de la checklist !", size = 13 },
    } }
  end
  children[#children + 1] = { type = "row", children = {
    { type = "text", text = "Durée : " .. fmt.duration(omsi.time() - list.started), size = 12, color = "#9AA0A6", grow = true },
    { type = "button", id = "close", text = "Fermer", icon = "close" },
  } }
  ui.set(PANEL, {
    anchor = "top_right", x = 16, y = 220, width = 330, accent = "#F47F30",
    draggable = true, grab = true, children = children,
  })
end

local function open(kind)
  seen = {}
  list = { kind = kind, items = kind == "start" and start_items() or end_items(), started = omsi.time() }
  show_panel()
end

local function close()
  list = nil
  show_panel()
end

local function complete()
  local took = omsi.time() - list.started
  if list.kind == "start" then
    stats.done = stats.done + 1
    stats.total_time = stats.total_time + took
    local record = not list.warned and (stats.best == nil or took < stats.best)
    if record then stats.best = took end
    ui.toast(string.format("Checklist validée en %s%s. Bonne route !", fmt.duration(took), record and " (record)" or ""),
      { title = "Prise de service", icon = "check_circle", color = "#34B26E", seconds = 6 })
  else
    stats.parked = stats.parked + 1
    ui.toast("Le bus est remisé correctement. Fin de service !",
      { title = "Remisage", icon = "garage", color = "#34B26E", seconds = 6 })
  end
  omsi.storage.set("stats", stats)
  omsi.storage.save()
  list.done_at = omsi.time()
  show_panel()
  omsi.after(4, function()
    if list and list.done_at then close() end
  end)
end

-- Mise à jour ----------------------------------------------------------------------------

local last_block = -100

omsi.every(0.5, function()
  if not list or list.done_at then return end
  if not omsi.has_vehicle() then close() return end

  for _, item in ipairs(list.items) do
    if not item.manual and not (item.sticky and item.ok) then
      local ok, result = pcall(item.check, item)
      if not ok then
        result = nil
      end
      if result == nil then
        item.ok, item.na = true, true   -- le bus ne le montre pas : on ne bloque pas dessus
      else
        item.ok, item.na = result == true, false
      end
    end
  end

  -- Un départ avant la fin de la checklist
  if list.kind == "start" and math.abs(omsi.speed()) > 3 and count_done() < #list.items then
    if not list.warned then
      list.warned = true
      stats.early = stats.early + 1
      omsi.storage.set("stats", stats)
      omsi.game.notify("Vous partez avant d'avoir terminé la checklist de prise de service.", "warning", 6)
    end
    if settings.bloquer and omsi.bus.handbrake() == false and omsi.time() - last_block > 10 then
      last_block = omsi.time()
      omsi.bus.toggle_handbrake()
      omsi.message("Frein de stationnement serré : terminez la checklist.", 4)
    end
  end

  if count_done() == #list.items then
    complete()
  else
    show_panel()
  end
end)

-- Ce que le plugin doit voir passer ----------------------------------------------------------

omsi.on("indicator", function(new)
  if new == "left" then seen.left = true end
  if new == "right" then seen.right = true end
end)
omsi.on("horn", function(down) if down then seen.horn = true end end)
omsi.on("engine_start", function() engine_since = omsi.time() end)
omsi.on("engine_stop", function() engine_since = nil end)

omsi.on("vehicle", function(name)
  engine_since = omsi.bus.engine_running() and omsi.time() - 3600 or nil
  if not name then close() return end
  if settings.auto and omsi.bus.engine_running() == false then open("start") end
end)

omsi.on("duty_start", function()
  if not list and settings.auto then open("start") end
end)

omsi.on("duty_end", function()
  if settings.fin_service and omsi.has_vehicle() then open("end") end
end)

omsi.on("ui_click", function(panel, element)
  if panel ~= PANEL or not list then return end
  if element == "close" then close() return end
  for _, item in ipairs(list.items) do
    if item.manual and element == "item_" .. item.id then
      item.ok = not item.ok
      show_panel()
    end
  end
end)

local function toggle()
  if list then close() else open("start") end
end

omsi.input.hotkey("Ctrl+KeyJ", toggle)
ui.set_menu_item("checklist", "Checklist de prise de service", "departure_board")
ui.set_menu_item("remisage", "Checklist de remisage", "garage")
omsi.on("menu_item", function(id)
  if id == "checklist" then open("start") end
  if id == "remisage" then open("end") end
end)

-- Au chargement, le joueur est peut-être déjà dans un bus.
if omsi.has_vehicle() and omsi.bus.engine_running() then engine_since = omsi.time() - 3600 end
