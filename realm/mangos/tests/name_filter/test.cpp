#include "OpenVanilla/NameFilter.h"
#include <cstdio>
int fails=0;
void e(const char* n, bool want){ bool got=OwNames::IsBlockedAscii(n); if(got!=want){printf("FAIL %s want %d\n",n,want);fails++;} }
int main(){
 const char* bad[]={"fuck","fuuuuck","shithead","biggnigger","faggot","hitlerx","assholes","cunty","peacockcock","ass","cum","rape","nazi","bitchy","zorkman","badword"};
 const char* ok[]={"cassandra","peacock","hancock","scunthorpe","raccoon","grape","drape","cumbria","bassett","dickens","therapist","magnus","torpedo","montenegro","swanky","shitake","orion","fenz","kardrak","bingus","analise","assassin","classic","tyrande","arthas","cocoon","isis","homer","titus","spicy","hello"};
 for(auto n:bad) e(n,true); for(auto n:ok) e(n,false);
 printf("%d fails\n",fails); return fails;}
