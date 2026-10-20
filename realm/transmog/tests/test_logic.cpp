// Transmog's pure rules (OpenVanilla/TransmogLogic.cpp): run_logic_tests.sh builds and runs this.
#include "OpenVanilla/Transmog.h"

#include <cstdio>
#include <string>
#include <vector>

static int g_pass = 0, g_fail = 0;
#define CHECK(cond) do { if (cond) ++g_pass; else { ++g_fail; std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

using namespace Transmog;

int main()
{
    // groups: chest and robe are one; neck, rings and misc weapons have no look
    CHECK(LookGroup(4, 1, 5) == LookGroup(4, 4, 20));
    CHECK(LookGroup(4, 0, 2) == 0);                       // neck
    CHECK(LookGroup(4, 0, 11) == 0);                      // finger
    CHECK(LookGroup(2, 14, 13) == 0);                     // miscellaneous weapon
    CHECK(LookGroup(4, 6, 14) == 12);                     // shield
    // weapons: retail's groups
    CHECK(LookFits(2, 3, 26, 2, 2, 15));                  // gun takes a bow look
    CHECK(LookFits(2, 2, 15, 2, 18, 26));                 // bow takes a crossbow look
    CHECK(LookFits(2, 10, 17, 2, 6, 17));                 // staff takes a polearm look
    CHECK(LookFits(2, 0, 13, 2, 13, 13));                 // one-hand axe takes a fist weapon look
    CHECK(!LookFits(2, 0, 13, 2, 15, 13));                // ... not a dagger look
    CHECK(!LookFits(2, 10, 17, 2, 7, 13));                // a staff can't look like a one-hand sword
    CHECK(LookFits(2, 19, 26, 2, 15, 13));                // a wand takes a dagger look
    CHECK(LookFits(2, 19, 26, 2, 7, 21));                 // ... a one-hand sword
    CHECK(LookFits(2, 19, 26, 2, 4, 13));                 // ... a one-hand mace
    CHECK(!LookFits(2, 19, 26, 2, 0, 13));                // ... not an axe
    CHECK(!LookFits(2, 15, 13, 2, 19, 26));               // and a dagger never looks like a wand
    CHECK(!LookFits(4, 6, 14, 4, 0, 23));                 // shield vs held in off hand
    CHECK(!LookFits(4, 1, 1, 4, 1, 3));                   // head vs shoulders
    // slots
    CHECK(LookFitsSlot(4, 20) && LookFitsSlot(4, 5));
    CHECK(LookFitsSlot(15, 17) && !LookFitsSlot(16, 17)); // two-hander: main hand only
    CHECK(LookFitsSlot(16, 13) && LookFitsSlot(16, 14) && LookFitsSlot(16, 23));
    CHECK(LookFitsSlot(17, 26) && !LookFitsSlot(17, 13));
    CHECK(!LookFitsSlot(1, 2) && !LookFitsSlot(12, 12));  // neck, trinket
    CHECK(Hideable(0) && Hideable(6) && Hideable(18) && !Hideable(15) && !Hideable(1));
    CHECK(TransmogSlot(17) && !TransmogSlot(10) && !TransmogSlot(13));
    int hideable = 0;
    for (int s = 0; s < 19; ++s) hideable += Hideable(uint8(s)) ? 1 : 0;
    CHECK(hideable == 11);                                // retail's eleven
    // armor type
    CHECK(ClassArmor(1) == 4 && ClassArmor(3) == 3 && ClassArmor(4) == 2 && ClassArmor(8) == 1 && ClassArmor(11) == 2);
    CHECK(ArmorTypeMatters(4, 3, 5));
    CHECK(!ArmorTypeMatters(4, 1, 16));                   // cloaks: any class
    CHECK(!ArmorTypeMatters(4, 0, 4) && !ArmorTypeMatters(4, 1, 4));   // shirts
    CHECK(!ArmorTypeMatters(4, 0, 19));                   // tabards
    CHECK(!ArmorTypeMatters(4, 6, 14));                   // shields
    // prices: retail's list at 0.01 (100 gold there = 1 gold here)
    CHECK(UnlockPrice(1, 0.01) == 0 && UnlockPrice(2, 0.01) == 0);
    CHECK(UnlockPrice(3, 0.01) == 10000);
    CHECK(UnlockPrice(10, 0.01) == 500000);
    CHECK(UnlockPrice(11, 0.01) == 1000000 && UnlockPrice(15, 0.01) == 1000000);
    CHECK(UnlockPrice(50, 0.01) == 10000000);
    uint64 total20 = 0;
    for (uint32 n = 1; n <= 20; ++n) total20 += UnlockPrice(n, 1.0);
    CHECK(total20 == uint64(162650) * 10000);             // retail: 162,650 gold for 20
    CHECK(ChangeCost(0, 0.01) == 100);                    // at least 1 silver
    CHECK(ChangeCost(50000, 0.01) == 25000);              // half the vendor price
    CHECK(IllusionCost(0.01) == 15000);
    // looks
    std::vector<SlotLook> v;
    CHECK(ParseLooks("4:2470:0,0:-1:0,15:19364:1900", v) && v.size() == 3 && v[1].look == -1 && v[2].illusion == 1900);
    CHECK(FormatLooks(v) == "4:2470:0,0:-1:0,15:19364:1900");
    CHECK(ParseLooks("", v) && v.empty());
    CHECK(!ParseLooks("4:1:0,4:2:0", v));                 // the same slot twice
    CHECK(!ParseLooks("1:100:0", v));                     // neck
    CHECK(!ParseLooks("4:-2:0", v));
    CHECK(!ParseLooks("4:1", v) && !ParseLooks("4:1:0:9", v) && !ParseLooks("x", v));
    CHECK(ParseLooks("4:1:0/5:2:0", v, '/') && v.size() == 2);
    // names
    CHECK(CleanName("  Court  Robes!! ") == "Court Robes");
    CHECK(CleanName("<>{}").empty());
    CHECK(CleanName(std::string(40, 'a')).size() == 24);
    // situations: all chosen categories must match, any option within one
    CHECK(!SituationMatch(0, SIT_ALL));
    CHECK(SituationMatch(SIT_RESTING, SIT_RESTING | SIT_ON_FOOT));
    CHECK(SituationMatch(SIT_RESTING | SIT_DUNGEON, SIT_DUNGEON | SIT_MOUNTED));
    CHECK(!SituationMatch(SIT_DUNGEON | SIT_ON_FOOT, SIT_DUNGEON | SIT_MOUNTED));
    CHECK(SituationMatch(SIT_NIGHT | SIT_RAIN | SIT_SPEC2, SIT_NIGHT | SIT_RAIN | SIT_SPEC2 | SIT_WORLD));
    CHECK(!SituationMatch(SIT_NIGHT | SIT_RAIN, SIT_NIGHT | SIT_CLEAR));
    CHECK(TimeOfDayBit(6) == SIT_MORNING && TimeOfDayBit(10) == SIT_MORNING && TimeOfDayBit(11) == SIT_MIDDAY);
    CHECK(TimeOfDayBit(17) == SIT_EVENING && TimeOfDayBit(21) == SIT_NIGHT && TimeOfDayBit(3) == SIT_NIGHT);
    std::printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
