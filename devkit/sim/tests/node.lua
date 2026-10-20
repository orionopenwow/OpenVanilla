-- Node: the Esc menu's "Become a Node" button and window (Node/Node.lua), the launcher's status
-- report (Node/Status.lua, written by launcher/p2p/node.py), /node.
local T, api = ...

local function report(env, st)
    st.source = "launcher"
    env.OpenVanillaNode_Status = st
    env.OpenVanillaNode:Refresh()
end

T.test("Node: the Esc menu gets Become a Node in the suite buttons, above Log Out; it opens the window", function()
    local env = T.addon("Node")
    env.GameMenuFrame:Show()
    local btn = env.GameMenuButtonNode
    T.ok(btn, "the button exists")
    T.eq(btn:GetText(), "Become a Node")
    T.eq(env.GameMenuButtonAddOns:GetText(), "AddOns", "WenillaCore's AddOns button is still there")
    local _, anchor = btn:GetPoint(1)
    T.eq(anchor, env.GameMenuButtonOVSupport, "last of the suite's buttons, under Support")
    local _, below = env.GameMenuButtonLogout:GetPoint(1)
    T.eq(below, btn, "Log Out moves under it")
    api.click(btn)
    T.hidden(env.GameMenuFrame, "the Esc menu closes")
    local f = env.OpenVanillaNodeFrame
    T.shown(f, "the window opens")
    for _, needle in ipairs({ "WHAT A NODE IS", "PRIVACY AND SAFETY", "HOW TO TURN IT ON", "HOW TO TURN IT OFF",
        "HOST > Become a node", "TURN OFF", "never shares Blizzard", "can't read chat", "they never see each other's",
        "does not make one realm bigger" }) do
        T.ok(api.screen_has(env, needle, f), "shows: " .. needle)
    end
    T.ok(api.press_escape(env), "Escape closes it")
    T.hidden(f)
end)

T.test("Node: without a launcher report the status says unknown, honestly", function()
    local env = T.addon("Node")
    env.__slash("/node")
    local f = env.OpenVanillaNodeFrame
    T.shown(f)
    T.ok(api.screen_has(env, "Status: unknown", f))
    T.ok(api.screen_has(env, "No report from the launcher yet", f))
    env.__slash("/node")
    T.hidden(f, "/node toggles")
end)

T.test("Node: the launcher's report shows on, verified, paused and off with its time", function()
    local env = T.addon("Node")
    env.__slash("/node")
    local f = env.OpenVanillaNodeFrame
    report(env, { state = "verified", on = true, verified = true, relayed_today_mb = 2500, daily_gb = 10, kbps = 512,
        hosts = 2, updated = "2026-10-16 14:05 UTC" })
    T.ok(api.screen_has(env, "Your node: ON (verified node", f))
    T.ok(api.screen_has(env, "Relayed today: 2.5 GB of 10 GB, up to 512 KB/s", f))
    T.ok(api.screen_has(env, "Carrying 2 realms", f))
    T.ok(api.screen_has(env, "As of 2026-10-16 14:05 UTC", f))
    T.ok(api.screen_has(env, "can't switch the node itself", f))
    report(env, { state = "pending", on = true, relayed_today_mb = 12, daily_gb = 10, kbps = 512, hosts = 1, updated = "x" })
    T.ok(api.screen_has(env, "being checked", f))
    T.ok(api.screen_has(env, "12 MB of 10 GB", f))
    T.ok(api.screen_has(env, "Carrying 1 realm.", f))
    report(env, { state = "paused", on = true, relayed_today_mb = 10000, daily_gb = 10, kbps = 512, updated = "x" })
    T.ok(api.screen_has(env, "PAUSED (daily cap reached", f))
    report(env, { state = "off", on = false, updated = "2026-10-16 15:00 UTC" })
    T.ok(api.screen_has(env, "Your node: OFF (nothing is relayed)", f))
    T.no(api.screen_has(env, "Relayed today", f))
    report(env, { state = "weird" })
    T.ok(api.screen_has(env, "Your node: OFF", f), "an unknown state reads as off")
end)

T.test("Node: loads beside the whole suite; the Esc menu keeps both buttons", function()
    local env = T.suite()
    env.GameMenuFrame:Show()
    T.eq(env.GameMenuButtonAddOns:GetText(), "AddOns")
    T.eq(env.GameMenuButtonNode:GetText(), "Become a Node")
    api.click(env.GameMenuButtonNode)
    T.shown(env.OpenVanillaNodeFrame)
end)
