#include <optional>
#include "Config.h"
#include <cassert>
#include <fstream>
#include <iostream>
int main() {
    { std::ofstream f("t.conf"); f << "Rate.Rest = 1\nOpenVanilla.Transmog = 0\nOpenVanilla.Transmog = 1\nOpenVanilla.Warfront.BotFill.Hours = \"2-14\"\nOpenVanilla.AoeLoot = 1\n"; }
    Config c; assert(c.SetSource("t.conf", "Mangosd_"));
    assert(c.GetBoolDefault("OpenVanilla.Transmog", false) == true);            // new spelling wins
    assert(c.GetStringDefault("OpenVanilla.Warfront.BotFill.Hours", "") == "2-14");
    assert(c.GetBoolDefault("OpenVanilla.AoeLoot", false) == true);              // old spelling still works
    assert(c.GetIntDefault("Rate.Rest", 0) == 1);
    { std::ofstream f("t.conf"); f << "OpenVanilla.Transmog = 1\nOpenVanilla.Transmog = 0\n"; }
    assert(c.Reload()); assert(c.GetBoolDefault("OpenVanilla.Transmog", false) == true);  // whatever the order
    std::cout << "config aliases ok\n";
}
