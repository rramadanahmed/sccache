#include "pch.h"
struct PublicBeta {
    double data[3];
};
PublicBeta public_beta{{19.0}};
int public_a();
int main() {
    return public_a() == 13 && public_beta.data[0] == 19.0
        && sizeof(PublicBeta) == 24 ? 0 : 1;
}
