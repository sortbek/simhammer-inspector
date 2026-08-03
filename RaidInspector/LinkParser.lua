local addonName, ns = ...

local LinkParser = {}
ns.LinkParser = LinkParser

-- Splitst de payload op dubbele punten en behoudt lege velden. Het toevoegen
-- van een afsluitende ":" zorgt dat ook het laatste veld gevonden wordt.
local function splitFields(payload)
  local fields, n = {}, 0
  for field in string.gmatch(payload .. ":", "([^:]*):") do
    n = n + 1
    fields[n] = field
  end
  fields.n = n
  return fields
end

local function num(fields, index)
  return tonumber(fields[index]) or 0
end

function LinkParser.parse(link)
  if type(link) ~= "string" or link == "" then return nil end

  local payload = string.match(link, "|Hitem:([^|]+)|h")
                  or string.match(link, "^item:(.+)$")
  if not payload then return nil end

  local f = splitFields(payload)
  if num(f, 1) == 0 then return nil end

  local gemIDs = { num(f, 3), num(f, 4), num(f, 5), num(f, 6) }
  local gemCount = 0
  for i = 1, 4 do
    if gemIDs[i] ~= 0 then gemCount = gemCount + 1 end
  end

  local bonusIDs, modifiers = {}, {}

  local bonusCount = num(f, 13)
  for i = 1, bonusCount do
    bonusIDs[i] = num(f, 13 + i)
  end

  -- modCount telt het aantal PAREN, niet het aantal velden. Dat verschil is de
  -- meest gemaakte fout bij dit formaat.
  local modCountIndex = 13 + bonusCount + 1
  local modCount = num(f, modCountIndex)
  for i = 1, modCount do
    local typeIndex  = modCountIndex + (i - 1) * 2 + 1
    local valueIndex = typeIndex + 1
    local modType = num(f, typeIndex)
    if modType ~= 0 then
      modifiers[modType] = num(f, valueIndex)
    end
  end

  return {
    itemID      = num(f, 1),
    enchantID   = num(f, 2),
    gemIDs      = gemIDs,
    gemCount    = gemCount,
    suffixID    = num(f, 7),
    linkLevel   = num(f, 9),
    specID      = num(f, 10),
    itemContext = num(f, 12),
    bonusIDs    = bonusIDs,
    modifiers   = modifiers,
  }
end
