#pragma once
#include <string>
class Config { public:
  bool GetBoolDefault(char const*, bool d) { return d; }
  std::string GetStringDefault(char const*, char const*) { return extra; }
  static std::string extra; };
inline std::string Config::extra = "Badword, zork;x";
namespace MaNGOS { template<class T> struct Singleton { static T& Instance() { static T t; return t; } }; }
