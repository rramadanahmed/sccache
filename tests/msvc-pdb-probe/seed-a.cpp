#include "pch.h"
struct PublicAlpha {
    long long data[17];
};
PublicAlpha public_alpha{{13}};
int public_a() { return static_cast<int>(public_alpha.data[0]); }
