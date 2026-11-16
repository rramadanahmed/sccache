#include "pch.h"
int public_a();
int main() { return public_a() == PUBLIC_PCH_VALUE + 4 ? 0 : 1; }
