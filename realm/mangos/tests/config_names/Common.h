#pragma once
#include <cstdint>
#include <cstdio>
typedef int32_t int32;
struct FakeLog { template<class... A> void outString(const char* f, A... a) { std::printf(f, a...); std::printf("\n"); } };
static FakeLog sLog;
