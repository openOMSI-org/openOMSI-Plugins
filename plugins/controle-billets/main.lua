-- Contrôle des titres de transport
--
-- Certains passagers montent sans titre valable (des fraudeurs). Le chauffeur peut lancer un
-- contrôle quand le bus est à l'arrêt : chaque passager à bord est vérifié, un fraudeur paie
-- une amende ou refuse de payer. Un contrôleur peut aussi monter de temps en temps et relever
-- les fraudeurs que le chauffeur n'a pas vus.
--
-- Ctrl+B montre ou cache la caisse, Ctrl+K lance un contrôle. Les boutons de la caisse
-- répondent au clic directement. La caisse est aussi dans le menu pause (Échap).

local fmt, ui = omsi.fmt, omsi.ui

local PANEL = "caisse"
local TAG_FRAUD = "cb_fraude"
local TAG_OK = "cb_ok"

local settings = omsi.plugin.settings({
  { key = "fraude_pct", type = "number", label = "Part de fraudeurs (%)", default = 8, min = 0, max = 50, step = 1 },
  { key = "amende", type = "number", label = "Montant de l'amende", default = 50, min = 0, max = 200, step = 5 },
  { key = "refus_pct", type = "number", label = "Fraudeurs qui refusent de payer (%)", default = 15, min = 0, max = 100, step = 5 },
  { key = "duree", type = "number", label = "Secondes par passager contrôlé", default = 3, min = 1, max = 10, step = 1 },
  { key = "inspecteur", type = "bool", label = "Un contrôleur monte parfois", default = true },
  { key = "inspecteur_pct", type = "number", label = "Chance d'un contrôleur à chaque arrêt (%)", default = 5, min = 1, max = 50, step = 1 },
  { key = "devise", type = "choice", label = "Devise", choices = { "€", "CHF", "zł", "£", "$" }, default = "€" },
}, "Contrôle des titres")

omsi.on("setting", function(key, value) settings[key] = value end)

-- Ce que le plugin sait des passagers : id -> { fraud, checked }
local known = {}
local aboard = {}        -- id -> true, au dernier relevé
local aboard_count = 0

local function new_session()
  return {
    tickets = 0, takings = 0,       -- billets vendus et recette
    checked = 0,                    -- passagers contrôlés
    caught = 0, fines = 0,          -- amendes payées et leur montant
    refused = 0,                    -- fraudeurs qui ont refusé de payer
    missed = 0,                     -- fraudeurs descendus sans être vus
    inspector = 0,                  -- fraudeurs trouvés par un contrôleur
    frauds = 0,                     -- fraudeurs montés (le chauffeur ne le voit pas)
  }
end

local session = new_session()
local totals = omsi.storage.get("totals") or { duties = 0, takings = 0, fines = 0, caught = 0, missed = 0, inspector = 0 }

local control = nil       -- contrôle en cours : { queue, index, found }
local inspector_on = false

local function money(x) return fmt.money(x, settings.devise) end

local function vigilance()
  local seen = session.caught + session.refused
  local all = seen + session.missed + session.inspector
  if all == 0 then return nil end
  return math.floor(seen * 100 / all + 0.5)
end

local function unchecked_aboard()
  local n = 0
  for id in pairs(aboard) do
    local k = known[id]
    if not (k and k.checked) then n = n + 1 end
  end
  return n
end

-- La caisse -------------------------------------------------------------------------------

local function line(label, value, id, color)
  return { type = "row", align = "between", children = {
    { type = "text", text = label, color = "#C8C8C8" },
    { type = "text", id = id, text = value, weight = "bold", color = color },
  } }
end

