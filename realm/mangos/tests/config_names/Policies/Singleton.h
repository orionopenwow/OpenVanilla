#pragma once
namespace MaNGOS { template<class T> struct Singleton { static T& Instance() { static T t; return t; } }; }
#define INSTANTIATE_SINGLETON_1(x)
