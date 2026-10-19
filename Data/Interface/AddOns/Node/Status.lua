-- The Open Vanilla launcher overwrites this file (launcher/p2p/node.py, write_game_status) whenever your
-- node changes state, and the game picks it up the next time it starts. This shipped copy means
-- "no report yet".
OpenVanillaNode_Status = {
    state = "unknown",
    source = "shipped",
}