local function status_text()
  if control then
    return string.format("Contrôle en cours : %d / %d", control.index - 1, #control.queue)
  end
  if inspector_on then return "Un contrôleur est à bord" end
  return "Prêt"
end

local function show_panel()
  local v = vigilance()
  ui.set(PANEL, {
    anchor = "top_left", x = 16, y = 120, width = 300, accent = "#3D8BFF", draggable = true, grab = true,
    visible = omsi.data.panel_visible ~= false,
    children = {
      { type = "row", children = {
        { type = "icon", name = "confirmation_number", color = "#3D8BFF" },
        { type = "text", text = "Contrôle des titres", size = 16, weight = "bold", grow = true },
        { type = "badge", id = "takings", text = money(session.takings + session.fines), color = "#2E7D32" },
      } },
      { type = "text", id = "status", text = status_text(), color = control and "#F4B400" or "#9AA0A6" },
      { type = "divider" },
      line("Billets vendus", string.format("%d (%s)", session.tickets, money(session.takings)), "tickets"),
      line("Passagers contrôlés", tostring(session.checked), "checked"),
      line("Amendes payées", string.format("%d (%s)", session.caught, money(session.fines)), "fines"),
      line("Refus de payer", tostring(session.refused), "refused", session.refused > 0 and "#FF8A65" or nil),
      line("Non contrôlés à bord", tostring(unchecked_aboard()), "unchecked"),
      line("Vigilance", v and (v .. " %") or "-", "vigilance", v and (v >= 70 and "#34B26E" or "#FF5F57") or nil),
      { type = "row", children = {
        { type = "button", id = "control", text = control and "Arrêter" or "Contrôler", icon = "badge", grow = true },
        { type = "button", id = "hide", text = "Cacher", icon = "close" },
      } },
    },
  })
end

local function set_visible(on)
  omsi.data.panel_visible = on
  ui.show(PANEL, on)
end

-- Le contrôle ----------------------------------------------------------------------------

local function stopped()
  return math.abs(omsi.speed() or 0) < 1
end

local function finish_control(reason)
  if not control then return end
  local c = control
  control = nil
  if reason then
    ui.toast(reason, { title = "Contrôle interrompu", icon = "warning", color = "#F4B400" })
  else
    ui.toast(string.format("%d passager(s) contrôlé(s), %d en fraude", c.index - 1, c.found),
      { title = "Contrôle terminé", icon = "check_circle", color = "#34B26E" })
  end
  show_panel()
end

local function check_next()
  if not control then return end
  if not stopped() then
    finish_control("Le bus roule : le contrôle se fait à l'arrêt.")
    return
  end
  local id = control.queue[control.index]
  if not id then
    finish_control()
    return
  end
  control.index = control.index + 1
  local k = known[id]
  if k and aboard[id] and not k.checked then
    k.checked = true
    session.checked = session.checked + 1
    if k.fraud then
      control.found = control.found + 1
      if omsi.util.random() * 100 < settings.refus_pct then
        session.refused = session.refused + 1
        ui.toast("Le passager refuse de payer. Signalement enregistré.",
          { title = "Fraude", icon = "error", color = "#FF5F57" })
      else
        session.caught = session.caught + 1
        session.fines = session.fines + settings.amende
        ui.toast("Amende de " .. money(settings.amende) .. " encaissée.",
          { title = "Fraude", icon = "payments", color = "#F4B400" })
      end
    end
  end
  show_panel()
  omsi.after(settings.duree, check_next)
end

local function start_control()
  if control then
    finish_control("Arrêté par le chauffeur.")
    return
  end
  if not omsi.has_vehicle() then return end
  if not stopped() then
    omsi.message("Arrêtez le bus pour contrôler les titres.", 3)
    return
  end
  local queue = {}
  for id in pairs(aboard) do
    local k = known[id]
    if k and not k.checked then queue[#queue + 1] = id end
  end
  if #queue == 0 then
    omsi.message("Tous les passagers à bord ont déjà été contrôlés.", 3)
    return
  end
  control = { queue = queue, index = 1, found = 0 }
  ui.toast(string.format("%d passager(s) à contrôler, environ %s.", #queue, fmt.duration(#queue * settings.duree)),
    { title = "Contrôle des titres", icon = "badge" })
  show_panel()
  omsi.after(settings.duree, check_next)
end

-- Le contrôleur --------------------------------------------------------------------------

local function inspector_check()
  inspector_on = false
  local found = 0
  for id in pairs(aboard) do
    local k = known[id]
    if k and k.fraud and not k.checked then
      k.checked = true
      found = found + 1
    end
  end
  session.inspector = session.inspector + found
  if found > 0 then
    ui.toast(string.format("Le contrôleur a trouvé %d fraudeur(s) que vous n'aviez pas contrôlé(s).", found),
      { title = "Rapport du contrôleur", icon = "badge", color = "#FF8A65", seconds = 8 })
  else
    ui.toast("Aucune fraude trouvée. Bon travail !",
      { title = "Rapport du contrôleur", icon = "emoji_events", color = "#34B26E", seconds = 6 })
  end
  show_panel()
end

omsi.on("stop_arrive", function()
  if not settings.inspecteur or inspector_on then return end
  if omsi.util.random() * 100 < settings.inspecteur_pct then
    inspector_on = true
    ui.toast("Un contrôleur monte à bord.", { title = "Contrôle", icon = "badge", seconds = 5 })
    show_panel()
    omsi.after(45, inspector_check)
  end
end)

-- Les passagers --------------------------------------------------------------------------

omsi.on("passenger_ticket", function(p)
  local fraud = false
  if (p.kind == "buy" or p.kind == "stamp") and omsi.util.random() * 100 < settings.fraude_pct then
    -- Il monte comme s'il avait un abonnement, mais il n'en a pas.
    fraud = omsi.people.set_ticket(p.id, { kind = "none", tag = TAG_FRAUD }) == true
  end
  if not fraud then omsi.people.set_ticket(p.id, { tag = TAG_OK }) end
  known[p.id] = { fraud = fraud, checked = false }
  if fraud then session.frauds = session.frauds + 1 end
end)

omsi.on("ticket_sold", function(_, price)
  session.tickets = session.tickets + 1
  session.takings = session.takings + (price or 0)
  show_panel()
end)

-- Qui est à bord : relevé chaque seconde, pour voir qui descend sans avoir été contrôlé.
omsi.every(1, function()
  if not omsi.has_vehicle() then return end
  local now, count = {}, 0
  for _, p in ipairs(omsi.people.list(40)) do
    if p.aboard then
      now[p.id] = true
      count = count + 1
      if not known[p.id] then
        known[p.id] = { fraud = p.tag == TAG_FRAUD, checked = false }
      end
    end
  end
  for id in pairs(aboard) do
    if not now[id] then
      local k = known[id]
      if k and k.fraud and not k.checked then session.missed = session.missed + 1 end
      known[id] = nil
    end
  end
  aboard = now
  if count ~= aboard_count then
    aboard_count = count
    ui.update(PANEL, "unchecked", { text = tostring(unchecked_aboard()) })
  end
end)

-- Fin de service : bilan et historique ----------------------------------------------------

local function save_history(line_name, tour)
  totals.duties = totals.duties + 1
  totals.takings = totals.takings + session.takings
  totals.fines = totals.fines + session.fines
  totals.caught = totals.caught + session.caught
  totals.missed = totals.missed + session.missed
  totals.inspector = totals.inspector + session.inspector
  omsi.storage.set("totals", totals)
  omsi.storage.save()

  if not omsi.files.exists("historique.csv") then
    omsi.files.write("historique.csv", "date;ligne;service;billets;recette;controles;amendes;montant_amendes;refus;manques;controleur\n")
  end
  local d = omsi.util.date()
  omsi.files.append("historique.csv", string.format("%04d-%02d-%02d %02d:%02d;%s;%s;%d;%.2f;%d;%d;%.2f;%d;%d;%d\n",
    d.year, d.month, d.day, d.hour, d.minute, tostring(line_name or "-"), tostring(tour or "-"),
    session.tickets, session.takings, session.checked, session.caught, session.fines,
    session.refused, session.missed, session.inspector))
end

omsi.on("duty_end", function(line_name, tour)
  if session.tickets + session.checked + session.missed > 0 then
    save_history(line_name, tour)
    local v = vigilance()
    ui.toast(string.format("Recette %s, amendes %s, %d fraudeur(s) non vu(s). Vigilance : %s.",
      money(session.takings), money(session.fines), session.missed + session.inspector, v and (v .. " %") or "-"),
      { title = "Bilan du service", icon = "receipt_long", seconds = 12 })
  end
  session = new_session()
  show_panel()
end)

-- Touches, menu, panneau ------------------------------------------------------------------

omsi.input.hotkey("Ctrl+KeyB", function() omsi.data.panel_visible = ui.toggle(PANEL) end)
omsi.input.hotkey("Ctrl+KeyK", start_control)

ui.set_menu_item("caisse", "Caisse et contrôle des titres", "confirmation_number")
omsi.on("menu_item", function(id)
  if id == "caisse" then
    set_visible(true)
  end
end)

omsi.on("ui_click", function(panel, element)
  if panel ~= PANEL then return end
  if element == "control" then start_control()
  elseif element == "hide" then set_visible(false) end
end)

omsi.on("vehicle", function()
  known, aboard, aboard_count = {}, {}, 0
  control = nil
  show_panel()
end)

show_panel()
