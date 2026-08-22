-- tools/scan_locals.lua - the 200-register headroom check for the Tinker.lua main chunk,
-- REWRITTEN 2026-08-19. The old version re-implemented a Lua parser in string.match and its
-- "~7 error" was TWO BUGS CANCELLING: it over-counted bare forward declarations whose trailing
-- comment had no `=` (`local can_bail   -- ...` at the then-:1067), and it under-counted because a
-- one-line `local function f() ... end` (8 exist today) made the body scan swallow everything to
-- the NEXT column-0 `end`. The standing rule was already "the authority is luac -p -l -l", so this
-- version PARSES THE AUTHORITY instead of approximating it:
--   headroom = 200 - <slots>, where <slots> is the main chunk's register frame straight from the
--   luac header line ("0+ params, N slots, ..."). That is the number the compiler actually errors
--   on ("function or expression needs too many registers").
-- The lift-candidate lister below stays textual (luac does not know PURE/ENGINE/STATE), with both
-- historical bugs fixed: comments are stripped BEFORE the `=` test, and a one-line function is its
-- own body.
-- Run:  lua tools/scan_locals.lua [file]        (default Tinker/Tinker.lua)
-- luac is found via the LUAC env var, else "luac" on PATH, else the sibling of the lua running us.

local path = arg[1] or "Tinker/Tinker.lua"

-- ---- the authority: luac header + named-local intervals --------------------------------------
local luac = os.getenv("LUAC") or "luac"
local function try(cmd)
    -- Windows cmd.exe strips the FIRST and LAST quote of a popen command line, so a quoted exe
    -- path plus a quoted file argument breaks unless the whole line is wrapped in one more pair.
    local h = io.popen('"' .. cmd .. ' 2>&1"') or io.popen(cmd .. " 2>&1")
    if not h then return nil end
    local out = h:read("a"); h:close(); return out
end
local listing = try(string.format('"%s" -p -l -l "%s"', luac, path))
if not (listing and listing:find("^main <", 1, false) or (listing and listing:find("\nmain <"))) then
    -- fall back to the sibling of the interpreter (arg[-1] is how we were invoked)
    local me = arg[-1] or ""
    local sib = me:gsub("lua(%.exe)?$", "luac%1")
    if sib ~= me then listing = try(string.format('"%s" -p -l -l "%s"', sib, path)) end
end
assert(listing and listing:find("main <"), "could not run luac (set LUAC=full path to luac.exe)")

local slots = tonumber(listing:match("main <.-\n.-(%d+) slots"))
local nloc  = tonumber(listing:match("main <.-\n.-(%d+) locals"))
assert(slots, "could not parse the main-chunk header")

-- peak simultaneously-live NAMED locals (cross-check; slots also counts temporaries)
local main_locals = listing:match("\nlocals %(%d+%)[^\n]*\n(.-)\n[a-z]+s? %(") or ""
local events = {}
for s, e in main_locals:gmatch("\t%d+\t[^\t]+\t(%d+)\t(%d+)") do
    events[#events + 1] = { tonumber(s), 1 }; events[#events + 1] = { tonumber(e) + 1, -1 }
end
table.sort(events, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
local cur, peak = 0, 0
for _, ev in ipairs(events) do cur = cur + ev[2]; if cur > peak then peak = cur end end

print(string.format("%s  main chunk: %d slots of 200  ->  HEADROOM %d   (named locals %d, peak live %d)",
    path, slots, 200 - slots, nloc or -1, peak))
if 200 - slots <= 8 then
    print(">>> HEADROOM UNDER 8. No new top-level locals; extend an existing function/table instead")
    print(">>> (the standing law; the v0.1.323 helper hit this exact wall).")
end

-- ---- lift candidates: top-level `local function` bodies, classified --------------------------
local f = assert(io.open(path, "r"))
local lines = {}
for l in f:lines() do lines[#lines + 1] = l end
f:close()

local ENGINE = "NPC%.|Entity%.|Ability%.|Item%.|Hero%.|Heroes%.|Player%.|Towers%.|Map%.|Vector%(|GameRules|Menu%."
local function classify(body)
    if body:find("State%.") or body:find("Menu%.") then return "STATE" end
    for pat in ENGINE:gmatch("[^|]+") do if body:find(pat) then return "ENGINE" end end
    return "PURE"
end

local cats, decls = { PURE = {}, ENGINE = {}, STATE = {} }, 0
local i = 1
while i <= #lines do
    local l = lines[i]
    local code = l:gsub("%-%-.*$", "")                       -- strip the comment FIRST (bug 1)
    local fname = code:match("^local%s+function%s+([%w_]+)")
    if fname then
        decls = decls + 1
        local body
        if code:match("end%s*$") then                        -- one-line function IS its body (bug 2)
            body = code
        else
            local j = i + 1
            while j <= #lines and not lines[j]:match("^end%s*[%-%s]*$") do j = j + 1 end
            body = table.concat(lines, "\n", i, math.min(j, #lines))
            i = j
        end
        local c = classify(body)
        cats[c][#cats[c] + 1] = fname
    elseif code:match("^local%s+[%w_]") then
        local names = code:match("^local%s+([^=]+)")         -- names before `=`, or all of them
        local n = select(2, names:gsub("[%w_]+", "")) 
        decls = decls + n
    end
    i = i + 1
end
print(string.format("top-level declarations (textual, for ranking only): %d", decls))
for _, c in ipairs({ "PURE", "ENGINE", "STATE" }) do
    print(string.format("  %-6s %3d  %s", c, #cats[c],
        #cats[c] > 0 and table.concat(cats[c], " ", 1, math.min(#cats[c], 10))
            .. (#cats[c] > 10 and " ..." or "") or ""))
end
print("PURE functions are lib-liftable as-is; ENGINE need the API in scope; STATE stay hero-local.")
